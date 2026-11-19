// The PR sessions (docs/behaviour/reviews.md, "PR sessions"): the start of a session, and the
// wait for the end of its turn on the real signals. The registry is real, on scripted session
// lists and a manual clock (FakeActionDeps). claude is a fake that runs no program, and the
// result file is a real file in a temporary folder.
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@MainActor
struct SessionsFixture {
    static let id = "11111111-2222-3333-4444-555555555555"
    static let name = "bifrost-test-Repo-A-7-review"
    static let shortID = ShortID("abcdef12")

    let deps = FakeActionDeps()
    let folder: TemporaryFolder
    let store: ReviewsStore
    let sessions: PRSessions
    // The input folder of the round, with no result file yet.
    let input: URL

    init() async throws {
        let folder = try TemporaryFolder()
        self.folder = folder
        let layout = ReviewsLayout(
            folder: URL(filePath: folder.realPath + "/reviews", directoryHint: .isDirectory))
        store = try await ReviewsStore.open(layout: layout, log: Recorder<StoreEvent>())
        sessions = PRSessions(
            store: store, registry: deps.registry, actions: deps.makeActions(),
            claude: deps.claudeRunner(), clock: deps.clock,
            now: { Date(timeIntervalSince1970: 1_794_312_000) }, testPrefix: true)
        input = URL(filePath: folder.realPath + "/io", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    }

    var result: URL { input.appending(path: "result.json", directoryHint: .notDirectory) }

    func end() async {
        sessions.stop()
        await store.close().value
        folder.remove()
    }

    // The entry of the session in the lists.
    static func entry(_ status: AgentStatus, waitingFor: String? = nil) -> AgentEntry {
        AgentEntry(
            sessionId: id, cwd: "/w", isBackground: true, startedAt: 1, name: name,
            status: status, pid: 4242, id: shortID, waitingFor: waitingFor)
    }

    // Show the entry, as a PR session, and give its row.
    func show(_ entry: AgentEntry) async throws -> SessionRow {
        deps.registry.expectPrSession(Self.name)
        await deps.show([entry]) { rows in rows.contains { $0.sessionId == Self.id } }
        return try #require(deps.row(Self.id))
    }

    // The wait of the turn of the session in its own task, and how it ended: nil at an end, else
    // blocked or the failure. A result passes the check of the round when it is the text "good".
    // checks records each text that the wait checked, and accepted the value of an end.
    func waitForTurnEnd(
        _ row: SessionRow, checks: Recorder<String> = Recorder(),
        accepted: Recorder<String?> = Recorder()
    ) -> Task<RoundFailure?, Never> {
        let (sessions, result) = (sessions, result)
        let start = sessions.time
        return Task {
            do throws(RoundFailure) {
                let end = try await sessions.waitForTurnEnd(
                    id: row.sessionId, startedAt: start, resultFile: result,
                    limit: .seconds(1800),
                    check: { data in
                        let text = String(decoding: data, as: UTF8.self)
                        checks.record(text)
                        return text == "good" ? text : nil
                    })
                switch end {
                case .ended(let value):
                    accepted.record(value)
                    return nil
                case .blocked(let value):
                    accepted.record(value)
                    return .blocked
                }
            } catch {
                return error
            }
        }
    }

    // The deadline of the timer of the wait: the earliest sleeper of the clock (the registry
    // sleeps for days).
    var deadline: Duration? { deps.clock.nextDeadline?.offset }
}

// The wall time of a test, which the test moves.
@MainActor
private final class Wall {
    var date: Date

    init(_ date: Date) {
        self.date = date
    }
}

@MainActor
@Suite("the PR sessions", .serialized, .timeLimit(.minutes(1)))
struct PRSessionsTests {
    // The registry sleeps on the clock in 4 loops; the wait adds one timer.
    private static let registrySleepers = 4

    // A short turn can show no working state at all: an idle row ends at once when a result
    // that passes the check lands. The file lands as an event, with no poll of the folder.
    @Test func aShortTurnWithNoWorkingStateEndsWhenTheResultLands() async throws {
        let f = try await SessionsFixture()
        await f.deps.start()
        let row = try await f.show(SessionsFixture.entry(.idle))
        let checks = Recorder<String>()
        let accepted = Recorder<String?>()
        let wait = f.waitForTurnEnd(row, checks: checks, accepted: accepted)
        await waitUntil { f.deadline == .seconds(120) }
        try Data("good".utf8).write(to: f.result)
        #expect(await wait.value == nil)
        #expect(f.deps.clock.now.offset == .zero)
        #expect(checks.values.last == "good")
        // The end gives the value that the check accepted.
        #expect(accepted.values == ["good"])
        await f.end()
    }

