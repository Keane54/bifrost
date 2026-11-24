// The PR sessions (docs/behaviour/reviews.md, "PR sessions"): the Claude Code background sessions
// of the rounds. A PR session is a normal Bifrost session: it shows in the Overview.
//
// - start runs "claude --bg" with the flags of its kind (PRSessionArgs) in the worktree of the PR.
//   The earlier session of the PR and kind goes first: each review round starts a new session,
//   because the input file holds the history. The registry expects the name as a PR session
//   before the start and marks the row after it, so the row gets no yellow box and no Resume all.
//   The state keeps the session of the PR (PRState.reviewSession), so a restart finds it.
// - beginTurn begins a turn of the request session of a PR of the user. This session stays
//   across the rounds of the PR, so Claude keeps the history. A later turn types its prompt into
//   the live session (PromptInput), or resumes the stopped session with no start flag: the
//   session restores the flags of its start, and the note of claude must name each limit
//   (PRSessionArgs.resumeNote). The turn waits up to busyWait while a person can use the session
//   (it works or shows a box) and while a list still shows it as active, and never stops it for
//   that. The preparation of the turn (the worktree, the files of the round) changes the folders
//   of the session, so it runs only when no person can use the session. A new session starts
//   after maxRounds rounds, for a worktree that Bifrost made again, for other flags (the
//   profile), and for a session that is gone or is not the session of the PR.
// - waitForTurnEnd follows RoundEnd on the real signals: it checks again at each change of the
//   rows and at each applied session list (Observations), at each change of the result file
//   (FileWatch: the file lands) and at the next deadline of the rule (one TimerSlot). Nothing
//   ticks. The result counts only when it passes the check of the round; the read follows no
//   link, and an unchanged file is not read again. The wait gives the value that the check
//   accepted, so a round uses the bytes that ended the turn and never reads the file again. The
//   wait reads the rows only when it wakes, and Observations can join changes, so it can miss a
//   working row. An idle row with a busy sample of the session list after the last row that the
//   wait saw (lastBusyAt) worked in between. An end with no result also needs a session list
//   that started after the settle time and still shows the row idle: the idle sample that
//   started the settle time can be old, because a hidden window lists each 15 s and a busy Mac
//   can list later still.
// - A session stays after its round, so the user can open its chat. A session with no round that
//   is idle with no box (no open question) for idleStop gets one stop. The check runs at each
//   change of the rows and at the next deadline, never on a tick.
// - A request session whose row is idle with no box, with another last activity than at the
//   last free row, ended a turn: requestFree tells the owner, so an own request of the user can
//   go (docs/behaviour/reviews.md, "Your own requests"). The check runs at each change of the
//   rows. The last activity changes with each change of state, so a change of the rows that the
//   follow did not see (Observations can join changes) does not lose the end of a turn.
// - remove stops and deletes the session through the session commands, then the registry forgets
//   its name.
// - The idle stops and the clean-up of a start that failed run in tasks of PRSessions. stop() ends
//   the follow of the rows and the timer, and waitForEnd() waits for those tasks, so no claude
//   command of PRSessions outlives Reviews.
import BifrostFoundation
import BifrostSessions
import Foundation
import OSLog
import Observation

