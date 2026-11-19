// One debounce: one task that sleeps to a deadline. A new event only moves the deadline, so a
// burst of events makes one task and one run of the action, after the quiet time of the last
// event. The deadline is kept as a time since the start of the debouncer, on the injected clock.
// A stop never runs the action. The action that runs is not stopped: it gives the next debounce
// its own task. The action runs on the main actor, with the debouncer empty again, so the action
// can schedule the next run.
@MainActor
package final class Debouncer {
    private let timeline: Timeline
    private var deadline: Duration?
    // The deadline that the task sleeps to now, or nil when no task sleeps.
    private var sleepingTo: Duration?
    private var action: (@MainActor () async -> Void)?
    private var current: Task<Void, Never>?
    private var generation = 0

    package init(clock: any Clock<Duration>) {
        timeline = Timeline(clock)
    }

    isolated deinit {
        current?.cancel()
    }

    // The task that waits, or nil. A test waits for it.
    package var task: Task<Void, Never>? { current }

    // True from an event until the action starts or a stop.
    package var isPending: Bool { deadline != nil }

    // True when the time that the task sleeps to came, and the task did not run yet. A test that
    // moves a manual clock waits until no timer is due.
    package var isDue: Bool { sleepingTo.map { $0 <= timeline.now() } ?? false }

    // An event: run the action after the quiet time. The last action and the last event count.
    package func schedule(after quiet: Duration, _ action: @escaping @MainActor () async -> Void) {
        let target = timeline.now() + quiet
        deadline = target
        self.action = action
        // The task that waits sleeps to a time that is not later: it sleeps again, up to the new
        // deadline.
        if let sleepingTo, sleepingTo <= target { return }
        current?.cancel()
        generation += 1
        let mine = generation
        sleepingTo = target
        current = makeTask(mine, target: target)
    }

    // Stop: the action never runs.
    package func cancel() {
        deadline = nil
        sleepingTo = nil
        action = nil
        generation += 1
        current?.cancel()
        current = nil
    }

    // The task sleeps with no strong reference to the debouncer, as TimerSlot does. So a dropped
    // debouncer stops its task (isolated deinit), and its action never runs. The task holds the
    // debouncer only after a sleep, to read the deadline and to run the action.
    private func makeTask(_ mine: Int, target first: Duration) -> Task<Void, Never> {
        Task { [weak self, timeline] in
            var target = first
            while true {
                do {
                    try await timeline.sleep(until: target)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self, self.generation == mine else { return }
                // An event moved the deadline while the task slept: sleep again.
                if let moved = self.deadline, moved > target {
                    target = moved
                    self.sleepingTo = moved
                    continue
                }
                await self.fire()
                return
            }
        }
    }

    private func fire() async {
        let run = action
        deadline = nil
        sleepingTo = nil
        action = nil
        current = nil
        await run?()
    }
}
