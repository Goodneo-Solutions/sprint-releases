import CSPrint
import Foundation

/// What a print node reports while it runs.
public enum NodeEvent: Sendable {
    /// The node's state changed; persist it (it holds the node token).
    case state(NodeState)
    /// A job was printed or failed.
    case job(id: Int64, result: PrintResult)
    /// A log line.
    case log(String)
    /// A protocol sweep the node runs changed (show Next / Stop / choose).
    case sweep(SweepView)
    /// What the server holds for the node's printers changed (already applied).
    case settings(PrinterSettings)
    /// A cloud or peer job started or ended printing.
    case printing(PrintingEvent)
}

/// A host's answer to a remote command: nil lets the node answer it itself;
/// a thrown error fails the command with its text.
public typealias NodeCommandHandler = @Sendable (NodeCommand) async throws -> CommandAnswer?

/// The receiver of the core's event callback: the user pointer the C side
/// carries points at it.
private final class EventSink: @unchecked Sendable {
    let continuation: AsyncStream<NodeEvent>.Continuation
    let onCommand: NodeCommandHandler?
    private let lock = NSLock()
    private var _handle: Int64 = 0
    var handle: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return _handle }
        set { lock.lock(); _handle = newValue; lock.unlock() }
    }

    init(_ c: AsyncStream<NodeEvent>.Continuation, onCommand: NodeCommandHandler?) {
        continuation = c
        self.onCommand = onCommand
    }

    struct Raw: Decodable {
        var type: String
        var state: NodeState?
        var job_id: Int64?
        var result: PrintResult?
        var message: String?
        var sweep: SweepView?
        var settings: PrinterSettings?
        var printing: PrintingEvent?
        var request: Int64?
        var command: NodeCommand?
    }

    struct Answer: Encodable {
        var handled: Bool
        var output: String?
        var error: String?
    }

    func answer(_ request: Int64, _ command: NodeCommand) {
        guard let onCommand else { return }
        Task.detached { [self] in
            var a = Answer(handled: false)
            do {
                if let r = try await onCommand(command) { a = Answer(handled: true, output: r.output, error: r.error) }
            } catch {
                a = Answer(handled: true, error: (error as? SPrintError)?.message ?? "\(error)")
            }
            let js = (try? Bridge.json(a)) ?? "{}"
            _ = Bridge.take(sprint_node_command_answer(self.handle, request, js))
        }
    }

    func receive(_ json: String) {
        guard let ev = try? Bridge.decode(Raw.self, json) else { return }
        switch ev.type {
        case "settings": if let s = ev.settings { continuation.yield(.settings(s)) }
        case "printing": if let p = ev.printing { continuation.yield(.printing(p)) }
        case "command": if let r = ev.request, let c = ev.command { answer(r, c) }
        case "state": if let s = ev.state { continuation.yield(.state(s)) }
        case "job": if let r = ev.result { continuation.yield(.job(id: ev.job_id ?? 0, result: r)) }
        case "log": if let m = ev.message { continuation.yield(.log(m)) }
        case "sweep": if let v = ev.sweep { continuation.yield(.sweep(v)) }
        default: break
        }
    }
}

private let eventCallback: sprint_event_cb = { json, user in
    guard let json, let user else { return }
    Unmanaged<EventSink>.fromOpaque(user).takeUnretainedValue().receive(String(cString: json))
}

/// Turns this Mac into a Superroute print node: pairing (or headless
/// provisioning), the heartbeat with the registry's printers, jobs printed and
/// acknowledged, remote commands (diagnostics, probe report, protocol sweep) and
/// the MQTT doorbell.
public final class PrintNode: @unchecked Sendable {
    private let handle: Int64
    private let sink: EventSink
    /// The registry the node prints with.
    public let registry: PrinterRegistry
    /// The node's events, in order.
    public let events: AsyncStream<NodeEvent>