@MainActor
package final class PRSessions {
    package static let idleStop = Duration.seconds(600)
    // The time limit of the start of claude, and the time that a start waits for its row.
    package static let startLimit = Duration.seconds(60)
    package static let rowWait = Duration.seconds(30)
    // The time from the SIGTERM of a start that a stop ends to its SIGKILL. It is shorter than
    // the wait of the quit, so a quit ends the start.
    package static let stopGrace = Duration.seconds(1)
    // The longest time that a turn waits for a live session to get idle with no box.
    package static let busyWait = Duration.seconds(120)
    // The rounds of one request session. The next turn starts a new session, so the context of
    // the session does not grow with no limit.
    package static let maxRounds = 10

    private static let logger = Logger(bifrost: "reviews")

    private let store: ReviewsStore
    private let registry: RegistryService
    private let actions: SessionActions
    private let claude: ClaudeRunner
    private let clock: any Clock<Duration>
    private let timeline: Timeline
    private let now: () -> Date
    private let testPrefix: Bool
    // The text input of the sessions, or nil when the app has none yet.
    private let input: @MainActor () -> (any PromptInput)?
    private let idleTimer: TimerSlot
    private var idleFollow: Task<Void, Never>?
    // The sessions that got their idle stop. A row that works again leaves the set.
    private var idleStopped: Set<String> = []
    // The count of the starts and resumes of PRSessions that expected each name. A remove in a
    // command task releases a name only when no start expected the name again in the meantime.
    private var nameClaims: [String: Int] = [:]
    // The last activity of each request session whose row was free (idle with no box) at the
    // last change of the rows, by session ID.
    private var freeAt: [String: Int] = [:]
    // The claude commands that run apart from a round (an idle stop, the clean-up of a start), by
    // number. Each one leaves the list at its end.
    private var commands: [Int: Task<Void, Never>] = [:]
    private var commandCount = 0

    // The PR of a request session that ended a turn: its row is free again, with a new last
    // activity. The owner sets it before start(). The default does nothing.
    package var requestFree: @MainActor (PRKey) -> Void = { _ in }

    // testPrefix: a test home, whose session names start with bifrost-test-. input gives the
    // text input of the sessions at the time of a turn.
    package init(
        store: ReviewsStore, registry: RegistryService, actions: SessionActions,
        claude: ClaudeRunner, clock: any Clock<Duration>, now: @escaping () -> Date,
        testPrefix: Bool, input: @escaping @MainActor () -> (any PromptInput)? = { nil }
    ) {
        self.store = store
        self.registry = registry
        self.actions = actions
        self.claude = claude
        self.clock = clock
        timeline = Timeline(clock)
        self.now = now
        self.testPrefix = testPrefix
        self.input = input
        idleTimer = TimerSlot(clock: clock)
    }

    isolated deinit {
        idleFollow?.cancel()
    }

    // The time on the clock of the sessions, for the start of a round.
    package var time: Duration { timeline.now() }

    // The text input that a turn gets now. A test reads it.
    package var currentInput: (any PromptInput)? { input() }

    // MARK: - The idle stop

    // Follow the rows for the idle stops and the ends of the turns until stop().
    package func start() {
        guard idleFollow == nil else { return }
        let registry = registry
        let changes = Observations { registry.rows }
        idleFollow = Task { [weak self] in
            for await rows in changes {
                self?.checkIdle(rows)
                self?.checkTurns(rows)
            }
        }
    }

    // Each request session whose row is free now, and was not free with this last activity at the
    // last change, ended a turn: requestFree gets its PR.
    private func checkTurns(_ rows: [SessionRow]) {
        var free: [String: Int] = [:]
        for (pr, state) in store.state.prs {
            guard let id = state.requestSession?.sessionID.text,
                let row = rows.first(where: { $0.sessionId == id }), Self.isFree(row)
            else { continue }
            free[id] = row.lastActivity
            if freeAt[id] != row.lastActivity { requestFree(pr) }
        }
        freeAt = free
    }

    // Stop the follow of the rows and the timer of the idle stops.
    package func stop() {
        idleFollow?.cancel()
        idleFollow = nil
        idleTimer.stop()
    }

    // Wait until each claude command of PRSessions that runs now ended.
    package func waitForEnd() async {
        for task in commands.values { await task.value }
    }

    // Run a claude command apart from a round, in a task that PRSessions keeps until its end.
    private func command(_ work: @escaping @MainActor () async -> Void) {
        commandCount += 1
        let number = commandCount
        commands[number] = Task { [weak self] in
            await work()
            self?.commands[number] = nil
        }
    }

    // The task of the timer of the next idle stop, or nil. A test waits for it.
    package var idleTimerTask: Task<Void, Never>? { idleTimer.task }

    // Stop each PR session with no round that is idle with no box for idleStop, one time. Then
    // plan the check at the earliest next end of the idle time.
    private func checkIdle(_ rows: [SessionRow]) {
        let time = now()
        var next: Date?
        for (pr, state) in store.state.prs where state.round == nil && state.questions.isEmpty {
            for ref in [state.reviewSession, state.requestSession].compactMap({ $0 }) {
                guard let row = rows.first(where: { $0.sessionId == ref.sessionID.text }) else {
                    continue
                }
                if row.state == .working { idleStopped.remove(row.sessionId) }
                guard row.state == .idle, row.alert == .none,
                    !idleStopped.contains(row.sessionId)
                else { continue }
                let end = Date(timeIntervalSince1970: Double(row.lastActivity) / 1000)
                    .addingTimeInterval(Self.idleStop.seconds)
                guard end <= time else {
                    next = min(next ?? end, end)
                    continue
                }
                idleStopped.insert(row.sessionId)
                Self.logger.info(
                    "A PR session of \(pr.text, privacy: .private) was idle, so Bifrost stops it.")
                let (actions, id) = (actions, row.sessionId)
                command { _ = try? await actions.run(.stop(id)) }
            }
        }
        guard let next else {
            idleTimer.stop()
            return
        }
        let registry = registry
        idleTimer.start(after: .seconds(next.timeIntervalSince(time))) { [weak self] in
            self?.checkIdle(registry.rows)
        }
    }

    // MARK: - The start

    // The name of a new session of the PR: the short name, or the name with the owner when a
    // row has the short name.
    package func name(_ pr: PRKey, _ kind: PRSessionKind) -> String {
        let inUse = Set(registry.rows.flatMap { [$0.name, $0.claudeName] })
        return SessionNames.free(pr, kind, inUse: inUse, testPrefix: testPrefix)
    }

    // Start the session of the round in the folder, after the remove of the earlier session of
    // the PR and kind. args hold the name after --name. The result is the row of the new
    // session. A trust error gives notTrusted; each other failure gives startFailed, and the log
    // keeps the text of claude.
    // The start waits for the end of claude also after a stop, so its output is complete. A
    // start that failed, timed out or stopped after claude gave the short ID of a session still
    // made that session, so the session goes (removeLater): no session of a round runs with no
    // round.
    package func start(
        _ pr: PRKey, _ kind: PRSessionKind, args: [String], in folder: URL
    ) async throws(RoundFailure) -> SessionRow {
        guard let at = args.firstIndex(of: "--name"), args.indices.contains(at + 1) else {
            throw .startFailed
        }
        let name = args[at + 1]
        await remove(pr, kind)
        if Task.isCancelled { throw .stopped }
        expectName(name)
        let result = await claude.run(
            args, directory: folder.path(percentEncoded: false), timeout: Self.startLimit,
            killSignal: .terminate, terminateGrace: Self.stopGrace, waitsForEnd: true)
        let started = ClaudeOutput.shortId(result.stdout)
        if ClaudeOutput.isTrustError(result.stdout) || ClaudeOutput.isTrustError(result.stderr) {
            failedStart(started, name: name)
            throw .notTrusted
        }
        guard result.succeeded, let shortID = started else {
            Self.logger.error(
                """
                The PR session of \(pr.text, privacy: .private) did not start. \
                \(ClaudeOutput.claudeFailure(result).message, privacy: .private)
                """)
            if started == nil, result.end == .cancelled {
                Self.logger.notice(
                    """
                    A stop ended the start of a PR session of \(pr.text, privacy: .private) \
                    before claude gave its short ID.
                    """)
            }
            failedStart(started, name: name)
            throw .startFailed
        }
        let row: SessionRow
        do throws(RowWaitError) {
            row = try await registry.waitForRow(timeout: Self.rowWait) {
                $0.shortId == shortID && $0.kind == .owned && $0.state != .parked
                    && $0.pid != nil
            }
        } catch {
            // The session can still run: it goes, so no session of a round runs with no round.
            removeLater(shortID, name: name)
            throw error == .timeout ? .startFailed : .stopped
        }
        registry.markPrSession(row.sessionId)
        registry.markStarted(row.sessionId)
        if let id = SessionID(row.sessionId) {
            let ref = SessionRef(sessionID: id, name: name, shortID: shortID)
            await store.update { state in
                var prState = state.prs[pr] ?? PRState()
                // The rounds on a PR of the user share its request session.
                switch kind {
                case .review: prState.reviewSession = ref
                case .request, .conflict, .ci: prState.requestSession = ref
                }
                state.prs[pr] = prState
            }
        }
        return row
    }

    // A start that failed. A session that claude made (it gave the short ID) goes. With no
    // session, the name goes from the registry at once: a later row with this name must not get
    // the PR rule, because it can be a session of the user.
    private func failedStart(_ started: ShortID?, name: String) {
        if let started {
            removeLater(started, name: name)
        } else {
            registry.releasePrSession(name)
        }
    }

    // A session whose start ran but whose round ended first: stop and delete it by its short ID,
    // in a command task of PRSessions, because the task of the round can end first. The name goes
    // from the registry also when the delete fails: no round holds the session, and a later row
    // with the name can be a session of the user. A nil name stays: another session has it. A
    // start that expected the name while the delete ran keeps it: the start owns the name now.
    private func removeLater(_ shortID: ShortID, name: String?) {
        let (claude, registry) = (claude, registry)
        let claim = name.map { nameClaims[$0, default: 0] }
        command { [weak self] in
            _ = await claude.run(["stop", shortID.text], timeout: Self.startLimit)
            _ = await claude.run(["rm", shortID.text], timeout: Self.startLimit)
            guard let name else { return }
            if let self, self.nameClaims[name, default: 0] != claim { return }
            registry.releasePrSession(name)
        }
    }

    // The registry expects the name as a PR session, and the claim count of the name grows.
    private func expectName(_ name: String) {
        nameClaims[name, default: 0] += 1
        registry.expectPrSession(name)
    }

    // MARK: - The turns of a PR of the user

    // Begin a turn of the request session of the PR in the worktree. prepare makes the turn: the
    // worktree at the head, the files of the round and the sandbox. It changes the folders of the
    // session, so the turn runs it only when no person can use the session: the session is free
    // (idle with no box), stopped or gone, or the row is not the session of the PR. A session
    // that stays busy never sees a change of its folders. The first rule that holds:
    // 1. A new session (the old one goes, then prepare): no session, no row of the session, or a
    //    row that is not the session of the PR in the worktree (isSession).
    // 2. The wait (waitForTurn), busyWait at most from the start of the turn, else sessionBusy.
    //    A working row and a row with a box wait: a person can work in the session or answer
    //    its box. A parked row that a list still shows as active waits too.
    // 3. At the first free or stopped row, prepare. Then a new session (the old one goes) after
    //    maxRounds rounds, for a worktree that Bifrost made again, and for other flags (a resume
    //    can't change them). A row that is not free after the preparation (a person typed) gives
    //    sessionBusy, and nothing changes the folders again.
    // 4. A free row gets the prompt (type). A prompt box at the send goes back to the wait. No
    //    input or another refusal stops the session, and the wait then waits for the stopped row,
    //    rowWait at least: a list can show the stopped row late.
    // 5. A stopped row resumes (resume).
    // A turn that it prepared and that waited again (a prompt box at the send, a stop, a resume
    // that did not go) runs recheck before the next send, resume or new session: a person can
    // change the folders in that time, and recheck refuses the turn then. A new session before
    // the preparation also runs recheck first, before the old session goes.
    // Then the state keeps the session with the profile and one more round.
    package func beginTurn(
        _ pr: PRKey, worktree: URL, prepare: () async throws(RoundFailure) -> MineTurn,
        recheck: () async throws(RoundFailure) -> Void = {}
    ) async throws(RoundFailure) -> BegunTurn {
        guard let ref = ref(pr, .request) else {
            return try await startFresh(pr, prepare, recheck)
        }
        let id = ref.sessionID.text
        guard let row = registry.rows.first(where: { $0.sessionId == id }) else {
            return try await startFresh(pr, prepare, recheck, because: "no row")
        }
        guard await isSession(row, of: ref, in: worktree) else {
            return try await startFresh(pr, prepare, recheck, because: "another session")
        }
        var deadline = timeline.now() + Self.busyWait
        // The row at the last refused send or failed resume: the wait needs a change of it.
        var last: SessionRow?
        var stoppedIt = false
        // The turn and its profile, after the preparation.
        var prepared: (turn: MineTurn, profile: String)?
        while true {
            let waited = await waitForTurn(id, until: deadline, after: last)
            // A turn that is prepared already waited again: the folders can have changed.
            let again = prepared != nil
            switch waited {
            case .free(var free):
                guard !stoppedIt, Self.keepsIdentity(free, of: ref) else {
                    let reason = stoppedIt ? "no stop" : "another session"
                    if let prepared {
                        try await recheck()
                        return try await startFresh(prepared.turn, because: reason)
                    }
                    return try await startFresh(pr, prepare, recheck, because: reason)
                }
                if again { try await recheck() }
                if prepared == nil {
                    let made = try await prepareTurn(prepare, ref: ref)
                    if let reason = made.newSession {
                        // The new session removes the old one: only when nobody uses it.
                        try checkNobodyUses(id, after: "prepared the turn")
                        return try await startFresh(made.turn, because: reason)
                    }
                    prepared = (made.turn, made.profile)
                    // A person can type into the session during the preparation.
                    guard let now = registry.rows.first(where: { $0.sessionId == id }),
                        Self.isFree(now), Self.keepsIdentity(now, of: ref)
                    else {
                        Self.logger.notice(
                            """
                            The session of \(pr.text, privacy: .private) got busy while Bifrost \
                            prepared the turn.
                            """)
                        throw .sessionBusy
                    }
                    free = now
                }
                guard let turn = prepared?.turn else { throw .startFailed }
                switch try await type(turn, ref: ref, into: free) {
                case .begun(let begun): return begun
                case .prompt: last = free
                case .failed:
                    await stop(id: id)
                    stoppedIt = true
                    // With a hidden window, a list shows the stopped row only after up to 15 s.
                    // A deadline before that would give a new session, which loses the history.
                    deadline = max(deadline, timeline.now() + Self.rowWait)
                }
            case .stopped(let parked):
                guard Self.keepsIdentity(parked, of: ref) else {
                    if let prepared {
                        try await recheck()
                        return try await startFresh(prepared.turn, because: "another session")
                    }
                    return try await startFresh(pr, prepare, recheck, because: "another session")
                }
                if again { try await recheck() }
                if prepared == nil {
                    let made = try await prepareTurn(prepare, ref: ref)
                    if let reason = made.newSession {
                        // A person can resume the session during the preparation.
                        try checkNobodyUses(id, after: "prepared the turn")
                        return try await startFresh(made.turn, because: reason)
                    }
                    prepared = (made.turn, made.profile)
                }
                guard let ready = prepared else { throw .startFailed }
                if let begun = try await resume(ready.turn, ref: ref, profile: ready.profile) {
                    return begun
                }
                last = parked
            case .gone:
                if let prepared {
                    try await recheck()
                    return try await startFresh(prepared.turn, because: "no row")
                }
                return try await startFresh(pr, prepare, recheck, because: "no row")
            case .busy:
                if stoppedIt, let prepared {
                    try await recheck()
                    return try await startFresh(prepared.turn, because: "no stop")
                }
                throw .sessionBusy
            case .cancelled: throw .stopped
            }
        }
    }

    // The turn of the preparation and its profile, and the reason for a new session, or nil when
    // the turn can go to the session of the ref.
    private func prepareTurn(
        _ prepare: () async throws(RoundFailure) -> MineTurn, ref: SessionRef
    ) async throws(RoundFailure) -> (turn: MineTurn, profile: String, newSession: String?) {
        if Task.isCancelled { throw .stopped }
        let turn = try await prepare()
        if Task.isCancelled { throw .stopped }
        let profile = Self.profile(turn)
        let reason: String? =
            if ref.rounds >= Self.maxRounds {
                "it ran its rounds"
            } else if !turn.worktree.isKept {
                "a new worktree"
            } else if ref.profile != profile {
                "other flags"
            } else {
                nil
            }
        return (turn, profile, reason)
    }

    // The arguments of the start of a request session for the turn.
    private static func startArgs(_ turn: MineTurn, name: String) -> [String] {
        PRSessionArgs.request(
            name: name, model: turn.model, inputFolder: turn.inputFolder, skills: turn.skills,
            settings: turn.settings, prompt: turn.prompt)
    }

    // The profile of the start arguments of the turn.
    private static func profile(_ turn: MineTurn) -> String {
        PRSessionArgs.profile(startArgs(turn, name: ""))
    }

    // Rule 1 before the preparation: recheck, then the old session goes, then prepare, then a
    // new session. recheck runs first, so a turn that the safety net stops keeps the old session,
    // and the person can still use it.
    private func startFresh(
        _ pr: PRKey, _ prepare: () async throws(RoundFailure) -> MineTurn,
        _ recheck: () async throws(RoundFailure) -> Void, because reason: String? = nil
    ) async throws(RoundFailure) -> BegunTurn {
        if Task.isCancelled { throw .stopped }
        try await recheck()
        logNewSession(pr, reason)
        await remove(pr, .request)
        if Task.isCancelled { throw .stopped }
        return try await startNew(try await prepare())
    }

    // A new session for a turn that is prepared: the old session goes first.
    private func startFresh(
        _ turn: MineTurn, because reason: String
    ) async throws(RoundFailure) -> BegunTurn {
        if Task.isCancelled { throw .stopped }
        logNewSession(turn.pr, reason)
        await remove(turn.pr, .request)
        return try await startNew(turn)
    }

    // The reason of a new session that replaces one goes to the log.
    private func logNewSession(_ pr: PRKey, _ reason: String?) {
        guard let reason else { return }
        Self.logger.notice(
            """
            The session of \(pr.text, privacy: .private) starts again: \
            \(reason, privacy: .public).
            """)
    }

    // A new session of the turn, with the prompt. The state keeps it with the profile and one
    // round.
    private func startNew(_ turn: MineTurn) async throws(RoundFailure) -> BegunTurn {
        if Task.isCancelled { throw .stopped }
        let startedAt = timeline.now()
        let row = try await start(
            turn.pr, .request, args: Self.startArgs(turn, name: name(turn.pr, .request)),
            in: turn.worktree.url)
        if let id = SessionID(row.sessionId), let ref = ref(turn.pr, .request),
            ref.sessionID == id
        {
            var counted = ref
            counted.profile = Self.profile(turn)
            counted.rounds = 1
            await keep(turn.pr, counted, replacing: id)
        }
        return BegunTurn(row: row, startedAt: startedAt, how: .started)
    }

    // A live row that is idle with no box: no person uses the session now.
    private static func isFree(_ row: SessionRow) -> Bool {
        row.state == .idle && row.alert == .none
    }

    // Read the row of the session again before a step that removes the session: the row must be
    // free, stopped or gone. Else a person uses the session (for example a person typed, or
    // resumed it, while Bifrost prepared the turn), and the turn fails as busy. after names the
    // step for the log.
    private func checkNobodyUses(_ id: String, after step: String) throws(RoundFailure) {
        guard let row = registry.rows.first(where: { $0.sessionId == id }),
            !Self.isFree(row), !Self.isStopped(row)
        else { return }
        Self.logger.notice(
            """
            A PR session got busy while Bifrost \(step, privacy: .public), so Bifrost keeps it.
            """)
        throw .sessionBusy
    }

    // True when a person can use the session now: its row runs, and it works or shows a box.
    // Then Bifrost does not reset the worktree of the session.
    package func inUse(id: String) -> Bool {
        guard let row = registry.rows.first(where: { $0.sessionId == id }), row.state != .parked
        else { return false }
        return !Self.isFree(row)
    }

    // inUse for the request session of the PR.
    package func requestInUse(_ pr: PRKey) -> Bool {
        ref(pr, .request).map { inUse(id: $0.sessionID.text) } ?? false
    }

    // True when the row is the session of the ref in the worktree: the same session ID, an owned
    // session with the mark of a PR session, the same name, and the worktree as its folder (real
    // paths). Only then does a turn type into the session or resume it.
    private func isSession(_ row: SessionRow, of ref: SessionRef, in worktree: URL) async -> Bool {
        guard row.sessionId == ref.sessionID.text, Self.keepsIdentity(row, of: ref) else {
            return false
        }
        let (cwd, tree) = (row.cwd, worktree.plainPath)
        let real = await BlockingExecutor.run { (RealPath.of(cwd), RealPath.of(tree)) }
        guard let folder = real.0 else { return false }
        return folder == real.1
    }

    // The fields of the identity that can change while the session runs: the kind, the mark of
    // a PR session and the name (a rename). The session ID and the folder do not change.
    private static func keepsIdentity(_ row: SessionRow, of ref: SessionRef) -> Bool {
        row.kind == .owned && row.prSession && row.name == ref.name
    }

    // How the wait for the session of a turn ended.
    private enum TurnWait {
        // A live row that is idle with no box.
        case free(SessionRow)
        // A row that is stopped (isStopped).
        case stopped(SessionRow)
        case gone
        // The deadline came first.
        case busy
        case cancelled
    }

    // Wait until the row of the session can take the turn, or the deadline: a live row that is
    // idle with no box, or a stopped row. A row equal to after waits for a change. The wait
    // checks again at each change of the row (Observations) and at the deadline (one
    // TimerSlot). Nothing ticks.
    private func waitForTurn(
        _ id: String, until deadline: Duration, after last: SessionRow?
    ) async -> TurnWait {
        let (wakes, wake) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let registry = registry
        let changes = Observations { registry.rows.first { $0.sessionId == id } }
        let follow = Task {
            for await _ in changes { wake.yield() }
        }
        let timer = TimerSlot(clock: clock)
        defer {
            follow.cancel()
            timer.stop()
            wake.finish()
        }
        timer.start(after: max(deadline - timeline.now(), .zero)) { wake.yield() }
        wake.yield()
        for await _ in wakes {
            guard let row = registry.rows.first(where: { $0.sessionId == id }) else {
                return .gone
            }
            if row != last {
                if Self.isStopped(row) { return .stopped(row) }
                if Self.isFree(row) { return .free(row) }
            }
            if timeline.now() >= deadline { return .busy }
        }
        return .cancelled
    }

    // How the send of a prompt ended.
    private enum Typed {
        case begun(BegunTurn)
        // A prompt box refused the text: the turn waits again.
        case prompt
        // No input, or another refusal: the turn stops the session and resumes it.
        case failed
    }

    // Type the prompt into the live session. An Interrupt of the user (a cancelled send) stops
    // the turn: the session stays as the user left it.
    private func type(
        _ turn: MineTurn, ref: SessionRef, into row: SessionRow
    ) async throws(RoundFailure) -> Typed {
        guard let input = input() else {
            Self.logger.notice("Bifrost has no input for a PR session yet, so it resumes it.")
            return .failed
        }
        if Task.isCancelled { throw .stopped }
        let startedAt = timeline.now()
        do throws(InputRefusal) {
            try await input.send(row.sessionId, turn.prompt)
        } catch .prompt {
            return .prompt
        } catch .cancelled {
            throw .stopped
        } catch {
            Self.logger.error(
                """
                Bifrost couldn't type into the session of \(turn.pr.text, privacy: .private), \
                so it resumes it. \(error.message, privacy: .public)
                """)
            return .failed
        }
        var counted = ref
        counted.rounds += 1
        await keep(turn.pr, counted, replacing: ref.sessionID)
        return .begun(BegunTurn(row: row, startedAt: startedAt, how: .typed))
    }

    // A parked row with no process that no session list shows as active. Only such a row
    // resumes: a resume of a session that runs starts a copy.
    private static func isStopped(_ row: SessionRow) -> Bool {
        row.state == .parked && row.pid == nil && !row.listedActive
    }

    // Resume the stopped session in the worktree, with no start flag, through the steps of a
    // start: the registry expects the name, the short ID comes from the output, and the row gets
    // the mark. The row is read again just before the run, with no wait in between, and only a
    // stopped row resumes: else the result is nil. The note of claude must name the woken
    // session and each limit; else the woken session goes and the turn fails, because the
    // session can run without its sandbox. A new session ID makes the old session go by its
    // short ID, and the name stays. A trust error gives notTrusted. A stop during the run or the
    // row wait stops the woken session and keeps it. Another failure gives rule 1.
    private func resume(
        _ turn: MineTurn, ref: SessionRef, profile: String
    ) async throws(RoundFailure) -> BegunTurn? {
        guard let row = registry.rows.first(where: { $0.sessionId == ref.sessionID.text }),
            Self.isStopped(row)
        else { return nil }
        guard let id = row.continueId, let old = row.shortId ?? ref.shortID else {
            return try await startFresh(turn, because: "no resume ID")
        }
        if Task.isCancelled { throw .stopped }
        expectName(ref.name)
        let startedAt = timeline.now()
        let result = await claude.run(
            PRSessionArgs.resume(id, prompt: turn.prompt),
            directory: turn.worktree.url.path(percentEncoded: false), timeout: Self.startLimit,
            killSignal: .terminate, terminateGrace: Self.stopGrace, waitsForEnd: true)
        let woken = ClaudeOutput.shortId(result.stdout)
        if ClaudeOutput.isTrustError(result.stdout) || ClaudeOutput.isTrustError(result.stderr) {
            if let woken { stopWoken(woken, old: old) }
            throw .notTrusted
        }
        if Task.isCancelled {
            if let woken { stopWoken(woken, old: old) }
            throw .stopped
        }
        guard result.succeeded, let shortID = woken else {
            Self.logger.error(
                """
                The session of \(turn.pr.text, privacy: .private) did not resume. \
                \(ClaudeOutput.claudeFailure(result).message, privacy: .private)
                """)
            if let woken { await dropResumed(turn.pr, ref, woken: woken, old: old) }
            return try await startFresh(turn, because: "no resume")
        }
        let note = PRSessionArgs.resumeNote(result.stdout + "\n" + result.stderr, session: shortID)
        guard note == .kept else {
            Self.logger.error(
                """
                The resumed session of \(turn.pr.text, privacy: .private) can lack its limits, \
                so Bifrost removes it. \(note.message, privacy: .private)
                """)
            await dropResumed(turn.pr, ref, woken: shortID, old: old)
            throw .startFailed
        }
        let resumed: SessionRow
        do throws(RowWaitError) {
            resumed = try await registry.waitForRow(timeout: Self.rowWait) {
                $0.shortId == shortID && $0.kind == .owned && $0.state != .parked
                    && $0.pid != nil
            }
        } catch .timeout {
            await dropResumed(turn.pr, ref, woken: shortID, old: old)
            return try await startFresh(turn, because: "no resumed row")
        } catch {
            stopWoken(shortID, old: old)
            throw .stopped
        }
        registry.markPrSession(resumed.sessionId)
        registry.markStarted(resumed.sessionId)
        if shortID != old { removeLater(old, name: nil) }
        if let resumedID = SessionID(resumed.sessionId) {
            let counted = SessionRef(
                sessionID: resumedID, name: ref.name, shortID: shortID, profile: profile,
                rounds: ref.rounds + 1)
            await keep(turn.pr, counted, replacing: ref.sessionID)
        }
        return BegunTurn(row: resumed, startedAt: startedAt, how: .resumed)
    }

    // A resume that a trust error or a stop ended after claude woke a session: the session
    // stops, and the session of the PR stays. A new session goes.
    private func stopWoken(_ woken: ShortID, old: ShortID) {
        guard woken == old else {
            removeLater(woken, name: nil)
            return
        }
        let claude = claude
        command { _ = await claude.run(["stop", woken.text], timeout: Self.startLimit) }
    }

    // A resume that failed after claude woke a session: the woken session and the old one go by
    // their short IDs, and the state forgets the session. The rows can still show the woken
    // session as parked, so the remove does not go through the session commands.
    private func dropResumed(_ pr: PRKey, _ ref: SessionRef, woken: ShortID, old: ShortID) async {
        removeLater(woken, name: ref.name)
        if woken != old { removeLater(old, name: nil) }
        idleStopped.remove(ref.sessionID.text)
        await forget(pr, .request, ref)
    }

    // Keep the session of a turn in the state, in the place of the session with the ID old. A
    // remove that ran in between keeps its result.
    private func keep(_ pr: PRKey, _ ref: SessionRef, replacing old: SessionID) async {
        await store.update { state in
            guard var prState = state.prs[pr], prState.requestSession?.sessionID == old else {
                return
            }
            prState.requestSession = ref
            state.prs[pr] = prState
        }
    }

    // MARK: - The end of the turn

    // Wait until the turn of the session with this row ID ends (RoundEnd). After a restart, the
    // round knows only the ID of its session, and the rows can lack it. check gives the value of
    // the bytes of the result file when they pass the check of the round, else nil. The end
    // gives the value that the last check accepted: ended at the end of the turn, blocked at a
    // prompt. The time limit gives timeout, and a session that went or a cancel gives stopped.
    // begun: the row of the session when the turn began (BegunTurn.row), or nil after a restart.
    // An idle row with a later busy sample (lastBusyAt) worked in the turn, also when the wait
    // did not see it work. With no begun row, the first row of the wait gives the start.
    package func waitForTurnEnd<Accepted: Sendable>(
        id: String, startedAt: Duration, resultFile: URL, limit: Duration,
        begun: SessionRow? = nil, check: @escaping @Sendable (Data) -> Accepted?
    ) async throws(RoundFailure) -> TurnEnd<Accepted> {
        let (wakes, wake) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let registry = registry
        let changes = Observations {
            (registry.rows.first { $0.sessionId == id }, registry.appliedListTurn)
        }
        let follow = Task {
            for await _ in changes { wake.yield() }
        }
        let watch = FileWatch(
            file: resultFile.path(percentEncoded: false),
            folder: resultFile.deletingLastPathComponent().path(percentEncoded: false),
            label: "bifrost.result-watch", changed: { wake.yield() })
        watch.start()
        let timer = TimerSlot(clock: clock)
        defer {
            follow.cancel()
            watch.stop()
            timer.stop()
            wake.finish()
        }
        let rowsSince = timeline.now()
        var seenWorking = false
        var idleSince: Duration?
        // The latest busy sample that the wait knows of, and whether it knows the start of the
        // turn (the begun row, or the first row of the wait).
        var lastBusy = begun?.lastBusyAt
        var knowsStart = begun != nil
        // The count of the started session lists when the rule first ended the turn with no
        // result, in this idle time. Only a list that started later can confirm that end.
        var confirmAfter: Int?
        var result = ResultProbe(path: resultFile.path(percentEncoded: false), check: check)
        wake.yield()
        for await _ in wakes {
            let accepted = await result.accepted()
            let now = timeline.now()
            let row = registry.rows.first { $0.sessionId == id }
            let signal = row.map(SessionSignal.init)
            let idleBefore = idleSince
            switch signal {
            case .working?:
                seenWorking = true
                idleSince = nil
            case .prompt?:
                idleSince = nil
            case .idle?:
                // A busy sample after the last row that the wait saw: the session worked between
                // two wakes of the wait, and is idle again from now.
                if knowsStart, let busy = row?.lastBusyAt, busy > (lastBusy ?? Int.min) {
                    seenWorking = true
                    idleSince = now
                }
                if idleSince == nil { idleSince = now }
            case nil:
                break
            }
            if let row {
                knowsStart = true
                if let busy = row.lastBusyAt { lastBusy = max(lastBusy ?? busy, busy) }
            }
            // Work, or a new idle time, needs a new confirm.
            if idleSince != idleBefore { confirmAfter = nil }
            let check = RoundEnd.check(
                RoundEndInput(
                    row: signal, seenWorking: seenWorking, idleSince: idleSince,
                    startedAt: startedAt, rowsSince: rowsSince, now: now,
                    resultReady: accepted != nil, limit: limit))
            switch check {
            case .ended where accepted == nil:
                // The settle time (or the time with no start) ended. A list that started after
                // now must still show the row idle; until it comes, only the time limit can end
                // the turn.
                if let after = confirmAfter, registry.appliedListTurn > after {
                    return .ended(accepted: nil)
                }
                if confirmAfter == nil { confirmAfter = registry.startedLists }
                timer.start(after: max(startedAt + limit - now, .zero)) { wake.yield() }
            case .ended: return .ended(accepted: accepted)
            case .blocked: return .blocked(accepted: accepted)
            case .timeout: throw .timeout
            case .gone: throw .sessionEnded
            case .wait(let next?): timer.start(after: next - now) { wake.yield() }
            case .wait(nil): timer.stop()
            }
        }
        throw .stopped
    }


    // MARK: - Stop and remove

    // The row of the session of the PR and kind, while it is not parked.
    package func row(_ pr: PRKey, _ kind: PRSessionKind) -> SessionRow? {
        guard let ref = ref(pr, kind) else { return nil }
        return registry.rows.first { $0.sessionId == ref.sessionID.text && $0.state != .parked }
    }

    // Stop the session of the PR and kind when it runs. The session stays, so the user can open
    // its chat.
    package func stop(_ pr: PRKey, _ kind: PRSessionKind) async {
        guard let row = row(pr, kind) else { return }
        await stop(id: row.sessionId)
    }

    // Stop the session with this row ID when it runs and is not parked.
    func stop(id: String) async {
        guard registry.rows.contains(where: { $0.sessionId == id && $0.state != .parked }) else {
            return
        }
        do throws(ActionRefusal) {
            _ = try await actions.run(.stop(id))
        } catch {
            Self.logger.error(
                "Bifrost couldn't stop a PR session. \(error.message, privacy: .private)")
        }
    }

    // Stop and delete the session of the PR and kind, then the registry forgets its name and
    // the state forgets the session. A session with no row has nothing to delete.
    package func remove(_ pr: PRKey, _ kind: PRSessionKind) async {
        guard let ref = ref(pr, kind) else { return }
        if registry.rows.contains(where: { $0.sessionId == ref.sessionID.text }) {
            do throws(ActionRefusal) {
                _ = try await actions.run(.remove(ref.sessionID.text, confirmed: true, seen: nil))
            } catch {
                Self.logger.error(
                    """
                    Bifrost couldn't remove a PR session of \(pr.text, privacy: .private). \
                    \(error.message, privacy: .private)
                    """)
                return
            }
        }
        registry.releasePrSession(ref.name)
        idleStopped.remove(ref.sessionID.text)
        await forget(pr, kind, ref)
    }

    // The state forgets the session of the PR and kind, when it is still this session.
    private func forget(_ pr: PRKey, _ kind: PRSessionKind, _ ref: SessionRef) async {
        await store.update { state in
            guard var prState = state.prs[pr] else { return }
            if kind.isMine, prState.requestSession == ref {
                prState.requestSession = nil
            } else if !kind.isMine, prState.reviewSession == ref {
                prState.reviewSession = nil
            } else {
                return
            }
            state.prs[pr] = prState
        }
    }

    private func ref(_ pr: PRKey, _ kind: PRSessionKind) -> SessionRef? {
        let state = store.state.prs[pr]
        return kind == .review ? state?.reviewSession : state?.requestSession
    }
}

