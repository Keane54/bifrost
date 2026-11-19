import BifrostSessions
import Darwin
import Synchronization
import Testing

// The real PTY spawner, with a record of each spawn and of each call of its children: the
// arguments, the open size, each resize, each close signal and each kill that the PTY process
// sends. Then the kill goes out with the default sender of PTYProcess, so the tests cover that
// sender. A gate can hold the next spawn, as a slow posix_spawn does. The PTY tests, the chat
// tests, the session input tests and the app services tests use it.
package final class RecordingPTYSpawner: PTYSpawner {
    // A close signal that the manager gave to a child.
    package struct Signal: Sendable, Equatable {
        package var pid: pid_t
        package var signal: CloseSignal

        package init(_ pid: pid_t, _ signal: CloseSignal) {
            self.pid = pid
            self.signal = signal
        }
    }

    // A kill that a PTY process sent: the pid and the signal number.
    package struct Kill: Sendable, Equatable {
        package var pid: pid_t
        package var number: Int32

        package init(_ pid: pid_t, _ number: Int32) {
            self.pid = pid
            self.number = number
        }
    }

    // Each start of a spawn and each close signal, in order.
    package enum Event: Sendable, Equatable {
        case spawn(TerminalSize)
        case signal(pid_t, CloseSignal)
    }

    package struct Log: Sendable {
        package var arguments: [[String]] = []
        // The pid of each child, at its spawn.
        package var pids: [pid_t] = []
        package var opens: [TerminalSize] = []
        package var resizes: [TerminalSize] = []
        package var signals: [Signal] = []
        package var kills: [Kill] = []
        package var events: [Event] = []
        // The spawns that started and did not end.
        package var spawning = 0
        package var children: [PTYProcess] = []
        // The gates of the next spawns, in order.
        var gates: [TestGate] = []
        // The arguments of the next spawns in place of the arguments of the manager.
        var replacement: [String]?
    }

    // The log of the spawner and of its children.
    private final class Shared: Sendable {
        let log = Mutex(Log())
    }

    private final class Child: PTYChild {
        let child: PTYProcess
        let shared: Shared

        init(_ child: PTYProcess, shared: Shared) {
            self.child = child
            self.shared = shared
        }

        var pid: pid_t { child.pid }
        var events: AsyncStream<PTYEvent> { child.events }
        func write(_ bytes: [UInt8]) { child.write(bytes) }
        func drain(limit: Int) -> [UInt8] { child.drain(limit: limit) }

        func resize(_ size: TerminalSize) {
            shared.log.withLock { $0.resizes.append(size) }
            child.resize(size)
        }

        func signal(_ s: CloseSignal) {
            shared.log.withLock { log in
                log.signals.append(Signal(child.pid, s))
                log.events.append(.signal(child.pid, s))
            }
            child.signal(s)
        }
    }

    private let shared = Shared()

    package init() {}

    package var log: Log { shared.log.withLock { $0 } }

    // The PTY process of each spawn, in order.
    package var children: [PTYProcess] { log.children }

    // Hold the next spawn at the gate.
    package func holdNext(_ gate: TestGate) {
        shared.log.withLock { $0.gates.append(gate) }
    }

    // The arguments of the next spawns in place of the arguments of the manager. nil: the
    // arguments of the manager. A test of the PTY itself runs a program with its own arguments.
    package func use(arguments: [String]?) {
        shared.log.withLock { $0.replacement = arguments }
    }

    package func spawn(
        program: String, arguments: [String], environment: [String: String],
        directory: String, size: TerminalSize
    ) throws(PTYError) -> any PTYChild {
        let (gate, used) = shared.log.withLock { log in
            let used = log.replacement ?? arguments
            log.arguments.append(used)
            log.opens.append(size)
            log.events.append(.spawn(size))
            log.spawning += 1
            return (log.gates.isEmpty ? nil : log.gates.removeFirst(), used)
        }
        defer { shared.log.withLock { $0.spawning -= 1 } }
        gate?.passBlocking()
        let shared = self.shared
        let child = try PTYProcess(
            program: program, arguments: used, environment: environment,
            directory: directory, size: size,
            send: { pid, number in
                shared.log.withLock { $0.kills.append(Kill(pid, number)) }
                PTYProcess.defaultSend(pid, number)
            })
        shared.log.withLock { log in
            log.pids.append(child.pid)
            log.children.append(child)
        }
        return Child(child, shared: shared)
    }
}
