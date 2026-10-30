import Foundation

/// Transports a ``TargetPrinter`` can name.
public enum Transport {
    /// Raw TCP (JetDirect / 9100); host is "ip" or "ip:port".
    public static let network = "network"
    /// Classic Bluetooth RFCOMM; host is the MAC address.
    public static let bluetooth = "bluetooth"
    /// Bluetooth LE; host is the platform's id.
    public static let ble = "ble"
    /// Direct USB; host is "VID:PID[:SERIAL]".
    public static let usb = "usb"
    /// An OS print queue (CUPS); host is the queue name.
    public static let system = "system"
}

/// Printer command languages.
public enum Language {
    public static let escpos = "escpos"
    public static let xprinter = "xprinter"
    public static let tspl = "tspl"
    public static let zpl = "zpl"
    public static let cpcl = "cpcl"
    public static let xpp = "xpp"
    public static let hprt = "hprt"
    public static let pl = "pl"
    public static let tp108 = "tp108"
    /// A document printer that takes the PDF itself.
    public static let pdf = "pdf"
}

/// Job types of a ``PrintJob``.
public enum JobType {
    public static let label = "label"
    public static let raw = "raw"
    public static let pdf = "pdf"
    public static let html = "html"
    public static let image = "image"
    public static let test = "test"
}

/// The names, USB id and IEEE-1284 device ID a printer goes by.
public struct PrinterKeys: Codable, Sendable, Equatable {
    public var names: [String]?
    public var usb: String?
    public var deviceId: String?

    public init(names: [String]? = nil, usb: String? = nil, deviceId: String? = nil) {
        self.names = names
        self.usb = usb
        self.deviceId = deviceId
    }

    enum CodingKeys: String, CodingKey {
        case names, usb
        case deviceId = "device_id"
    }
}

/// A configured printer. The JSON keys are the ones the SuperPrinter Android app
/// and superprinter_flutter persist. Zero / nil means "not known": dpi 0 is 203
/// (XPP 300), width 0 keeps the page's own width, a nil TSPL2 / Xprinter setting
/// keeps the family's stock preset.
public struct TargetPrinter: Codable, Sendable, Equatable {
    public var name: String
    public var host: String
    public var transport: String
    public var isDefault: Bool
    public var language: String
    public var widthDots: Int
    public var paperWidthMm: Int
    public var paperHeightMm: Int
    public var dpi: Int
    public var compress: Bool
    public var plGapMm: Int?
    public var plDensity: Int?
    public var plDirection: Int?
    public var xpCut: String?
    public var xpDensity: Int?
    public var channel: Int
    public var languageSource: String?
    public var evidence: PrinterKeys?

    public init(name: String, host: String = "", transport: String = Transport.network, isDefault: Bool = false,
                language: String = "", widthDots: Int = 0, paperWidthMm: Int = 0, paperHeightMm: Int = 0,
                dpi: Int = 0, compress: Bool = false, plGapMm: Int? = nil, plDensity: Int? = nil,
                plDirection: Int? = nil, xpCut: String? = nil, xpDensity: Int? = nil, channel: Int = 0,
                languageSource: String? = nil, evidence: PrinterKeys? = nil) {
        self.name = name
        self.host = host
        self.transport = transport
        self.isDefault = isDefault
        self.language = language
        self.widthDots = widthDots
        self.paperWidthMm = paperWidthMm
        self.paperHeightMm = paperHeightMm
        self.dpi = dpi
        self.compress = compress
        self.plGapMm = plGapMm
        self.plDensity = plDensity
        self.plDirection = plDirection
        self.xpCut = xpCut
        self.xpDensity = xpDensity
        self.channel = channel
        self.languageSource = languageSource
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey {
        case name, host, transport, language, dpi, compress, channel, evidence
        case isDefault = "default"
        case widthDots = "width_dots"
        case paperWidthMm = "paper_width_mm"
        case paperHeightMm = "paper_height_mm"
        case plGapMm = "pl_gap_mm"
        case plDensity = "pl_density"
        case plDirection = "pl_direction"
        case xpCut = "xp_cut"
        case xpDensity = "xp_density"
        case languageSource = "language_source"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        transport = try c.decodeIfPresent(String.self, forKey: .transport) ?? Transport.network
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        widthDots = try c.decodeIfPresent(Int.self, forKey: .widthDots) ?? 0
        paperWidthMm = try c.decodeIfPresent(Int.self, forKey: .paperWidthMm) ?? 0
        paperHeightMm = try c.decodeIfPresent(Int.self, forKey: .paperHeightMm) ?? 0
        dpi = try c.decodeIfPresent(Int.self, forKey: .dpi) ?? 0
        compress = try c.decodeIfPresent(Bool.self, forKey: .compress) ?? false
        plGapMm = try c.decodeIfPresent(Int.self, forKey: .plGapMm)
        plDensity = try c.decodeIfPresent(Int.self, forKey: .plDensity)
        plDirection = try c.decodeIfPresent(Int.self, forKey: .plDirection)
        xpCut = try c.decodeIfPresent(String.self, forKey: .xpCut)
        xpDensity = try c.decodeIfPresent(Int.self, forKey: .xpDensity)
        channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? 0
        languageSource = try c.decodeIfPresent(String.self, forKey: .languageSource)
        evidence = try c.decodeIfPresent(PrinterKeys.self, forKey: .evidence)
    }
}

/// One primitive of a ``LabelJob``; x / y / w / h in millimetres from the top-left.
public struct LabelElement: Codable, Sendable, Equatable {
    public var type: String
    public var x: Double, y: Double, w: Double, h: Double
    public var text: String?
    public var sizePt: Double?
    public var bold: Bool?
    public var align: String?
    public var valign: String?
    public var font: String?
    public var wrap: Bool?
    public var format: String?
    public var value: String?
    public var rotation: Int?
    public var showValue: Bool?
    public var valuePt: Double?
    public var valueH: Double?
    public var ecc: String?
    public var side: Double?
    public var pad: Double?
    public var caption: String?
    public var captionPt: Double?
    public var captionH: Double?
    public var borderMm: Double?
    public var fill: Bool?
    public var mime: String?
    public var dataBase64: String?