// The text input of the sessions (SessionInput): a turn types its prompt into a session that
// runs. A test gives a fake.
@MainActor
package protocol PromptInput: AnyObject {
    func send(_ session: String, _ text: String) async throws(InputRefusal)
}

extension SessionInput: PromptInput {}

// A turn of the request session of a PR of the user (PRSessions.beginTurn).
package struct MineTurn: Sendable {
    package var pr: PRKey
    package var model: ModelChoice
    // The real path of the input folder of the PR (--add-dir).
    package var inputFolder: URL
    // The bundled skills folder (--plugin-dir).
    package var skills: URL
    // The --settings value of the sandbox (RequestSandbox).
    package var settings: String
    package var prompt: String
    package var worktree: WorktreePlace

    package init(
        pr: PRKey, model: ModelChoice, inputFolder: URL, skills: URL, settings: String,
        prompt: String, worktree: WorktreePlace
    ) {
        self.pr = pr
        self.model = model
        self.inputFolder = inputFolder
        self.skills = skills
        self.settings = settings
        self.prompt = prompt
        self.worktree = worktree
    }
}

// How a turn began: a new session, a resume of the parked session, or the prompt typed into the
// live session.
package enum TurnStart: Sendable {
    case started, resumed, typed
}

// A turn that began: the row of its session, and the time on the clock of the sessions just
// before the start, the resume or the send.
package struct BegunTurn: Sendable {
    package var row: SessionRow
    package var startedAt: Duration
    package var how: TurnStart
}

