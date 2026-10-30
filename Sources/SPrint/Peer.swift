import CSPrint
import Foundation

// LAN peer printing (docs/LAN-PEER-DESIGN.md; the peer-direct protocol 1.1.0
// the SuperPrinter apps speak): a ``PeerHost`` shares this device's printers,
// ``Peers/browse(timeout:)`` lists the devices advertising on the LAN and
// ``Peers/connect(to:identity:fingerprint:password:note:pingInterval:)`` opens
// a ``PeerSession`` to another device's printers. Calls that talk to the
// network block: make them from a background task, never the main thread.

/// What a ``PeerHost`` reports while it runs.
public enum PeerHostEvent: Sendable {
    /// The state to store changed (mode, password, shared printers, trust list).
    case state(PeerHostState)
    /// A peer asks to connect (approval mode): ``PeerHost/decide(_:approve:)``.
    case pending(PeerPending)
    /// A peer was admitted.
    case connected(PeerSessionInfo)
    /// A peer's session ended (reason disconnected, revoked, expired or stopped).
    case disconnected(PeerSessionInfo, reason: String)
    /// A log line.
    case log(String)
}

/// What a ``PeerSession`` reports.
public enum PeerSessionEvent: Sendable {
    /// The peer ended the session (reason revoked, expired or unreachable).
    case ended(fingerprint: String, name: String, reason: String)
}

/// The receiver of the core's event callback; the user pointer the C side
/// carries points at it.
private final class PeerSink: @unchecked Sendable {
    let receive: @Sendable (String) -> Void
    let finish: @Sendable () -> Void

    init(receive: @escaping @Sendable (String) -> Void, finish: @escaping @Sendable () -> Void) {
        self.receive = receive
        self.finish = finish
    }

    var user: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
}

private let peerEventCallback: sprint_event_cb = { json, user in
    guard let json, let user else { return }
    Unmanaged<PeerSink>.fromOpaque(user).takeUnretainedValue().receive(String(cString: json))
}

private struct RawPeerEvent: Decodable {
    var type: String
    var state: PeerHostState?
    var pending: PeerPending?
    var peer: PeerSessionInfo?
    var fingerprint: String?
    var name: String?
    var reason: String?
    var message: String?
}

extension Bridge {
    /// A refusal's code is the bracketed suffix of the core's message ("… (BAD_PASSWORD)").
    static func peerError(_ p: UnsafeMutablePointer<CChar>?) -> SPrintError {
        let message = take(p)
        var code: String?
        if message.hasSuffix(")"), let open = message.lastIndex(of: "(") {
            let c = message[message.index(after: open)..<message.index(before: message.endIndex)]
            if !c.isEmpty, c.allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }) { code = String(c) }
        }
        return SPrintError(message: message, code: code)
    }
}

// MARK: - Identity

/// This device's identity on the LAN: an Ed25519 key whose fingerprint peers
/// pin. Store its ``seed`` (a host keeps it in ``PeerHostState/seed``).
public final class PeerIdentity: @unchecked Sendable {
    let handle: Int64

    /// A fresh identity.
    public convenience init() throws { try self.init(seedBase64: "") }

    /// The identity of a stored 32-byte seed.
    public convenience init(seed: Data) throws { try self.init(seedBase64: seed.base64EncodedString()) }

    private init(seedBase64: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let h = sprint_peer_identity_new(seedBase64, &err)
        if h == 0 { throw Bridge.error(err) }
        handle = h
    }

    deinit { sprint_peer_identity_free(handle) }

    /// The seed, to store.
    public var seed: Data { Data(base64Encoded: Bridge.take(sprint_peer_identity_seed(handle))) ?? Data() }

    /// The protocol's fingerprint ("a1b2:c3d4:…"): the first 16 bytes of
    /// SHA-256 of the public key, colon-grouped hex.
    public var fingerprint: String { Bridge.take(sprint_peer_identity_fingerprint(handle)) }
}

// MARK: - Host

