#if os(iOS)
import CSPrint
import CoreBluetooth
import Foundation

/// Bluetooth LE printing on iOS (CoreBluetooth), as superprinter_flutter does it
/// (SuperDepot iOS): every device is scanned (no service filter), the write and
/// status characteristics are chosen by GattChoice (0xFF02 / 0xFF03 under the
/// 0xFF00 print service when the printer has them, else the first writable and
/// notifying ones), writes are chunked to the link's MTU less 3, at most 180
/// bytes, and paced, without response when the characteristic allows it. A printer's host is its CoreBluetooth
/// identifier (a UUID; iOS gives no MAC address). The printer acts on writes
/// only once FF03 is subscribed; writes are paced in chunks; an XPP job (it
/// starts 1F 11) is followed by the printer's status until it reports idle —
/// its acknowledgement — and fails with "did not confirm" when it never does,
/// so the core does not print it again.
final class BLELink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    static let shared = BLELink()

    private static let xppStatus = Data([0x1F, 0x11, 0x07])

    private let queue = DispatchQueue(label: "ca.superroute.sprint.ble")
    private var central: CBCentralManager!
    private let poweredOn = DispatchSemaphore(value: 0)
    private var state: CBManagerState = .unknown

    private final class Session {
        let peripheral: CBPeripheral
        var write: CBCharacteristic?
        var notify: CBCharacteristic?
        var pendingServices = 0
        var wrote = DispatchSemaphore(value: 0)
        var connected = DispatchSemaphore(value: 0)
        var ready = DispatchSemaphore(value: 0)
        var writable = DispatchSemaphore(value: 0)
        var error: String?
        var notifications: [Data] = []
        var answered = false
        var lastUse = Date()
        init(_ p: CBPeripheral) { peripheral = p }
    }

    private var sessions: [UUID: Session] = [:]
    private let lock = NSLock()
    private var locks: [String: NSLock] = [:]
    private var scanned: [UUID: (String, CBPeripheral, [String])] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    private func waitPoweredOn() throws {
        if queue.sync(execute: { state }) == .poweredOn { return }
        _ = poweredOn.wait(timeout: .now() + 5)
        let s = queue.sync { state }
        if s != .poweredOn {
            throw SPrintError(message: s == .unauthorized ? "Bluetooth permission not granted" : "Bluetooth is off or not available")
        }
    }

    private func printerLock(_ host: String) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let l = locks[host] { return l }
        let l = NSLock()
        locks[host] = l
        return l
    }

    // MARK: sessions

    private func session(_ host: String) throws -> Session {
        try waitPoweredOn()
        guard let id = UUID(uuidString: host) else { throw SPrintError(message: "ble: \(host) is not a CoreBluetooth identifier") }
        if let s = queue.sync(execute: { sessions[id] }), s.peripheral.state == .connected, s.write != nil { return s }
        guard let p = queue.sync(execute: { central.retrievePeripherals(withIdentifiers: [id]).first ?? scanned[id]?.1 }) else {
            throw SPrintError(message: "ble: printer \(host) is not known to this device (scan first)")
        }
        let s = Session(p)
        queue.sync {
            sessions[id] = s
            p.delegate = self
            central.connect(p)
        }
        if s.connected.wait(timeout: .now() + 15) == .timedOut { drop(id); throw SPrintError(message: "ble: connect timed out") }
        // Subscribing may make iOS ask the user to pair (a printer that wants an
        // encrypted link, e.g. the Phomemo M832): wait for the answer.
        if s.ready.wait(timeout: .now() + 40) == .timedOut {
            drop(id)
            throw SPrintError(message: "ble: the printer did not get ready (accept the pairing request if iOS asked, and print again)")
        }
        if let e = s.error { drop(id); throw SPrintError(message: e) }
        return s
    }

    private func drop(_ id: UUID) {
        queue.sync {
            if let s = sessions.removeValue(forKey: id) { central.cancelPeripheralConnection(s.peripheral) }
        }
    }

    private func write(_ s: Session, _ data: Data) throws {
        guard let c = s.write else { throw SPrintError(message: "ble: no write characteristic") }
        let noResponse = c.properties.contains(.writeWithoutResponse)
        let type: CBCharacteristicWriteType = noResponse ? .withoutResponse : .withResponse
        // At most 180 bytes a write: the Phomemo M832 agrees an MTU of 512 but
        // drops or ignores a job written in 509-byte chunks (Pixel 7 / iPhone 16,
        // 2026-10-29); 180 is what the SuperPrinter engines write.
        let chunk = max(20, min(180, s.peripheral.maximumWriteValueLength(for: type)))
        var off = 0
        while off < data.count {
            let end = min(off + chunk, data.count)
            let part = data.subdata(in: off..<end)
            if noResponse {
                let canSend = queue.sync { s.peripheral.canSendWriteWithoutResponse }
                if !canSend { _ = s.writable.wait(timeout: .now() + 2) }
            }
            if s.peripheral.state != .connected { throw SPrintError(message: "ble: link dropped") }
            queue.sync { s.peripheral.writeValue(part, for: c, type: type) }
            if !noResponse, s.wrote.wait(timeout: .now() + 5) == .timedOut {
                throw SPrintError(message: "ble: write not acknowledged")
            }
            off = end
            Thread.sleep(forTimeInterval: 0.01)
        }
        s.lastUse = Date()
    }

    private func takeNotifications(_ s: Session) -> [Data] {
        queue.sync {
            let n = s.notifications
            s.notifications = []
            return n
        }
    }

    private func status(_ s: Session) throws -> Data? {
        _ = takeNotifications(s)
        try write(s, Self.xppStatus)
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            if let f = takeNotifications(s).first(where: { $0.first == 0x1A }) { return f }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    private static func isXPP(_ d: Data) -> Bool { d.count >= 2 && d[d.startIndex] == 0x1F && d[d.startIndex + 1] == 0x11 }
    private static func xppReply(_ r: Data?) -> Bool { (r?.count ?? 0) >= 3 && r![r!.startIndex] == 0x1A && r![r!.startIndex + 1] == 0x07 }
    private static func xppIdle(_ r: Data?) -> Bool { xppReply(r) && r![r!.startIndex + 2] == 0x02 }

    // MARK: transport

    func send(host: String, data: Data) throws {
        let l = printerLock(host)
        l.lock()
        defer { l.unlock() }
        let s = try session(host)
        try write(s, data)
        guard Self.isXPP(data) else { return }
        let start = Date()
        while Date().timeIntervalSince(start) < 15 {
            Thread.sleep(forTimeInterval: 0.2)
            let r: Data?
            do { r = try status(s) } catch {
                drop(s.peripheral.identifier)
                throw SPrintError(message: "ble: the printer did not confirm the job: link lost while printing")
            }
            if Self.xppReply(r) {
                s.answered = true
                if Self.xppIdle(r) { return }
                continue
            }
            if !s.answered && Date().timeIntervalSince(start) >= 4 { return } // a printer that never answers
        }
        drop(s.peripheral.identifier)
        throw SPrintError(message: "ble: the printer did not confirm the job within 15 s (switched off or out of paper?)")
    }

    func query(host: String, cmd: Data, quiet: TimeInterval, overall: TimeInterval) throws -> Data {
        let l = printerLock(host)
        l.lock()
        defer { l.unlock() }
        let s = try session(host)
        _ = takeNotifications(s)
        try write(s, cmd)
        var out = Data()
        let deadline = Date().addingTimeInterval(overall)
        var last = Date()
        while Date() < deadline {
            let n = takeNotifications(s)
            if !n.isEmpty {
                n.forEach { out.append($0) }
                last = Date()
            } else if !out.isEmpty && Date().timeIntervalSince(last) >= quiet {
                break
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return out
    }

    func reachable(host: String) -> Bool { (try? session(host)) != nil }

    /// Every BLE device seen within `seconds` (no service filter), with the
    /// services it advertises, marked by the core (likely printer, known
    /// model) and likely printers first. `anyDevice` is kept for compatibility.
    func scan(seconds: TimeInterval, anyDevice: Bool = true) throws -> [DiscoveredPrinter] {
        let raw = try rawScan(seconds: seconds)
        guard let js = try? Bridge.json(raw) else { return raw }
        return (try? Discovery.found(sprint_merge_bluetooth(js))) ?? raw
    }

    func rawScan(seconds: TimeInterval) throws -> [DiscoveredPrinter] {
        try waitPoweredOn()
        queue.sync {
            scanned = [:]
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
        Thread.sleep(forTimeInterval: seconds)
        return queue.sync {
            central.stopScan()
            return scanned.map { id, v in
                DiscoveredPrinter(name: v.0, host: id.uuidString, transport: Transport.ble, keys: PrinterKeys(names: [v.0]),
                                  services: v.2.isEmpty ? nil : v.2)
            }.sorted { $0.name < $1.name }
        }
    }

    // MARK: delegates (on `queue`)

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        if state == .poweredOn || state == .unauthorized || state == .poweredOff || state == .unsupported { poweredOn.signal() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let before = scanned[peripheral.identifier]
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
            ?? before?.0 ?? peripheral.identifier.uuidString
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map { Self.full($0) }
        scanned[peripheral.identifier] = (name, peripheral, uuids.isEmpty ? (before?.2 ?? []) : uuids)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let s = sessions[peripheral.identifier] else { return }
        s.connected.signal()
        peripheral.discoverServices(nil)
    }

    /// A CBUUID in the 128-bit form the core and the other platforms use.
    static func full(_ u: CBUUID) -> String {
        let s = u.uuidString.lowercased()
        switch s.count {
        case 4: return "0000\(s)-0000-1000-8000-00805f9b34fb"
        case 8: return "\(s)-0000-1000-8000-00805f9b34fb"
        default: return s
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        guard let s = sessions[peripheral.identifier] else { return }
        s.error = "ble: connect failed: \(error?.localizedDescription ?? "unknown")"
        s.connected.signal()
        s.ready.signal()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        sessions.removeValue(forKey: peripheral.identifier)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let s = sessions[peripheral.identifier] else { return }
        let svcs = peripheral.services ?? []
        if svcs.isEmpty {
            s.error = "ble: the printer has no services"
            s.ready.signal()
            return
        }
        s.pendingServices = svcs.count
        svcs.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard let s = sessions[peripheral.identifier] else { return }
        s.pendingServices -= 1
        guard s.pendingServices <= 0 else { return }
        var real: [String: CBCharacteristic] = [:]
        var chars: [GattChoice.Char] = []
        for svc in peripheral.services ?? [] {
            for c in svc.characteristics ?? [] {
                let ch = GattChoice.Char(service: Self.full(svc.uuid), uuid: Self.full(c.uuid),
                                         write: c.properties.contains(.write),
                                         writeWithoutResponse: c.properties.contains(.writeWithoutResponse),
                                         notify: c.properties.contains(.notify) || c.properties.contains(.indicate))
                chars.append(ch)
                real[ch.service + "/" + ch.uuid] = c
            }
        }
        let w = GattChoice.write(chars)
        guard let w, let wc = real[w.service + "/" + w.uuid] else {
            s.error = "ble: the printer has no writable characteristic"
            s.ready.signal()
            return
        }
        s.write = wc
        if let n = GattChoice.notify(chars, write: w), let nc = real[n.service + "/" + n.uuid] {
            s.notify = nc
            peripheral.setNotifyValue(true, for: nc)
        } else {
            s.ready.signal() // some printers print without a status channel
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        // A failed subscribe is not fatal (superprinter_flutter): some printers
        // print without it; the job's own answer tells.
        guard let s = sessions[peripheral.identifier] else { return }
        _ = error
        s.ready.signal()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        sessions[peripheral.identifier]?.wrote.signal()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard let s = sessions[peripheral.identifier], let v = characteristic.value else { return }
        s.notifications.append(v)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        sessions[peripheral.identifier]?.writable.signal()
    }
}

private func targetHost(_ json: UnsafePointer<CChar>?) -> String {
    guard let json, let d = String(cString: json).data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "" }
    return o["host"] as? String ?? ""
}

private let bleSend: sprint_send_cb = { target, data, len, err, _ in
    do {
        try BLELink.shared.send(host: targetHost(target), data: data.map { Data(bytes: $0, count: len) } ?? Data())
        return 0
    } catch {
        err?.pointee = strdup(String(describing: error))
        return 1
    }
}

private let bleQuery: sprint_query_cb = { target, cmd, len, quiet, overall, out, outLen, err, _ in
    do {
        let r = try BLELink.shared.query(host: targetHost(target), cmd: cmd.map { Data(bytes: $0, count: len) } ?? Data(),
                                         quiet: TimeInterval(quiet) / 1000, overall: TimeInterval(overall) / 1000)
        if !r.isEmpty {
            let p = malloc(r.count)!.assumingMemoryBound(to: UInt8.self)
            r.copyBytes(to: p, count: r.count)
            out?.pointee = p
            outLen?.pointee = r.count
        }
        return 0
    } catch {
        err?.pointee = strdup(String(describing: error))
        return 1
    }
}

private let bleReachable: sprint_reachable_cb = { target, _ in BLELink.shared.reachable(host: targetHost(target)) ? 1 : 0 }

/// The core's "ble" scanner: every binding (Swift, Flutter through FFI) gets
/// the CoreBluetooth scan; the core marks and sorts what it saw.
private let bleScan: sprint_scan_cb = { ms, _ in
    let answer: String
    do {
        let list = try BLELink.shared.rawScan(seconds: TimeInterval(ms) / 1000)
        answer = (try? Bridge.json(["printers": list])) ?? #"{"printers":[]}"#
    } catch {
        answer = (try? Bridge.json(["error": String(describing: error)])) ?? #"{"error":"ble scan failed"}"#
    }
    return strdup(answer)
}

enum BLETransport {
    static func register() {
        _ = BLELink.shared
        _ = sprint_register_transport(Transport.ble, bleSend, bleQuery, bleReachable, nil)
        _ = sprint_register_scanner(Transport.ble, bleScan, nil)
    }
}

#endif
