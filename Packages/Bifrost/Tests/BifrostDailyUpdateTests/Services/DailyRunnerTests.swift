import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostDailyUpdate

// The run of the drafts (docs/behaviour/daily-update.md, "The run") with the fake claude -p in a
// test home (RunHome). The limit of 5 minutes runs on a manual clock. Safety: the fake reads and
// writes only the test home, gh is a FakeRunner, and no test uses a real model.

// The settings of a run with the board as the source and no merged PRs, so no gh runs.
private func boardOnly() -> DailySettings {
    var settings = boardSettings()
    settings.mergedPrs = false
    return settings
}

private let now = wednesday(9, 30)

// The value of a run task as a Result, so a test can compare the failure.
private func outcome(_ task: Task<DailyResult, any Error>) async -> RunFailure? {
    do {
        _ = try await task.value
        return nil
    } catch {
        return error as? RunFailure
    }
}

private func isGone(_ pid: pid_t) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
}

@MainActor
@Suite("the run of the drafts", .timeLimit(.minutes(2)), .tags(.realProcess))
struct DailyRunnerTests {
    @Test func eachStartEndAndFailureIsReported() async throws {
        let home = try RunHome()
        defer { home.finish() }
        let runner = home.runner()
        try home.write("fake-daily-result.json", output(goodResult))
        let result = try await runner.run(boardOnly(), state: .empty, now: now)
        #expect(result.areas.map(\.id) == ["area-1"])
        #expect(result.areas.first?.items.first?.id == "T-1")
        #expect(home.events == [.started, .finished])

        try home.write("fake-daily-result.json", output(#"{"version":1,"failure":"no-user"}"#))
        await #expect(throws: RunFailure.noUser) {
            try await runner.run(boardOnly(), state: .empty, now: now)
        }
        #expect(home.events == [.started, .finished, .started, .failed(.noUser)])
    }

    @Test func nothingToReadRunsNoClaude() async throws {
        let home = try RunHome()
        defer { home.finish() }
        var settings = settings()
        settings.mergedPrs = false
        await #expect(throws: RunFailure.nothingToRead) {
            try await home.runner().run(settings, state: .empty, now: now)
        }
        #expect(home.events == [.started, .failed(.nothingToRead)])
        #expect(home.calls.isEmpty)
        #expect(home.gh.commands.isEmpty)
    }

    @Test func aRunStopsAfterFiveMinutes() async throws {
        let home = try RunHome()
        defer { home.finish() }
        try home.write("fake-daily-hang", "")
        let runner = home.runner()
        let run = Task { try await runner.run(boardOnly(), state: .empty, now: now) }
        try #require(await waitUntil { home.hangingPid != nil })
        let pid = try #require(home.hangingPid)
        try #require(await home.clock.waitForSleepers(1))
        home.clock.advance(by: .seconds(299))
        // One second before the limit the run still goes.
        #expect(home.clock.sleeperCount == 1)
        #expect(!isGone(pid))
        home.clock.advance(by: .seconds(1))
        #expect(await outcome(run) == .timeout)
        #expect(home.events == [.started, .failed(.timeout)])
        // The run ends only after the program of claude ended.
        #expect(isGone(pid))
    }

    // A stop by the caller is no result, so it writes no line.
    @Test func aStopOfTheCallerWritesNoLine() async throws {
        let home = try RunHome()
        defer { home.finish() }
        try home.write("fake-daily-hang", "")
        let runner = home.runner()
        let run = Task { try await runner.run(boardOnly(), state: .empty, now: now) }
        try #require(await waitUntil { home.hangingPid != nil })
        let pid = try #require(home.hangingPid)
        run.cancel()
        #expect(await outcome(run) == .stopped)
        #expect(home.events == [.started])
        #expect(isGone(pid))
    }

