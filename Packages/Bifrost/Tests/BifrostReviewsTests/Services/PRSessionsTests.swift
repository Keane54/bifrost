// The PR sessions (docs/behaviour/reviews.md, "PR sessions"): the start of a session, the turns
// of the one request session of a PR of the user, and the wait for the end of a turn on the real
// signals. The registry is real, on scripted session lists and a manual clock (FakeActionDeps).
// claude is a fake that runs no program, the text input is a fake that records each send, and
// the result file and the worktree are real items in a temporary folder.
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

    // The request session of the PR, and the session that a new start or a resume makes.
    static let requestID = "dc56b1af-ac1e-45bc-b23d-369b4a25f190"
    static let requestShort = ShortID("dc56b1af")
    static let requestName = "bifrost-test-Repo-A-7-request"
    static let newID = "4101c621-4466-4bc5-a3b2-43c160288fb8"
    static let newShort = ShortID("4101c621")

    let deps = FakeActionDeps()
    let folder: TemporaryFolder
    let store: ReviewsStore
    let sessions: PRSessions
    let prompts = RecordingPromptInput()
    // The input folder of the round, with no result file yet.
    let input: URL
    // The worktree of the PR, and another folder.
    let worktree: URL
    let otherFolder: URL
    let skills = URL(filePath: "/App/bifrost-skills", directoryHint: .isDirectory)
    let pr: PRKey
    let requestID: SessionID

    init() async throws {
        pr = try ReviewData.pr()
        requestID = try #require(SessionID(Self.requestID))
        let folder = try TemporaryFolder()
        self.folder = folder
        let layout = ReviewsLayout(
            folder: URL(filePath: folder.realPath + "/reviews", directoryHint: .isDirectory))
        store = try await ReviewsStore.open(layout: layout, log: Recorder<StoreEvent>())
        let prompts = prompts
        sessions = PRSessions(
            store: store, registry: deps.registry, actions: deps.makeActions(),
            claude: deps.claudeRunner(), clock: deps.clock,
            now: { Date(timeIntervalSince1970: 1_794_312_000) }, testPrefix: true,
            input: { prompts.available ? prompts : nil })
        input = URL(filePath: folder.realPath + "/io", directoryHint: .isDirectory)
        worktree = URL(filePath: folder.realPath + "/wt", directoryHint: .isDirectory)
        otherFolder = URL(filePath: folder.realPath + "/other", directoryHint: .isDirectory)
        for made in [input, worktree, otherFolder] {
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        }
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
        accepted: Recorder<String?> = Recorder(), begun: SessionRow? = nil
    ) -> Task<RoundFailure?, Never> {
        let (sessions, result) = (sessions, result)
        let start = sessions.time
        return Task {
            do throws(RoundFailure) {
                let end = try await sessions.waitForTurnEnd(
                    id: row.sessionId, startedAt: start, resultFile: result,
                    limit: .seconds(1800), begun: begun,
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

    // MARK: - The request session

    // A turn of the PR in the worktree that Bifrost kept.
    func turn(model: ModelChoice = .standard, made: Bool = false) -> MineTurn {
        MineTurn(
            pr: pr, model: model, inputFolder: input, skills: skills, settings: "{}",
            prompt: "/bifrost-resolve-comments bifrost-input=\(input.path(percentEncoded: false))"
                + "input-0f8a2c1e5b7d.json",
            worktree: made ? .made(worktree) : .kept(worktree))
    }

    // The start arguments of the turn with the name.
    func startArgs(_ turn: MineTurn, name: String = Self.requestName) -> [String] {
        PRSessionArgs.request(
            name: name, model: turn.model, inputFolder: turn.inputFolder, skills: turn.skills,
            settings: turn.settings, prompt: turn.prompt)
    }

    func profile(_ turn: MineTurn) -> String { PRSessionArgs.profile(startArgs(turn)) }

    // The state keeps the request session with the rounds and the profile.
    func keep(rounds: Int, profile: String?) async {
        let (ref, pr) = (
            SessionRef(
                sessionID: requestID, name: Self.requestName, shortID: Self.requestShort,
                profile: profile, rounds: rounds),
            pr
        )
        await store.update { state in
            var prState = PRState()
            prState.requestSession = ref
            state.prs[pr] = prState
        }
    }

    // The request session in the lists: a running entry in the worktree, or in the folder.
    func requestEntry(
        _ status: AgentStatus, in place: URL? = nil, waitingFor: String? = nil
    ) -> AgentEntry {
        AgentEntry(
            sessionId: Self.requestID, cwd: (place ?? worktree).path(percentEncoded: false),
            isBackground: true,
            startedAt: 1, name: Self.requestName, status: status, pid: 4242,
            id: Self.requestShort, waitingFor: waitingFor)
    }

    // The stopped request session of the --all list: a parked row.
    func parkedEntry() -> AgentEntry {
        AgentEntry(
            sessionId: Self.requestID, cwd: worktree.path(percentEncoded: false),
            isBackground: true, startedAt: 1, name: Self.requestName, id: Self.requestShort)
    }

    // The session that a new start or a resume made, as it runs.
    func newEntry() -> AgentEntry {
        AgentEntry(
            sessionId: Self.newID, cwd: worktree.path(percentEncoded: false), isBackground: true,
            startedAt: 2, name: Self.requestName, status: .busy, pid: 4343, id: Self.newShort)
    }

    // Start the registry with the request session parked: the --all list has it.
    func startParked() async {
        deps.registry.expectPrSession(Self.requestName)
        deps.lists.all = [parkedEntry()]
        await deps.start()
    }

    // Start the registry with the request session live in the lists. With parks true, the --all
    // list also has the session, so its row parks when the active list loses it.
    func startLive(_ entry: AgentEntry, parks: Bool = false) async {
        deps.registry.expectPrSession(Self.requestName)
        deps.lists.active = [entry]
        if parks { deps.lists.all = [parkedEntry()] }
        await deps.start()
    }

    // The output of claude --bg for a start of the session with the short ID.
    static func started(_ short: ShortID?) -> String {
        "backgrounded \u{B7} \(short?.text ?? "") \u{B7} \(requestName)\n"
    }

    // The output of a resume that woke the session with the short ID with its saved options.
    static func resumed(_ short: ShortID?, options: String = allOptions) -> String {
        let id = short?.text ?? ""
        return "note: woke session \(id) with its saved options (\(options)).\n"
            + "backgrounded \u{B7} \(id) (idle)\n"
    }

    static let allOptions =
        "--restricted, --strict-mcp-config, --tools, --permission-mode, --settings, --add-dir, "
        + "--plugin-dir, --name, --model"

    // Answer each claude --bg run: a resume and a start give their outputs; another run ends
    // with exit code 0.
    func answer(resume: ExecResult? = nil, start: ExecResult? = nil) {
        deps.calls.answerClaude { args in
            guard args.first == "--bg" else { return ExecResult(.exited(0)) }
            if args.dropFirst().first == "--resume" { return resume ?? ExecResult(.exited(1)) }
            return start ?? ExecResult(.exited(1))
        }
    }

    // The turn in its own task, with its end. Its preparation gives the turn, and records each
    // run in preparations.
    func begin(
        _ turn: MineTurn, preparations: Recorder<Bool>? = nil
    ) -> Task<Result<BegunTurn, RoundFailure>, Never> {
        let sessions = sessions
        return Task {
            do throws(RoundFailure) {
                return .success(
                    try await sessions.beginTurn(turn.pr, worktree: turn.worktree.url) {
                        preparations?.record(true)
                        return turn
                    })
            } catch {
                return .failure(error)
            }
        }
    }

    // The turn, with a preparation that gives it.
    func beginTurn(_ turn: MineTurn) async throws(RoundFailure) -> BegunTurn {
        try await sessions.beginTurn(turn.pr, worktree: turn.worktree.url) { turn }
    }

    // Wait for the count of claude --bg runs, then make the lists show the entries.
    func showAfterRun(_ entries: [AgentEntry], runs: Int = 1) async {
        await waitUntil { bgRuns.count >= runs }
        deps.lists.active = entries
        await deps.poll()
    }

    // The claude --bg runs, in order.
    var bgRuns: [[String]] { deps.calls.claudeRuns.filter { $0.first == "--bg" } }

    // The folder of the first claude --bg run.
    var firstBgFolder: String? {
        deps.calls.all.lazy.compactMap { call -> String? in
            guard case .claude(let args, let folder, _, _, _) = call, args.first == "--bg"
            else { return nil }
            return folder
        }.first
    }

    var ref: SessionRef? { store.state.prs[pr]?.requestSession }

    // The end of the turn. A cancel of the test (its time limit) cancels the turn too, so a
    // test with a defect ends.
    func result(
        _ task: Task<Result<BegunTurn, RoundFailure>, Never>
    ) async -> Result<BegunTurn, RoundFailure> {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // The failure of the turn, or nil when it began.
    func failure(_ task: Task<Result<BegunTurn, RoundFailure>, Never>) async -> RoundFailure? {
        if case .failure(let error) = await result(task) { error } else { nil }
    }
}

// The text input of the sessions: it records each send, and refuses the next sends with the
// refusals in order. With available false, the app has no input.
@MainActor
final class RecordingPromptInput: PromptInput {
    struct Send: Equatable {
        var session: String
        var text: String
    }

    private(set) var sends: [Send] = []
    var refusals: [InputRefusal] = []
    var available = true
    // Runs at each send, before a refusal: a person acts in the session at that time.
    var onSend: () -> Void = {}

    func send(_ session: String, _ text: String) async throws(InputRefusal) {
        sends.append(Send(session: session, text: text))
        onSend()
        if !refusals.isEmpty { throw refusals.removeFirst() }
    }
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
@Suite("the PR sessions", .serialized, .testTimeLimit)
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

    // An idle session that never worked and wrote no result ends after 120 s, at the next session
    // list that still shows it idle.
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
        await waitUntil { f.deadline == .seconds(1800) }
        await f.deps.poll()
        #expect(await wait.value == nil)
        // The turn ended with no result that passed the check.
        #expect(accepted.values == [nil])
        await f.end()
    }

    // The wait reads the rows only when it wakes, so it can miss a short working state, for
    // example when the session works and is idle again before the wait takes its first sample.
    // An idle row with a busy sample after the row of the start of the turn worked in between:
    // the turn ends 10 s after it, not 120 s after an idle row that never worked.
    @Test func aTurnThatWorkedBetweenTwoSamplesEndsAfterTheSettleTime() async throws {
        let f = try await SessionsFixture()
        await f.deps.start()
        _ = try await f.show(SessionsFixture.entry(.busy))
        let begun = try await f.show(SessionsFixture.entry(.idle))
        let busyBefore = try #require(begun.lastBusyAt)
        // The session works and is idle again before the wait starts.
        await f.deps.show([SessionsFixture.entry(.busy)]) { rows in
            rows.contains { $0.sessionId == F.id && $0.state == .working }
        }
        await f.deps.show([SessionsFixture.entry(.idle)]) { rows in
            rows.contains { $0.sessionId == F.id && $0.state == .idle }
        }
        let worked = try #require(f.deps.row(F.id)?.lastBusyAt)
        #expect(worked > busyBefore)
        let wait = f.waitForTurnEnd(begun, begun: begun)
        let now = f.deps.clock.now.offset
        await waitUntil { f.deadline == now + RoundEnd.settle || f.deadline == now + .seconds(120) }
        let deadline = try #require(f.deadline)
        #expect(deadline == now + RoundEnd.settle)
        f.deps.clock.advance(by: deadline - now)
        await waitUntil { f.deadline == .seconds(1800) }
        await f.deps.poll()
        #expect(await wait.value == nil)
        await f.end()
    }

    // A change of the status that is not work (here to waiting with no prompt box and back)
    // moves no busy sample, so the turn does not count as work: an idle row that never worked
    // still waits 120 s.
    @Test func aChangeOfTheStatusWithNoBusySampleIsNoWork() async throws {
        let f = try await SessionsFixture()
        await f.deps.start()
        _ = try await f.show(SessionsFixture.entry(.busy))
        let begun = try await f.show(SessionsFixture.entry(.idle))
        await f.deps.show([SessionsFixture.entry(.waiting)]) { rows in
            rows.contains { $0.sessionId == F.id && $0.status == .waiting }
        }
        await f.deps.show([SessionsFixture.entry(.idle)]) { rows in
            rows.contains { $0.sessionId == F.id && $0.status == .idle }
        }
        #expect(f.deps.row(F.id)?.lastBusyAt == begun.lastBusyAt)
        let wait = f.waitForTurnEnd(begun, begun: begun)
        let now = f.deps.clock.now.offset
        await waitUntil { f.deadline == now + RoundEnd.settle || f.deadline == now + .seconds(120) }
        let deadline = try #require(f.deadline)
        #expect(deadline == now + .seconds(120))
        f.deps.clock.advance(by: deadline - now)
        await waitUntil { f.deadline == .seconds(1800) }
        await f.deps.poll()
        #expect(await wait.value == nil)
        await f.end()
    }

    // A new session before the preparation (here for a row of another folder) runs the safety
    // net first. When it stops the turn, the old session stays: no stop, no remove and no start,
    // so the person can still use it.
    @Test func theSafetyNetBeforeANewSessionKeepsTheOldSession() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.idle, in: f.otherFolder))
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        var preparations = 0
        var failure: RoundFailure?
        do throws(RoundFailure) {
            _ = try await f.sessions.beginTurn(
                f.pr, worktree: f.worktree,
                prepare: {
                    preparations += 1
                    return turn
                },
                recheck: { () async throws(RoundFailure) in throw .changesNotOnGitHub })
        } catch {
            failure = error
        }
        #expect(failure == .changesNotOnGitHub)
        #expect(preparations == 0)
        #expect(f.deps.calls.claudeRuns.isEmpty)
        #expect(f.ref?.sessionID == f.requestID)
        #expect(f.deps.row(F.requestID) != nil)
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

    // A session whose row goes for good is not a stop of the user: the wait fails with the
    // session-ended failure.
    @Test func aRowThatGoesEndsTheTurnAsASessionThatEnded() async throws {
        let f = try await SessionsFixture()
        await f.deps.start()
        let row = try await f.show(SessionsFixture.entry(.busy))
        let wait = f.waitForTurnEnd(row)
        await waitUntil { f.deadline == .seconds(1800) }
        await f.deps.show([]) { rows in rows.isEmpty }
        f.deps.clock.advance(by: .seconds(70))
        await f.deps.poll()
        #expect(await wait.value == .sessionEnded)
        await f.end()
    }

    // The wait sleeps once, until the next deadline of the rule, and wakes there: a session that
    // worked and went idle ends 10 s later, at the next session list, with no tick in between.
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
        await waitUntil { f.deadline == .seconds(1800) }
        await f.deps.poll()
        #expect(await wait.value == nil)
        await f.end()
    }

    // An idle sample can be old: a hidden window lists the sessions each 15 s, and a busy Mac
    // lists later still. So the end of the settle time with no result waits for a session list
    // that started after it. A list that shows the session working goes on with the turn, and a
    // list that still shows it idle ends the turn. Only the time limit is planned meanwhile.
    @Test func anOldIdleSampleNeverEndsATurn() async throws {
        let f = try await SessionsFixture()
        await f.deps.start()
        let row = try await f.show(SessionsFixture.entry(.busy))
        let wait = f.waitForTurnEnd(row)
        let end = TaskEnd(wait)
        await waitUntil { f.deadline == .seconds(1800) }
        _ = try await f.show(SessionsFixture.entry(.idle))
        await waitUntil { f.deadline == .seconds(10) }
        f.deps.clock.advance(by: .seconds(10))
        await waitUntil { f.deadline == .seconds(1800) }
        #expect(!end.ended)
        // The next list shows the session working: the idle sample came between two tools.
        _ = try await f.show(SessionsFixture.entry(.busy))
        _ = try await f.show(SessionsFixture.entry(.idle))
        await waitUntil { f.deadline == .seconds(20) }
        f.deps.clock.advance(by: .seconds(10))
        await waitUntil { f.deadline == .seconds(1800) }
        #expect(!end.ended)
        await f.deps.poll()
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

    // MARK: - The turns of a PR of the user

    private typealias F = SessionsFixture

    // The first turn starts the request session in the worktree with the flags of a start and
    // the prompt last. The state keeps the session with one round and the profile of its flags.
    @Test func theFirstTurnStartsTheSessionWithThePrompt() async throws {
        let f = try await SessionsFixture()
        await f.deps.start()
        let turn = f.turn()
        f.answer(start: ExecResult(.exited(0), stdout: F.started(F.newShort)))
        let begin = f.begin(turn)
        await f.showAfterRun([f.newEntry()])
        let begun = try await f.result(begin).get()
        #expect(begun.how == .started)
        #expect(begun.row.sessionId == F.newID)
        #expect(f.bgRuns == [f.startArgs(turn)])
        #expect(f.bgRuns.first?.last == turn.prompt)
        #expect(f.firstBgFolder == f.worktree.path(percentEncoded: false))
        #expect(f.ref?.sessionID.text == F.newID)
        #expect(f.ref?.rounds == 1)
        #expect(f.ref?.profile == f.profile(turn))
        #expect(f.prompts.sends.isEmpty)
        await f.end()
    }

    // A later turn types its prompt into the live session of the PR: no claude run, one send to
    // the session ID, and one more round.
    @Test func aLaterTurnTypesThePromptIntoTheLiveSession() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.idle))
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        let begun = try await f.beginTurn(turn)
        #expect(begun.how == .typed)
        #expect(begun.row.sessionId == F.requestID)
        #expect(f.prompts.sends == [.init(session: F.requestID, text: turn.prompt)])
        #expect(f.deps.calls.claudeRuns.isEmpty)
        #expect(f.ref?.rounds == 2)
        #expect(f.ref?.profile == f.profile(turn))
        await f.end()
    }

    // A parked session resumes with its session ID and the prompt, and no start flag: the
    // session restores the flags of its start, and keeps its ID and its history.
    @Test func aParkedSessionResumesWithNoStartFlag() async throws {
        let f = try await SessionsFixture()
        await f.startParked()
        #expect(f.deps.row(F.requestID)?.state == .parked)
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        f.answer(resume: ExecResult(.exited(0), stdout: F.resumed(F.requestShort)))
        let begin = f.begin(turn)
        await f.showAfterRun([f.requestEntry(.busy)])
        let begun = try await f.result(begin).get()
        #expect(begun.how == .resumed)
        #expect(begun.row.sessionId == F.requestID)
        #expect(f.bgRuns == [["--bg", "--resume", F.requestID, turn.prompt]])
        #expect(f.firstBgFolder == f.worktree.path(percentEncoded: false))
        #expect(f.ref?.sessionID == f.requestID)
        #expect(f.ref?.rounds == 2)
        #expect(f.prompts.sends.isEmpty)
        await f.sessions.waitForEnd()
        // No stop and no delete.
        #expect(f.deps.calls.claudeRuns == f.bgRuns)
        await f.end()
    }

    // A resume that gives a new session: the old session goes by its short ID, the name stays
    // with the new session, and the state keeps the new session.
    @Test func aResumeThatGivesANewSessionRemovesTheOldOne() async throws {
        let f = try await SessionsFixture()
        await f.startParked()
        let turn = f.turn()
        await f.keep(rounds: 3, profile: f.profile(turn))
        f.answer(resume: ExecResult(.exited(0), stdout: F.resumed(F.newShort)))
        let begin = f.begin(turn)
        await f.showAfterRun([f.newEntry()])
        let begun = try await f.result(begin).get()
        #expect(begun.how == .resumed)
        #expect(begun.row.sessionId == F.newID)
        await f.sessions.waitForEnd()
        #expect(
            f.deps.calls.claudeRuns == [
                ["--bg", "--resume", F.requestID, turn.prompt], ["stop", "dc56b1af"],
                ["rm", "dc56b1af"],
            ])
        #expect(f.ref?.sessionID.text == F.newID)
        #expect(f.ref?.shortID == F.newShort)
        #expect(f.ref?.name == F.requestName)
        #expect(f.ref?.rounds == 4)
        // The name stays a name of a PR session: a later row with it gets the PR rule.
        let later = AgentEntry(
            sessionId: "5e6f7a8b-1111-2222-3333-444444444444", cwd: "/w", isBackground: true,
            startedAt: 3, name: F.requestName, status: .idle, pid: 4444, id: ShortID("5e6f7a8b"))
        await f.deps.show([f.newEntry(), later]) { rows in
            rows.contains { $0.sessionId == later.sessionId }
        }
        #expect(f.deps.row(later.sessionId)?.prSession == true)
        await f.end()
    }

    // A resume that fails starts a new session, after the old one goes.
    @Test func aResumeThatFailsStartsAFreshSession() async throws {
        let f = try await SessionsFixture()
        await f.startParked()
        let turn = f.turn()
        await f.keep(rounds: 2, profile: f.profile(turn))
        f.answer(
            resume: ExecResult(.exited(1), stderr: "No conversation found."),
            start: ExecResult(.exited(0), stdout: F.started(F.newShort)))
        let begin = f.begin(turn)
        await f.showAfterRun([f.newEntry()], runs: 2)
        let begun = try await f.result(begin).get()
        #expect(begun.how == .started)
        #expect(begun.row.sessionId == F.newID)
        #expect(f.bgRuns == [["--bg", "--resume", F.requestID, turn.prompt], f.startArgs(turn)])
        #expect(f.deps.calls.claudeRuns.contains(["rm", "dc56b1af"]))
        #expect(f.ref?.sessionID.text == F.newID)
        #expect(f.ref?.rounds == 1)
        await f.end()
    }

    // The resumed session must keep its limits: with no note of its saved options, or a note
    // with a missing limit, the woken session goes, nothing is typed and the turn fails.
    @Test func aResumeWithoutItsLimitsFailsTheTurn() async throws {
        let f = try await SessionsFixture()
        await f.startParked()
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        let fewer = F.resumed(F.requestShort, options: "--restricted, --tools, --name, --model")
        f.answer(resume: ExecResult(.exited(0), stdout: fewer))
        #expect(await f.failure(f.begin(turn)) == .startFailed)
        await f.sessions.waitForEnd()
        #expect(
            f.deps.calls.claudeRuns == [
                ["--bg", "--resume", F.requestID, turn.prompt], ["stop", "dc56b1af"],
                ["rm", "dc56b1af"],
            ])
        #expect(f.ref == nil)
        #expect(f.prompts.sends.isEmpty)
        await f.end()
    }

    // A row with the name of the session in another folder gets no prompt: the session goes,
    // and a new one starts in the worktree.
    @Test func aRowOfAnotherFolderGetsNoPrompt() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.idle, in: f.otherFolder))
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        f.answer(start: ExecResult(.exited(0), stdout: F.started(F.newShort)))
        let begin = f.begin(turn)
        await f.showAfterRun([f.newEntry()])
        let begun = try await f.result(begin).get()
        #expect(begun.how == .started)
        #expect(f.prompts.sends.isEmpty)
        #expect(f.bgRuns == [f.startArgs(turn)])
        #expect(f.deps.calls.claudeRuns.contains(["rm", "dc56b1af"]))
        #expect(f.ref?.sessionID.text == F.newID)
        await f.end()
    }

    // A working session gets the prompt when it is idle with no box. The time of the turn is
    // the time of the send.
    @Test func aWorkingSessionGetsThePromptWhenItIsIdle() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.busy))
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        let begin = f.begin(turn)
        await waitUntil { f.deadline == PRSessions.busyWait }
        #expect(f.prompts.sends.isEmpty)
        f.deps.clock.advance(by: .seconds(60))
        await f.deps.show([f.requestEntry(.idle)])
        let begun = try await f.result(begin).get()
        #expect(begun.how == .typed)
        #expect(begun.startedAt == .seconds(60))
        #expect(f.prompts.sends == [.init(session: F.requestID, text: turn.prompt)])
        #expect(f.ref?.rounds == 2)
        await f.end()
    }

    // A session that works for busyWait gets no prompt, and the turn fails as busy.
    @Test func aSessionBusyFor120sFailsTheTurn() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.busy))
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        let preparations = Recorder<Bool>()
        let begin = f.begin(turn, preparations: preparations)
        await waitUntil { f.deadline == .seconds(120) }
        f.deps.clock.advance(by: .seconds(119))
        await f.deps.clock.waitForSleepers(exactly: Self.registrySleepers + 1)
        #expect(f.deadline == .seconds(120))
        f.deps.clock.advance(by: .seconds(1))
        #expect(await f.failure(begin) == .sessionBusy)
        #expect(preparations.values.isEmpty)
        #expect(f.prompts.sends.isEmpty)
        #expect(f.deps.calls.claudeRuns.isEmpty)
        #expect(f.ref?.rounds == 1)
        await f.end()
    }

    // A prompt box waits for a person, as a working row does: no send and no stop. When the
    // person answers and the row is idle with no box, the turn types its prompt.
    @Test func aPromptBoxWaitsForThePersonLikeAWorkingRow() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.waiting, waitingFor: "permission"))
        #expect(f.deps.row(F.requestID)?.alert.blocksPrompt == true)
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        let begin = f.begin(turn)
        await waitUntil { f.deadline == PRSessions.busyWait }
        #expect(f.prompts.sends.isEmpty)
        await f.deps.show([f.requestEntry(.busy)]) { rows in
            rows.contains { $0.sessionId == F.requestID && $0.alert == .none }
        }
        await f.deps.show([f.requestEntry(.idle)])
        let begun = try await f.result(begin).get()
        #expect(begun.how == .typed)
        #expect(f.prompts.sends.count == 1)
        #expect(f.deps.calls.claudeRuns.isEmpty)
        await f.end()
    }

    // A box that stays for busyWait fails the turn as busy, with no preparation, no send and no
    // stop.
    @Test func aPromptBoxForBusyWaitFailsTheTurnAsBusy() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.waiting, waitingFor: "permission"))
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        let preparations = Recorder<Bool>()
        let begin = f.begin(turn, preparations: preparations)
        await waitUntil { f.deadline == PRSessions.busyWait }
        f.deps.clock.advance(by: PRSessions.busyWait)
        #expect(await f.failure(begin) == .sessionBusy)
        #expect(preparations.values.isEmpty)
        #expect(f.prompts.sends.isEmpty)
        #expect(f.deps.calls.claudeRuns.isEmpty)
        #expect(f.ref?.rounds == 1)
        await f.end()
    }

    // A box that comes just before the send makes the input refuse the text. The turn waits
    // again until the row changes and is idle with no box, then sends again. It never stops the
    // session.
    @Test func aPromptAtTheSendWaitsAgain() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.idle))
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        f.prompts.refusals = [.prompt]
        let begin = f.begin(turn)
        await waitUntil { f.prompts.sends.count == 1 && f.deadline == PRSessions.busyWait }
        await f.deps.show([f.requestEntry(.busy)])
        await f.deps.show([f.requestEntry(.idle)])
        let begun = try await f.result(begin).get()
        #expect(begun.how == .typed)
        #expect(f.prompts.sends.count == 2)
        #expect(f.deps.calls.claudeRuns.isEmpty)
        #expect(f.ref?.rounds == 2)
        await f.end()
    }

    // An Interrupt of the user cancels the send: the turn stops, and the session stays as the
    // user left it (no stop and no resume).
    @Test func anInterruptOfTheSendStopsTheTurn() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.idle))
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        f.prompts.refusals = [.cancelled]
        #expect(await f.failure(f.begin(turn)) == .stopped)
        #expect(f.prompts.sends.count == 1)
        #expect(f.deps.calls.claudeRuns.isEmpty)
        #expect(f.ref?.rounds == 1)
        await f.end()
    }

    // A rename of the session while the turn waits: the row is no longer the session of the PR,
    // so it gets no prompt, and a new session starts.
    @Test func aRenameDuringTheWaitGetsNoPrompt() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.busy))
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        f.answer(start: ExecResult(.exited(0), stdout: F.started(F.newShort)))
        let begin = f.begin(turn)
        await waitUntil { f.deadline == PRSessions.busyWait }
        #expect(f.deps.registry.setAlias(F.requestID, "bifrost-test-mine"))
        await f.deps.show([f.requestEntry(.idle)])
        await f.showAfterRun([f.newEntry()])
        let begun = try await f.result(begin).get()
        #expect(begun.how == .started)
        #expect(f.prompts.sends.isEmpty)
        #expect(f.ref?.sessionID.text == F.newID)
        await f.end()
    }

    // A row that a hint parked while the active list still shows it can still run: a resume
    // would start a copy. The turn waits, and resumes the row only when it is stopped.
    @Test func aParkedRowThatAListStillShowsIsNotResumed() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.idle), parks: true)
        // The hint is newer than each sample of the test, so no sample clears the park.
        let hint = 1_800_000_100_000
        f.deps.registry.pushLive(.state(HookEvent(.sessionEnd, F.requestID, at: hint)))
        let parked = try #require(f.deps.row(F.requestID))
        #expect(parked.state == .parked && parked.listedActive)
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        f.answer(resume: ExecResult(.exited(0), stdout: F.resumed(F.requestShort)))
        let begin = f.begin(turn)
        await waitUntil { f.deadline == PRSessions.busyWait }
        #expect(f.deps.calls.claudeRuns.isEmpty)
        #expect(f.prompts.sends.isEmpty)
        await f.deps.show([]) { rows in
            rows.contains { $0.sessionId == F.requestID && $0.pid == nil && !$0.listedActive }
        }
        // The resume runs. The session list shows its process, and its start line ends the park.
        await waitUntil { f.bgRuns.count == 1 }
        await f.deps.show([f.requestEntry(.busy)]) { rows in
            rows.contains { $0.sessionId == F.requestID && $0.pid != nil }
        }
        f.deps.registry.pushLive(.state(HookEvent(.sessionStart, F.requestID, at: hint + 1)))
        let begun = try await f.result(begin).get()
        #expect(begun.how == .resumed)
        #expect(f.bgRuns == [["--bg", "--resume", F.requestID, turn.prompt]])
        await f.end()
    }

    // A stop of the turn while it waits for the row of the resumed session: the session stops
    // and stays the session of the PR, as at a stop just after the run.
    @Test func aStopDuringTheResumeKeepsTheSession() async throws {
        let f = try await SessionsFixture()
        await f.startParked()
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        f.answer(resume: ExecResult(.exited(0), stdout: F.resumed(F.requestShort)))
        let begin = f.begin(turn)
        await waitUntil { f.deadline == PRSessions.rowWait }
        begin.cancel()
        #expect(await f.failure(begin) == .stopped)
        await f.sessions.waitForEnd()
        #expect(
            f.deps.calls.claudeRuns == [
                ["--bg", "--resume", F.requestID, turn.prompt], ["stop", "dc56b1af"],
            ])
        #expect(f.ref?.sessionID == f.requestID)
        #expect(f.ref?.rounds == 1)
        await f.end()
    }

    // A resume that fails after claude woke the session: the old session goes in a command task,
    // and a new session starts with the same name. The release of the name at the end of that
    // task never undoes the new start: a later row with the name still gets the PR rule.
    @Test func theRemoveOfAFailedResumeKeepsTheNameOfTheNewStart() async throws {
        let f = try await SessionsFixture()
        await f.startParked()
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        f.answer(
            resume: ExecResult(
                .exited(1), stdout: "backgrounded \u{B7} dc56b1af (idle)\n", stderr: "Failed."),
            start: ExecResult(.exited(0), stdout: F.started(F.newShort)))
        let gate = TestGate()
        defer { gate.openAll() }
        f.deps.calls.hold(gate)
        let begin = f.begin(turn)
        #expect(await gate.waitUntilHolding(1))
        // The row of the old session goes, so the new start takes the same name.
        f.deps.registry.forget(F.requestID)
        gate.open()
        // The stop of the old session and the new start wait at the gate: the new start
        // expected the name before the release.
        #expect(await gate.waitUntilHolding(2))
        gate.openAll()
        await f.sessions.waitForEnd()
        await f.showAfterRun([f.newEntry()], runs: 2)
        let begun = try await f.result(begin).get()
        #expect(begun.how == .started)
        #expect(f.bgRuns.last == f.startArgs(turn))
        let later = AgentEntry(
            sessionId: "5e6f7a8b-1111-2222-3333-444444444444", cwd: "/w", isBackground: true,
            startedAt: 3, name: F.requestName, status: .idle, pid: 4444, id: ShortID("5e6f7a8b"))
        await f.deps.show([f.newEntry(), later]) { rows in
            rows.contains { $0.sessionId == later.sessionId }
        }
        #expect(f.deps.row(later.sessionId)?.prSession == true)
        await f.end()
    }

    // A resume keeps the flags of the start, so a turn with another model starts a new session
    // with the new flags after the old one goes.
    @Test func aChangedModelStartsAFreshSession() async throws {
        let f = try await SessionsFixture()
        await f.startParked()
        await f.keep(rounds: 1, profile: f.profile(f.turn()))
        let turn = f.turn(model: .opus)
        f.answer(start: ExecResult(.exited(0), stdout: F.started(F.newShort)))
        let begin = f.begin(turn)
        await f.showAfterRun([f.newEntry()])
        let begun = try await f.result(begin).get()
        #expect(begun.how == .started)
        #expect(f.bgRuns == [f.startArgs(turn)])
        #expect(f.bgRuns.first.map { Array($0.suffix(5).prefix(2)) } == ["--model", "opus"])
        #expect(f.deps.calls.claudeRuns.contains(["rm", "dc56b1af"]))
        #expect(f.ref?.profile == f.profile(turn))
        #expect(f.ref?.rounds == 1)
        await f.end()
    }

    // The tenth turn still types into the session. The eleventh starts a new session, so the
    // context of a session does not grow with no limit.
    @Test func theEleventhTurnStartsAFreshSession() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.idle))
        let turn = f.turn()
        await f.keep(rounds: PRSessions.maxRounds - 1, profile: f.profile(turn))
        #expect(try await f.beginTurn(turn).how == .typed)
        #expect(f.ref?.rounds == PRSessions.maxRounds)

        f.answer(start: ExecResult(.exited(0), stdout: F.started(F.newShort)))
        let begin = f.begin(turn)
        await f.showAfterRun([f.newEntry()])
        let begun = try await f.result(begin).get()
        #expect(begun.how == .started)
        #expect(f.prompts.sends.count == 1)
        #expect(f.deps.calls.claudeRuns.contains(["rm", "dc56b1af"]))
        #expect(f.ref?.sessionID.text == F.newID)
        #expect(f.ref?.rounds == 1)
        await f.end()
    }

    // A worktree that Bifrost made again gets a new session.
    @Test func aRemadeWorktreeStartsAFreshSession() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.idle))
        let turn = f.turn(made: true)
        await f.keep(rounds: 1, profile: f.profile(turn))
        f.answer(start: ExecResult(.exited(0), stdout: F.started(F.newShort)))
        let begin = f.begin(turn)
        await f.showAfterRun([f.newEntry()])
        let begun = try await f.result(begin).get()
        #expect(begun.how == .started)
        #expect(f.prompts.sends.isEmpty)
        #expect(f.bgRuns == [f.startArgs(turn)])
        #expect(f.ref?.sessionID.text == F.newID)
        await f.end()
    }

    // With no text input, the live session stops, then resumes with the prompt.
    @Test func aLiveSessionWithNoInputStopsAndResumes() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.idle), parks: true)
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        f.prompts.available = false
        f.answer(resume: ExecResult(.exited(0), stdout: F.resumed(F.requestShort)))
        let begin = f.begin(turn)
        await waitUntil { f.deps.calls.claudeRuns.contains(["stop", "dc56b1af"]) }
        await f.deps.show([]) { rows in
            rows.contains { $0.sessionId == F.requestID && $0.state == .parked }
        }
        await f.showAfterRun([f.requestEntry(.busy)])
        let begun = try await f.result(begin).get()
        #expect(begun.how == .resumed)
        #expect(f.bgRuns == [["--bg", "--resume", F.requestID, turn.prompt]])
        #expect(f.ref?.rounds == 2)
        await f.end()
    }

    // A turn that stops the session itself near the end of busyWait still waits rowWait for the
    // stopped row. A list can show the stopped row late (with a hidden window, each 15 s), and a
    // new session in its place would lose the history.
    @Test func aStopNearTheDeadlineStillWaitsForTheStoppedRow() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.busy), parks: true)
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        f.prompts.available = false
        f.answer(resume: ExecResult(.exited(0), stdout: F.resumed(F.requestShort)))
        let begin = f.begin(turn)
        await waitUntil { f.deadline == PRSessions.busyWait }
        f.deps.clock.advance(by: .seconds(110))
        await f.deps.show([f.requestEntry(.idle)])
        await waitUntil { f.deps.calls.claudeRuns.contains(["stop", "dc56b1af"]) }
        // The stop waits for the park of the row.
        await waitUntil { f.deadline == .seconds(110) + SessionActions.parkWait }
        // A hint parks the row while the active list still shows it, so the row is not stopped.
        let hint = 1_800_000_100_000
        f.deps.registry.pushLive(.state(HookEvent(.sessionEnd, F.requestID, at: hint)))
        await waitUntil {
            [PRSessions.busyWait, .seconds(110) + PRSessions.rowWait].contains(f.deadline)
        }
        try #require(f.deadline == .seconds(110) + PRSessions.rowWait)
        f.deps.clock.advance(by: .seconds(10))
        await f.deps.clock.waitForSleepers(exactly: Self.registrySleepers + 1)
        #expect(f.deadline == .seconds(110) + PRSessions.rowWait)
        #expect(f.bgRuns.isEmpty)
        // The list loses the row: it is stopped, and the turn resumes it.
        await f.deps.show([]) { rows in
            rows.contains { $0.sessionId == F.requestID && $0.pid == nil && !$0.listedActive }
        }
        await waitUntil { f.bgRuns.count == 1 }
        await f.deps.show([f.requestEntry(.busy)]) { rows in
            rows.contains { $0.sessionId == F.requestID && $0.pid != nil }
        }
        f.deps.registry.pushLive(.state(HookEvent(.sessionStart, F.requestID, at: hint + 1)))
        let begun = try await f.result(begin).get()
        #expect(begun.how == .resumed)
        #expect(f.bgRuns == [["--bg", "--resume", F.requestID, turn.prompt]])
        await f.end()
    }

    // The preparation changes the folders of the session, so it runs only when no person can use
    // the session: while the row works, the turn prepares nothing. When the row is idle with no
    // box, the turn prepares one time and types.
    @Test func thePreparationWaitsUntilTheSessionIsFree() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.busy))
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        let preparations = Recorder<Bool>()
        let begin = f.begin(turn, preparations: preparations)
        await waitUntil { f.deadline == PRSessions.busyWait }
        #expect(preparations.values.isEmpty)
        await f.deps.show([f.requestEntry(.idle)])
        let begun = try await f.result(begin).get()
        #expect(begun.how == .typed)
        #expect(preparations.values.count == 1)
        #expect(f.prompts.sends == [.init(session: F.requestID, text: turn.prompt)])
        await f.end()
    }

    // A person who types into the session while the turn prepares makes the row work again. The
    // turn sends nothing, prepares nothing more and fails as busy.
    @Test func aSessionThatWorksAfterThePreparationFailsAsBusy() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.idle))
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        var preparations = 0
        var failure: RoundFailure?
        do throws(RoundFailure) {
            _ = try await f.sessions.beginTurn(f.pr, worktree: f.worktree) {
                preparations += 1
                await f.deps.show([f.requestEntry(.busy)]) { rows in
                    rows.contains { $0.sessionId == F.requestID && $0.state == .working }
                }
                return turn
            }
        } catch {
            failure = error
        }
        #expect(failure == .sessionBusy)
        #expect(preparations == 1)
        #expect(f.prompts.sends.isEmpty)
        #expect(f.deps.calls.claudeRuns.isEmpty)
        #expect(f.ref?.rounds == 1)
        await f.end()
    }

    // A turn that it prepared and that waits again (a prompt box refused the send) checks the
    // folders again before the next send. A refusal there ends the turn with its failure, and
    // nothing more is typed.
    @Test func aPreparedTurnThatWaitsAgainChecksTheFoldersFirst() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.idle))
        let turn = f.turn()
        await f.keep(rounds: 1, profile: f.profile(turn))
        f.prompts.refusals = [.prompt]
        let checks = Recorder<Bool>()
        let sessions = f.sessions
        let begin = Task { () -> Result<BegunTurn, RoundFailure> in
            do throws(RoundFailure) {
                return .success(
                    try await sessions.beginTurn(
                        turn.pr, worktree: turn.worktree.url, prepare: { turn },
                        recheck: { () async throws(RoundFailure) in
                            checks.record(true)
                            throw .changesNotOnGitHub
                        }))
            } catch {
                return .failure(error)
            }
        }
        await waitUntil { f.prompts.sends.count == 1 }
        #expect(checks.values.isEmpty)
        await f.deps.show([f.requestEntry(.busy)])
        await f.deps.show([f.requestEntry(.idle)])
        #expect(await f.failure(begin) == .changesNotOnGitHub)
        #expect(checks.values.count == 1)
        #expect(f.prompts.sends.count == 1)
        #expect(f.deps.calls.claudeRuns.isEmpty)
        await f.end()
    }

    // The round limit counts only after the wait: a busy session at the limit keeps its session
    // while the turn waits (no remove and no preparation). When the row is idle with no box, the
    // turn prepares one time, the old session goes, and a new session starts.
    @Test func theRoundLimitIsCheckedAfterTheWait() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.busy))
        let turn = f.turn()
        await f.keep(rounds: PRSessions.maxRounds, profile: f.profile(turn))
        f.answer(start: ExecResult(.exited(0), stdout: F.started(F.newShort)))
        let preparations = Recorder<Bool>()
        let begin = f.begin(turn, preparations: preparations)
        await waitUntil { f.deadline == PRSessions.busyWait }
        #expect(preparations.values.isEmpty)
        #expect(f.deps.calls.claudeRuns.isEmpty)
        #expect(f.ref?.sessionID == f.requestID)
        await f.deps.show([f.requestEntry(.idle)])
        await f.showAfterRun([f.newEntry()])
        let begun = try await f.result(begin).get()
        #expect(begun.how == .started)
        #expect(preparations.values.count == 1)
        #expect(f.deps.calls.claudeRuns.contains(["rm", "dc56b1af"]))
        #expect(f.ref?.sessionID.text == F.newID && f.ref?.rounds == 1)
        #expect(f.prompts.sends.isEmpty)
        await f.end()
    }

    // A turn that needs a new session after its preparation (here at the round limit) reads the
    // row again first. A person who typed into the session during the preparation makes the turn
    // fail as busy: the session stays, with no stop, no remove and no start.
    @Test func aNewSessionAfterThePreparationNeedsAFreeRow() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.idle))
        let turn = f.turn()
        await f.keep(rounds: PRSessions.maxRounds, profile: f.profile(turn))
        var failure: RoundFailure?
        do throws(RoundFailure) {
            _ = try await f.sessions.beginTurn(f.pr, worktree: f.worktree) {
                await f.deps.show([f.requestEntry(.busy)]) { rows in
                    rows.contains { $0.sessionId == F.requestID && $0.state == .working }
                }
                return turn
            }
        } catch {
            failure = error
        }
        #expect(failure == .sessionBusy)
        #expect(f.deps.calls.claudeRuns.isEmpty)
        #expect(f.ref?.sessionID == f.requestID && f.ref?.rounds == PRSessions.maxRounds)
        await f.end()
    }

    // A request session that ends a turn (its row is idle with no box again, with a new last
    // activity) tells the owner, so an own request of the user can go. A later change of the
    // rows with the same free row tells nothing more; the next turn tells again, also after a
    // box.
    @Test func aRequestSessionThatEndsATurnTellsTheOwner() async throws {
        let f = try await SessionsFixture()
        await f.startLive(f.requestEntry(.busy))
        await f.keep(rounds: 1, profile: nil)
        let freed = Recorder<PRKey>()
        f.sessions.requestFree = { freed.record($0) }
        f.sessions.start()
        await f.deps.show([f.requestEntry(.idle)])
        await waitUntil { freed.values == [f.pr] }
        await f.deps.poll()
        #expect(freed.values == [f.pr])
        await f.deps.show([f.requestEntry(.waiting, waitingFor: "permission")]) { rows in
            rows.contains { $0.sessionId == F.requestID && $0.alert.blocksPrompt }
        }
        await f.deps.show([f.requestEntry(.busy)]) { rows in
            rows.contains { $0.sessionId == F.requestID && $0.alert == .none }
        }
        #expect(freed.values == [f.pr])
        await f.deps.show([f.requestEntry(.idle)])
        await waitUntil { freed.values == [f.pr, f.pr] }
        await f.end()
    }
}
