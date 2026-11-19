// The lock of the plugin changes: the actions of Live details and of the skills, and their
// starts (docs/behaviour/live.md, One change at a time). Two changes at the same time could both
// change the settings file of the user, or get the same backup name. So a call of run that comes
// while another call holds the lock rejects with PluginFailure.busy, and its work does not run.
//
// A start goes through runFirst, or through first, which runs the start in a task of its own and
// counts it from the call, so a status read in the same turn of the main actor waits for it. A
// start takes the lock after the earlier starts and after the call that holds the lock, in the
// order of the calls. A call of run or afterFirst that comes while a start waits or runs waits
// until no start is left. When the last start ends, the lock decides for these calls in the order
// of the calls, with the usual rule: the first call of run gets the lock, each next call of run
// rejects with busy, and afterFirst runs its work without the lock. The tasks of the calls can
// run again in a different order, so a waiting task does not take the lock itself. So an action
// that comes during a start waits and does not reject, a status read (afterFirst) gives the state
// after the start, and an action and a status read never stop each other. A wait for a start
// ignores a cancel: a start always ends, because each claude call in it has a time limit.
//
// A call from inside the work that holds the lock is a nested call. A task-local marker shows
// it: the marker has the token of the hold, and each hold gets a new token. So a task that the
// work made and that runs after the end of the work is not nested: its token is old. A nested
// afterFirst runs its work at once, because its caller is already the only change, also while a
// start waits. A nested run or runFirst would wait for its own caller, so it rejects with busy
// at once, and the misuse action runs (an assertion failure in a Debug build).
@MainActor
package final class SerialLock {
    package nonisolated static let busyText = PluginFailure.busy.message

    // True while a call holds the lock.
    private var held = false
    // The token of the hold whose work runs now, and the last token.
    private var current: UInt64?
    private var lastToken: UInt64 = 0
    // The number of starts that wait for the lock or run.
    private var starts = 0
    // The starts that wait for the lock, in order.
    private var startQueue: [CheckedContinuation<Void, Never>] = []
    // The calls of run and afterFirst that wait for the end of the starts, in order.
    private var afterStarts: [Waiter] = []
    // A call that waits for the end of the starts. takesLock is true for run. The turn gives true
    // when the call can go on, and false when the call rejects with busy.
    private struct Waiter {
        let takesLock: Bool
        let turn: CheckedContinuation<Bool, Never>
    }
    // The action for a nested run or runFirst. A test records the text.
    private let misuse: @MainActor (String) -> Void

    package init(misuse: @escaping @MainActor (String) -> Void = { assertionFailure($0) }) {
        self.misuse = misuse
    }

    // The number of calls that wait now: the starts that wait for the lock, and the calls that
    // wait for the starts. A test waits for them.
    package var waiting: Int { startQueue.count + afterStarts.count }

    // Run the work with the lock, after the starts. A call that comes while another call holds
    // the lock rejects with busy. An error of the work goes to the caller, and the lock is free.
    package func run<T>(
        _ work: () async throws(PluginFailure) -> T
    ) async throws(PluginFailure) -> T {
        try refuseNested("run")
        guard await waitForStarts(takingLock: true) else { throw .busy }
        return try await hold(work)
    }

    // Run the work with the lock, as a start: after the earlier starts and after the call that
    // holds the lock. Each call of run and afterFirst that comes before the work ends waits for
    // it. Only a nested call rejects.
    package func runFirst(_ work: () async -> Void) async throws(PluginFailure) {
        try refuseNested("runFirst")
        starts += 1
        await takeTurn(work)
    }

    // Run the work as a start in a task of its own, and give the task. The start counts from this
    // call, so each call of run and afterFirst after this call waits for it, also in the same turn
    // of the main actor. The caller does not wait, so a call from inside the work that holds the
    // lock is not a misuse: the start runs after that work.
    package func first(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        starts += 1
        return Task { await self.takeTurn(work) }
    }

    // Take the turn of a start that counts in starts, run the work, then end the start. The last
    // start lets the calls that wait for the starts go on.
    private func takeTurn(_ work: () async -> Void) async {
        defer {
            starts -= 1
            if starts == 0 { endStarts() }
        }
        if !take() {
            await withCheckedContinuation { startQueue.append($0) }
        }
        await hold(work)
    }

    // Run the work after the starts, without the lock. So it never rejects with busy, and it
    // never stops a call of run. A nested call runs its work at once.
    package func afterFirst<T>(_ work: () async throws -> T) async rethrows -> T {
        if !isNested { _ = await waitForStarts(takingLock: false) }
        return try await work()
    }

    // Run the work of a call that holds the lock, with a new token in the marker. Then free the
    // lock, or give it to the next start. The marker gets a result, so the error of the work
    // keeps its type.
    private func hold<T, Failure: Error>(
        _ work: () async throws(Failure) -> T
    ) async throws(Failure) -> T {
        lastToken += 1
        let marker = LockHolder.Marker(lock: ObjectIdentifier(self), token: lastToken)
        current = marker.token
        defer {
            current = nil
            release()
        }
        let result = await LockHolder.$marker.withValue(marker) {
            () async -> Result<T, Failure> in
            do throws(Failure) {
                return .success(try await work())
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    // True when the current task runs inside the work that holds this lock now.
    private var isNested: Bool {
        guard let marker = LockHolder.marker, marker.lock == ObjectIdentifier(self) else {
            return false
        }
        return marker.token == current
    }

    private func refuseNested(_ call: String) throws(PluginFailure) {
        guard isNested else { return }
        misuse("SerialLock.\(call) was called inside the work that holds the same lock.")
        throw .busy
    }

    // Wait until no start waits or runs. A start that comes during the wait makes the wait
    // longer. With takingLock, also take the lock with the usual rule. The result is false when
    // another call holds the lock.
    private func waitForStarts(takingLock: Bool) async -> Bool {
        guard starts > 0 else { return !takingLock || take() }
        return await withCheckedContinuation {
            afterStarts.append(Waiter(takesLock: takingLock, turn: $0))
        }
    }

    // Let the calls that wait for the starts go on, in the order of the calls. Each call of run
    // takes the lock now, with the usual rule. So the first call of run holds the lock before its
    // task runs again, and a call that comes before that task runs rejects with busy.
    private func endStarts() {
        let waiters = afterStarts
        afterStarts.removeAll()
        for waiter in waiters {
            waiter.turn.resume(returning: !waiter.takesLock || take())
        }
    }

    // Take the lock when it is free. The result is false when a call holds the lock.
    private func take() -> Bool {
        guard !held else { return false }
        held = true
        return true
    }

    // Give the lock to the next start that waits, else free the lock.
    private func release() {
        if startQueue.isEmpty {
            held = false
        } else {
            startQueue.removeFirst().resume()
        }
    }
}

// The lock and the hold whose work the current task runs, or nil. A child task and a task that
// the work makes get the value too.
private enum LockHolder {
    struct Marker: Sendable {
        let lock: ObjectIdentifier
        let token: UInt64
    }

    @TaskLocal static var marker: Marker?
}
