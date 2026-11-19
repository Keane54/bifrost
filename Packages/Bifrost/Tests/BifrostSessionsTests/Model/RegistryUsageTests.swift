import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSessions

// Live events, usage and rate limits.

private func limits(_ used: Double) -> RateLimits {
    RateLimits(
        fiveHour: RateWindow(usedPercent: used, resetsAt: 5_000_000),
        sevenDay: RateWindow(usedPercent: used + 1, resetsAt: 9_000_000))
}

func win(_ used: Double, _ resetsAt: Int) -> RateWindow {
    RateWindow(usedPercent: used, resetsAt: resetsAt)
}
private let hr = 3_600_000

@Suite("live events and usage lines")
struct LiveEventTests {
    private func seqEv(_ name: HookEventName, _ at: Int, _ seq: Int) -> HookEvent {
        HookEvent(name, "s1", at: at, seq: seq)
    }
    // An interactive session with no stored name. Only its usage keeps its ID in the registry.
    private let term = bg(id: nil, background: false, name: "")

    @Test("a live line stays fresh for 90 s")
    func ninety() {
        #expect(SessionRegistry.liveTime == .seconds(90))
    }

    @Test("an event older than the newest applied event drops")
    func dropsOlder() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyEvents([ev(.stop, "s1", 300)], now: 300)
        r.applyEvents([ev(.postToolUse, "s1", 200)], now: 310)
        let row = r.row("s1")
        #expect(row?.alert.colour == .yellow)
        #expect(row?.alert.since == 300)
        #expect(row?.lastActivity == 300)
    }

    @Test
    func sessionStartKeeps() {
        var r = registry()
        r.applyAgents([bg(status: .busy)], sampledAt: 100)
        r.applyEvents([seqEv(.stop, 300, 1)], now: 300)
        let before = r.row("s1")
        #expect(before?.alert.colour == .yellow)
        #expect(before?.alert.since == 300)
        r.applyEvents([seqEv(.sessionStart, 400, 2)], now: 400)
        let after = r.row("s1")
        #expect(
            after?.alert.colour == .yellow
                && after?.alert.since == 300
                && after?.state == before?.state)
    }

    @Test("the sequence number orders two events with the same time")
    func usesSeq() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyEvents([seqEv(.stop, 300, 5)], now: 300)
        r.applyEvents([seqEv(.postToolUse, 300, 4)], now: 300)
        #expect(r.row("s1")?.alert.colour == .yellow)
        #expect(r.row("s1")?.state == .needsYou)
        r.applyEvents([seqEv(.postToolUse, 300, 6)], now: 300)
        #expect(r.row("s1")?.alert.colour == AlertColour.none)
        #expect(r.row("s1")?.state == .working)
    }

    @Test("two events with the same time and no sequence both apply")
    func noSeqBoth() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyEvents([ev(.stop, "s1", 300)], now: 300)
        r.applyEvents([seqEv(.postToolUse, 300, 1)], now: 300)
        #expect(r.row("s1")?.state == .working)
    }

    @Test("pending events apply under the same order rule")
    func pendingOrder() {
        var r = registry()
        r.applyEvents([ev(.stop, "s1", 300), ev(.postToolUse, "s1", 200)], now: 300)
        r.applyAgents([bg()], sampledAt: 400)
        #expect(r.row("s1")?.alert.colour == .yellow)
        #expect(r.row("s1")?.alert.since == 300)
    }

    @Test
    func usageOnRow() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyUsage(
            "s1", LiveUsage(model: "claude-haiku-5-5", contextPercent: 6, costUsd: 0.01), at: 200)
        let row = r.row("s1")
        #expect(
            row?.usage?.contextPercent == 6
                && row?.usage?.costUsd == 0.01
                && row?.model == "Haiku 5.5")
    }

    @Test("the newest usage line replaces the usage and an older line changes nothing")
    func newestReplaces() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyUsage("s1", LiveUsage(model: "claude-opus-5-5", costUsd: 0.5), at: 300)
        r.applyUsage("s1", LiveUsage(model: "claude-haiku-5-5", costUsd: 0.1), at: 200)
        #expect(r.row("s1")?.usage?.costUsd == 0.5)
        #expect(r.row("s1")?.model == "Opus 5.5")
        r.applyUsage("s1", LiveUsage(costUsd: 0.7), at: 400)
        #expect(r.row("s1")?.usage?.costUsd == 0.7)
        #expect(r.row("s1") != nil)
        #expect(r.row("s1")?.model == nil)
    }

    @Test("a usage line is no activity")
    func notActivity() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyEvents([ev(.stop, "s1", 300)], now: 300)
        r.applyUsage("s1", LiveUsage(costUsd: 0.2), at: 5000)
        #expect(r.row("s1")?.lastActivity == 300)
        // A usage line does not change the event time, so an older event still applies.
        r.applyEvents([ev(.userPromptSubmit, "s1", 400)], now: 5000)
        #expect(r.row("s1")?.lastActivity == 400)
        #expect(r.row("s1")?.state == .working)
    }

    // Only a session of the session list gives rate limits, so a line of another program cannot
    // set the windows of the plan.
    @Test func theRateLimitsOfAnUnknownSessionDoNotCount() {
        var r = registry()
        r.applyUsage("s9", LiveUsage(costUsd: 0.1, rateLimits: limits(10)), at: 100)
        #expect(r.usage() == nil)
        r.applyAgents([bg(sessionId: "s9")], sampledAt: 200)
        #expect(r.usage() == nil)
        #expect(r.row("s9")?.usage?.costUsd == 0.1)
    }

    // A window counts only when it resets from now to now + 8 days. A line whose windows all fail
    // keeps the last good windows.
    @Test func aRateWindowCountsOnlyWhenItResetsWithinEightDays() {
        let now = 1_000_000
        let day = 24 * hr
        var r = registry()
        r.applyAgents([bg()], sampledAt: now)
        r.applyUsage(
            "s1",
            LiveUsage(
                rateLimits: RateLimits(
                    fiveHour: win(10, now + 5 * hr), sevenDay: win(20, now + 8 * day + 1))),
            at: now)
        #expect(r.usage()?.limits == RateLimits(fiveHour: win(10, now + 5 * hr)))
        r.applyUsage(
            "s1", LiveUsage(rateLimits: RateLimits(fiveHour: win(30, now - 1))), at: now + 1)
        #expect(r.usage()?.limits == RateLimits(fiveHour: win(10, now + 5 * hr)))
        r.applyUsage(
            "s1", LiveUsage(rateLimits: RateLimits(sevenDay: win(40, now + 8 * day))), at: now + 2)
        #expect(r.usage()?.limits.sevenDay == win(40, now + 8 * day))
    }

    // A flood of lines with new session IDs keeps the lines of the newest 256 IDs with no row.
    @Test func theLinesOfUnknownSessionsKeepTheNewest256IDs() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        for n in 0..<10_000 {
            r.applyEvents([ev(.userPromptSubmit, "x\(n)", 200 + n)], now: 200 + n)
            r.applyUsage("y\(n)", LiveUsage(costUsd: 1), at: 200 + n)
        }
        #expect(r.unknownIds.count == SessionRegistry.maxUnknownSessions)
        #expect(r.unknownIds.first == "x9872" && r.unknownIds.last == "y9999")
        #expect(r.pending.count == 128)
        #expect(r.usageLines.count == 128)
        #expect(r.liveAt.count == 256)
        #expect(r.rows().map(\.sessionId) == ["s1"])
    }

    // At most 1,000 events wait for a session to show. The oldest goes first.
    @Test func atMost1000EventsWaitAndTheOldestGoesFirst() {
        var r = registry()
        for n in 0..<2_000 {
            r.applyEvents([ev(.userPromptSubmit, "s1", 100 + n)], now: 100 + n)
        }
        #expect(r.pending.count == SessionRegistry.maxPendingEvents)
        #expect(r.pending.first?.at == 1_100)
        r.applyAgents([bg()], sampledAt: 2_200)
        #expect(r.row("s1")?.lastActivity == 2_099)
    }

    @Test("a usage line for an unknown session shows once the session comes")
    func unknownUsage() {
        var r = registry()
        r.applyUsage(
            "s1", LiveUsage(model: "claude-sonnet-5", contextPercent: 12, costUsd: 0.3), at: 100)
        #expect(r.rows() == [])
        r.applyAgents([bg()], sampledAt: 200)
        let row = r.row("s1")
        #expect(
            row?.usage?.contextPercent == 12
                && row?.usage?.costUsd == 0.3
                && row?.model == "Sonnet 5")
    }

    @Test("a row stays live for 90 s after its last line")
    func liveFor90() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        #expect(r.row("s1") != nil)
        #expect(r.row("s1")?.live == false)
        #expect(r.liveCount() == 0)
        r.applyUsage("s1", LiveUsage(), at: 1000)
        r.tick(now: 91_000)
        #expect(r.row("s1")?.live == true)
        #expect(r.liveCount() == 1)
        r.tick(now: 91_001)
        #expect(r.row("s1") != nil)
        #expect(r.row("s1")?.live == false)
        #expect(r.liveCount() == 0)
    }

    @Test("a state event also keeps the row live")
    func eventLive() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyEvents([ev(.userPromptSubmit, "s1", 200)], now: 200)
        #expect(r.row("s1")?.live == true)
        r.applyAgents([bg(status: .busy)], sampledAt: 200 + 90_000 + 1)
        #expect(r.row("s1") != nil)
        #expect(r.row("s1")?.live == false)
    }

    @Test
    func liveCountParked() {
        var r = registry()
        r.markStarted("s1")
        r.applyAgents([bg()], sampledAt: 100)
        r.applyEvents([ev(.sessionEnd, "s1", 200)], now: 200)
        #expect(r.row("s1")?.state == .parked)
        #expect(r.liveCount() == 0)
    }

    @Test("a poll-only session gets a yellow box when busy turns idle")
    func pollYellow() {
        var r = registry()
        r.applyAgents([bg(status: .busy)], sampledAt: 1000)
        r.applyAgents([bg(status: .idle)], sampledAt: 3000)
        let row = r.row("s1")
        #expect(
            row?.alert.colour == .yellow && row?.alert.since == 3000 && row?.alert.flashes == true
                && row?.state == .needsYou)
        // A later busy sample clears it.
        r.applyAgents([bg(status: .busy)], sampledAt: 5000)
        #expect(r.row("s1")?.alert.colour == AlertColour.none)
        #expect(r.row("s1")?.state == .working)
    }

    @Test
    func liveNoPollYellow() {
        var r = registry()
        r.applyAgents([bg(status: .busy)], sampledAt: 1000)
        r.applyEvents([ev(.userPromptSubmit, "s1", 1500)], now: 1500)
        r.applyEvents([ev(.turnAborted, "s1", 2500)], now: 2500)
        r.applyAgents([bg(status: .idle)], sampledAt: 3000)
        #expect(r.row("s1")?.alert.colour == AlertColour.none)
        #expect(r.row("s1")?.state == .idle)
    }

    @Test
    func usageOnlyLive() {
        var r = registry()
        r.applyAgents([bg(status: .busy)], sampledAt: 1000)
        r.applyUsage("s1", LiveUsage(costUsd: 0.1), at: 2000)
        r.applyAgents([bg(status: .idle)], sampledAt: 3000)
        #expect(r.row("s1")?.alert.colour == AlertColour.none)
        #expect(r.row("s1")?.state == .idle)
    }

    @Test("clearing live ends the live flag of each row and keeps the usage")
    func clearLive() {
        var r = registry()
        r.applyAgents([bg(status: .busy)], sampledAt: 1000)
        r.applyUsage(
            "s1", LiveUsage(model: "claude-haiku-5-5", contextPercent: 5, costUsd: 0.1), at: 1500)
        #expect(r.liveCount() == 1)
        r.clearLive()
        #expect(r.liveCount() == 0)
        #expect(r.row("s1") != nil)
        #expect(r.row("s1")?.live == false)
        let row = r.row("s1")
        #expect(
            row?.usage?.contextPercent == 5
                && row?.usage?.costUsd == 0.1
                && row?.model == "Haiku 5.5")
        // The session is poll-only again. So the next busy to idle sample gives the yellow box.
        r.applyAgents([bg(status: .idle)], sampledAt: 3000)
        let after = r.row("s1")
        #expect(
            after?.alert.colour == .yellow
                && after?.alert.since == 3000
                && after?.state == .needsYou)
    }

    @Test("no yellow box comes from the first sample after the start")
    func firstSample() {
        var r = registry()
        r.applyAgents([bg(status: .idle)], sampledAt: 1000)
        #expect(r.row("s1")?.alert.colour == AlertColour.none)
        #expect(r.row("s1")?.state == .idle)
        // A parked session that runs again has no status before the sample.
        var p = registry()
        p.markStarted("s1")
        p.applyAgents([], sampledAt: 1000)
        p.applyAgents([bg(status: .idle)], sampledAt: 3000)
        #expect(p.row("s1")?.alert.colour == AlertColour.none)
        #expect(p.row("s1")?.state == .idle)
    }

    @Test("the usage of a session that left all lists goes away")
    func removesUsage() {
        var r = registry()
        r.applyAgents([term], sampledAt: 100)
        r.applyUsage("s1", LiveUsage(costUsd: 0.5), at: 150)
        r.applyAgents([], sampledAt: 200)
        // One counted --all list without the session keeps the usage.
        r.applyAllAgents([another], complete: true)
        r.applyAgents([term], sampledAt: 300)
        #expect(r.row("s1")?.usage?.costUsd == 0.5)
        r.applyAgents([], sampledAt: 400)
        // GONE_LISTS counted lists in a row without the session remove the usage.
        r.applyAllAgents([another], complete: true)
        r.applyAllAgents([another], complete: true)
        r.applyAgents([term], sampledAt: 500)
        #expect(r.row("s1") != nil)
        #expect(r.row("s1")?.usage?.costUsd == nil)
        #expect(r.row("s1") != nil)
        #expect(r.row("s1")?.live == false)
    }

    @Test("the usage of a session that never showed goes away")
    func neverShowed() {
        var r = registry()
        r.applyUsage("s1", LiveUsage(costUsd: 0.5), at: 100)
        r.applyAllAgents([another], complete: true)
        r.applyAllAgents([another], complete: true)
        r.applyAgents([term], sampledAt: 200)
        #expect(r.row("s1") != nil)
        #expect(r.row("s1")?.usage?.costUsd == nil)
    }

    @Test("forget drops the usage of the session")
    func forgetUsage() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyUsage("s1", LiveUsage(model: "claude-opus-5-5", costUsd: 0.5), at: 150)
        r.forget("s1")
        r.applyAgents([bg()], sampledAt: 200)
        #expect(r.row("s1") != nil)
        #expect(r.row("s1")?.usage?.costUsd == nil)
        #expect(r.row("s1") != nil)
        #expect(r.row("s1")?.model == nil)
        #expect(r.row("s1") != nil)
        #expect(r.row("s1")?.live == false)
    }
}

