import Synchronization
import Testing

// A clock that moves only when a test moves it. A sleeper wakes when the time reaches its
// deadline. A test can wait until a number of sleepers wait: each change of the sleepers sends
// the signal of each wait that it meets. Each such wait has a limit on the real clock.
package final class ManualClock: Clock {
    package struct Instant: InstantProtocol {
        package var offset: Duration

        package init(offset: Duration) { self.offset = offset }

        package func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }
        package func duration(to other: Instant) -> Duration { other.offset - offset }
        package static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct Sleeper {
        var id: Int
        var deadline: Instant
        var wake: CheckedContinuation<Void, any Error>
    }

    // The number of sleepers that a wait of a test waits for.
    private enum Target {
        case atLeast(Int)
        case exactly(Int)

        func isMet(by count: Int) -> Bool {
            switch self {
            case .atLeast(let n): count >= n
            case .exactly(let n): count == n
            }
        }
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextId = 0
        var sleepers: [Sleeper] = []
        var watchers: [(target: Target, signal: TestSignal)] = []

        // Take the signals of the waits that the number of sleepers meets now.
        mutating func metWatchers() -> [TestSignal] {
            let count = sleepers.count
            let met = watchers.filter { $0.target.isMet(by: count) }.map(\.signal)
            watchers.removeAll { $0.target.isMet(by: count) }
            return met
        }
    }

    private let state = Mutex(State())

    package init() {}

    package var now: Instant { state.withLock { $0.now } }
    package var minimumResolution: Duration { .zero }
    package var sleeperCount: Int { state.withLock { $0.sleepers.count } }
    // The earliest deadline of the sleepers, or nil when no sleeper waits.
    package var nextDeadline: Instant? { state.withLock { $0.sleepers.map(\.deadline).min() } }

    private enum Outcome {
        case cancelled, due
        case waiting([TestSignal])
    }

    package func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { s in
            s.nextId += 1
            return s.nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (wake: CheckedContinuation<Void, any Error>) in
                let outcome: Outcome = state.withLock { s in
                    if Task.isCancelled { return .cancelled }
                    if deadline <= s.now { return .due }
                    s.sleepers.append(Sleeper(id: id, deadline: deadline, wake: wake))
                    return .waiting(s.metWatchers())
                }
                switch outcome {
                case .cancelled: wake.resume(throwing: CancellationError())
                case .due: wake.resume()
                case .waiting(let watchers): for watcher in watchers { watcher.send() }
                }
            }
        } onCancel: {
            let (removed, met) = state.withLock { s in
                let found = s.sleepers.first { $0.id == id }
                s.sleepers.removeAll { $0.id == id }
                return (found, s.metWatchers())
            }
            removed?.wake.resume(throwing: CancellationError())
            for watcher in met { watcher.send() }
        }
    }

    // Move the time. Each sleeper whose deadline came wakes.
    package func advance(by duration: Duration) {
        let (due, met) = state.withLock { s in
            s.now = s.now.advanced(by: duration)
            let now = s.now
            let due = s.sleepers.filter { $0.deadline <= now }
            s.sleepers.removeAll { $0.deadline <= now }
            return (due, s.metWatchers())
        }
        for sleeper in due { sleeper.wake.resume() }
        for watcher in met { watcher.send() }
    }

    // Wait until at least count sleepers wait, for at most the limit on the real clock. At the
    // limit, the wait records an issue and gives false: a timer that does not sleep (a defect)
    // fails the test, and the test does not wait with no end.
    @discardableResult
    package func waitForSleepers(
        _ count: Int, within limit: Duration = testWaitLimit,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await wait(for: .atLeast(count), "\(count) sleepers", limit, sourceLocation)
    }

    // Wait until exactly count sleepers wait, for at most the limit on the real clock.
    @discardableResult
    package func waitForSleepers(
        exactly count: Int, within limit: Duration = testWaitLimit,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await wait(for: .exactly(count), "exactly \(count) sleepers", limit, sourceLocation)
    }

    // Wait until no sleeper waits, for at most the limit on the real clock.
    @discardableResult
    package func waitUntilNoSleepers(
        within limit: Duration = testWaitLimit, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await wait(for: .exactly(0), "end of the sleepers", limit, sourceLocation)
    }

    private func wait(
        for target: Target, _ event: String, _ limit: Duration, _ sourceLocation: SourceLocation
    ) async -> Bool {
        let signal = TestSignal()
        state.withLock { s in
            if target.isMet(by: s.sleepers.count) {
                signal.send()
            } else {
                s.watchers.append((target, signal))
            }
        }
        let met = await signal.wait(for: event, within: limit, sourceLocation: sourceLocation)
        if !met { state.withLock { s in s.watchers.removeAll { $0.signal === signal } } }
        return met
    }
}
