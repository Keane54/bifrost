// The injected clock as the time since the start of the owner. The owner keeps times as a
// Duration since this start, so a manual clock and the real clock work the same way. The
// generic init opens the type of the instants of the clock.
package struct Timeline: Sendable {
    // The time since the start.
    package let now: @Sendable () -> Duration
    private let sleeper: @Sendable (Duration) async throws -> Void

    package init<C: Clock<Duration>>(_ clock: C) {
        let start = clock.now
        now = { start.duration(to: clock.now) }
        sleeper = { time in try await clock.sleep(until: start.advanced(by: time), tolerance: nil) }
    }

    // Sleep until the time. A cancel of the task throws.
    package func sleep(until time: Duration) async throws {
        try await sleeper(time)
    }
}
