import CSPrint
import Foundation
import dnssd

/// mDNS for LAN peer printing through Bonjour (the system's mDNSResponder,
/// DNS-SD API), handed to the core as its native browser
/// (`sprint_register_scanner("mdns", …)`) and advertiser
/// (`sprint_register_mdns_advertiser`). iOS needs it: Go cannot join the
/// multicast group there and the app must hold the local-network permission
/// (NSLocalNetworkUsageDescription, NSBonjourServices `_superprinter._tcp`).
///
/// DNS-SD rather than NWBrowser / NWListener: the peer server is the core's
/// own listener, and DNS-SD advertises a port another socket owns, while
/// NWListener advertises only its own; resolving a browse result to an address
/// and port with DNS-SD does not open a connection to the peer.
final class BonjourMDNS: @unchecked Sendable {
    static let shared = BonjourMDNS()

    private let queue = DispatchQueue(label: "ca.superroute.sprint.mdns")
    /// Registrations by instance name (touched on `queue` only).
    private var registrations: [String: DNSServiceRef] = [:]
    private var waits: [String: RegisterWait] = [:]

    // MARK: browsing

    /// Browses `_superprinter._tcp` for `seconds` and answers what resolved.
    func browse(seconds: TimeInterval, serviceType: String = "_superprinter._tcp") throws -> [MDNSService] {
        let b = MDNSBrowse(queue: queue)
        let ctx = Unmanaged.passUnretained(b).toOpaque()
        let rc = queue.sync { () -> DNSServiceErrorType in
            var ref: DNSServiceRef?
            let rc = DNSServiceBrowse(&ref, 0, 0, serviceType, "local.", browseReply, ctx)
            if rc == kDNSServiceErr_NoError, let ref { b.keep(ref) }
            return rc
        }
        if rc != kDNSServiceErr_NoError { throw SPrintError(message: "mdns: browse failed (\(Self.describe(rc)))") }
        Thread.sleep(forTimeInterval: max(0.2, seconds))
        let (out, err) = queue.sync { b.close() }
        if out.isEmpty, err != kDNSServiceErr_NoError {
            throw SPrintError(message: "mdns: browse failed (\(Self.describe(err)))")
        }
        return out
    }

    // MARK: advertising

    /// Announces a service (a later call for the same instance replaces it).
    func advertise(_ s: MDNSService) throws {
        let txt = Self.encodeTXT(s.txt)
        // The wait lives as long as its registration: the daemon may answer again later.
        let wait = RegisterWait()
        let ctx = Unmanaged.passUnretained(wait).toOpaque()
        let rc = queue.sync { () -> DNSServiceErrorType in
            if let old = registrations.removeValue(forKey: s.instance) { DNSServiceRefDeallocate(old) }
            waits[s.instance] = nil
            var ref: DNSServiceRef?
            let rc = txt.withUnsafeBytes { buf in
                DNSServiceRegister(&ref, 0, 0, s.instance, s.service, s.domain.isEmpty ? nil : s.domain, nil,
                                   UInt16(clamping: s.port).bigEndian, UInt16(buf.count), buf.baseAddress,
                                   registerReply, ctx)
            }
            if rc == kDNSServiceErr_NoError, let ref {
                registrations[s.instance] = ref
                waits[s.instance] = wait
                DNSServiceSetDispatchQueue(ref, queue)
            }
            return rc
        }
        if rc != kDNSServiceErr_NoError { throw SPrintError(message: "mdns: advertise failed (\(Self.describe(rc)))") }
        // The daemon answers the registration (or a refusal, such as the
        // local-network permission denied) shortly; a slow daemon is not an error.
        _ = wait.done.wait(timeout: .now() + 3)
        let err = queue.sync { wait.error }
        if err != kDNSServiceErr_NoError {
            withdraw(s.instance)
            throw SPrintError(message: "mdns: advertise failed (\(Self.describe(err)))")
        }
    }

    /// Removes a service.
    func withdraw(_ instance: String) {
        queue.sync {
            if let ref = registrations.removeValue(forKey: instance) { DNSServiceRefDeallocate(ref) }
            waits[instance] = nil
        }
    }

    /// TXT record wire format: each entry one length byte and at most 255 bytes.
    static func encodeTXT(_ entries: [String]) -> Data {
        var d = Data()
        for e in entries {
            let b = Array(e.utf8.prefix(255))
            d.append(UInt8(b.count))
            d.append(contentsOf: b)
        }
        return d
    }