/// Shares this device's printers with peers on the LAN. Off by default: it
/// listens only once started, shares only the printers named in
/// ``setShared(_:)``, and asks the owner about every new peer unless the mode
/// says otherwise. Jobs a peer sends print through ``registry`` exactly as
/// local jobs do.
public final class PeerHost: @unchecked Sendable {
    private let handle: Int64
    private let sink: PeerSink
    /// The registry whose printers may be shared.
    public let registry: PrinterRegistry
    /// The identity given at creation (nil: the state's seed, or a new one).
    public let identity: PeerIdentity?
    /// The host's events, in order.
    public let events: AsyncStream<PeerHostEvent>

    /// - Parameters:
    ///   - name: shown to peers (hello, mDNS); nil = the device's name.
    ///   - port: the server's port on every interface (0 = 17778).
    ///   - bindAddress: "host:port" listened on instead ("127.0.0.1:0": any free port).
    ///   - state: the state stored before; its seed is the identity when `identity` is nil.
    ///   - agentVersion: advertised to peers (default "sprint/<version>").
    public init(registry: PrinterRegistry, identity: PeerIdentity? = nil, name: String? = nil, port: Int = 0,
                bindAddress: String? = nil, state: PeerHostState? = nil, agentVersion: String? = nil) throws {
        struct Config: Encodable {
            var name: String?
            var port: Int
            var bind_addr: String?
            var state: PeerHostState?
            var agent_version: String?
        }
        var cont: AsyncStream<PeerHostEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1000)) { cont = $0 }
        let c = cont!
        sink = PeerSink(receive: { json in
            guard let ev = try? Bridge.decode(RawPeerEvent.self, json) else { return }
            switch ev.type {
            case "peer_state": if let s = ev.state { c.yield(.state(s)) }
            case "peer_pending": if let p = ev.pending { c.yield(.pending(p)) }
            case "peer_connected": if let p = ev.peer { c.yield(.connected(p)) }
            case "peer_disconnected": if let p = ev.peer { c.yield(.disconnected(p, reason: ev.reason ?? "")) }
            case "log": if let m = ev.message { c.yield(.log(m)) }
            default: break
            }
        }, finish: { c.finish() })
        self.registry = registry
        self.identity = identity
        let config = try Bridge.json(Config(name: name, port: port, bind_addr: bindAddress, state: state,
                                            agent_version: agentVersion))
        var err: UnsafeMutablePointer<CChar>?
        let h = sprint_peer_host_new(config, registry.handle, identity?.handle ?? 0, peerEventCallback, sink.user, &err)
        if h == 0 {
            sink.finish()
            throw Bridge.error(err)
        }
        handle = h
    }

    deinit {
        // Stops the host; no event reaches the sink after sprint_peer_host_free returns.
        sprint_peer_host_free(handle)
        sink.finish()
    }

    /// Opens the server (and advertises it when discoverable).
    public func start() throws { try Bridge.check(Bridge.take(sprint_peer_host_start(handle))) }

    /// Closes the server, withdraws the advertisement and ends every session.
    public func stop() { sprint_peer_host_stop(handle) }

    /// The access mode: ``PeerMode/open``, ``PeerMode/password`` or ``PeerMode/approval``.
    public func setMode(_ mode: String) throws { try Bridge.check(Bridge.take(sprint_peer_host_set_mode(handle, mode))) }

    /// The password of password mode (kept as a hash in the state).
    public func setPassword(_ password: String) throws {
        try Bridge.check(Bridge.take(sprint_peer_host_set_password(handle, password)))
    }

    /// The registry printers peers may see and print to (none by default).
    public func setShared(_ names: [String]) throws {
        try Bridge.check(Bridge.take(sprint_peer_host_set_shared(handle, try Bridge.json(names))))
    }

    /// Advertised over mDNS or not; browsing and connecting out are unaffected.
    public func setDiscoverable(_ on: Bool) throws {
        try Bridge.check(Bridge.take(sprint_peer_host_set_discoverable(handle, on ? 1 : 0)))
    }

    /// Approval requests waiting for the owner.
    public func pending() throws -> [PeerPending] {
        try Bridge.decode([PeerPending]?.self, Bridge.take(sprint_peer_host_pending(handle))) ?? []
    }

    /// Approves (the peer joins the trust list) or refuses a request.
    public func decide(_ requestId: String, approve: Bool) throws {
        try Bridge.check(Bridge.take(sprint_peer_host_decide(handle, requestId, approve ? 1 : 0)))
    }

    /// The connected peers.
    public func sessions() throws -> [PeerSessionInfo] {
        try Bridge.decode([PeerSessionInfo]?.self, Bridge.take(sprint_peer_host_sessions(handle))) ?? []
    }

    /// Removes a peer from the trust list and ends its sessions at once.
    public func revoke(_ fingerprint: String) throws {
        try Bridge.check(Bridge.take(sprint_peer_host_revoke(handle, fingerprint)))
    }

    /// The state to store.
    public func state() throws -> PeerHostState {
        try Bridge.decode(PeerHostState.self, Bridge.take(sprint_peer_host_state(handle)))
    }

    /// The host's status.
    public func status() throws -> PeerHostStatus {
        try Bridge.decode(PeerHostStatus.self, Bridge.take(sprint_peer_host_status(handle)))
    }

    /// The host's fingerprint, the one peers pin.
    public var fingerprint: String { (try? status().fingerprint) ?? "" }
}