extension SessionSignal {
    // A red box of a prompt, a working row, or any other row.
    init(_ row: SessionRow) {
        if row.alert.blocksPrompt {
            self = .prompt
        } else {
            self = row.state == .working ? .working : .idle
        }
    }
}

extension Duration {
    // The span in seconds.
    fileprivate var seconds: Double {
        let (whole, atto) = components
        return Double(whole) + Double(atto) / 1e18
    }
}

// How the turn of a session ended (PRSessions.waitForTurnEnd), with the value of the last result
// that passed the check of the round, or nil.
package enum TurnEnd<Accepted: Sendable>: Sendable {
    // The turn ended.
    case ended(accepted: Accepted?)
    // The session shows a prompt: a session of a round must never ask.
    case blocked(accepted: Accepted?)
}

// The result file of a turn, when it is there and passes the check of the round. A file whose
// stamp did not change since the last read gives the last value, so a change of the rows does
// not read the file again. The read and the check run off the main actor.
private struct ResultProbe<Accepted: Sendable> {
    let path: String
    let check: @Sendable (Data) -> Accepted?
    private var last: (stamp: FileStamp, accepted: Accepted?)?

    init(path: String, check: @escaping @Sendable (Data) -> Accepted?) {
        self.path = path
        self.check = check
    }

    mutating func accepted() async -> Accepted? {
        guard let stamp = FileStamp(path) else {
            last = nil
            return nil
        }
        if let last, last.stamp == stamp { return last.accepted }
        let (path, check) = (path, check)
        let accepted = await BlockingExecutor.run { () -> Accepted? in
            guard case .data(let data) = RepoFolders.readRegular(path, limit: ReviewResult.maxBytes)
            else { return nil }
            return check(data)
        }
        last = (stamp, accepted)
        return accepted
    }
}

// The identity and the change times of a regular file (lstat): a write or a new file at the path
// gives another stamp. nil when no regular file is at the path.
private struct FileStamp: Equatable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modified: Int
    let modifiedNanoseconds: Int
    let changed: Int
    let changedNanoseconds: Int

    init?(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        modified = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changed = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}