    // A working session that wrote its result waits until its row is idle, then ends at once.
    @Test func aWorkingSessionWithItsResultEndsWhenIdle() async throws {
        let f = try await SessionsFixture()
        await f.deps.start()
        let row = try await f.show(SessionsFixture.entry(.busy))
        let checks = Recorder<String>()
        let wait = f.waitForTurnEnd(row, checks: checks)
        await waitUntil { f.deadline == .seconds(1800) }
        try Data("good".utf8).write(to: f.result)
        await waitUntil { checks.values == ["good"] }
        _ = try await f.show(SessionsFixture.entry(.idle))
        #expect(await wait.value == nil)
        #expect(f.deps.clock.now.offset == .zero)
        // The file did not change, so the end at the idle row read it no more.
        #expect(checks.values == ["good"])
        await f.end()
    }

    // An idle session that never worked and wrote no result ends after 120 s.
    @Test func anIdleSessionWithNoResultEndsAfter120s() async throws {
        let f = try await SessionsFixture()
        await f.deps.start()
        let row = try await f.show(SessionsFixture.entry(.idle))
        let accepted = Recorder<String?>()
        let wait = f.waitForTurnEnd(row, accepted: accepted)
        await waitUntil { f.deadline == .seconds(120) }
        f.deps.clock.advance(by: .seconds(119))
        await f.deps.clock.waitForSleepers(exactly: Self.registrySleepers + 1)
        #expect(f.deadline == .seconds(120))
        f.deps.clock.advance(by: .seconds(1))
        #expect(await wait.value == nil)
        // The turn ended with no result that passed the check.
        #expect(accepted.values == [nil])
        await f.end()
    }

    // A session of a round must never ask: a prompt box ends the round at once, as blocked.
    @Test func aPromptBoxEndsTheRoundAtOnce() async throws {
        let f = try await SessionsFixture()
        await f.deps.start()
        let row = try await f.show(SessionsFixture.entry(.busy))
        let wait = f.waitForTurnEnd(row)
        await waitUntil { f.deadline == .seconds(1800) }
        _ = try await f.show(SessionsFixture.entry(.waiting, waitingFor: "permission"))
        #expect(await wait.value == .blocked)
        await f.end()
    }

    // The wait sleeps once, until the next deadline of the rule, and wakes there: a session that
    // worked and went idle ends 10 s later, with no tick in between.
    @Test func theWaitWakesAtTheDeadlineWithNoTick() async throws {
        let f = try await SessionsFixture()
        await f.deps.start()
        let row = try await f.show(SessionsFixture.entry(.busy))
        let wait = f.waitForTurnEnd(row)
        await waitUntil { f.deadline == .seconds(1800) }
        f.deps.clock.advance(by: .seconds(30))
        _ = try await f.show(SessionsFixture.entry(.idle))
        await waitUntil { f.deadline == .seconds(40) }
        #expect(f.deps.clock.sleeperCount == Self.registrySleepers + 1)
        f.deps.clock.advance(by: .seconds(10))
        #expect(await wait.value == nil)
        await f.end()
    }

    // A session stays after its round. With no round and no open question, an idle session gets
    // one stop at 10 idle minutes, at the deadline of one timer, with no tick.
    @Test func anIdleSessionWithNoRoundStopsAfterTenMinutes() async throws {
        let f = try await SessionsFixture()
        await f.deps.start()
        let row = try await f.show(SessionsFixture.entry(.idle))
        let pr = try ReviewData.pr()
        let id = try #require(SessionID(SessionsFixture.id))
        await f.store.update { state in
            var prState = PRState()
            prState.reviewSession = SessionRef(
                sessionID: id, name: SessionsFixture.name, shortID: SessionsFixture.shortID)
            state.prs[pr] = prState
        }
        let wall = Wall(Date(timeIntervalSince1970: Double(row.lastActivity) / 1000 + 599))
        let sessions = PRSessions(
            store: f.store, registry: f.deps.registry, actions: f.deps.makeActions(),
            claude: f.deps.claudeRunner(), clock: f.deps.clock, now: { wall.date },
            testPrefix: true)
        sessions.start()
        let due = f.deps.clock.now.offset + .seconds(1)
        await waitUntil { f.deadline == due }
        #expect(!f.deps.calls.claudeRuns.contains(["stop", "abcdef12"]))
        wall.date += 1
        f.deps.clock.advance(by: .seconds(1))
        await waitUntil {
            f.deps.calls.claudeRuns.contains(["stop", "abcdef12"])
        }
        sessions.stop()
        await f.end()
    }