// MARK: - Browsing and connecting

/// Finding and connecting to other devices' printers.
public enum Peers {
    /// The devices advertising peer printing on the LAN, listening for
    /// `timeout` seconds (0: 3 s); this process's own hosts are left out. On
    /// iOS this needs ``NativeLayer/register()`` and the local-network keys in
    /// Info.plist (see the README).
    public static func browse(timeout: TimeInterval = 3) throws -> [PeerAdvert] {
        struct R: Decodable { var peers: [PeerAdvert]?; var error: String? }
        let r = try Bridge.decode(R.self, Bridge.take(sprint_peers_browse(Int32(timeout * 1000))))
        if let e = r.error, !e.isEmpty, (r.peers ?? []).isEmpty { throw SPrintError(message: e) }
        return r.peers ?? []
    }

    /// Runs the handshake with a peer at `address` ("host:port", from
    /// ``browse(timeout:)`` or typed in). The session is connected at once
    /// (open mode, the password, or a peer that trusts this identity) or waits
    /// for the owner (``PeerSession/status()`` pending: call
    /// ``PeerSession/waitApproval(timeout:)``). A refusal throws with its code
    /// (``SPrintError/code``: BAD_PASSWORD, THROTTLED, …).
    /// - Parameters:
    ///   - fingerprint: the peer's fingerprint to pin; nil trusts the first one seen (check it by eye).
    ///   - password: the peer's password (password mode).
    ///   - note: a message for the owner (approval mode).
    ///   - pingInterval: the keepalive interval (nil: 8 s).
    public static func connect(to address: String, identity: PeerIdentity, fingerprint: String? = nil,
                               password: String? = nil, note: String? = nil,
                               pingInterval: TimeInterval? = nil) throws -> PeerSession {
        try PeerSession(address: address, identity: identity, fingerprint: fingerprint, password: password,
                        note: note, pingInterval: pingInterval)
    }
}

/// A connection to another device's shared printers. It keeps itself alive;
/// a revoke, an expiry or the peer leaving ends it with
/// ``PeerSessionEvent/ended(fingerprint:name:reason:)``.
public final class PeerSession: @unchecked Sendable {
    let handle: Int64
    private let sink: PeerSink
    /// The identity the session was opened with.
    public let identity: PeerIdentity
    /// The session's events.
    public let events: AsyncStream<PeerSessionEvent>

