import CSPrint
import Foundation

/// An error sPrint reported.
public struct SPrintError: Error, Sendable, CustomStringConvertible {
    public let message: String
    /// A machine-readable code when there is one: a peer's refusal
    /// (BAD_PASSWORD, THROTTLED, NOT_AUTHORIZED, …), or "denied" / "timeout"
    /// from ``PeerSession/waitApproval(timeout:)``.
    public var code: String?
    public var description: String { message }

    init(message: String, code: String? = nil) {
        self.message = message
        self.code = code
    }
}

// MARK: - Bridging helpers

enum Bridge {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Takes a string sPrint returned and frees it.
    static func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p else { return "" }
        defer { sprint_free(p) }
        return String(cString: p)
    }

    static func takeBytes(_ p: UnsafeMutablePointer<UInt8>?, _ n: Int) -> Data {
        guard let p else { return Data() }
        defer { sprint_free(p) }
        return Data(bytes: p, count: n)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ s: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(s.utf8))
    }

    struct OK: Decodable {
        var ok: Bool?
        var error: String?
    }

    static func check(_ s: String) throws {
        let r = try decode(OK.self, s)
        if r.ok != true { throw SPrintError(message: r.error ?? "sprint: failed") }
    }

    static func error(_ p: UnsafeMutablePointer<CChar>?) -> SPrintError { SPrintError(message: take(p)) }
}

/// sPrint, Superroute's printing SDK: encoding, printing, discovery and
/// identification. Printers you keep are in a ``PrinterRegistry``; a Superroute
/// print node is a ``PrintNode``.
public enum SPrint {
    /// The version of the sPrint core.
    public static var version: String { Bridge.take(sprint_version()) }

    /// The command languages sPrint encodes into.
    public static var languages: [String] {
        (try? Bridge.decode([String].self, Bridge.take(sprint_languages()))) ?? []
    }

    /// Cuts the print in flight; true when something was printing.
    @discardableResult
    public static func stop() -> Bool { sprint_stop() == 1 }

    /// The bytes a label prints as on a printer.
    public static func encodeLabel(_ label: LabelJob, for printer: TargetPrinter, copies: Int = 1) throws -> Data {
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        var err: UnsafeMutablePointer<CChar>?
        let rc = sprint_encode_label(try Bridge.json(printer), try Bridge.json(label), Int32(copies), &out, &len, &err)
        if rc != 0 { throw Bridge.error(err) }
        return Bridge.takeBytes(out, len)
    }

    /// The bytes an image (PNG, JPEG, GIF) prints as on a thermal printer.
    public static func encodeImage(_ image: Data, for printer: TargetPrinter, copies: Int = 1) throws -> Data {
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        var err: UnsafeMutablePointer<CChar>?
        let target = try Bridge.json(printer)
        let rc = image.withUnsafeBytes { buf in
            sprint_encode_image(target, buf.bindMemory(to: UInt8.self).baseAddress, buf.count, Int32(copies), &out, &len, &err)
        }
        if rc != 0 { throw Bridge.error(err) }
        return Bridge.takeBytes(out, len)
    }

    /// The one-line self-test in a language.
    public static func selfTest(language: String, text: String) throws -> Data {
        var out: UnsafeMutablePointer<UInt8>?
        var len = 0
        if sprint_self_test(language, text, &out, &len) != 0 {
            throw SPrintError(message: "sprint: unknown language \"\(language)\"")
        }
        return Bridge.takeBytes(out, len)
    }

    /// Runs a job on a printer that is not (necessarily) in a registry.
    public static func print(_ job: PrintJob, to printer: TargetPrinter) throws -> PrintResult {
        try Bridge.decode(PrintResult.self, Bridge.take(sprint_print(try Bridge.json(printer), try Bridge.json(job))))
    }

