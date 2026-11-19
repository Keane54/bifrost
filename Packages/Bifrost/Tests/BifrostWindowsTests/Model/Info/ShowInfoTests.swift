// The values of the Show Info panel (docs/behaviour/panels.md, "Show Info"). Each test gives a
// fixed time zone, so no text depends on the zone of the computer.
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostWindows

private let rowId = "0f8fad5b-d9cb-469f-a165-70867728950e"
private let conversationId = "1db82d17-d5fd-4e53-a042-7dd67ea654d8"
private let jobId = "2f493bf0-1598-4b3b-b419-8acb9cb11bcb"
private let now = utcMs(2026, 11, 5, 12, 0)
private let utc = TimeZone.gmt

// A row with each value that Show Info shows.
private func full() -> SessionRow {
    let limits = RateLimits(
        fiveHour: RateWindow(usedPercent: 61.6, resetsAt: utcMs(2026, 11, 5, 14, 3)),
        sevenDay: RateWindow(usedPercent: 12, resetsAt: utcMs(2026, 11, 7, 9, 7)))
    let usage = LiveUsage(
        model: "claude-sonnet-5-5", contextPercent: 42.4, contextWindow: 200_000, costUsd: 1.234,
        rateLimits: limits, version: "2.1.318", effort: "high", permissionMode: "plan",
        transcriptPath: "/Users/o/.claude/projects/app/t.jsonl")
    return SessionRow(
        sessionId: rowId, shortId: "abcd1234", name: "fix-a", claudeName: "fix-a",
        kind: .external, pid: 4242, cwd: "/Users/o/Developer/app", status: .idle, state: .idle,
        lastActivity: now, startedAt: utcMs(2026, 11, 5, 9, 7), usage: usage, live: true,
        branch: "fix-a", terminalApp: "Warp")
}

// A row with only the values of the test.
private func bare(
    sessionId: String = "x", cwd: String = "/r", state: SessionState = .idle,
    startedAt: Int = utcMs(2026, 11, 5, 9, 7), limits: RateLimits? = nil
) -> SessionRow {
    var row = SessionRow.test(
        sessionId: sessionId, shortId: nil, name: "b", cwd: cwd, state: state,
        startedAt: startedAt)
    if let limits { row.usage = LiveUsage(rateLimits: limits) }
    return row
}

private func sections(_ row: SessionRow, pr: PRInfo? = nil, zone: TimeZone = utc)
    -> [InfoSection]
{
    ShowInfo.sections(row, now: now, pr: pr, zone: zone)
}

private func item(_ sections: [InfoSection], _ title: String, _ label: String) -> String? {
    sections.first { $0.title == title }?.items.first { $0.label == label }?.value
}

private func labels(_ sections: [InfoSection], _ title: String) -> [String] {
    sections.first { $0.title == title }?.items.map(\.label) ?? []
}

