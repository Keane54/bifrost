import Synchronization

// A clock that never waits: each sleep ends at once, moves the time to its deadline and records
// its span. A test of a gap between two steps reads the spans, and no step waits on the real
// clock.
package final class GapClock: Clock {
    package struct Instant: InstantProtocol {
        package var offset: Duration

        package init(offset: Duration) { self.offset = offset }

        package func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }
        package func duration(to other: Instant) -> Duration { other.offset - offset }
        package static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct State {
        var now = Instant(offset: .zero)
        var spans: [Duration] = []
    }

    private let state = Mutex(State())

    package init() {}

    package var now: Instant { state.withLock { $0.now } }
    package var minimumResolution: Duration { .zero }
    // The span of each sleep, in order.
    package var spans: [Duration] { state.withLock { $0.spans } }

    package func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        state.withLock { s in
            s.spans.append(s.now.duration(to: deadline))
            if s.now < deadline { s.now = deadline }
        }
        await Task.yield()
    }
}
