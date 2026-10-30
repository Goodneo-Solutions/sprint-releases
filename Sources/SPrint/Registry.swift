import CSPrint
import Foundation

/// The configured printers and the default one. Jobs to one printer run one at
/// a time, in arrival order. Safe to use from any thread or task: every call is
/// a call into the core, which holds its own locks.
public final class PrinterRegistry: @unchecked Sendable {
    let handle: Int64

    /// A registry in memory, or loaded from and saved to `path`.
    public init(path: String? = nil) throws {
        var err: UnsafeMutablePointer<CChar>?
        let h = sprint_registry_open(path ?? "", &err)
        if h == 0 { throw Bridge.error(err) }
        handle = h
    }

    deinit { sprint_registry_close(handle) }

    private struct File: Decodable {
        var `default`: String?
        var printers: [TargetPrinter]?
        var error: String?
    }

    private func read() throws -> File {
        let f = try Bridge.decode(File.self, Bridge.take(sprint_registry_list(handle)))
        if let e = f.error { throw SPrintError(message: e) }
        return f
    }

    /// The printers, by name.
    public func printers() throws -> [TargetPrinter] { try read().printers ?? [] }

    /// The default printer's name.
    public func defaultName() throws -> String? {
        let d = try read().default
        return (d ?? "").isEmpty ? nil : d
    }

    /// A printer by its name.
    public func printer(named name: String) throws -> TargetPrinter? {
        try printers().first { $0.name == name }
    }

    /// Adds or replaces a printer (the first saved becomes the default).
    public func save(_ printer: TargetPrinter) throws {
        try Bridge.check(Bridge.take(sprint_registry_save(handle, try Bridge.json(printer))))
    }

    /// Removes a printer.
    public func remove(_ name: String) throws { try Bridge.check(Bridge.take(sprint_registry_remove(handle, name))) }

    /// Makes a printer the default.
    public func setDefault(_ name: String) throws { try Bridge.check(Bridge.take(sprint_registry_set_default(handle, name))) }

    /// Runs a job on the printer it names, or the default printer.
    public func print(_ job: PrintJob) throws -> PrintResult {
        try Bridge.decode(PrintResult.self, Bridge.take(sprint_registry_print(handle, try Bridge.json(job))))
    }

    /// Turns the fallback chain for label jobs on or off (off by default).
    public func setFallback(_ on: Bool) { _ = sprint_registry_set_fallback(handle, on ? 1 : 0) }

    /// A printer's fallback chain state.
    public func fallbackState(_ name: String) throws -> FallbackState {
        try Bridge.decode(FallbackState.self, Bridge.take(sprint_registry_fallback_state(handle, name)))
    }

    /// Reopens every path of a printer's fallback chain.
    public func resetFallback(_ name: String) { sprint_registry_reset_fallback(handle, name) }

    /// The superprinter.probe/1 report of a printer (JSON).
    public func probeReport(_ name: String) throws -> String {
        let s = Bridge.take(sprint_registry_probe_report(handle, name))
        guard s.hasPrefix("{\"schema\"") else {
            throw SPrintError(message: (try? Bridge.decode(Bridge.OK.self, s).error) ?? "probe report failed")
        }
        return s
    }
}