    /// Works out a printer's language from what it goes by, without talking to it.
    public static func identify(_ keys: PrinterKeys) throws -> PrinterIdentity? {
        struct R: Decodable { var ok: Bool?; var identity: PrinterIdentity?; var error: String? }
        let r = try Bridge.decode(R.self, Bridge.take(sprint_identify(try Bridge.json(keys))))
        if let e = r.error { throw SPrintError(message: e) }
        return r.ok == true ? r.identity : nil
    }

    /// Asks a printer what it speaks without using paper; nil when nothing answered.
    public static func probeLanguage(_ printer: TargetPrinter) throws -> Probe? {
        struct R: Decodable { var probe: Probe?; var error: String? }
        let r = try Bridge.decode(R.self, Bridge.take(sprint_probe(try Bridge.json(printer))))
        if let e = r.error { throw SPrintError(message: e) }
        return r.probe
    }

    /// Loads a model table revision the server published; returns the active revision.
    @discardableResult
    public static func loadModelTable(_ json: String) throws -> Int {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sprint_load_model_table(json, &err)
        if rc < 0 { throw Bridge.error(err) }
        return Int(rc)
    }
}

/// Finding printers.
public enum Discovery {
    struct Found: Decodable { var printers: [DiscoveredPrinter]?; var error: String? }

    static func found(_ p: UnsafeMutablePointer<CChar>?) throws -> [DiscoveredPrinter] {
        let f = try Bridge.decode(Found.self, Bridge.take(p))
        if let e = f.error, !e.isEmpty, (f.printers ?? []).isEmpty { throw SPrintError(message: e) }
        return f.printers ?? []
    }

    /// This Mac's private IPv4 /24 prefixes ("192.168.1").
    public static func localPrefixes() -> [String] {
        (try? Bridge.decode([String].self, Bridge.take(sprint_local_prefixes()))) ?? []
    }

    /// Printers answering on IPP (631) or raw (9100) in a /24; nil scans every local one.
    public static func scanNetwork(prefix: String? = nil, timeoutMs: Int = 350) throws -> [DiscoveredPrinter] {
        try found(sprint_scan_network(prefix ?? "", Int32(timeoutMs)))
    }

    /// The CUPS queues.
    public static func systemPrinters() throws -> [DiscoveredPrinter] { try found(sprint_system_printers()) }

    /// Printers attached by USB.
    public static func usbPrinters() throws -> [DiscoveredPrinter] { try found(sprint_usb_printers()) }

    /// Classic Bluetooth printers: the bonded ones, plus an inquiry of scanMs.
    public static func bluetoothPrinters(scanMs: Int = 0) throws -> [DiscoveredPrinter] {
        try found(sprint_bluetooth_printers(Int32(scanMs)))
    }

    /// Bluetooth LE devices seen in scanMs: every one, likely printers first
    /// (on iOS through CoreBluetooth; needs NSBluetoothAlwaysUsageDescription).
    public static func blePrinters(scanMs: Int = 4000) throws -> [DiscoveredPrinter] {
        #if os(iOS)
        return try BLELink.shared.scan(seconds: TimeInterval(scanMs) / 1000)
        #else
        return try found(sprint_ble_printers(Int32(scanMs)))
        #endif
    }

    /// Every Bluetooth device nearby, each once, over both transports (classic
    /// and LE on macOS; LE only on iOS, where Apple gives apps no classic
    /// Bluetooth): transports lists what it was seen on, transport / host the
    /// one SuperPrinter prefers for it.
    public static func nearbyBluetoothPrinters(scanMs: Int = 8000) throws -> [DiscoveredPrinter] {
        try found(sprint_nearby_bluetooth_printers(Int32(scanMs)))
    }

    /// Whether a Bluetooth device is a printer candidate — the rule every sPrint layer uses.
    public static func looksLikePrinter(name: String, services: [String] = [], classOfDevice: Int = 0) -> Bool {
        let js = (try? Bridge.json(services)) ?? "[]"
        return sprint_looks_like_printer(name, js, Int32(classOfDevice)) != 0
    }
}
