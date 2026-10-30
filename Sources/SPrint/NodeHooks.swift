import CSPrint
import Foundation

// The print node's hooks for a host app (docs/NODE-HOOKS.md): the server's
// printer settings, the jobs in flight, the command hook, extra heartbeat
// fields and the ZPL media query.

/// Any JSON value: command params and extra heartbeat fields.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// The string, when this is one.
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    /// The number, when this is one.
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    /// A member of an object.
    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    public init(nilLiteral: ()) { self = .null }
}

/// What the client locked for one printer on the Print Nodes page.
public struct PrinterLock: Codable, Sendable, Equatable {
    public var language: Bool
    public var path: Bool
}

/// What the server holds for the node's printers: the operator's languages
/// ("auto" = the node's identification), the locks and the default papers.
/// The node applies them itself: a locked language is not changed by
/// ``PrinterRegistry/save(_:)`` and the default paper fills a job without one.
public struct PrinterSettings: Codable, Sendable, Equatable {
    public var languages: [String: String]
    public var locks: [String: PrinterLock]
    public var paper: [String: String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        languages = try c.decodeIfPresent([String: String].self, forKey: .languages) ?? [:]
        locks = try c.decodeIfPresent([String: PrinterLock].self, forKey: .locks) ?? [:]
        paper = try c.decodeIfPresent([String: String].self, forKey: .paper) ?? [:]
    }

    enum CodingKeys: String, CodingKey { case languages, locks, paper }
}

/// A job that started or ended printing: a cloud job (``jobId``) or one a LAN
/// peer sent (``peer``).
public struct PrintingEvent: Codable, Sendable {
    /// started or ended.
    public var state: String
    /// cloud or peer.
    public var source: String
    public var jobId: Int64?
    public var peer: String?
    public var printer: String
    public var at: String
    /// The outcome, when ended.
    public var result: PrintResult?

    enum CodingKeys: String, CodingKey {
        case state, source, peer, printer, at, result
        case jobId = "job_id"
    }
}

/// A remote command the server sent the node.
public struct NodeCommand: Codable, Sendable {
    public var id: Int64
    public var action: String
    public var params: [String: JSONValue]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        action = try c.decode(String.self, forKey: .action)
        params = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .params)) ?? [:]
    }

    enum CodingKeys: String, CodingKey { case id, action, params }
}

/// The host's answer to a command: ``output`` reported as done, or failed
/// with ``error``.
public struct CommandAnswer: Codable, Sendable {
    public var output: String
    public var error: String?

    public init(output: String, error: String? = nil) {
        self.output = output
        self.error = error
    }
}

/// What a ZPL printer told about its media (0 when it did not say).
public struct ZplMedia: Codable, Sendable, Equatable {
    public var dpi: Int
    public var widthMm: Int
    public var lengthMm: Int
    public var widthDots: Int
    public var lengthDots: Int

    enum CodingKeys: String, CodingKey {
        case dpi
        case widthMm = "width_mm"
        case lengthMm = "length_mm"
        case widthDots = "width_dots"
        case lengthDots = "length_dots"
    }
}

extension SPrint {
    /// Asks a ZPL printer for its resolution (~HI) and loaded media (^HH),
    /// without paper; nil when it did not answer. Only a printer set to ZPL is asked.
    public static func queryZplMedia(_ printer: TargetPrinter) throws -> ZplMedia? {
        struct R: Decodable { var ok: Bool?; var media: ZplMedia?; var error: String? }
        let r = try Bridge.decode(R.self, Bridge.take(sprint_query_zpl_media(try Bridge.json(printer))))
        if let e = r.error { throw SPrintError(message: e) }
        return r.ok == true ? r.media : nil
    }
}
