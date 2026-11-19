// The end of the turn of a PR session (docs/behaviour/reviews.md, "PR sessions"): one case per
// rule, with the edges of the settle time after work (10 s), the time with no start (120 s) and
// the grace of a missing row (60 s).
import BifrostTestSupport
import Testing

@testable import BifrostReviews

@Suite("the end rule of a round", .testTimeLimit)
struct RoundEndTests {
    private let limit = Duration.seconds(1800)

    private func check(
        _ row: SessionSignal?, seen: Bool = false, idle: Duration? = nil, now: Duration,
        ready: Bool = false, rowsSince: Duration = .zero
    ) -> EndCheck {
        RoundEnd.check(
            RoundEndInput(
                row: row, seenWorking: seen, idleSince: idle, startedAt: .zero,
                rowsSince: rowsSince, now: now, resultReady: ready, limit: limit))
    }

    // A prompt box ends the round at once, also past the limit and with a ready result.
    @Test func aPromptBoxIsBlockedAtOnce() {
        #expect(check(.prompt, now: .zero) == .blocked)
        #expect(check(.prompt, now: .seconds(5000), ready: true) == .blocked)
    }

    // A working row waits until the limit, also with a ready result.
    @Test func aWorkingRowWaitsForTheLimit() {
        #expect(check(.working, seen: true, now: .seconds(60), ready: true) == .wait(next: limit))
        #expect(check(.working, seen: true, now: limit, ready: true) == .timeout)
    }

    // An idle row with a ready result ends the turn at once, with no settle time.
    @Test func anIdleRowWithAReadyResultEndsAtOnce() {
        #expect(check(.idle, idle: .seconds(30), now: .seconds(30), ready: true) == .ended)
        #expect(check(.idle, now: .seconds(5), ready: true) == .ended)
    }

    // An idle row that worked, with no ready result (none, or one that does not pass the
    // check), ends after 10 s of idle.
    @Test func anIdleRowThatWorkedEndsAfterTheSettleTime() {
        let idle = Duration.seconds(30)
        #expect(
            check(.idle, seen: true, idle: idle, now: idle + .seconds(9))
                == .wait(next: idle + .seconds(10)))
        #expect(check(.idle, seen: true, idle: idle, now: idle + .seconds(10)) == .ended)
    }

    // An idle row that never worked and has no ready result ends after 120 s of idle.
    @Test func anIdleRowWithNoStartEndsAfter120s() {
        #expect(check(.idle, idle: .zero, now: .zero) == .wait(next: .seconds(120)))
        #expect(check(.idle, idle: .zero, now: .seconds(10)) == .wait(next: .seconds(120)))
        #expect(check(.idle, idle: .zero, now: .seconds(119)) == .wait(next: .seconds(120)))
        #expect(check(.idle, idle: .zero, now: .seconds(120)) == .ended)
    }

    // A row with no idle time yet waits for a signal.
    @Test func anIdleRowWithNoIdleTimeWaits() {
        #expect(check(.idle, now: .seconds(5)) == .wait(next: limit))
    }

    // A missing row is gone after 60 s of rows, also with a ready result.
    @Test func aMissingRowIsGoneAfter60s() {
        #expect(check(nil, now: .seconds(70), ready: true, rowsSince: .seconds(10)) == .gone)
        #expect(
            check(nil, now: .seconds(69), rowsSince: .seconds(10))
                == .wait(next: .seconds(70)))
    }

    // Past the limit, a ready result wins at an idle row, or once a missing row is gone; with no
    // ready result, or a working row, the round times out.
    @Test func pastTheLimitAReadyResultWins() {
        let after = limit + .seconds(1)
        #expect(check(.idle, idle: limit - .seconds(30), now: after) == .timeout)
        #expect(check(.idle, idle: limit, now: after, ready: true) == .ended)
        #expect(check(.working, now: after, ready: true) == .timeout)
        #expect(
            check(nil, now: after, ready: true, rowsSince: limit - .seconds(30))
                == .wait(next: limit + .seconds(30)))
        #expect(
            check(nil, now: limit + .seconds(30), ready: true, rowsSince: limit - .seconds(30))
                == .ended)
    }
}
