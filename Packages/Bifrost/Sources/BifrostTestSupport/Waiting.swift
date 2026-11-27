import Foundation
import Synchronization
import Testing

// The waits of the tests. Each wait has a limit on the real clock. At the limit, the wait records
// an issue at the line of the caller and gives false. Thus a defect stops a test with a message,
// and no test waits with no end or goes on in silence.
//
// A fake that knows when its event comes gives a TestSignal, and a test waits on it. A test of a
// real process or a real file waits for a condition with waitUntil. A test with a manual clock
// waits for the sleepers of the clock (ManualClock), and a gate tells when a caller waits at it
// (TestGate).

// The limit of each wait of the tests for a condition, a sleeper, a gate or a signal. It is wide,
// because a test host under load can start a program 20 s late, and a CI runner with few cores
// runs the main actor and the executors of thousands of tests at once. A wait ends as soon as its
// condition is true, so the limit only bounds a test that a defect holds. A wait that proves that
// something does not happen gives its own short limit (TestSignal.value(within:)).
package let testWaitLimit = Duration.seconds(60)

extension Trait where Self == TimeLimitTrait {
    // The time limit of a test: a guard against a test that hangs. It is wider than
    // testWaitLimit, so a test with a slow wait under load still ends by itself.
    package static var testTimeLimit: Self { .timeLimit(.minutes(3)) }
}

// Wait until the condition is true, for at most the limit (testWaitLimit). The wait checks the
// condition on the main actor, by default each 10 ms. The wait ends as soon as the condition is
// true. The result is false only at the limit, after the issue.
@MainActor
@discardableResult
package func waitUntil(
    within limit: Duration = testWaitLimit, every interval: Duration = .milliseconds(10),
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
) async -> Bool {
    let end = ContinuousClock.now + limit
    while !condition() {
        if ContinuousClock.now >= end {
            if condition() { return true }
            Issue.record(
                "The condition was not true after \(limit).", sourceLocation: sourceLocation)
            return false
        }
        try? await Task.sleep(for: interval)
    }
    return true
}

// A signal that a fake sends one time, for example "a caller waits at the gate" or "the clock
// has two sleepers". The first send sets the value. A wait gives the value at once when the
// signal came, else it waits with no thread until the signal or the limit.
package final class TestSignal: Sendable {
    private struct State {
        var value: Bool?
        var wake: CheckedContinuation<Bool, Never>?
    }

    private let state = Mutex(State())

    package init() {}

    // True after a send of true.
    package var sent: Bool { state.withLock { $0.value == true } }

    // Send the value. Only the first send counts.
    package func send(_ value: Bool = true) {
        let wake = state.withLock { s -> CheckedContinuation<Bool, Never>? in
            guard s.value == nil else { return nil }
            s.value = value
            defer { s.wake = nil }
            return s.wake
        }
        wake?.resume(returning: value)
    }

    // Wait for the signal, for at most the limit. At the limit the result is false and the
    // signal keeps false. This wait records no issue: the caller names what it waited for.
    package func value(within limit: Duration) async -> Bool {
        let timer = Task { [self] in
            do {
                try await Task.sleep(for: limit)
                send(false)
            } catch {}
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { (wake: CheckedContinuation<Bool, Never>) in
            let now = state.withLock { s -> Bool? in
                if let value = s.value { return value }
                s.wake = wake
                return nil
            }
            if let now { wake.resume(returning: now) }
        }
    }

    // Wait for the signal, for at most the limit. At the limit the wait records an issue that
    // names the event, and gives false.
    @discardableResult
    package func wait(
        for event: String, within limit: Duration = testWaitLimit,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        if await value(within: limit) { return true }
        Issue.record("No \(event) after \(limit).", sourceLocation: sourceLocation)
        return false
    }
}

// True when an item is at the path. A link is not followed.
package func fileExists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

// Wait for the end of a task that the test started, such as the task of a round. When the test
// is cancelled, for example by its time limit, the task is cancelled too. A plain await of its
// value would go on waiting, as the cancel of a test never reaches a task it made, so a round
// that a defect holds would hang the whole run instead of failing its test.
package func ended(_ task: Task<Void, Never>?) async {
    guard let task else { return }
    await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

// The same wait for a task with a result, which the wait gives back.
@discardableResult
package func ended<Value: Sendable>(_ task: Task<Value, Never>) async -> Value {
    await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

// The same for a task that can throw: the wait throws its error.
@discardableResult
package func ended<Value: Sendable>(_ task: Task<Value, any Error>) async throws -> Value {
    try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

// The end of a task, as a flag that a wait reads.
@MainActor
package final class TaskEnd {
    package private(set) var ended = false

    package init<T: Sendable>(_ task: Task<T, Never>) {
        Task { [weak self] in
            _ = await task.value
            self?.ended = true
        }
    }
}