@Suite("Show Info")
struct ShowInfoTests {
    @Test func theSectionsHoldTheValuesInOrder() {
        let s = sections(full())
        #expect(s.map(\.title) == [
            "Session", "Files", "Git", "Model", "Time", "Cost and context", "Limits and version",
        ])
        #expect(labels(s, "Session") == ["Name", "Session ID", "Short ID", "Kind", "PID"])
        #expect(labels(s, "Files") == ["Project folder", "Transcript"])
        #expect(labels(s, "Git") == ["Branch", "PR", "Worktree"])
        #expect(labels(s, "Model") == ["Model", "Effort", "Permission mode"])
        #expect(labels(s, "Time") == ["Started", "Duration"])
        #expect(labels(s, "Cost and context") == ["Cost", "Context window", "Context use"])
        #expect(
            labels(s, "Limits and version")
                == ["5-hour limit", "7-day limit", "Claude Code version"])
        #expect(item(s, "Session", "Name") == "fix-a")
        #expect(item(s, "Session", "Session ID") == rowId)
        #expect(item(s, "Session", "Short ID") == "abcd1234")
        #expect(item(s, "Session", "Kind") == "External (Warp)")
        #expect(item(s, "Session", "PID") == "4242")
        #expect(item(s, "Files", "Project folder") == "/Users/o/Developer/app")
        #expect(item(s, "Files", "Transcript") == "/Users/o/.claude/projects/app/t.jsonl")
        #expect(item(s, "Git", "Branch") == "fix-a")
        #expect(item(s, "Git", "PR") == "Loading...")
        #expect(item(s, "Git", "Worktree") == "None")
        #expect(item(s, "Model", "Model") == "Sonnet 5.5")
        #expect(item(s, "Model", "Effort") == "high")
        #expect(item(s, "Model", "Permission mode") == "plan")
        #expect(item(s, "Time", "Started") == "09:07")
        #expect(item(s, "Time", "Duration") == "2 h 53 min")
        #expect(item(s, "Cost and context", "Cost") == "≈$1.23")
        #expect(item(s, "Cost and context", "Context window") == "200k tokens")
        #expect(item(s, "Cost and context", "Context use") == "42%")
        #expect(item(s, "Limits and version", "5-hour limit") == "62%, resets 14:03")
        #expect(item(s, "Limits and version", "7-day limit") == "12%, resets Sat 7 Nov 09:07")
        #expect(item(s, "Limits and version", "Claude Code version") == "2.1.318")
    }

    @Test func theIDsAndThePathsAreMono() {
        let mono = sections(full()).flatMap { $0.items.filter(\.mono).map(\.label) }
        #expect(mono == ["Session ID", "Short ID", "Project folder", "Transcript"])
    }

    // The panel shows the Copy session ID button after the session ID, and only a PR is a link.
    @Test func theSessionIdAndAPRHaveTheirControls() throws {
        let url = try #require(URL(string: "https://github.com/o/r/pull/12"))
        let s = sections(full(), pr: .pr(number: 12, title: "Fix", url: url, state: "OPEN"))
        let controls = s.flatMap { $0.items.filter { $0.control != .none } }
            .map { "\($0.label): \($0.control)" }
        #expect(controls == ["Session ID: copySessionId", "PR: prLink"])
        for pr in [nil, PRInfo.none, .unavailable(.notInstalled)] {
            let item = sections(full(), pr: pr)[2].items.first { $0.label == "PR" }
            #expect(item?.control == InfoItem.Control.none)
        }
    }

    // A local name hides the real name, so Show Info gives the real name after it.
    @Test func theClaudeCodeNameFollowsALocalName() {
        var row = full()
        row.name = "Work"
        let s = sections(row)
        #expect(labels(s, "Session").prefix(3) == ["Name", "Claude Code name", "Session ID"])
        #expect(item(s, "Session", "Name") == "Work")
        #expect(item(s, "Session", "Claude Code name") == "fix-a")
    }

    // The session ID is the ID that claude --resume needs, as Copy session ID copies it.
    @Test func anInteractiveRowAfterAClearShowsItsCurrentIdAsItsSessionId() {
        var row = full()
        row.currentId = conversationId
        let s = sections(row)
        #expect(labels(s, "Session") == ["Name", "Session ID", "Short ID", "Kind", "PID"])
        #expect(item(s, "Session", "Session ID") == conversationId)
    }

    @Test func aBackgroundRowShowsItsResumeIdThenItsCurrentConversation() {
        var job = full()
        job.kind = .owned
        job.currentId = conversationId
        job.resumeId = jobId
        let s = sections(job)
        #expect(labels(s, "Session").prefix(3) == ["Name", "Session ID", "Current conversation"])
        #expect(item(s, "Session", "Session ID") == jobId)
        #expect(item(s, "Session", "Current conversation") == conversationId)
        #expect(s[0].items.first { $0.label == "Current conversation" }?.mono == true)
        // A background row with no /clear shows one ID only.
        var plain = full()
        plain.kind = .owned
        plain.resumeId = rowId
        #expect(!labels(sections(plain), "Session").contains("Current conversation"))
    }

    @Test func aBackgroundRowWithNoResumeIdYetShowsADash() {
        var job = full()
        job.kind = .owned
        job.currentId = conversationId
        let s = sections(job)
        #expect(item(s, "Session", "Session ID") == "-")
        #expect(item(s, "Session", "Current conversation") == conversationId)
    }

    @Test func theKindOfAnOwnedRowAndOfAnExternalRow() {
        #expect(item(sections(bare()), "Session", "Kind") == "Owned")
        var external = bare()
        external.kind = .external
        #expect(item(sections(external), "Session", "Kind") == "External")
        external.terminalApp = ""
        #expect(item(sections(external), "Session", "Kind") == "External")
    }

    @Test func aMissingValueShowsADashAndAParkedRowShowsParked() {
        let s = sections(bare(sessionId: "b", cwd: "", state: .parked, startedAt: 0))
        let dashes: [(String, String)] = [
            ("Session", "Session ID"), ("Session", "Short ID"), ("Session", "PID"),
            ("Files", "Project folder"), ("Files", "Transcript"), ("Git", "Branch"),
            ("Model", "Model"), ("Model", "Effort"), ("Model", "Permission mode"),
            ("Time", "Started"), ("Cost and context", "Cost"),
            ("Cost and context", "Context window"), ("Cost and context", "Context use"),
            ("Limits and version", "5-hour limit"), ("Limits and version", "7-day limit"),
            ("Limits and version", "Claude Code version"),
        ]
        for (title, label) in dashes {
            #expect(item(s, title, label) == "-", "\(label)")
        }
        #expect(item(s, "Time", "Duration") == "Parked")
    }

    @Test func theDurationIsADashWithNoStartTime() {
        #expect(item(sections(bare(startedAt: 0)), "Time", "Duration") == "-")
    }

    // A plan can have no 5-hour window. Then the row hides, as in the Usage HUD.
    @Test func aPlanWithOnlyASevenDayWindowHidesTheFiveHourRow() {
        let limits = RateLimits(
            sevenDay: RateWindow(usedPercent: 5, resetsAt: utcMs(2026, 11, 5, 13, 0)))
        let s = sections(bare(limits: limits))
        #expect(labels(s, "Limits and version") == ["7-day limit", "Claude Code version"])
        #expect(item(s, "Limits and version", "7-day limit") == "5%, resets 13:00")
    }

    @Test func bothLimitRowsShowWhileTheSessionHasNoLimits() {
        let s = sections(bare())
        #expect(item(s, "Limits and version", "5-hour limit") == "-")
        #expect(item(s, "Limits and version", "7-day limit") == "-")
    }

    // After the reset, the use is not known until the next message, as in the Usage HUD.
    @Test func aLimitWhoseResetPassedShowsADashAndTheResetTime() {
        let passed = RateLimits(
            fiveHour: RateWindow(usedPercent: 93, resetsAt: utcMs(2026, 11, 5, 9, 7)),
            sevenDay: RateWindow(usedPercent: 40, resetsAt: utcMs(2026, 11, 3, 2, 0)))
        let s = sections(bare(limits: passed))
        #expect(item(s, "Limits and version", "5-hour limit") == "-, reset at 09:07")
        #expect(item(s, "Limits and version", "7-day limit") == "-, reset at Tue 3 Nov 02:00")
        let atNow = RateLimits(fiveHour: RateWindow(usedPercent: 93, resetsAt: now))
        #expect(
            item(sections(bare(limits: atNow)), "Limits and version", "5-hour limit")
                == "-, reset at 12:00")
    }

    @Test func aLimitWithAPercentThatIsNotFiniteShowsADash() {
        let limits = RateLimits(
            fiveHour: RateWindow(usedPercent: .nan, resetsAt: utcMs(2026, 11, 5, 14, 3)))
        #expect(
            item(sections(bare(limits: limits)), "Limits and version", "5-hour limit")
                == "-, resets 14:03")
    }

    @Test func aLimitThatResetsInUnderAMinuteStillShowsItsUse() {
        let limits = RateLimits(fiveHour: RateWindow(usedPercent: 97, resetsAt: now + 30_000))
        #expect(
            item(sections(bare(limits: limits)), "Limits and version", "5-hour limit")
                == "97%, resets 12:00")
    }

    // The start time compares the day in the zone: 23:30 UTC on 4 Nov is 5 Nov in Tokyo.
    @Test func theStartTimeComparesTheDayInTheZone() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let late = bare(startedAt: utcMs(2026, 11, 4, 23, 30))
        #expect(item(sections(late, zone: tokyo), "Time", "Started") == "08:30")
        #expect(item(sections(late), "Time", "Started") == "Wed 4 Nov 23:30")
    }

    @Test func theWorktreeOfAWorktreeRow() {
        var worktree = bare(cwd: "/r/.claude/worktrees/fix-a/src")
        worktree.branch = "worktree-fix-a"
        #expect(item(sections(worktree), "Git", "Worktree") == "/r/.claude/worktrees/fix-a")
        // A stopped session reports its start folder, so the stored worktree shows.
        var stopped = bare(cwd: "/r", state: .parked)
        stopped.worktree = "/r/.claude/worktrees/fix-a"
        #expect(item(sections(stopped), "Git", "Worktree") == "/r/.claude/worktrees/fix-a")
        #expect(item(sections(bare(cwd: "/r")), "Git", "Worktree") == "None")
    }

    @Test func thePRStates() throws {
        let url = try #require(URL(string: "https://github.com/o/r/pull/12"))
        func pr(_ value: PRInfo?) -> String? { item(sections(full(), pr: value), "Git", "PR") }
        #expect(pr(.pr(number: 12, title: "Fix", url: url, state: "OPEN")) == "#12 Fix (open)")
        // PRInfo.none, not Optional.none: nil is the PR line while the lookup runs.
        #expect(pr(PRInfo.none) == "None")
        #expect(
            pr(.unavailable(.notInstalled))
                == "GitHub CLI (gh) isn't installed.")
        #expect(pr(nil) == "Loading...")
    }

    @Test func theTokenTexts() {
        #expect(ShowInfo.tokens(1_000_000) == "1M")
        #expect(ShowInfo.tokens(200_000) == "200k")
        #expect(ShowInfo.tokens(1_500_000) == "1.5M")
        #expect(ShowInfo.tokens(1_250_000) == "1.3M")
        #expect(ShowInfo.tokens(1_000) == "1k")
        #expect(ShowInfo.tokens(999_950) == "1000k")
        #expect(ShowInfo.tokens(999) == "999")
        #expect(ShowInfo.tokens(0) == "0")
        #expect(ShowInfo.tokens(Int.max).hasSuffix("M"))
    }

    // The hint shows for a row with no live line and no model, as Live details is then off.
    @Test func aRowWithNoLiveDataGetsTheHint() {
        #expect(ShowInfo.showsLiveHint(bare()))
        #expect(!ShowInfo.showsLiveHint(full()))
        var model = bare()
        model.usage = LiveUsage(model: "claude-opus-5-5")
        #expect(!ShowInfo.showsLiveHint(model))
        var live = bare()
        live.live = true
        #expect(!ShowInfo.showsLiveHint(live))
        #expect(
            ShowInfo.liveHint
                == "Turn on Live details in Settings to see the model, effort, cost and limits.")
    }
}