    public init(type: String, x: Double, y: Double, w: Double, h: Double, text: String? = nil, sizePt: Double? = nil,
                bold: Bool? = nil, align: String? = nil, valign: String? = nil, value: String? = nil,
                format: String? = nil, ecc: String? = nil, borderMm: Double? = nil, fill: Bool? = nil) {
        self.type = type
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.text = text
        self.sizePt = sizePt
        self.bold = bold
        self.align = align
        self.valign = valign
        self.value = value
        self.format = format
        self.ecc = ecc
        self.borderMm = borderMm
        self.fill = fill
    }

    enum CodingKeys: String, CodingKey {
        case type, x, y, w, h, text, bold, align, valign, font, wrap, format, value, rotation, ecc, side, pad
        case caption, fill, mime
        case sizePt = "size_pt"
        case showValue = "show_value"
        case valuePt = "value_pt"
        case valueH = "value_h"
        case captionPt = "caption_pt"
        case captionH = "caption_h"
        case borderMm = "border_mm"
        case dataBase64 = "data_base64"
    }
}

/// A label described as primitives placed in millimetres (version 1).
public struct LabelJob: Codable, Sendable, Equatable {
    public var version: Int
    public var widthMm: Double
    public var heightMm: Double
    public var elements: [LabelElement]

    public init(widthMm: Double, heightMm: Double, elements: [LabelElement] = []) {
        version = 1
        self.widthMm = widthMm
        self.heightMm = heightMm
        self.elements = elements
    }

    /// Reads a label from its JSON.
    public static func parse(_ json: Data) throws -> LabelJob { try JSONDecoder().decode(LabelJob.self, from: json) }

    enum CodingKeys: String, CodingKey {
        case version, elements
        case widthMm = "width_mm"
        case heightMm = "height_mm"
    }
}

/// One thing to print.
public struct PrintJob: Codable, Sendable {
    public var type: String
    /// The registry printer; nil for the default one.
    public var printer: String?
    public var label: LabelJob?
    /// Raw bytes, a PDF or an image.
    public var data: Data?
    public var html: String?
    public var baseUrl: String?
    public var text: String?
    public var copies: Int
    public var duplex: String?
    public var paper: String?

    public init(type: String, printer: String? = nil, label: LabelJob? = nil, data: Data? = nil, html: String? = nil,
                baseUrl: String? = nil, text: String? = nil, copies: Int = 1, duplex: String? = nil, paper: String? = nil) {
        self.type = type
        self.printer = printer
        self.label = label
        self.data = data
        self.html = html
        self.baseUrl = baseUrl
        self.text = text
        self.copies = copies
        self.duplex = duplex
        self.paper = paper
    }

    enum CodingKeys: String, CodingKey {
        case type, printer, label, data, html, text, copies, duplex, paper
        case baseUrl = "base_url"
    }
}

/// The outcome of a print.
public struct PrintResult: Codable, Sendable {
    public var ok: Bool
    /// transient, printer_offline, printer_disabled, download_failed, unsupported, print_error or stopped.
    public var reason: String?
    public var message: String?
    public var printer: String?
    public var language: String?
    /// stream, raw, passthrough, driver or html.
    public var path: String?
    public var bytes: Int?
}

/// A printer found by discovery.
public struct DiscoveredPrinter: Codable, Sendable {
    public var name: String
    public var host: String
    public var transport: String
    public var ipp: Bool?
    public var raw: Bool?
    public var bonded: Bool?
    public var isDefault: Bool?
    public var driverKind: String?
    public var keys: PrinterKeys?
    /// Bluetooth LE: the service UUIDs it advertises.
    public var services: [String]?
    /// Bluetooth: every transport it was seen on and its host on each; transport / host are the preferred one.
    public var transports: [String]?
    public var hosts: [String: String]?
    /// Classic Bluetooth: the Class of Device.
    public var classOfDevice: Int?
    /// Bluetooth discovery lists every device found; this marks the likely printers.
    public var likelyPrinter: Bool?
    /// The printer model table entry its name matched.
    public var known: PrinterIdentity?

