import Dispatch
import Darwin
import Synchronization
import Testing

// A gate that holds a piece of work until the test opens it, as a slow spawn, write, read or
// lookup does. Each open() lets one caller through, in the order of arrival. openAll() lets each
// caller through, now and later: a test calls it in a defer, so no caller waits after the test.
//
// An async caller waits in pass() and holds no thread. A synchronous caller waits in
// passBlocking(). The code under test calls a synchronous fake (a spawner, a write step, a lookup
// of Launch Services) on the blocking executor, never on a thread of the cooperative pool. Each
// wait has a limit. At the limit, the gate records an issue and lets the caller through, so a
// test with a defect ends with a message.
package final class TestGate: Sendable {
    private enum Waiter: Sendable {
        case task(TestSignal)
        case thread(DispatchSemaphore)

        func wake() {
            switch self {
            case .task(let signal): signal.send()
            case .thread(let semaphore): semaphore.signal()
            }
        }
    }

    private struct State {
        var permits = 0
        var allOpen = false
        var queue: [(id: Int, waiter: Waiter)] = []
        var nextId = 0
        var arrivals = 0
        var mainThread = false
        // The waits of the test for a number of held callers.
        var watchers: [(count: Int, signal: TestSignal)] = []
    }

    private let state = Mutex(State())
    private let limit: Duration

    package init(limit: Duration = .seconds(30)) { self.limit = limit }

    // The callers that wait at the gate now.
    package var holding: Int { state.withLock { $0.queue.count } }
    // The callers that came to the gate, also the callers that went through at once.
    package var arrivals: Int { state.withLock { $0.arrivals } }
    // True when a caller came to the gate on the main thread.
    package var ranOnTheMainThread: Bool { state.withLock { $0.mainThread } }

    // Let the first waiting caller through, or the next caller when none waits.
    package func open() {
        let waiter = state.withLock { s -> Waiter? in
            guard !s.queue.isEmpty else {
                s.permits += 1
                return nil
            }
            return s.queue.removeFirst().waiter
        }
        waiter?.wake()
    }

    // Let each caller through, now and later.
    package func openAll() {
        let waiters = state.withLock { s in
            s.allOpen = true
            defer { s.queue.removeAll() }
            return s.queue.map(\.waiter)
        }
        for waiter in waiters { waiter.wake() }
    }

    // The caller of an async fake waits here until the gate lets it through, or the limit.
    package func pass(sourceLocation: SourceLocation = #_sourceLocation) async {
        let signal = TestSignal()
        guard let id = arrive(.task(signal)) else { return }
        if await signal.value(within: limit) { return }
        if leave(id) {
            Issue.record("A caller waited \(limit) at the gate.", sourceLocation: sourceLocation)
        }
    }

    // The caller of a synchronous fake waits here until the gate lets it through, or the limit.
    package func passBlocking(sourceLocation: SourceLocation = #_sourceLocation) {
        let semaphore = DispatchSemaphore(value: 0)
        guard let id = arrive(.thread(semaphore)) else { return }
        let (seconds, attoseconds) = limit.components
        let wait = Double(seconds) + Double(attoseconds) / 1e18
        if semaphore.wait(timeout: .now() + wait) == .success { return }
        if leave(id) {
            Issue.record("A caller waited \(limit) at the gate.", sourceLocation: sourceLocation)
        }
    }

    // Wait until count callers wait at the gate, for at most the limit. At the limit the wait
    // records an issue and gives false.
    @discardableResult
    package func waitUntilHolding(
        _ count: Int = 1, within limit: Duration = .seconds(30),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        let signal = TestSignal()
        state.withLock { s in
            if s.queue.count >= count {
                signal.send()
            } else {
                s.watchers.append((count, signal))
            }
        }
        return await signal.wait(
            for: "caller \(count) at the gate", within: limit, sourceLocation: sourceLocation)
    }

    // Come to the gate. The result is nil when the caller goes through at once, else the place of
    // the caller in the queue.
    private func arrive(_ waiter: Waiter) -> Int? {
        let mainThread = pthread_main_np() != 0
        let (id, due) = state.withLock { s -> (Int?, [TestSignal]) in
            s.arrivals += 1
            if mainThread { s.mainThread = true }
            if s.allOpen { return (nil, []) }
            if s.permits > 0 {
                s.permits -= 1
                return (nil, [])
            }
            s.nextId += 1
            s.queue.append((s.nextId, waiter))
            let count = s.queue.count
            let due = s.watchers.filter { $0.count <= count }.map(\.signal)
            s.watchers.removeAll { $0.count <= count }
            return (s.nextId, due)
        }
        for signal in due { signal.send() }
        return id
    }

    // Leave the queue at the limit. The result is false when an open came first.
    private func leave(_ id: Int) -> Bool {
        state.withLock { s in
            guard let index = s.queue.firstIndex(where: { $0.id == id }) else { return false }
            s.queue.remove(at: index)
            return true
        }
    }
}