@Suite("session details and the newest rate limits")
struct SessionDetailTests {
    @Test("a row shows the details of its usage line")
    func details() {
        var r = registry()
        r.applyAgents([bg()], sampledAt: 100)
        r.applyUsage(
            "s1",
            LiveUsage(
                contextWindow: 1_000_000, rateLimits: limits(40), version: "2.1.318",
                effort: "xhigh", permissionMode: "plan",
                transcriptPath: "/h/.claude/projects/p/s1.jsonl"),
            at: 200)
        let row = r.row("s1")
        #expect(
            row?.usage?.version == "2.1.318" && row?.usage?.contextWindow == 1_000_000
                && row?.usage?.effort == "xhigh"
                && row?.usage?.permissionMode == "plan" && row?.usage?.rateLimits == limits(40)
                && row?.usage?.transcriptPath == "/h/.claude/projects/p/s1.jsonl")
        // A line without the details leaves the fields out. The rate limits stay.
        r.applyUsage("s1", LiveUsage(costUsd: 0.1), at: 300)
        let after = r.row("s1")
        #expect(after != nil)
        #expect(after?.usage?.version == nil)
        #expect(after?.usage?.contextWindow == nil)
        #expect(after?.usage?.effort == nil)
        #expect(after?.usage?.permissionMode == nil)
        #expect(after?.usage?.transcriptPath == nil)
        #expect(after?.usage?.rateLimits == limits(40))
    }

    @Test("a usage line without rate limits keeps the last rate limits")
    func keepsLimits() {
        var r = registry()
        r.applyAgents(
            [
                bg(id: "aaaaaaaa", name: "alpha", sessionId: "a"),
                bg(id: "cccccccc", name: "gamma", sessionId: "c"),
            ], sampledAt: 100)
        r.applyUsage("a", LiveUsage(rateLimits: limits(10)), at: 1000)
        r.applyUsage("c", LiveUsage(rateLimits: limits(30)), at: 1500)
        r.applyUsage("a", LiveUsage(costUsd: 0.2), at: 2000)
        #expect(r.row("a")?.usage?.costUsd == 0.2)
        #expect(r.row("a")?.usage?.rateLimits == limits(10))
        // The time of the kept limits is the time of the line that had them. So C stays the newest.
        #expect(
            r.usage()
                == UsageSnapshot(sessionId: "c", name: "gamma", updatedAt: 1500, limits: limits(30))
        )
        // Only a line with rate limits replaces them.
        r.applyUsage("a", LiveUsage(rateLimits: limits(60)), at: 2500)
        #expect(r.row("a")?.usage?.rateLimits == limits(60))
        #expect(
            r.usage()
                == UsageSnapshot(sessionId: "a", name: "alpha", updatedAt: 2500, limits: limits(60))
        )
    }

    @Test("usage picks the window with the highest use when the resets match")
    func highestUse() {
        var r = registry()
        r.applyAgents(
            [
                bg(id: "aaaaaaaa", name: "alpha", sessionId: "a"),
                bg(id: "bbbbbbbb", name: "beta", sessionId: "b"),
                bg(id: "cccccccc", name: "gamma", sessionId: "c"),
            ],
            sampledAt: 100)
        r.applyUsage("a", LiveUsage(rateLimits: limits(10)), at: 1000)
        r.applyUsage("b", LiveUsage(costUsd: 0.2), at: 2000)
        r.applyUsage("c", LiveUsage(rateLimits: limits(30)), at: 1500)
        // A line that comes last but has a lower use does not win.
        r.applyUsage("d", LiveUsage(rateLimits: limits(20)), at: 2500)
        #expect(
            r.usage()
                == UsageSnapshot(sessionId: "c", name: "gamma", updatedAt: 1500, limits: limits(30))
        )
    }

    // A session with no row gives no rate limits: a line of another program cannot set the
    // windows of the plan.
    @Test
    func notARow() {
        var r = registry()
        let id = "73b5ca76-a4a8-4f97-9764-e41657296414"
        r.applyUsage(id, LiveUsage(rateLimits: limits(20)), at: 1000)
        #expect(r.rows() == [])
        #expect(r.usage() == nil)
    }

    @Test("usage is null when there are no rate limits")
    func nullWithout() {
        var r = registry()
        #expect(r.usage() == nil)
        r.applyAgents([bg()], sampledAt: 100)
        r.applyUsage("s1", LiveUsage(contextPercent: 5, costUsd: 0.1), at: 200)
        #expect(r.usage() == nil)
        // forget removes the kept rate limits.
        r.applyUsage("s1", LiveUsage(rateLimits: limits(10)), at: 300)
        r.applyUsage("s1", LiveUsage(costUsd: 0.2), at: 400)
        #expect(r.usage()?.sessionId == "s1")
        #expect(r.usage()?.updatedAt == 300)
        r.forget("s1")
        #expect(r.usage() == nil)
    }
}

