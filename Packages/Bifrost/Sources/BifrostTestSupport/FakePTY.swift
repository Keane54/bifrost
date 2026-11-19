import BifrostFoundation
import BifrostSessions
import Darwin
import Synchronization
import Testing

// A fake PTY for the tests of the PTY manager, the session input and the chat terminal. No child
// process starts and no signal goes to a process: the fake child only records its calls.

// A child that records its calls. A test gives it output and an exit.
package final class FakeChild: PTYChild {
    struct State {
        var written: [[UInt8]] = []
        var resizes: [TerminalSize] = []
        // Each signal call, also after the exit.
        var signals: [CloseSignal] = []
        var signalsAfterExit = 0
        var waiting: [UInt8] = []
        var notified = false
        var drains = 0
        // True after the exit (the reap).
        var exited = false
    }

    package let pid: pid_t
    package let events: AsyncStream<PTYEvent>
    private let sendEvent: AsyncStream<PTYEvent>.Continuation
    let state = Mutex(State())

    init(pid: pid_t) {
        self.pid = pid
        (events, sendEvent) = AsyncStream.makeStream()
    }

    package var written: [[UInt8]] { state.withLock { $0.written } }
    package var resizes: [TerminalSize] { state.withLock { $0.resizes } }
    package var signals: [CloseSignal] { state.withLock { $0.signals } }
    package var signalsAfterExit: Int { state.withLock { $0.signalsAfterExit } }
    package var waiting: Int { state.withLock { $0.waiting.count } }
    package var drains: Int { state.withLock { $0.drains } }

    package func write(_ bytes: [UInt8]) { state.withLock { $0.written.append(bytes) } }
    package func resize(_ size: TerminalSize) { state.withLock { $0.resizes.append(size) } }
    package func signal(_ s: CloseSignal) {
        state.withLock {
            $0.signals.append(s)
            if $0.exited { $0.signalsAfterExit += 1 }
        }
    }

    // The rule of PTYProcess: one bytesWaiting event while bytes wait.
    package func drain(limit: Int) -> [UInt8] {
        let (bytes, more) = state.withLock { s in
            s.drains += 1
            let bytes = Array(s.waiting.prefix(limit))
            s.waiting.removeFirst(bytes.count)
            s.notified = !s.waiting.isEmpty
            return (bytes, s.notified)
        }
        if more { sendEvent.yield(.bytesWaiting) }
        return bytes
    }

    package func emitData(_ text: String) { emitBytes(Array(text.utf8)) }

    package func emitBytes(_ bytes: [UInt8]) {
        let notify = state.withLock { s in
            s.waiting += bytes
            defer { s.notified = true }
            return !s.notified
        }
        if notify { sendEvent.yield(.bytesWaiting) }
    }

    package func emitExit(_ code: Int32) {
        reap()
        sendEvent.yield(.exited(code))
        sendEvent.finish()
    }

    // The child ended, and the manager did not get the exit yet. A later signal counts as a
    // signal after the exit.
    package func reap() {
        state.withLock { $0.exited = true }
    }
}

// A spawner that records each spawn and makes a FakeChild. The pids start at firstPid. A gate
// can hold the next spawn, and a hook can give the new child output or an exit before the spawn
// ends.
package final class FakeSpawner: PTYSpawner {
    package struct Spawn: Sendable {
        package var program: String
        package var arguments: [String]
        package var environment: [String: String]
        package var directory: String
        package var size: TerminalSize
    }

    private struct State {
        var spawns: [Spawn] = []
        var children: [FakeChild] = []
        var error: PTYError?
        var gates: [TestGate?] = []
        var hooks: [(@Sendable (FakeChild) -> Void)?] = []
    }

    private let state = Mutex(State())
    private let firstPid: Int32

    package init(firstPid: Int32 = 4242) { self.firstPid = firstPid }

    package var spawns: [Spawn] { state.withLock { $0.spawns } }
    package var fakes: [FakeChild] { state.withLock { $0.children } }

    package func failNext(_ error: PTYError) { state.withLock { $0.error = error } }

    // The gate and the hook of the next spawn that has none. nil: no gate or no hook.
    package func holdNext(
        _ gate: TestGate?, then hook: (@Sendable (FakeChild) -> Void)? = nil
    ) {
        state.withLock { s in
            s.gates.append(gate)
            s.hooks.append(hook)
        }
    }

    package func spawn(
        program: String, arguments: [String], environment: [String: String],
        directory: String, size: TerminalSize
    ) throws(PTYError) -> any PTYChild {
        let (gate, hook) = state.withLock { s in
            s.gates.isEmpty ? (nil, nil) : (s.gates.removeFirst(), s.hooks.removeFirst())
        }
        gate?.passBlocking()
        let result: Result<FakeChild, PTYError> = state.withLock { s in
            if let error = s.error {
                s.error = nil
                return .failure(error)
            }
            let pid = firstPid + Int32(s.children.count)
            let child = FakeChild(pid: pid)
            s.spawns.append(Spawn(
                program: program, arguments: arguments, environment: environment,
                directory: directory, size: size))
            s.children.append(child)
            return .success(child)
        }
        let child = try result.get()
        hook?(child)
        return child
    }
}

// A runner that never runs a program.
package struct NoRunner: CommandRunner {
    package init() {}

    package func run(_ command: Command) async -> ExecResult {
        ExecResult(.notStarted)
    }
}
