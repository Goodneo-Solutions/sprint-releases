import Foundation

// The models of LAN peer printing (docs/LAN-PEER-DESIGN.md): JSON keys are the
// core's, so a state stored by another binding (or by the SuperPrinter agent's
// format) reads back unchanged.

/// Access modes of a ``PeerHost``.
public enum PeerMode {
    /// Anyone on the network.
    public static let open = "open"
    /// Whoever gives the password.
    public static let password = "password"
    /// The owner approves each new peer (the default).
    public static let approval = "approval"
}

/// Why a peer session ended.
public enum PeerReason {
    /// The printer user disconnected.
    public static let disconnected = "disconnected"
    /// The owner revoked the peer.
    public static let revoked = "revoked"
    /// The session's hour ran out.
    public static let expired = "expired"
    /// The peer left the network.
    public static let unreachable = "unreachable"
    /// The host stopped sharing.
    public static let stopped = "stopped"
}

/// The peer-direct protocol's constants.
public enum PeerProtocol {
    /// The mDNS service peers advertise (domain "local.").
    public static let serviceType = "_superprinter._tcp"
    /// The peer server's port unless told otherwise.
    public static let defaultPort = 17778
}

extension Transport {
    /// A connected peer's printer in a registry (named "peer:<fingerprint>/<printer>").
    public static let peer = "peer"
}

/// A peer on a host's trust list (approved once, reconnects without asking).
public struct TrustedPeer: Codable, Sendable, Equatable {
    public var fingerprint: String
    public var name: String?
    /// RFC 3339.
    public var addedAt: String?

    public init(fingerprint: String, name: String? = nil, addedAt: String? = nil) {
        self.fingerprint = fingerprint
        self.name = name
        self.addedAt = addedAt
    }

    enum CodingKeys: String, CodingKey {
        case fingerprint, name
        case addedAt = "added_at"
    }
}

/// What a ``PeerHost`` keeps between runs; store it on every
/// ``PeerHostEvent/state(_:)`` and hand it back to the next host.
public struct PeerHostState: Codable, Sendable, Equatable {
    /// The identity's Ed25519 seed.
    public var seed: Data?
    /// open | password | approval (nil = approval).
    public var mode: String?
    /// The password mode's PBKDF2-SHA256 hash.
    public var passwordHash: String?
    /// The registry printers peers may see and print to.
    public var shared: [String]?
    /// Peers that connect without asking again.
    public var trusted: [TrustedPeer]?
    /// Advertised over mDNS while the host runs.
    public var discoverable: Bool?

    public init(seed: Data? = nil, mode: String? = nil, passwordHash: String? = nil, shared: [String]? = nil,
                trusted: [TrustedPeer]? = nil, discoverable: Bool? = nil) {
        self.seed = seed
        self.mode = mode
        self.passwordHash = passwordHash
        self.shared = shared
        self.trusted = trusted
        self.discoverable = discoverable
    }

    enum CodingKeys: String, CodingKey {
        case seed, mode, shared, trusted, discoverable
        case passwordHash = "password_hash"
    }
}

/// An approval request waiting for the owner.
public struct PeerPending: Codable, Sendable, Equatable {
    public var id: String
    public var fingerprint: String
    public var name: String?
    public var note: String?
    public var addr: String?
    /// RFC 3339.
    public var requested: String
}

/// A peer connected to a host.
public struct PeerSessionInfo: Codable, Sendable, Equatable {
    public var fingerprint: String
    public var name: String?
    public var addr: String?
    /// RFC 3339.
    public var since: String
    /// RFC 3339.
    public var expires: String
    /// Admitted by the trust list, so a revoke ends it.
    public var trusted: Bool?
}

/// A host's status.
public struct PeerHostStatus: Codable, Sendable {
    public var running: Bool
    /// The address listened on ("[::]:17778").
    public var addr: String?
    public var fingerprint: String
    public var name: String
    public var mode: String
    public var discoverable: Bool
    public var advertising: Bool
    public var advertiseError: String?
    public var sessions: Int
    public var pending: Int

    /// The port listened on, when running.
    public var port: Int? {
        guard let a = addr, let i = a.lastIndex(of: ":") else { return nil }
        return Int(a[a.index(after: i)...])
    }

    enum CodingKeys: String, CodingKey {
        case running, addr, fingerprint, name, mode, discoverable, advertising, sessions, pending
        case advertiseError = "advertise_error"
    }
}

/// A device advertising peer printing on the LAN. The fields are hints for
/// the UI; the authority is the fingerprint the connection proves.
public struct PeerAdvert: Codable, Sendable, Equatable {
    public var fingerprint: String
    public var name: String
    public var mode: String
    /// host:port, for ``Peers/connect(to:identity:fingerprint:password:note:pingInterval:)``.
    public var addr: String
    /// The agent's version.
    public var version: String
    public var instance: String?
}

/// A printer a peer shares.
public struct PeerPrinter: Codable, Sendable, Equatable {
    public var name: String
    public var isDefault: Bool
    public var transport: String?
    public var language: String?
    public var widthDots: Int?
    public var dpi: Int?
    public var state: String?

    enum CodingKeys: String, CodingKey {
        case name, transport, language, dpi, state
        case isDefault = "default"
        case widthDots = "width_dots"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        transport = try c.decodeIfPresent(String.self, forKey: .transport)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        widthDots = try c.decodeIfPresent(Int.self, forKey: .widthDots)
        dpi = try c.decodeIfPresent(Int.self, forKey: .dpi)
        state = try c.decodeIfPresent(String.self, forKey: .state)
    }
}

/// A session's status.
public struct PeerSessionStatus: Codable, Sendable {
    /// connected | pending | ended.
    public var status: String
    /// Why it ended (``PeerReason``).
    public var reason: String?
    public var fingerprint: String
    public var name: String
    public var mode: String
    public var addr: String
    /// The peer's agent version.
    public var version: String

    public var isConnected: Bool { status == "connected" }
    public var isPending: Bool { status == "pending" }
    public var isEnded: Bool { status == "ended" }
}