    /// - Parameters:
    ///   - commandsEvery: how often remote commands are polled (default 30 s; MQTT push makes it a fallback).
    ///   - commandTimeout: how long the node waits for `onCommand` (default 30 s; then it answers itself).
    ///   - onCommand: answers remote commands before the node does (`connectivity_test`,
    ///     `restart_agent`, or an override of a built-in one); return nil to let the node answer.
    public init(registry: PrinterRegistry, state: NodeState? = nil, device: DeviceInfo? = nil,
                agentVersion: String? = nil, reportSystemQueues: Bool = true,
                commandsEvery: TimeInterval? = nil, commandTimeout: TimeInterval? = nil,
                onCommand: NodeCommandHandler? = nil) throws {
        struct Config: Encodable {
            var state: NodeState?
            var device: DeviceInfo?
            var agent_version: String?
            var report_system_queues: Bool
            var command_hook: Bool
            var command_timeout_ms: Int?
            var commands_every_ms: Int?
        }
        var cont: AsyncStream<NodeEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1000)) { cont = $0 }
        sink = EventSink(cont, onCommand: onCommand)
        self.registry = registry
        let ms: (TimeInterval?) -> Int? = { $0.map { Int(($0 * 1000).rounded()) } }
        let config = try Bridge.json(Config(state: state, device: device, agent_version: agentVersion,
                                            report_system_queues: reportSystemQueues, command_hook: onCommand != nil,
                                            command_timeout_ms: ms(commandTimeout), commands_every_ms: ms(commandsEvery)))
        var err: UnsafeMutablePointer<CChar>?
        let h = sprint_node_new(config, registry.handle, eventCallback,
                                Unmanaged.passUnretained(sink).toOpaque(), &err)
        if h == 0 { throw Bridge.error(err) }
        handle = h
        sink.handle = h
    }

    deinit {
        // No event reaches the sink after sprint_node_free returns.
        sprint_node_free(handle)
        sink.continuation.finish()
    }

    /// Redeems a pairing code (or activation code) from the Print Nodes page.
    public func pair(_ code: String) throws { try Bridge.check(Bridge.take(sprint_node_pair(handle, code))) }

    /// Registers without a code; the node is claimed on the Print Nodes page.
    public func provision() throws { try Bridge.check(Bridge.take(sprint_node_provision(handle))) }

    /// Sends one heartbeat now.
    public func heartbeat() throws { try Bridge.check(Bridge.take(sprint_node_heartbeat(handle))) }

    /// Forgets the node token.
    public func unpair() { sprint_node_unpair(handle) }

    /// Runs the node in the background until ``stop()``.
    public func start() throws {
        if sprint_node_start(handle) != 0 { throw SPrintError(message: "the node is already running") }
    }

    /// Stops the node's background run.
    public func stop() { sprint_node_stop(handle) }

    /// The node's state.
    public func state() throws -> NodeState { try Bridge.decode(NodeState.self, Bridge.take(sprint_node_state(handle))) }

    /// The node's status.
    public func status() throws -> NodeStatus { try Bridge.decode(NodeStatus.self, Bridge.take(sprint_node_status(handle))) }

    /// The protocol sweeps the node is running.
    public func sweeps() throws -> [SweepView] { try Bridge.decode([SweepView].self, Bridge.take(sprint_node_sweeps(handle))) }

    /// Next, Stop or a manual choice (action next | stop | choose) for a running sweep.
    @discardableResult
    public func sweepPress(_ sweep: Int64, action: String, language: String? = nil) throws -> SweepState {
        struct R: Decodable { var ok: Bool; var state: SweepState?; var error: String? }
        let r = try Bridge.decode(R.self, Bridge.take(sprint_node_sweep_press(handle, sweep, action, language ?? "")))
        if !r.ok { throw SPrintError(message: r.error ?? "sweep press failed") }
        return r.state ?? SweepState()
    }

    /// What the server holds for the node's printers (languages, locks, default papers).
    public func printerSettings() throws -> PrinterSettings {
        try Bridge.decode(PrinterSettings.self, Bridge.take(sprint_node_printer_settings(handle)))
    }

    /// Sends languages chosen on this device (printer → language, "auto" drops
    /// the operator's choice) and applies them here. Printers in `corrections`
    /// carry the post-job check's answer, accepted even on a locked printer;
    /// any other change of a locked printer is refused. Returns the refused printers.
    @discardableResult
    public func pushLanguages(_ languages: [String: String], corrections: [String] = []) throws -> [String] {
        struct R: Decodable { var ok: Bool?; var refused: [String]?; var error: String? }
        let r = try Bridge.decode(R.self, Bridge.take(sprint_node_push_languages(handle, try Bridge.json(languages),
                                                                                  try Bridge.json(corrections))))
        if r.ok != true { throw SPrintError(message: r.error ?? "sprint: push failed") }
        return r.refused ?? []
    }

    /// Extra fields the heartbeat reports for a printer (`language_check`,
    /// `language_kept`, …); nil or empty removes them.
    public func setPrinterFields(_ printer: String, fields: [String: JSONValue]?) throws {
        let js = (fields?.isEmpty ?? true) ? "" : try Bridge.json(fields)
        try Bridge.check(Bridge.take(sprint_node_set_printer_fields(handle, printer, js)))
    }

    /// The same with any Encodable object as the fields.
    public func setPrinterFields<T: Encodable>(_ printer: String, encoding fields: T) throws {
        try Bridge.check(Bridge.take(sprint_node_set_printer_fields(handle, printer, try Bridge.json(fields))))
    }

    /// The jobs in flight (cloud jobs, and peer jobs printed through the registry).
    public func printing() throws -> [PrintingEvent] {
        try Bridge.decode([PrintingEvent].self, Bridge.take(sprint_node_printing(handle)))
    }
}
