import Foundation

/// Which characteristics of a BLE printer sPrint writes to and listens on —
/// superprinter_flutter's rule (its iOS printing, as SuperDepot uses it): the
/// 0xFF02 characteristic, else the first writable one; for status 0xFF03,
/// else a notifying one of the write characteristic's service, else the first
/// that notifies. Pure, so recorded GATT layouts are tested anywhere.
public enum GattChoice {
    public struct Char: Equatable, Sendable {
        public var service: String
        public var uuid: String
        public var write: Bool
        public var writeWithoutResponse: Bool
        public var notify: Bool
        public init(service: String, uuid: String, write: Bool = false, writeWithoutResponse: Bool = false, notify: Bool = false) {
            self.service = service
            self.uuid = uuid
            self.write = write
            self.writeWithoutResponse = writeWithoutResponse
            self.notify = notify
        }
        var writable: Bool { write || writeWithoutResponse }
    }

    /// "FF02", "0000ff02-0000-1000-8000-00805f9b34fb" → "ff02".
    static func short(_ u: String) -> String {
        let l = u.lowercased()
        if l.count == 36, l.hasPrefix("0000"), l.hasSuffix("-0000-1000-8000-00805f9b34fb") {
            return String(l.dropFirst(4).prefix(4))
        }
        return l
    }

    public static func write(_ chars: [Char]) -> Char? {
        chars.first { $0.writable && short($0.uuid) == "ff02" } ?? chars.first { $0.writable }
    }

    public static func notify(_ chars: [Char], write: Char?) -> Char? {
        chars.first { $0.notify && short($0.uuid) == "ff03" }
            ?? chars.first { $0.notify && write != nil && $0.service == write!.service }
            ?? chars.first { $0.notify }
    }
}
