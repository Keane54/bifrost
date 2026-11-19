// The end of the turn of a PR session (docs/behaviour/reviews.md, "PR sessions"). The rule
// follows the real signals: the session row, and a result file that passes the check of the
// round (result ready). A file that is there but does not pass the check (a part of a write, or a
// bad file) is no signal. The time limits are fail-safes only. The times are on the injected
// clock (a Duration since the start of its Timeline). The first rule that holds gives the result:
// 1. A prompt box ends the round at once: a session of a round must never ask.
// 2. Past the time limit: a ready result wins at an idle row, or once a missing row is gone for
//    goneGrace, as after a quit of Bifrost during the turn; else a timeout.
// 3. A missing row for goneGrace: the session went.
// 4. A working row waits.
// 5. An idle row with a ready result: the turn ended, at once.
// 6. An idle row that worked, with no ready result, for settle: the turn ended with no result.
//    The settle time stands in for a signal that does not exist: Claude Code gives no "turn
//    ended" event, and the registry samples the rows each 2 s, so an idle sample can come
//    between two tools, before more work.
// 7. An idle row that never worked, for noStart: the session did not start to work.

// What the session row shows for the rule.
package enum SessionSignal: Sendable, Equatable {
    case working
    // The red box of a prompt.
    case prompt
    // Idle, parked, a yellow box or an error box.
    case idle
}

package enum EndCheck: Sendable, Equatable {
    // No end yet. next is the time on the clock at which the rule can give another result with
    // no new signal, or nil when only a signal can change it.
    case wait(next: Duration?)
    case ended
    // The row went for goneGrace.
    case gone
    // The session shows a prompt.
    case blocked
    case timeout
}

package struct RoundEndInput: Sendable, Equatable {
    // The row of the session, or nil when the rows do not have it.
    package var row: SessionSignal?
    // True when the row was working at some time in the round.
    package var seenWorking: Bool
    // The time of the first idle sample after the last working one, or nil.
    package var idleSince: Duration?
    // The start of the session.
    package var startedAt: Duration
    // The time of the first rows after the start, or after a restart.
    package var rowsSince: Duration
    package var now: Duration
    // True when the result file is there and passes the check of the round.
    package var resultReady: Bool
    // The time limit of the round.
    package var limit: Duration

    package init(
        row: SessionSignal?, seenWorking: Bool, idleSince: Duration?, startedAt: Duration,
        rowsSince: Duration, now: Duration, resultReady: Bool, limit: Duration
    ) {
        self.row = row
        self.seenWorking = seenWorking
        self.idleSince = idleSince
        self.startedAt = startedAt
        self.rowsSince = rowsSince
        self.now = now
        self.resultReady = resultReady
        self.limit = limit
    }
}

package enum RoundEnd {
    package static let settle = Duration.seconds(10), noStart = Duration.seconds(120)
    package static let goneGrace = Duration.seconds(60)

    package static func check(_ input: RoundEndInput) -> EndCheck {
        if input.row == .prompt { return .blocked }
        let deadline = input.startedAt + input.limit
        if input.now >= deadline { return pastLimit(input) }
        guard let row = input.row else {
            let gone = input.rowsSince + goneGrace
            return input.now >= gone ? .gone : .wait(next: min(gone, deadline))
        }
        guard row == .idle else { return .wait(next: deadline) }
        if input.resultReady { return .ended }
        guard let idleSince = input.idleSince else { return .wait(next: deadline) }
        // With no ready result: the settle time after work, else the time with no start. A
        // result that lands checks the rule again.
        let end = idleSince + (input.seenWorking ? settle : noStart)
        return input.now >= end ? .ended : .wait(next: min(end, deadline))
    }

    // Past the limit: a ready result wins at an idle row, or once a missing row is gone; else the
    // round times out.
    private static func pastLimit(_ input: RoundEndInput) -> EndCheck {
        guard input.resultReady, input.row != .working else { return .timeout }
        guard input.row == nil else { return .ended }
        let gone = input.rowsSince + goneGrace
        return input.now >= gone ? .ended : .wait(next: gone)
    }
}