// Rows for the session IDs, so their rate limits count.
private func known(_ ids: String...) -> [AgentEntry] {
    ids.map { bg(id: nil, name: $0, sessionId: $0) }
}

@Suite("usage picks each window on its own")
struct WindowPickTests {
    @Test("an idle session that sends last with an old lower value does not win")
    func oldLower() {
        var r = registry()
        r.applyAgents([bg(id: "aaaaaaaa", name: "alpha", sessionId: "a")], sampledAt: 100)
        r.applyUsage("a", LiveUsage(rateLimits: RateLimits(sevenDay: win(34, 9 * hr))), at: 1000)
        r.applyUsage("b", LiveUsage(rateLimits: RateLimits(sevenDay: win(4, 9 * hr))), at: 2000)
        #expect(
            r.usage()
                == UsageSnapshot(
                    sessionId: "a", name: "alpha", updatedAt: 1000,
                    limits: RateLimits(sevenDay: win(34, 9 * hr))))
    }

    @Test("a new window beats a higher value of the old window")
    func newWindow() {
        var r = registry()
        r.applyAgents(known("a", "b"), sampledAt: 100)
        r.applyUsage("a", LiveUsage(rateLimits: RateLimits(fiveHour: win(90, 5 * hr))), at: 1000)
        r.applyUsage("b", LiveUsage(rateLimits: RateLimits(fiveHour: win(2, 10 * hr))), at: 2000)
        #expect(r.usage()?.limits.fiveHour == win(2, 10 * hr))
    }

    @Test("two resets 5 minutes apart count as one window")
    func fiveMinutes() {
        var r = registry()
        r.applyAgents(known("a", "b", "c"), sampledAt: 100)
        r.applyUsage("a", LiveUsage(rateLimits: RateLimits(sevenDay: win(50, 9 * hr))), at: 1000)
        r.applyUsage(
            "b", LiveUsage(rateLimits: RateLimits(sevenDay: win(20, 9 * hr + 300_000))), at: 2000)
        #expect(r.usage()?.limits.sevenDay == win(50, 9 * hr))
        r.applyUsage(
            "c", LiveUsage(rateLimits: RateLimits(sevenDay: win(60, 9 * hr - 300_000))), at: 3000)
        #expect(r.usage()?.limits.sevenDay == win(60, 9 * hr - 300_000))
    }

    @Test("resets more than 10 minutes apart are different windows")
    func elevenMinutes() {
        var r = registry()
        r.applyAgents(known("a", "b"), sampledAt: 100)
        r.applyUsage("a", LiveUsage(rateLimits: RateLimits(sevenDay: win(50, 9 * hr))), at: 1000)
        r.applyUsage(
            "b", LiveUsage(rateLimits: RateLimits(sevenDay: win(5, 9 * hr + 11 * 60_000))),
            at: 2000)
        #expect(r.usage()?.limits.sevenDay == win(5, 9 * hr + 11 * 60_000))
    }

    @Test("a value that is not finite never wins over a finite one")
    func notFinite() {
        var r = registry()
        r.applyAgents(known("a", "b"), sampledAt: 100)
        r.applyUsage("a", LiveUsage(rateLimits: RateLimits(sevenDay: win(10, 9 * hr))), at: 1000)
        r.applyUsage(
            "b", LiveUsage(rateLimits: RateLimits(sevenDay: win(.nan, 9 * hr))), at: 2000)
        #expect(r.usage()?.limits.sevenDay == win(10, 9 * hr))
    }

    @Test("the 5-hour and 7-day values can come from different sessions")
    func differentSessions() {
        var r = registry()
        r.applyAgents([bg(id: "bbbbbbbb", name: "beta", sessionId: "b")], sampledAt: 100)
        r.applyUsage(
            "a",
            LiveUsage(
                rateLimits: RateLimits(fiveHour: win(10, 5 * hr), sevenDay: win(5, 9 * hr))),
            at: 1000)
        r.applyUsage(
            "b",
            LiveUsage(
                rateLimits: RateLimits(fiveHour: win(3, 8 * hr), sevenDay: win(34, 9 * hr))),
            at: 900)
        #expect(
            r.usage()
                == UsageSnapshot(
                    sessionId: "b", name: "beta", updatedAt: 900,
                    limits: RateLimits(fiveHour: win(3, 8 * hr), sevenDay: win(34, 9 * hr))))
    }

    // A tie of use and time has one result, the reading of the lowest session ID (row D8 of
    // docs/ports/registry/DELIBERATE-DIFFERENCES.md).
    @Test("a tie in use and time gives the lowest session ID")
    func tie() {
        var r = registry()
        r.applyAgents(known("a", "b", "c"), sampledAt: 100)
        r.applyUsage("b", LiveUsage(rateLimits: RateLimits(sevenDay: win(40, 9 * hr))), at: 1000)
        r.applyUsage("a", LiveUsage(rateLimits: RateLimits(sevenDay: win(40, 9 * hr))), at: 1000)
        #expect(r.usage()?.sessionId == "a")
        r.applyUsage("a", LiveUsage(rateLimits: RateLimits(sevenDay: win(40, 9 * hr))), at: 900)
        r.applyUsage("c", LiveUsage(rateLimits: RateLimits(sevenDay: win(40, 9 * hr))), at: 1100)
        #expect(r.usage()?.sessionId == "c")
    }
}

