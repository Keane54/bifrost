import Synchronization

// The cancel of the caller of one action of the Live details control or of the skills control
// (docs/behaviour/live.md, The actions). Before the first plugin write, a cancel ends the action
// and cancels its task, so a list read stops at once. From the first write on, a cancel does
// nothing: the plugin state changed, so the action runs to its end. The call of the cancel
// handler can come from any thread, so a mutex keeps the state.
package final class ActionCancel: Sendable {
    private struct State {
        var cancelled = false
        var wrote = false
        var cancelTask: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    // Run the steps of an action in the lock, in a task of its own, and give their result. The
    // task gets the task-local values of the caller, so a call from inside the work that holds
    // the lock is still a nested call of the lock (SerialLock). A cancel of the caller ends the
    // action only before its first plugin write (beginWrite). From then on, the caller waits for
    // the end of the action.
    @MainActor
    package static func run<Value: Sendable>(
        in lock: SerialLock,
        _ steps: @escaping @MainActor (ActionCancel) async throws(PluginFailure) -> Value
    ) async throws(PluginFailure) -> Value {
        let cancel = ActionCancel()
        let work = Task { @MainActor () -> Result<Value, PluginFailure> in
            do throws(PluginFailure) {
                return .success(try await lock.run { () async throws(PluginFailure) in
                    try await steps(cancel)
                })
            } catch {
                return .failure(error)
            }
        }
        cancel.watch(work)
        return try await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            cancel.request()
        }.get()
    }

    // True when a cancel came before the first write.
    package var isCancelled: Bool { state.withLock { $0.cancelled } }

    // Mark the first write, in one step with the check for a cancel. False when a cancel came
    // first: then the write must not start.
    package func beginWrite() -> Bool {
        state.withLock { s in
            if s.cancelled { return false }
            s.wrote = true
            return true
        }
    }

    // The task of the action. A cancel that came before it cancels it at once.
    private func watch<Success: Sendable>(_ task: Task<Success, Never>) {
        let cancelNow = state.withLock { s in
            s.cancelTask = { task.cancel() }
            return s.cancelled
        }
        if cancelNow { task.cancel() }
    }

    // The caller cancelled. Before the first write, the action ends.
    private func request() {
        let cancelTask = state.withLock { s -> (@Sendable () -> Void)? in
            guard !s.wrote else { return nil }
            s.cancelled = true
            return s.cancelTask
        }
        cancelTask?()
    }
}