    @Test func theRunWritesItsInputInANewPrivateFolder() async throws {
        let home = try RunHome()
        defer { home.finish() }
        try home.write("fake-daily-result.json", output(goodResult))
        _ = try await home.runner().run(boardOnly(), state: .empty, now: now)
        #expect(home.runFolders == ["20261118-093000"])
        let runs = home.layout.runsFolder.path(percentEncoded: false)
        let folder = try #require(RealPath.of("\(runs)/20261118-093000"))
        #expect(mode(of: home.layout.folder.path(percentEncoded: false)) == 0o700)
        #expect(mode(of: runs) == 0o700)
        #expect(mode(of: folder) == 0o700)
        #expect(mode(of: "\(folder)/input.json") == 0o600)
        let input = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: URL(filePath: "\(folder)/input.json")))
        // The input names only the read tools that the run may call.
        #expect(
            input.object?["source"]
                == ["server": "board", "tools": ["mcp__board__list_items", "mcp__board__get_item"]])
        // The probe, then the run with the real paths.
        let skills = try #require(RealPath.of(home.skills.path(percentEncoded: false)))
        #expect(home.calls.first == RunArgs.inventory().joined(separator: " "))
        let run = try #require(home.runCalls.first)
        #expect(run.contains("--plugin-dir \(skills) "))
        #expect(run.hasSuffix("/bifrost-daily-update bifrost-input=\(folder)/input.json"))
        // A second run in the same second gets its own folder.
        _ = try await home.runner().run(boardOnly(), state: .empty, now: now)
        #expect(home.runFolders == ["20261118-093000", "20261118-093000-2"])
    }

    @Test func theOldestRunFoldersGo() async throws {
        let home = try RunHome()
        defer { home.finish() }
        let runs = home.layout.runsFolder
        let old = (1...12).map { String(format: "20261101-0900%02d", $0) }
        for name in old + ["notes"] {
            try FileManager.default.createDirectory(
                at: runs.appending(path: name), withIntermediateDirectories: true)
        }
        try home.write("fake-daily-result.json", output(goodResult))
        _ = try await home.runner().run(boardOnly(), state: .empty, now: now)
        // The 9 newest old runs stay with the new one. A folder of another name stays.
        #expect(home.runFolders == Array(old.suffix(9)) + ["20261118-093000", "notes"])
    }

    @Test func aSourceThatIsNotConnectedFailsBeforeTheRun() async throws {
        let home = try RunHome()
        defer { home.finish() }
        var settings = boardOnly()
        settings.source = DailySource(server: "claude.ai Claude Docs", tools: docsTools)
        let failure = RunFailure.sourceUnavailable(
            server: "claude.ai Claude Docs", status: "needs-auth")
        await #expect(throws: failure) {
            try await home.runner().run(settings, state: .empty, now: now)
        }
        #expect(home.runCalls.isEmpty)
        #expect(
            failure.message
                == "Bifrost couldn't reach claude.ai Claude Docs (needs-auth). Check it in Claude "
                + "Code with /mcp.")
    }

    @Test func aFailedClaudeGivesItsReason() async throws {
        let home = try RunHome()
        defer { home.finish() }
        try home.write("fake-daily-result.json", reply("API Error: overloaded", isError: true))
        let reason = "Claude Code reported a problem: API Error: overloaded"
        let failure = RunFailure.claudeFailed(reason)
        await #expect(throws: failure) {
            try await home.runner().run(boardOnly(), state: .empty, now: now)
        }
        try home.write("fake-daily-result.json", reply("Hello."))
        await #expect(throws: RunFailure.badResult) {
            try await home.runner().run(boardOnly(), state: .empty, now: now)
        }
    }

    // The PRs go into the input. The tool calls that the permissions refused and a failure of gh
    // go to the Event log, and the run goes on.
    @Test func theNoticesOfARunGoToTheEventLog() async throws {
        let pr = """
            [{"number":12,"title":"Add refunds (T-1)",\
            "url":"https://github.com/example/pay/pull/12",\
            "repository":{"nameWithOwner":"example/pay"},"closedAt":"2026-11-17T16:05:09Z",\
            "body":""}]
            """
        let home = try RunHome(ghResult: ExecResult(.exited(0), stdout: pr))
        defer { home.finish() }
        try home.write("fake-daily-result.json", output(goodResult, denials: 2))
        _ = try await home.runner().run(boardSettings(), state: .empty, now: now)
        #expect(home.events == [.started, .callsDenied(2), .finished])
        // The search starts at the start of the last due day: Tuesday.
        let since = moment(2026, 11, 17, 0, 0, in: calendar())
        #expect(home.gh.commands.first?.arguments == MergedPRs.args(since: since))
        let folder = try #require(home.runFolders.first)
        let file = home.layout.runsFolder.appending(path: "\(folder)/input.json")
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        #expect(input.object?["prs"]?.array?.first?.object?["title"] == "Add refunds (T-1)")

        let failing = try RunHome(ghResult: ExecResult(.exited(1), stderr: "gh: not logged in"))
        defer { failing.finish() }
        try failing.write("fake-daily-result.json", output(goodResult))
        _ = try await failing.runner().run(boardSettings(), state: .empty, now: now)
        #expect(
            failing.events == [
                .started, .mergedPRsMissing(.failed("gh: not logged in")), .finished,
            ])
    }

    @Test func theLinesOfTheEventLog() {
        #expect(DailyRunEvent.started.line == "Daily update: Bifrost is writing the drafts.")
        #expect(DailyRunEvent.finished.line == "Daily update: the drafts are ready.")
        #expect(
            DailyRunEvent.failed(.timeout).line
                == "Daily update: The run took more than 5 minutes, so Bifrost stopped it.")
        #expect(
            DailyRunEvent.callsDenied(1).line
                == "Daily update: Claude tried 1 tool call that the run isn't allowed to make.")
        #expect(
            DailyRunEvent.mergedPRsMissing(.timedOut).line
                == "Daily update: Bifrost couldn't read your merged PRs, so the drafts leave them "
                + "out. GitHub CLI (gh) took too long to answer.")
    }
}
