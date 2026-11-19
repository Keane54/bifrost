// The PR sessions (docs/behaviour/reviews.md, "PR sessions"): the Claude Code background sessions
// of the rounds. A PR session is a normal Bifrost session: it shows in the Overview.
//
// - start runs "claude --bg" with the flags of its kind (PRSessionArgs) in the worktree of the PR.
//   The earlier session of the PR and kind goes first: each round starts a new session, because
//   the input file holds the history. The registry expects the name as a PR session before the
//   start and marks the row after it, so the row gets no yellow box and no Resume all. The state
//   keeps the session of the PR (PRState.reviewSession), so a restart finds it.
// - waitForTurnEnd follows RoundEnd on the real signals: it checks again at each change of the
//   rows (Observations), at each change of the result file (FileWatch: the file lands) and at the
//   next deadline of the rule (one TimerSlot). Nothing ticks. The result counts only when it
//   passes the check of the round; the read follows no link, and an unchanged file is not read
//   again. The wait gives the value that the check accepted, so a round uses the bytes that
//   ended the turn and never reads the file again.
// - A session stays after its round, so the user can open its chat. A session with no round that
//   is idle with no box (no open question) for idleStop gets one stop. The check runs at each
//   change of the rows and at the next deadline, never on a tick.
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

    private static let logger = Logger(bifrost: "reviews")

    private let store: ReviewsStore
    private let registry: RegistryService
    private let actions: SessionActions
    private let claude: ClaudeRunner
    private let clock: any Clock<Duration>
    private let timeline: Timeline
    private let now: () -> Date
    private let testPrefix: Bool
    private let idleTimer: TimerSlot
    private var idleFollow: Task<Void, Never>?
    // The sessions that got their idle stop. A row that works again leaves the set.
    private var idleStopped: Set<String> = []
    // The claude commands that run apart from a round (an idle stop, the clean-up of a start), by
    // number. Each one leaves the list at its end.
    private var commands: [Int: Task<Void, Never>] = [:]
    private var commandCount = 0

    // testPrefix: a test home, whose session names start with bifrost-test-.
    package init(
        store: ReviewsStore, registry: RegistryService, actions: SessionActions,
        claude: ClaudeRunner, clock: any Clock<Duration>, now: @escaping () -> Date,
        testPrefix: Bool
    ) {
        self.store = store
        self.registry = registry
        self.actions = actions
        self.claude = claude
        self.clock = clock
        timeline = Timeline(clock)
        self.now = now
        self.testPrefix = testPrefix
        idleTimer = TimerSlot(clock: clock)
    }

    isolated deinit {
        idleFollow?.cancel()
    }

    // The time on the clock of the sessions, for the start of a round.
    package var time: Duration { timeline.now() }

    // MARK: - The idle stop

    // Follow the rows for the idle stops until stop().
    package func start() {
        guard idleFollow == nil else { return }
        let registry = registry
        let changes = Observations { registry.rows }
        idleFollow = Task { [weak self] in
            for await rows in changes { self?.checkIdle(rows) }
        }
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
        registry.expectPrSession(name)
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
                switch kind {
                case .review: prState.reviewSession = ref
                case .request: prState.requestSession = ref
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
    // with the name can be a session of the user.
    private func removeLater(_ shortID: ShortID, name: String) {
        let (claude, registry) = (claude, registry)
        command {
            _ = await claude.run(["stop", shortID.text], timeout: Self.startLimit)
            _ = await claude.run(["rm", shortID.text], timeout: Self.startLimit)
            registry.releasePrSession(name)
        }
    }

    // MARK: - The end of the turn

    // Wait until the turn of the session with this row ID ends (RoundEnd). After a restart, the
    // round knows only the ID of its session, and the rows can lack it. check gives the value of
    // the bytes of the result file when they pass the check of the round, else nil. The end
    // gives the value that the last check accepted: ended at the end of the turn, blocked at a
    // prompt. The time limit gives timeout, and a session that went or a cancel gives stopped.
    package func waitForTurnEnd<Accepted: Sendable>(
        id: String, startedAt: Duration, resultFile: URL, limit: Duration,
        check: @escaping @Sendable (Data) -> Accepted?
    ) async throws(RoundFailure) -> TurnEnd<Accepted> {
        let (wakes, wake) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let registry = registry
        let changes = Observations { registry.rows.first { $0.sessionId == id } }
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
        var result = ResultProbe(path: resultFile.path(percentEncoded: false), check: check)
        wake.yield()
        for await _ in wakes {
            let accepted = await result.accepted()
            let now = timeline.now()
            let signal = registry.rows.first { $0.sessionId == id }.map(SessionSignal.init)
            switch signal {
            case .working?:
                seenWorking = true
                idleSince = nil
            case .prompt?:
                idleSince = nil
            case .idle?:
                if idleSince == nil { idleSince = now }
            case nil:
                break
            }
            let check = RoundEnd.check(
                RoundEndInput(
                    row: signal, seenWorking: seenWorking, idleSince: idleSince,
                    startedAt: startedAt, rowsSince: rowsSince, now: now,
                    resultReady: accepted != nil, limit: limit))
            switch check {
            case .ended: return .ended(accepted: accepted)
            case .blocked: return .blocked(accepted: accepted)
            case .timeout: throw .timeout
            case .gone: throw .stopped
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
        await store.update { state in
            guard var prState = state.prs[pr] else { return }
            switch kind {
            case .review where prState.reviewSession == ref: prState.reviewSession = nil
            case .request where prState.requestSession == ref: prState.requestSession = nil
            default: return
            }
            state.prs[pr] = prState
        }
    }

    private func ref(_ pr: PRKey, _ kind: PRSessionKind) -> SessionRef? {
        let state = store.state.prs[pr]
        return kind == .review ? state?.reviewSession : state?.requestSession
    }
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