@Suite("pending events")
struct PendingEventTests {
    @Test("an event at exactly the pending limit is kept")
    func exactKept() {
        var r = registry()
        r.applyEvents([ev(.stop, "s1", 10)], now: 10)
        r.tick(now: 10 + 60_000)
        r.applyAgents([bg()], sampledAt: 10 + 60_000)
        #expect(r.rows().first?.alert.colour == .yellow)
    }

    @Test("applying events also drops old pending events")
    func dropsOld() {
        var r = registry()
        r.applyEvents([ev(.stop, "s1", 10)], now: 10)
        r.applyEvents([], now: 10 + 60_000 + 1)
        r.applyAgents([bg()], sampledAt: 10 + 60_000 + 2)
        #expect(r.rows().first?.alert.colour == AlertColour.none)
    }

    @Test
    func pendingToAll() {
        var r = registry()
        r.applyEvents([ev(.sessionStart, "s1", 10), ev(.stop, "s1", 20)], now: 20)
        r.applyAllAgents([bg(pid: nil, status: .unknown)], complete: true)
        let row = r.rows().first
        #expect(
            row?.alert.colour == AlertColour.none
                && row?.lastActivity == 20
                && row?.state == .parked)
    }

    @Test("the pending event limit is 60 s")
    func sixty() {
        #expect(SessionRegistry.pendingEventTime == .seconds(60))
    }
}