    public init(name: String, host: String, transport: String, ipp: Bool? = nil, raw: Bool? = nil, bonded: Bool? = nil,
                isDefault: Bool? = nil, driverKind: String? = nil, keys: PrinterKeys? = nil, services: [String]? = nil) {
        self.name = name
        self.host = host
        self.transport = transport
        self.ipp = ipp
        self.raw = raw
        self.bonded = bonded
        self.isDefault = isDefault
        self.driverKind = driverKind
        self.keys = keys
        self.services = services
    }

    enum CodingKeys: String, CodingKey {
        case name, host, transport, ipp, raw, bonded, keys, services, transports, hosts, known
        case isDefault = "default"
        case driverKind = "driver_kind"
        case classOfDevice = "class_of_device"
        case likelyPrinter = "likely_printer"
    }
}

/// What identification worked out about a printer, and from what.
public struct PrinterIdentity: Codable, Sendable {
    public var language: String?
    public var dpi: Int?
    public var widthMm: Int?
    public var kind: String?
    /// device_id, model_table, status, user or none.
    public var source: String?
    public var model: String?

    enum CodingKeys: String, CodingKey {
        case language, dpi, kind, source, model
        case widthMm = "width_mm"
    }
}

/// A back-channel identification.
public struct Probe: Codable, Sendable {
    public var language: String
    public var evidence: String
}

/// A printer's fallback chain state.
public struct FallbackState: Codable, Sendable {
    public var closed: [String]?
    public var reason: String?
    public var since: String?
    public var nextCheck: String?
    public var lastPath: String?
    public var lastMs: Int?

    enum CodingKeys: String, CodingKey {
        case closed, reason, since
        case nextCheck = "next_check"
        case lastPath = "last_path"
        case lastMs = "last_ms"
    }
}

/// What a print node keeps between runs; persist it on every ``NodeEvent/state(_:)``.
public struct NodeState: Codable, Sendable {
    public var server: String
    public var nodeToken: String?
    public var provisionToken: String?
    public var nodeId: Int64?
    public var name: String?
    public var warehouseId: Int64?
    public var machineId: String?
    public var mqttUrl: String?
    public var mqttTopic: String?

    public init(server: String = "https://api.superroute.ca", nodeToken: String? = nil) {
        self.server = server
        self.nodeToken = nodeToken
    }

    /// Whether the node holds a node token.
    public var paired: Bool { !(nodeToken ?? "").isEmpty }

    enum CodingKeys: String, CodingKey {
        case server, name
        case nodeToken = "node_token"
        case provisionToken = "provision_token"
        case nodeId = "node_id"
        case warehouseId = "warehouse_id"
        case machineId = "machine_id"
        case mqttUrl = "mqtt_url"
        case mqttTopic = "mqtt_topic"
    }
}

/// The device described at pairing (nil fields are filled from this Mac).
public struct DeviceInfo: Codable, Sendable {
    public var hostname: String?
    public var os: String?
    public var user: String?
    public var hardwareId: String?

    public init(hostname: String? = nil, os: String? = nil, user: String? = nil, hardwareId: String? = nil) {
        self.hostname = hostname
        self.os = os
        self.user = user
        self.hardwareId = hardwareId
    }

    enum CodingKeys: String, CodingKey {
        case hostname, os, user
        case hardwareId = "hardware_id"
    }
}

/// A print node's status.
public struct NodeStatus: Codable, Sendable {
    public var state: NodeState
    public var lastBeat: String?
    public var lastError: String?
    public var push: Bool

    enum CodingKeys: String, CodingKey {
        case state, push
        case lastBeat = "last_beat"
        case lastError = "last_error"
    }
}

/// The server's view of a protocol sweep.
public struct SweepState: Codable, Sendable {
    public var sweep: Int64?
    public var status: String?
    public var position: Int?
    public var count: Int?
    public var next: Bool?
    public var confirmedLanguage: String?

    enum CodingKeys: String, CodingKey {
        case sweep, status, position, count, next
        case confirmedLanguage = "confirmed_language"
    }
}

/// A protocol sweep candidate.
public struct SweepCandidate: Codable, Sendable {
    public var position: Int
    public var language: String
}

/// A protocol sweep the node runs, for a banner.
public struct SweepView: Codable, Sendable {
    public var sweep: Int64
    public var printer: String
    public var state: SweepState
    public var printed: Int
    public var candidates: [SweepCandidate]?
    public var lastError: String?
    public var busy: Bool?

    enum CodingKeys: String, CodingKey {
        case sweep, printer, state, printed, candidates, busy
        case lastError = "last_error"
    }
}