    fileprivate init(address: String, identity: PeerIdentity, fingerprint: String?, password: String?, note: String?,
                     pingInterval: TimeInterval?) throws {
        struct Options: Encodable {
            var addr: String
            var fingerprint: String?
            var password: String?
            var note: String?
            var ping_ms: Int?
        }
        var cont: AsyncStream<PeerSessionEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(100)) { cont = $0 }
        let c = cont!
        sink = PeerSink(receive: { json in
            guard let ev = try? Bridge.decode(RawPeerEvent.self, json), ev.type == "peer_ended" else { return }
            c.yield(.ended(fingerprint: ev.fingerprint ?? "", name: ev.name ?? "", reason: ev.reason ?? ""))
        }, finish: { c.finish() })
        self.identity = identity
        let options = try Bridge.json(Options(addr: address, fingerprint: fingerprint, password: password, note: note,
                                              ping_ms: pingInterval.map { Int($0 * 1000) }))
        var err: UnsafeMutablePointer<CChar>?
        let h = sprint_peer_connect(options, identity.handle, peerEventCallback, sink.user, &err)
        if h == 0 {
            sink.finish()
            throw Bridge.peerError(err)
        }
        handle = h
    }

    deinit {
        // Disconnects; no event reaches the sink after sprint_peer_free returns.
        sprint_peer_free(handle)
        sink.finish()
    }

    /// The session's status.
    public func status() throws -> PeerSessionStatus {
        try Bridge.decode(PeerSessionStatus.self, Bridge.take(sprint_peer_status(handle)))
    }

    /// The peer's fingerprint, as its certificate proved it.
    public var fingerprint: String { (try? status().fingerprint) ?? "" }

    /// Waits for the owner's decision (0: two minutes). Throws with code
    /// "denied" or "timeout" when the owner refused or did not answer.
    public func waitApproval(timeout: TimeInterval = 0) throws {
        struct R: Decodable { var ok: Bool?; var error: String?; var code: String? }
        let r = try Bridge.decode(R.self, Bridge.take(sprint_peer_wait_approval(handle, Int32(timeout * 1000))))
        if r.ok != true { throw SPrintError(message: r.error ?? "sprint: approval failed", code: r.code) }
    }

    /// The peer's shared printers.
    public func printers() throws -> [PeerPrinter] {
        struct R: Decodable { var printers: [PeerPrinter]?; var error: String? }
        let r = try Bridge.decode(R.self, Bridge.take(sprint_peer_printers(handle)))
        if let e = r.error, !e.isEmpty { throw SPrintError(message: e) }
        return r.printers ?? []
    }

    /// Runs a job (label, raw, PDF, HTML, image) on one of the peer's shared
    /// printers (nil: the peer's default, when it is shared).
    public func print(_ job: PrintJob, printer: String? = nil) throws -> PrintResult {
        try Bridge.decode(PrintResult.self, Bridge.take(sprint_peer_print(handle, printer ?? "", try Bridge.json(job))))
    }

    /// Ends the session from this side: the peer's owner sees it disconnect,
    /// and the trust it gave stays.
    public func disconnect() { sprint_peer_disconnect(handle) }
}

// MARK: - Registry targets

extension PrinterRegistry {
    /// Makes a connected peer's shared printers targets of the registry, named
    /// "peer:<fingerprint>/<printer>", so a job (or a print node's cloud job)
    /// to them goes to the peer. The list is read now: attach again to refresh it.
    public func attachPeer(_ session: PeerSession) throws {
        try Bridge.check(Bridge.take(sprint_registry_attach_peer(handle, session.handle)))
    }

    /// Removes a peer's printers from the registry's targets.
    public func detachPeer(fingerprint: String) { sprint_registry_detach_peer(handle, fingerprint) }

    /// The registry target name of a peer's printer.
    public static func peerTargetName(fingerprint: String, printer: String) -> String {
        "peer:\(fingerprint.trimmingCharacters(in: .whitespaces).lowercased())/\(printer)"
    }
}