    // The start runs claude --bg in the folder, marks the row as a PR session, and keeps the
    // session in the state. A trust error gives notTrusted and releases the name.
    @Test func aStartMarksThePRSessionAndKeepsIt() async throws {
        let f = try await SessionsFixture()
        await f.deps.start()
        let pr = try ReviewData.pr()
        let args = ["--bg", "--name", SessionsFixture.name, "/bifrost-review bifrost-input=/x"]
        f.deps.calls.answerClaude { args in
            args.first == "--bg"
                ? ExecResult(.exited(0), stdout: "backgrounded \u{B7} abcdef12 \u{B7} name\n")
                : ExecResult(.exited(0))
        }
        f.deps.lists.active = [SessionsFixture.entry(.busy)]
        let start = Task { () async -> SessionRow? in
            try? await f.sessions.start(pr, .review, args: args, in: f.input)
        }
        await f.deps.poll()
        let row = try #require(await start.value)
        #expect(row.sessionId == SessionsFixture.id)
        #expect(f.deps.row(SessionsFixture.id)?.prSession == true)
        #expect(f.store.state.prs[pr]?.reviewSession?.name == SessionsFixture.name)
        #expect(f.store.state.prs[pr]?.reviewSession?.shortID == SessionsFixture.shortID)
        let runs = f.deps.calls.all.compactMap { call -> (args: [String], folder: String?)? in
            if case .claude(let args, let folder, _, _, _) = call { (args, folder) } else { nil }
        }
        #expect(runs.first?.args == args)
        #expect(runs.first?.folder == f.input.path(percentEncoded: false))

        // A start that fails releases its name: a later row with the name, which can be a
        // session of the user, gets no PR rule.
        f.deps.calls.answerClaude { _ in ExecResult(.exited(1), stderr: "No such model.") }
        let failed = try ReviewData.pr("Owner-A/Repo-A#9")
        await #expect(throws: RoundFailure.startFailed) {
            try await f.sessions.start(
                failed, .review, args: ["--bg", "--name", "bifrost-test-y", "p"], in: f.input)
        }
        let user = AgentEntry(
            sessionId: "22222222-3333-4444-5555-666666666666", cwd: "/w", isBackground: true,
            startedAt: 1, name: "bifrost-test-y", status: .idle, pid: 4343, id: ShortID("bcdef123"))
        await f.deps.show([SessionsFixture.entry(.busy), user]) { rows in
            rows.contains { $0.sessionId == user.sessionId }
        }
        #expect(f.deps.row(user.sessionId)?.prSession == false)

        f.deps.calls.answerClaude { _ in
            ExecResult(.exited(1), stderr: "Workspace not trusted. Run claude first.")
        }
        let other = try ReviewData.pr("Owner-A/Repo-A#8")
        await #expect(throws: RoundFailure.notTrusted) {
            try await f.sessions.start(
                other, .review, args: ["--bg", "--name", "bifrost-test-x", "p"], in: f.input)
        }
        await f.end()
    }

    // A start that failed after claude gave the short ID of a session still made that session:
    // it goes (stop, then rm), so no session of a round runs with no round, and waitForEnd waits
    // for that clean-up. The start waits for the end of claude, which a stop ends with SIGTERM
    // and SIGKILL after stopGrace.
    @Test func aFailedStartThatMadeASessionRemovesIt() async throws {
        let f = try await SessionsFixture()
        await f.deps.start()
        let pr = try ReviewData.pr()
        let args = ["--bg", "--name", SessionsFixture.name, "/bifrost-review bifrost-input=/x"]
        f.deps.calls.answerClaude { args in
            args.first == "--bg"
                ? ExecResult(
                    .exited(1), stdout: "backgrounded \u{B7} abcdef12 \u{B7} name\n",
                    stderr: "The session stopped.")
                : ExecResult(.exited(0))
        }
        await #expect(throws: RoundFailure.startFailed) {
            try await f.sessions.start(pr, .review, args: args, in: f.input)
        }
        await f.sessions.waitForEnd()
        #expect(f.deps.calls.claudeRuns == [args, ["stop", "abcdef12"], ["rm", "abcdef12"]])
        let start = f.deps.calls.all.first { if case .claude = $0 { true } else { false } }
        #expect(
            start
                == .claude(
                    args, directory: f.input.path(percentEncoded: false),
                    timeout: PRSessions.startLimit, killSignal: .terminate,
                    terminateGrace: PRSessions.stopGrace))
        #expect(f.store.state.prs[pr]?.reviewSession == nil)
        await f.end()
    }
}
