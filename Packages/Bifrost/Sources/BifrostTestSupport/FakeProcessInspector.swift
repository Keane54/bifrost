import BifrostSessions
import Darwin
import Synchronization
import Testing

// A process inspector that reads no process. The test sets each answer. The fake records each
// call, and the calls that ran on the main thread. With no size, the size read fails. A gate can
// hold the next device read, so a test can act during the read.
package final class FakeProcessInspector: ProcessInspector {
    // One call of the inspector.
    package enum Call: Sendable, Equatable {
        case terminalApps([pid_t])
        case terminalDevice(pid_t)
        case terminalSize(String)
        case identity(pid_t)
        case attachClients(own: pid_t)
    }

    private struct State {
        var table: ProcessTable?
        var identities: [pid_t: ProcessIdentity] = [:]
        var device: String?
        // The answers of the size reads: each read takes the next answer, and the last stays.
        var sizes: [TerminalSize?]
        var calls: [Call] = []
        var mainThreadCalls = 0
        // The gates of the next device reads, in order.
        var gates: [TestGate] = []

        mutating func nextSize() -> TerminalSize? {
            sizes.count > 1 ? sizes.removeFirst() : sizes.first ?? nil
        }
    }

    private let state: Mutex<State>

    package init(
        table: ProcessTable? = nil, device: String? = "/dev/ttys900", size: TerminalSize? = nil
    ) {
        state = Mutex(State(table: table, device: device, sizes: [size]))
    }

    // The processes of the walk of terminalApps, and of the attach clients (the arguments and
    // the start time of each entry). A PID that the table does not have ends the walk.
    package var table: ProcessTable? {
        get { state.withLock { $0.table } }
        set { state.withLock { $0.table = newValue } }
    }

    // The answers of identity(of:). A PID that the map does not have is a process that does not
    // exist.
    package var identities: [pid_t: ProcessIdentity] {
        get { state.withLock { $0.identities } }
        set { state.withLock { $0.identities = newValue } }
    }

    // The answer of terminalDevice. nil: the process has no terminal.
    package var device: String? {
        get { state.withLock { $0.device } }
        set { state.withLock { $0.device = newValue } }
    }

    // The answer of terminalSize. nil: the read fails.
    package var size: TerminalSize? {
        get { state.withLock { $0.sizes.first ?? nil } }
        set { state.withLock { $0.sizes = [newValue] } }
    }

    // The answers of the next size reads, in order. The last answer stays.
    package func answer(_ sizes: TerminalSize?...) { state.withLock { $0.sizes = sizes } }

    // Each call, in order.
    package var calls: [Call] { state.withLock { $0.calls } }
    // The pid of each device read, in order.
    package var reads: [pid_t] {
        calls.compactMap { call in
            if case .terminalDevice(let pid) = call { pid } else { nil }
        }
    }
    // The number of calls that ran on the main thread.
    package var mainThreadCalls: Int { state.withLock { $0.mainThreadCalls } }

    package func terminalApps(of pids: [pid_t]) async -> TerminalApps {
        let table = record(.terminalApps(pids)) { $0.table } ?? [:]
        return TerminalApps(of: pids) { table.terminalApp(of: $0) }
    }

    // Hold the next device read at the gate, as a slow read does.
    package func holdNext(_ gate: TestGate) {
        state.withLock { $0.gates.append(gate) }
    }

    package func terminalDevice(of pid: pid_t) async -> String? {
        let gate = state.withLock { s in
            s.calls.append(.terminalDevice(pid))
            return s.gates.isEmpty ? nil : s.gates.removeFirst()
        }
        await gate?.pass()
        return answer { $0.device }
    }

    package func terminalSize(ofDevice device: String) async -> TerminalSize? {
        record(.terminalSize(device)) { $0.nextSize() }
    }

    package func identity(of pid: pid_t) async -> ProcessIdentity? {
        record(.identity(pid)) { $0.identities[pid] }
    }

    package func attachClients(own: pid_t) async -> [AttachClient] {
        let table = record(.attachClients(own: own)) { $0.table } ?? [:]
        return table.attachClients(own: own)
    }

    private func record<T: Sendable>(_ call: Call, _ answer: (inout State) -> T) -> T {
        state.withLock { $0.calls.append(call) }
        return self.answer(answer)
    }

    private func answer<T: Sendable>(_ answer: (inout State) -> T) -> T {
        let mainThread = pthread_main_np() != 0
        return state.withLock { s in
            if mainThread { s.mainThreadCalls += 1 }
            return answer(&s)
        }
    }
}
