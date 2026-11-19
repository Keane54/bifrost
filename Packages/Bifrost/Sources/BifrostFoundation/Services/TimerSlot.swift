// One timer that can wait at a time. A start stops the timer that waits, and a
// stop stops it. A timer that stopped never acts: a sleep can end after the stop of its timer,
// so after the sleep the task checks Task.isCancelled and the generation of the slot. A newer
// timer has a newer generation.
//
// The deadline is the time of the start plus the duration, on the injected clock. So a late
// start of the task does not make the wait longer. The action runs on the main actor, after the
// slot is empty again: the action can start the next timer.
@MainActor
package final class TimerSlot {
    private let clock: any Clock<Duration>
    private var generation = 0
    private var current: Task<Void, Never>?

    package init(clock: any Clock<Duration>) {
        self.clock = clock
    }

    isolated deinit {
        current?.cancel()
    }

    // The task of the timer that waits or acts, or nil. A test waits for it.
    package var task: Task<Void, Never>? { current }

    // True while a timer waits.
    package var isRunning: Bool { current != nil }

    // Start the timer: the action runs after the duration. A timer that waits stops first.
    package func start(after duration: Duration, _ action: @escaping @MainActor () async -> Void) {
        stop()
        generation += 1
        current = makeTask(on: clock, after: duration, generation: generation, action)
    }

    // Stop the timer that waits. Its action never runs.
    package func stop() {
        current?.cancel()
        current = nil
    }

    private func makeTask<C: Clock>(
        on clock: C, after duration: Duration, generation: Int,
        _ action: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> where C.Duration == Duration {
        let deadline = clock.now.advanced(by: duration)
        return Task { [weak self] in
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.current = nil
            await action()
        }
    }
}