    static func decodeTXT(_ p: UnsafePointer<UInt8>?, _ len: Int) -> [String] {
        guard let p, len > 0 else { return [] }
        var out: [String] = []
        var i = 0
        while i < len {
            let n = Int(p[i])
            i += 1
            if n == 0 { continue }
            guard i + n <= len else { break }
            out.append(String(decoding: UnsafeBufferPointer(start: p + i, count: n), as: UTF8.self))
            i += n
        }
        return out
    }

    static func describe(_ rc: DNSServiceErrorType) -> String {
        switch Int(rc) {
        case Int(kDNSServiceErr_PolicyDenied): return "local network permission not granted"
        case Int(kDNSServiceErr_ServiceNotRunning): return "the mDNS service is not running"
        case Int(kDNSServiceErr_NameConflict): return "name conflict"
        default: return "DNS-SD error \(rc)"
        }
    }

    // MARK: registration with the core

    /// Makes Bonjour the core's mDNS browser and advertiser (or, with false,
    /// removes them: macOS then falls back to the core's own).
    static func register(_ on: Bool) {
        if on {
            _ = shared
            _ = sprint_register_scanner("mdns", mdnsScan, nil)
            _ = sprint_register_mdns_advertiser(mdnsAdvertise, mdnsWithdraw, nil)
        } else {
            _ = sprint_register_scanner("mdns", nil, nil)
            _ = sprint_register_mdns_advertiser(nil, nil, nil)
        }
    }
}


/// One browse: every instance seen, resolved to an address, port and TXT.
/// Touched on the DNS-SD queue only; its lookups live as long as it does.
final class MDNSBrowse: @unchecked Sendable {
    /// One instance being resolved (the context of its resolve and address lookups).
    final class Lookup: @unchecked Sendable {
        unowned let browse: MDNSBrowse
        let instance: String
        let service: String
        let domain: String
        var host = ""
        var v6 = ""
        var port = 0
        var txt: [String] = []
        var resolved = false

        init(browse: MDNSBrowse, instance: String, service: String, domain: String) {
            self.browse = browse
            self.instance = instance
            self.service = service
            self.domain = domain
        }

        var ctx: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
    }

    let queue: DispatchQueue
    private var refs: [DNSServiceRef] = []
    private var lookups: [String: Lookup] = [:]
    private var order: [String] = []
    private var error: DNSServiceErrorType = 0
    private(set) var closed = false

    init(queue: DispatchQueue) { self.queue = queue }

    func keep(_ ref: DNSServiceRef) {
        refs.append(ref)
        DNSServiceSetDispatchQueue(ref, queue)
    }

    func close() -> ([MDNSService], DNSServiceErrorType) {
        closed = true
        for r in refs { DNSServiceRefDeallocate(r) }
        refs.removeAll()
        let list = order.compactMap { lookups[$0] }.compactMap { l -> MDNSService? in
            let host = l.host.isEmpty ? l.v6 : l.host
            guard !host.isEmpty, l.port > 0 else { return nil }
            return MDNSService(instance: l.instance, service: l.service, domain: l.domain, host: host, port: l.port,
                               txt: l.txt)
        }
        return (list, error)
    }

    func found(flags: DNSServiceFlags, iface: UInt32, err: DNSServiceErrorType, name: String, type: String,
               domain: String) {
        if closed { return }
        if err != kDNSServiceErr_NoError { error = err; return }
        guard flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0, lookups[name] == nil else { return }
        let service = type.hasSuffix(".") ? String(type.dropLast()) : type
        let l = Lookup(browse: self, instance: name, service: service, domain: domain)
        lookups[name] = l
        order.append(name)
        var ref: DNSServiceRef?
        if DNSServiceResolve(&ref, 0, iface, name, type, domain, resolveReply, l.ctx) == kDNSServiceErr_NoError, let ref {
            keep(ref)
        }
    }