@Suite("the escalation setting")
struct EscalationSettingTests {
    private let T = 1000

    private func yellowAtT() -> SessionRegistry {
        var r = registry()
        r.applyAgents([bg()], sampledAt: T)
        r.applyEvents([ev(.stop, "s1", T)], now: T)
        #expect(r.rows().first?.alert.colour == .yellow)
        #expect(r.rows().first?.alert.since == T)
        return r
    }

    @Test("a new escalation time changes an old yellow box at the next tick")
    func changesTime() {
        var r = yellowAtT()
        r.tick(now: T + 120_000)
        #expect(r.rows().first?.alert.colour == .yellow)
        r.setEscalation(.seconds(60))
        r.tick(now: T + 120_000)
        #expect(r.rows().first?.alert.colour == .red)
        #expect(r.rows().first?.alert.reason == .escalated)
    }

    @Test("escalation time 0 stops the escalation")
    func zeroStops() {
        var r = yellowAtT()
        r.setEscalation(.zero)
        r.tick(now: T + 6_000_000)
        #expect(r.rows().first?.alert.colour == .yellow)
        // A later value starts the escalation again.
        r.setEscalation(.seconds(600))
        r.tick(now: T + 6_000_000)
        #expect(r.rows().first?.alert.colour == .red)
    }
}
