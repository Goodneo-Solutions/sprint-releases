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
}

/// The receiver of the core's event callback: the user pointer the C side
/// carries points at it.
private final class EventSink: @unchecked Sendable {
    let continuation: AsyncStream<NodeEvent>.Continuation

    init(_ c: AsyncStream<NodeEvent>.Continuation) { continuation = c }

    struct Raw: Decodable {
        var type: String
        var state: NodeState?
        var job_id: Int64?
        var result: PrintResult?
        var message: String?
        var sweep: SweepView?
    }

    func receive(_ json: String) {
        guard let ev = try? Bridge.decode(Raw.self, json) else { return }
        switch ev.type {
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

    public init(registry: PrinterRegistry, state: NodeState? = nil, device: DeviceInfo? = nil,
                agentVersion: String? = nil, reportSystemQueues: Bool = true) throws {
        struct Config: Encodable {
            var state: NodeState?
            var device: DeviceInfo?
            var agent_version: String?
            var report_system_queues: Bool
        }
        var cont: AsyncStream<NodeEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1000)) { cont = $0 }
        sink = EventSink(cont)
        self.registry = registry
        let config = try Bridge.json(Config(state: state, device: device, agent_version: agentVersion,
                                            report_system_queues: reportSystemQueues))
        var err: UnsafeMutablePointer<CChar>?
        let h = sprint_node_new(config, registry.handle, eventCallback,
                                Unmanaged.passUnretained(sink).toOpaque(), &err)
        if h == 0 { throw Bridge.error(err) }
        handle = h
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
}