    func resolved(_ l: Lookup, iface: UInt32, err: DNSServiceErrorType, target: String, port: UInt16, txt: [String]) {
        if closed || err != kDNSServiceErr_NoError || l.resolved { return }
        l.resolved = true
        l.port = Int(UInt16(bigEndian: port))
        l.txt = txt
        var ref: DNSServiceRef?
        let proto = DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6)
        if DNSServiceGetAddrInfo(&ref, 0, iface, proto, target, addrReply, l.ctx) == kDNSServiceErr_NoError, let ref {
            keep(ref)
        }
    }

    private static func text(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func address(_ l: Lookup, err: DNSServiceErrorType, address: UnsafePointer<sockaddr>?) {
        guard !closed, err == kDNSServiceErr_NoError, let address else { return }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            var a = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil else { return }
            if l.host.isEmpty { l.host = Self.text(buf) }
        case AF_INET6:
            var a = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            guard inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) != nil else { return }
            let s = Self.text(buf)
            // A link-local address needs its zone, which host:port cannot carry.
            if l.v6.isEmpty, !s.lowercased().hasPrefix("fe80") { l.v6 = s }
        default: break
        }
    }
}

final class RegisterWait: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var error: DNSServiceErrorType = 0
    var answered = false

    func answer(_ err: DNSServiceErrorType) {
        error = err
        if !answered {
            answered = true
            done.signal()
        }
    }
}

// MARK: - DNS-SD callbacks (C function pointers; the context is the unretained owner)

private func str(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }

private let browseReply: DNSServiceBrowseReply = { _, flags, iface, err, name, type, domain, ctx in
    guard let ctx else { return }
    Unmanaged<MDNSBrowse>.fromOpaque(ctx).takeUnretainedValue()
        .found(flags: flags, iface: iface, err: err, name: str(name), type: str(type), domain: str(domain))
}

private let resolveReply: DNSServiceResolveReply = { _, _, iface, err, _, target, port, txtLen, txt, ctx in
    guard let ctx else { return }
    let l = Unmanaged<MDNSBrowse.Lookup>.fromOpaque(ctx).takeUnretainedValue()
    l.browse.resolved(l, iface: iface, err: err, target: str(target), port: port,
                      txt: BonjourMDNS.decodeTXT(txt, Int(txtLen)))
}

private let addrReply: DNSServiceGetAddrInfoReply = { _, _, _, err, _, address, _, ctx in
    guard let ctx else { return }
    let l = Unmanaged<MDNSBrowse.Lookup>.fromOpaque(ctx).takeUnretainedValue()
    l.browse.address(l, err: err, address: address)
}

private let registerReply: DNSServiceRegisterReply = { _, _, err, _, _, _, ctx in
    guard let ctx else { return }
    Unmanaged<RegisterWait>.fromOpaque(ctx).takeUnretainedValue().answer(err)
}

// MARK: - The core's native mDNS callbacks

private let mdnsScan: sprint_scan_cb = { ms, _ in
    let answer: String
    do {
        let list = try BonjourMDNS.shared.browse(seconds: TimeInterval(ms) / 1000)
        answer = (try? Bridge.json(["services": list])) ?? #"{"services":[]}"#
    } catch {
        answer = (try? Bridge.json(["error": String(describing: error)])) ?? #"{"error":"mdns browse failed"}"#
    }
    return strdup(answer)
}

private let mdnsAdvertise: sprint_mdns_advertise_cb = { json, err, _ in
    do {
        guard let json else { throw SPrintError(message: "mdns: no service") }
        let s = try Bridge.decode(MDNSService.self, String(cString: json))
        try BonjourMDNS.shared.advertise(s)
        return 0
    } catch {
        err?.pointee = strdup(String(describing: error))
        return 1
    }
}

private let mdnsWithdraw: sprint_mdns_withdraw_cb = { instance, _ in
    if let instance { BonjourMDNS.shared.withdraw(String(cString: instance)) }
    return 0
}

/// A DNS-SD service instance, as the core's native mDNS hooks pass it.
struct MDNSService: Codable, Sendable, Equatable {
    var instance: String
    var service: String
    var domain: String
    var host: String
    var port: Int
    var txt: [String]

    init(instance: String, service: String, domain: String, host: String = "", port: Int, txt: [String]) {
        self.instance = instance
        self.service = service
        self.domain = domain
        self.host = host
        self.port = port
        self.txt = txt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instance = try c.decodeIfPresent(String.self, forKey: .instance) ?? ""
        service = try c.decodeIfPresent(String.self, forKey: .service) ?? "_superprinter._tcp"
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? "local."
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        txt = try c.decodeIfPresent([String].self, forKey: .txt) ?? []
    }
}
