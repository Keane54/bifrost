// The session commands (docs/behaviour/actions.md, "The session commands"): New session, Stop,
// Resume, Resume all, Delete and Take control. The callers give a row ID, the checked New session
// values, a confirmation and the counts of the Delete dialog only. The commands find the row,
// check it again and make the claude arguments. They never take a PID or a path from a caller.
import BifrostFoundation
import Foundation
import Observation

// Each command is a job: one task, which run starts and awaits. A cancel of the caller cancels
// the job. A job holds its locks from the check to its end:
// - One action at a time runs for each session. The lock check and the lock are in one step on
//   the main actor, so two calls cannot both pass.
// - One New session start runs at a time, so a double click starts one session.
// - One Resume all runs at a time, and it holds the lock of each session that it resumes.
//
// Each claude command gets the limit runTimeout. Exit code 0 is not proof of a start, so a start
// waits up to startTimeout for its row in the registry. The commands read the rows of the
// registry, their one place, so the row that the wait gives is already in the rows. Claude Code
// lists a new job as soon as claude --bg ends, so New session reads the active list at once
// (RegistryService.checkActive) and does not wait for the next poll (see create). stop() at the
// quit of the app cancels each job and refuses each later command. A job that stop() or its
// caller cancelled, and a wait that the registry ends at its stop, end the job with cancelled at
// its next step. The park wait of Stop is the exception: claude stop already worked, so a stop of
// the registry ends Stop as done. At the quit of the app, the registry stops in the same step as
// stop(), so that wait ends at once and frees the lock (see stop(_:)). After the end of its job,
// no step runs. A claude rm of Delete is the exception to the limit and to the kill signal, and
// its run can outlive its job: see rm.
//
// The locks are observable, so the UI follows isRunning and resumeAllRunning. A claude rm that
// runs also holds the lock of its session, also after the end of its job.
//
// Resume, Resume all and Delete decide on the session list, and Live state is only a hint
// (isStopped). A row that only an --all read lists (ActiveListing.unconfirmed) can be a session
// that starts. Before such a command takes its locks, it asks the registry for one new active
// list (checkSessions), and then decides on the real state. isCheckingSessions is observable, so
// the UI shows the check. A row that is still unconfirmed after the check, because the check gave
// no list, gets the refusal unconfirmed with the reason. No other command and no start of the app
// runs this check. The read of New session after claude --bg is not this check: it shows no
// notice and decides nothing before the start.
@MainActor
@Observable
package final class SessionActions {
    // The time that a start waits for the row of its session.
    package static let startTimeout = Duration.seconds(30)
    // The time limit of each claude command.
    package static let runTimeout = Duration.seconds(60)
    // Take control waits this long for the end of the terminal process.
    package static let endWait = Duration.seconds(5)
    // Delete waits this long for the end of the session process after claude stop, because
    // claude rm refuses a worktree while the process runs.
    package static let deleteEndWait = Duration.seconds(15)
    // The time limit of claude rm. A discard can delete a large worktree. At the limit claude rm
    // gets SIGTERM and never SIGKILL, because a SIGKILL can leave the worktree half deleted.
    package static let rmTimeout = Duration.seconds(600)
    // After the SIGTERM of the limit, Delete waits this long more for the end of claude rm.
    package static let rmGrace = Duration.seconds(30)
    // After Take control, the resumed session must still run this long after its row showed,
    // because a resume can fail just after the start of its process.
    package static let resumeSettle = Duration.seconds(3)
    // After claude stop, Stop waits this long at most for the park of its row.
    package static let parkWait = Duration.seconds(20)

    @ObservationIgnored private let claude: () -> ClaudeRunner?
    @ObservationIgnored private let registry: RegistryService
    @ObservationIgnored private let probe: ProcessProbe
    // Delete and Take control use these.
    @ObservationIgnored private let signals: SystemSignals
    @ObservationIgnored private let worktrees: WorktreeChecker
    @ObservationIgnored private let projects: URL
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let log: any SessionsLog

    // The row IDs of the sessions that have a job.
    private var locked: Set<String> = []
    private var creating = false
    private var resumingAll = false
    // The task of each job that runs, by its number.
    @ObservationIgnored private var jobs: [Int: Task<Result<ActionDone, ActionRefusal>, Never>] =
        [:]
    @ObservationIgnored private var lastJob = 0
    // Each claude rm that runs, by the row ID of its session. The value is true after its job
    // stopped to wait for its result. A run can outlive its job (see rm), and it holds the lock of
    // the session until the program ends.
    private var rmRuns: [String: Bool] = [:]
    // True after stop(). No job runs after it.
    @ObservationIgnored private var stopped = false
    // The checks of the active list that run now (checkSessions).
    private var checks = 0

    // claude: the claude runner, or nil when Bifrost cannot find claude. projects: the projects
    // folder of Claude Code, <home>/.claude/projects, which the commands only read.
    package init(
        claude: @escaping () -> ClaudeRunner?, registry: RegistryService, probe: ProcessProbe,
        signals: SystemSignals, worktrees: WorktreeChecker, projects: URL,
        clock: any Clock<Duration>, log: any SessionsLog
    ) {
        self.claude = claude
        self.registry = registry
        self.probe = probe
        self.signals = signals
        self.worktrees = worktrees
        self.projects = projects
        self.clock = clock
        self.log = log
    }

    // True while a job, or a claude rm that runs, holds the lock of the session.
    package func isRunning(_ sessionId: String) -> Bool {
        locked.contains(sessionId) || rmRuns[sessionId] != nil
    }

    // True while a Resume all runs.
    package var resumeAllRunning: Bool { resumingAll }

    // True while a New session start runs.
    package var isCreating: Bool { creating }

    // True while a command checks the active list before it decides (checkSessions).
    package var isCheckingSessions: Bool { checks > 0 }

    // Stop at the quit of the app: cancel each job and refuse each later command with cancelled.
    // A job ends at its next step and frees its locks. A claude rm that runs gets no signal (see
    // rm).
    package func stop() {
        stopped = true
        for task in jobs.values { task.cancel() }
    }

    // The folder check of the New session dialog. A relative path is missing with no read.
    package func dirInfo(_ path: String) async -> DirInfo {
        await probe.dirInfo(path)
    }

    // The worktree check of the Delete dialog. A stopped session reports its start folder as its
    // folder, so the check uses the worktree that Bifrost stored while the session ran. The check
    // of a worktree also reads its HEAD commit, so a discard can only remove the commits that the
    // dialog showed. A folder that is not a worktree gets the check with no worktree and runs no
    // git. nil for an unknown row, an external row, a row with no folder and a failed check.
    package func deleteCheck(_ sessionId: String) async -> WorktreeCheck? {
        guard let row = registry.rows.first(where: { $0.sessionId == sessionId }),
            row.kind != .external
        else { return nil }
        let folder = Self.worktree(of: row) ?? row.cwd
        if folder.isEmpty { return nil }
        if WorktreeRoot(cwd: folder) == nil { return await worktrees.check(folder) }
        return await worktrees.checkWithHead(folder)
    }

    // Run the command, and give its result or the reason why it did not run to its end.
    package func run(_ command: SessionCommand) async throws(ActionRefusal) -> ActionDone {
        try await run(command, steps: { _ in })
    }

    // Run New session, and give the row ID of the new session. steps gets each step of the
    // start before its end (StartStep), in their order. A refusal before claude --bg starts gives
    // no step.
    package func newSession(
        _ spec: NewSessionSpec, steps: @escaping @MainActor (StartStep) -> Void
    ) async throws(ActionRefusal) -> String {
        guard case .created(let sessionId) = try await run(.create(spec), steps: steps) else {
            throw .startGaveNoId
        }
        return sessionId
    }

    // Only New session gives steps.
    private func run(
        _ command: SessionCommand, steps: @escaping @MainActor (StartStep) -> Void
    ) async throws(ActionRefusal) -> ActionDone {
        let job: Job
        do throws(ActionRefusal) {
            try await checkSessions(for: command)
            job = try start(command, steps: steps)
        } catch {
            record(command, .failure(error))
            throw error
        }
        let result = await runJob(job)
        record(command, result)
        return try result.get()
    }

    // MARK: - The check of the session list

    // Before a command that needs a row that only an --all read lists, poll the active list once
    // (RegistryService.checkActive): its turn in the lock of the lists comes after that read.
    // The command then decides on the rows after the poll. A stop of the registry and a cancel
    // end the command. A failed list keeps the row unconfirmed (see checked(_:)).
    private func checkSessions(for command: SessionCommand) async throws(ActionRefusal) {
        guard !stopped, needsCheck(command) else { return }
        checks += 1
        defer { checks -= 1 }
        let check = await registry.checkActive()
        try checkCancel()
        if check == .ended { throw .cancelled }
    }

    // True when Resume or a confirmed Delete is for an unconfirmed row with no lock, or when
    // Resume all can start and a row that it resumes is unconfirmed.
    private func needsCheck(_ command: SessionCommand) -> Bool {
        let rows = registry.rows
        switch command {
        case .resume(let sessionId), .remove(let sessionId, confirmed: true, _):
            return !isRunning(sessionId)
                && rows.contains { $0.sessionId == sessionId && $0.listing == .unconfirmed }
        case .resumeAll:
            return !resumingAll && rows.contains { $0.resumable && $0.listing == .unconfirmed }
        case .create, .stop, .remove, .takeControl:
            return false
        }
    }

    // A row that only an --all read lists after the check: the check gave no list, so Bifrost
    // does not know if the session runs. The reason is the error of the last active poll.
    private func checked(_ row: SessionRow) throws(ActionRefusal) {
        if row.listing == .unconfirmed { throw .unconfirmed(registry.error) }
    }

    // MARK: - The jobs

    // A job with the values that its start took. A create holds the receiver of its steps. The
    // resume of Resume all holds the rows that it locked, and the failures of the rows that
    // another job holds.
    private enum Job {
        case create(NewSessionSpec, steps: @MainActor (StartStep) -> Void)
        case stop(String)
        case resume(String)
        case remove(String, seen: SeenCounts?)
        case takeControl(String)
        case resumeAll(held: [SessionRow], failed: [ResumeFailure])
        // Resume all with no parked row to resume. It takes no lock.
        case nothingToResume
    }

    // Check the locks and take them, in one step with no wait. After stop(), no job starts.
    private func start(
        _ command: SessionCommand, steps: @escaping @MainActor (StartStep) -> Void
    ) throws(ActionRefusal) -> Job {
        if stopped { throw .cancelled }
        switch command {
        case .create(let spec):
            if creating { throw .creating }
            creating = true
            return .create(spec, steps: steps)
        case .stop(let sessionId):
            try lock(sessionId)
            return .stop(sessionId)
        case .resume(let sessionId):
            try lock(sessionId)
            return .resume(sessionId)
        case .remove(let sessionId, let confirmed, let seen):
            guard confirmed else { throw .deleteNotConfirmed }
            try lock(sessionId)
            return .remove(sessionId, seen: seen)
        case .takeControl(let sessionId, let confirmed):
            guard confirmed else { throw .takeControlNotConfirmed }
            try lock(sessionId)
            return .takeControl(sessionId)
        case .resumeAll:
            if resumingAll { throw .resumeAllRuns }
            // A resumable row that the session list lists, for example a session that starts
            // with no pid yet, fails as not parked. A row that is still unconfirmed after the
            // check fails with the reason. So the result never hides a row. Neither takes a lock.
            let candidates = registry.rows.filter {
                $0.resumable && (Self.isStopped($0) || $0.listedActive)
            }
            if candidates.isEmpty { return .nothingToResume }
            resumingAll = true
            var held: [SessionRow] = []
            var failed: [ResumeFailure] = []
            for row in candidates {
                if row.listing == .unconfirmed {
                    failed.append(ResumeFailure(row, .unconfirmed(registry.error)))
                } else if row.listing == .listed {
                    failed.append(ResumeFailure(row, .notParked))
                } else if takeLock(row.sessionId) {
                    held.append(row)
                } else {
                    failed.append(ResumeFailure(row, .locked))
                }
            }
            return .resumeAll(held: held, failed: failed)
        }
    }

    private func lock(_ sessionId: String) throws(ActionRefusal) {
        guard takeLock(sessionId) else { throw .locked }
    }

    // Take the lock of the session, when no job and no claude rm holds it.
    private func takeLock(_ sessionId: String) -> Bool {
        rmRuns[sessionId] == nil && locked.insert(sessionId).inserted
    }

    // Run the job in its own task, and give its locks back at its end. A cancel of the caller
    // and stop() cancel the task.
    private func runJob(_ job: Job) async -> Result<ActionDone, ActionRefusal> {
        lastJob += 1
        let number = lastJob
        let task = Task { () async -> Result<ActionDone, ActionRefusal> in
            defer {
                release(job)
                jobs[number] = nil
            }
            do throws(ActionRefusal) {
                return .success(try await perform(job))
            } catch {
                return .failure(error)
            }
        }
        jobs[number] = task
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func release(_ job: Job) {
        switch job {
        case .create: creating = false
        case .stop(let sessionId), .resume(let sessionId), .remove(let sessionId, _),
            .takeControl(let sessionId):
            locked.remove(sessionId)
        case .resumeAll(let held, _):
            for row in held { locked.remove(row.sessionId) }
            resumingAll = false
        case .nothingToResume: break
        }
    }

    private func perform(_ job: Job) async throws(ActionRefusal) -> ActionDone {
        switch job {
        case .create(let spec, let steps):
            return .created(sessionId: try await create(spec, steps: steps))
        case .stop(let sessionId):
            try await stop(sessionId)
            return .done
        case .resume(let sessionId):
            try await resume(sessionId)
            return .done
        case .remove(let sessionId, let seen):
            try await remove(sessionId, seen: seen)
            return .done
        case .takeControl(let sessionId):
            try await takeControl(sessionId)
            return .tookControl(sessionId: sessionId)
        case .resumeAll(let held, let failed):
            return .resumedAll(try await resumeAll(held, failed: failed))
        case .nothingToResume: return .resumedAll(ResumeAllResult())
        }
    }

    // MARK: - The commands

    // Check the folder of the New session values, run "claude --bg" and wait for the row of the
    // new session. The result is its row ID. Claude Code lists the new job as soon as claude --bg
    // ends, first with no PID. So the job reads the active list at once, and the row shows in the
    // rows then, not at the next poll. A failed read keeps the rows, and the wait goes on with the
    // polls. A stop of the registry ends the wait. The PID comes with a later poll.
    // steps gets accepted just before claude --bg starts, and launched with its short ID.
    private func create(
        _ spec: NewSessionSpec, steps: @MainActor (StartStep) -> Void
    ) async throws(ActionRefusal) -> String {
        let dir = await probe.dirInfo(spec.cwd)
        try checkCancel()
        guard dir.kind == .dir else { throw .dirMissing }
        if spec.worktree && !dir.git { throw .noGit }
        let claude = try runner()
        steps(.accepted)
        let result = try await startRun(claude, SessionCommandArgs.newSession(spec), in: spec.cwd)
        guard let shortId = ClaudeOutput.shortId(result.stdout) else { throw .startGaveNoId }
        steps(.launched(shortId))
        _ = await registry.checkActive()
        try checkCancel()
        let row = try await waitForRow(timeout: .notStarted(shortId: shortId)) {
            Self.isStart(of: shortId, $0)
        }
        registry.markStarted(row.sessionId)
        return row.sessionId
    }

    // Run "claude stop" with the short ID of an owned session that runs. A /clear does not change
    // the short ID. Then wait until the row reads parked or leaves the rows, for parkWait at most.
    // Until the next sample of the list, the row still looks as if it runs, and a Delete would run
    // a second claude stop. So the job keeps the lock of the session while it waits, and Delete,
    // Stop, Resume and Take control are off (row X33). The stop worked, so the end of the wait at
    // its limit or at the stop of the registry ends Stop as done. At the quit of the app, the
    // registry stops in the same step as stop(), before the cancel reaches the wait, so the wait
    // ends at once as done and the job frees the lock. Only a cancel with no stop of the registry
    // ends Stop as cancelled.
    private func stop(_ sessionId: String) async throws(ActionRefusal) {
        let row = try row(sessionId)
        guard row.kind == .owned, row.state != .parked else { throw .onlyRunning }
        guard let shortId = row.shortId else { throw .badSessionId }
        try await claudeStop(try runner(), shortId)
        registry.markStopped(row.sessionId)
        let id = row.sessionId
        // The match gets all the rows, so a change that leaves no row also ends the wait.
        do throws(RowWaitError) {
            try await registry.waitForRows(timeout: Self.parkWait) { rows in
                !rows.contains { $0.sessionId == id && $0.state != .parked }
            }
        } catch .cancelled {
            throw .cancelled
        } catch {
            // The limit, or the stop of the registry: the stop worked.
        }
    }

    // Resume a parked session and wait until its row runs again.
    private func resume(_ sessionId: String) async throws(ActionRefusal) {
        let row = try row(sessionId)
        try checked(row)
        guard Self.isStopped(row) else { throw .notParked }
        let claude = try runner()
        try await startResume(claude, row)
        try await waitResumed(row.sessionId)
        registry.markStarted(row.sessionId)
    }

    // Resume the held rows one after the other, each with its row of now: an earlier resume can
    // take some seconds. Then wait for all rows at the same time. Each session is marked as
    // started when its row shows. The failures keep the order of the rows. A cancel, and a wait
    // that the registry ended at its stop, end the whole job with cancelled.
    private func resumeAll(
        _ held: [SessionRow], failed: [ResumeFailure]
    ) async throws(ActionRefusal) -> ResumeAllResult {
        var result = ResumeAllResult(failed: failed)
        let claude = try runner()
        var started: [SessionRow] = []
        for row in held {
            try checkCancel()
            do throws(ActionRefusal) {
                try await startResume(claude, try self.row(row.sessionId))
                started.append(row)
            } catch .cancelled {
                throw .cancelled
            } catch {
                result.failed.append(ResumeFailure(row, error))
            }
        }
        let ids = started.map(\.sessionId)
        let waits = await withTaskGroup(of: (Int, ActionRefusal?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { (index, await self.markWhenResumed(id)) }
            }
            var errors = [ActionRefusal?](repeating: nil, count: ids.count)
            for await (index, error) in group { errors[index] = error }
            return errors
        }
        try checkCancel()
        if waits.contains(.cancelled) { throw .cancelled }
        for (row, error) in zip(started, waits) {
            if let error {
                result.failed.append(ResumeFailure(row, error))
            } else {
                result.resumed += 1
            }
        }
        return result
    }

    // MARK: - Delete

    // Delete: claude stop for a session that runs, then claude rm, then the row leaves the list.
    // A parked row with no short ID only leaves the list. A row that runs with no short ID is
    // refused: Bifrost cannot stop it, and the next sample shows it again. removeSession gives the
    // rules for a worktree that claude rm keeps.
    // claude rm can remove a clean worktree of a stopped session while another session uses it.
    // So Delete never removes a folder that another row uses. Such a row with a short ID stops if
    // it runs, and then its claude rm waits as a deferred delete. No claude rm runs now, so no
    // check runs before the stop, and the counts of the dialog are not used. The Delete of the
    // last session in the worktree runs the deferred deletes there.
    // The check of the dialog must be of the worktree of the row now. Else the dialog did not show
    // the work that a discard removes.
    // Another session can start in the worktree during the stop. So the Delete looks for a sharer
    // again just before claude rm, and defers the claude rm when it finds one.
    private func remove(_ sessionId: String, seen: SeenCounts?) async throws(ActionRefusal) {
        let row = try row(sessionId)
        try checked(row)
        if row.kind == .external && !Self.isStopped(row) { throw .deleteExternal }
        if row.shortId == nil && !Self.isStopped(row) { throw .noShortId }
        let worktree = Self.worktree(of: row)
        if let shortId = row.shortId, let worktree,
            folderSharer(of: row, in: registry.rows) != nil
        {
            if !Self.isStopped(row) { try await stopForDelete(try runner(), row, shortId) }
            deferDelete(row, shortId, worktree)
            return
        }
        if let seen, seen.worktree != worktree { throw .worktreeChanged }
        if let shortId = row.shortId {
            let claude = try runner()
            if !Self.isStopped(row) {
                try await checkTrackedChanges(row)
                try await stopForDelete(claude, row, shortId)
            }
            if let worktree, folderSharer(of: row, in: registry.rows) != nil {
                deferDelete(row, shortId, worktree)
                return
            }
            let target = RmTarget(sessionId: row.sessionId, worktree: worktree)
            try await removeSession(claude, target, shortId, seen: seen)
            if let worktree {
                try await removeDeferred(claude, after: row, in: worktree, seen: seen)
            }
        }
        registry.forget(row.sessionId)
    }

    // The row leaves the list, and its claude rm waits for the Delete of the last session in the
    // worktree.
    private func deferDelete(_ row: SessionRow, _ shortId: ShortID, _ worktree: String) {
        registry.defer(
            DeferredDelete(sessionId: row.sessionId, shortId: shortId, worktree: worktree))
    }

    // What claude rm needs of a session: its row ID, and its worktree root when Bifrost knows it.
    // A deferred delete gives these values with no row.
    private struct RmTarget {
        var sessionId: String
        var worktree: String?
    }

    // Run claude stop, then wait up to deleteEndWait for the end of the session process: claude rm
    // refuses a worktree while its process runs. A row with no PID gets no wait.
    private func stopForDelete(
        _ claude: ClaudeRunner, _ row: SessionRow, _ shortId: ShortID
    ) async throws(ActionRefusal) {
        try await claudeStop(claude, shortId)
        guard let pid = row.pid else { return }
        guard try await hasEnded(pid, within: Self.deleteEndWait) else { throw .notStopped }
    }

    // claude rm refuses a worktree with changes that git tracks and that are not committed. So the
    // Delete of a running worktree session counts these changes first, and does not stop the
    // session for no result. Untracked files alone do not block, and a failed count does not
    // block: claude rm then decides, and it never deletes changes that are not committed.
    private func checkTrackedChanges(_ row: SessionRow) async throws(ActionRefusal) {
        guard let worktree = Self.worktree(of: row) else { return }
        let tracked = await worktrees.trackedChanges(worktree)
        try checkCancel()
        if let tracked, tracked > 0 { throw .uncommitted }
    }

    // Run claude rm. claude rm keeps a worktree that has commits on no remote, and prints the value
    // that discards them. Bifrost discards only when all of these apply:
    // - The Delete dialog showed a check of the worktree (seen).
    // - The kept line names the short ID of the session and the worktree that Bifrost knows.
    // - A new check after the stop finds no more commits and no more changed files than seen.
    // - The HEAD commit of the worktree is still the HEAD of seen, so the commits are the commits
    //   that the dialog showed, and it is the commit at the start of the discard value.
    // Only ClaudeOutput.kept gives the discard value. claude rm also keeps a worktree with changes
    // that are not committed, and Claude Code has no command that deletes such a worktree. So
    // Bifrost never tries a discard for it, also when the output has a discard value.
    private func removeSession(
        _ claude: ClaudeRunner, _ target: RmTarget, _ shortId: ShortID, seen: SeenCounts?
    ) async throws(ActionRefusal) {
        let result = try await rm(claude, ["rm", shortId.text], for: target.sessionId)
        if result.succeeded { return }
        if let changes = ClaudeOutput.keptChanges(result.stdout) {
            rememberKept(target, shortId, named: changes.shortId, at: changes.worktree)
            throw .uncommitted
        }
        guard let kept = ClaudeOutput.kept(result.stdout) else {
            throw ClaudeOutput.claudeFailure(result)
        }
        guard let worktree = target.worktree else {
            rememberKept(target, shortId, named: kept.shortId, at: kept.worktree)
            throw .kept
        }
        guard let seen else { throw .kept }
        guard kept.shortId == shortId,
            Self.withoutSlash(kept.worktree) == Self.withoutSlash(worktree)
        else { throw .worktreeChanged }
        let now = await worktrees.checkWithHead(worktree)
        try checkCancel()
        guard let now, now.worktree != nil, now.unmergedCommits <= seen.unmergedCommits,
            now.changedFiles <= seen.changedFiles, let head = now.head, head == seen.head,
            head == String(kept.discard.prefix { $0 != "@" })
        else { throw .worktreeChanged }
        let discard = try await rm(
            claude, ["rm", shortId.text, "--discard-unpushed", kept.discard], for: target.sessionId)
        if discard.succeeded { return }
        // A second refusal means that the worktree changed after the first claude rm.
        if ClaudeOutput.keptChanges(discard.stdout) != nil { throw .uncommitted }
        if ClaudeOutput.kept(discard.stdout) != nil { throw .worktreeChanged }
        throw ClaudeOutput.claudeFailure(discard)
    }

    // Store the worktree that a kept line names, for a session whose worktree Bifrost does not
    // know. The next Delete can then check this worktree and offer Open worktree. The kept line
    // must name the short ID of the session and a worktree root.
    private func rememberKept(
        _ target: RmTarget, _ shortId: ShortID, named keptId: ShortID, at path: String
    ) {
        guard target.worktree == nil else { return }
        let keptPath = Self.withoutSlash(path)
        guard keptId == shortId, WorktreeRoot.isRoot(keptPath) else { return }
        _ = registry.rememberWorktree(target.sessionId, keptPath)
    }

    // Run claude rm for each deferred delete of the worktree, in the order of the defers. The
    // Delete of the last session there runs this after its own claude rm. Each run gets the check
    // of the last Delete dialog, so the discard rules of removeSession apply. A good run drops its
    // entry. A failed run undefers its entry and each later entry, so these sessions show again as
    // parked rows. Then the last session leaves the list, because its claude rm worked, and the
    // Delete fails with the reason of the failed run. A cancel changes no entry.
    // A claude rm can take minutes. So before each run, Bifrost skips an entry that the registry
    // no longer has, for example after the orphan rule, and an entry while another row uses the
    // worktree again. That entry stays for the Delete of that row. Each run holds the lock of its
    // entry, and an entry whose lock another job or claude rm holds is skipped.
    private func removeDeferred(
        _ claude: ClaudeRunner, after row: SessionRow, in worktree: String, seen: SeenCounts?
    ) async throws(ActionRefusal) {
        let entries = registry.deferredIn(worktree)
        for (index, entry) in entries.enumerated() {
            let kept = registry.deferredIn(worktree).contains { $0.sessionId == entry.sessionId }
            let used = registry.rows.contains {
                $0.sessionId != row.sessionId && Self.worktree(of: $0) == entry.worktree
            }
            guard kept, !used, takeLock(entry.sessionId) else { continue }
            defer { locked.remove(entry.sessionId) }
            let target = RmTarget(
                sessionId: entry.sessionId, worktree: WorktreeRoot(cwd: entry.worktree)?.worktree)
            do throws(ActionRefusal) {
                try await removeSession(claude, target, entry.shortId, seen: seen)
            } catch .cancelled {
                throw .cancelled
            } catch {
                for later in entries[index...] { registry.undefer(later.sessionId) }
                registry.forget(row.sessionId)
                throw error
            }
            registry.dropDeferred(entry.sessionId)
        }
    }

    // Run claude rm for the session with the limit rmTimeout. The runner sends SIGTERM and no
    // SIGKILL at the limit, and also when the output goes over the output limit of the runner
    // (1 MiB), because a SIGKILL can leave the worktree half deleted. SIGTERM is the only signal
    // that Bifrost sends to a claude rm. An overflow and then the limit send it two times. With
    // the first SIGTERM, the runner stops its reads of the output and closes its ends of the
    // pipes, so a claude rm that writes after that can get SIGPIPE from the system. After
    // the limit, the job waits rmGrace more for the end of the program, then fails with
    // rmTooSlow. A cancel of the job and stop() end the job at once with cancelled, and send
    // nothing to the program.
    // The run is the one exception to the rule that each task ends at the stop of its owner: no
    // one cancels its task, and it waits until the program ends, also after the end of its job and
    // at the quit of the app. While it runs, it holds the lock of the session. The lock is only in
    // memory, so a new start of the app does not know a run of the last start. A run that ends
    // after its job gives a notice in the log, and the next poll shows its result.
    // A run that timed out gives rmTooSlow, because its output after the SIGTERM is not complete.
    // Only the output of a run that ended by itself can give a kept line.
    private func rm(
        _ claude: ClaudeRunner, _ args: [String], for sessionId: String
    ) async throws(ActionRefusal) -> ExecResult {
        try checkCancel()
        let run = Task {
            let result = await claude.run(
                args, timeout: Self.rmTimeout, killSignal: .terminate, terminateGrace: nil)
            rmEnded(sessionId, result.end)
            return result
        }
        rmRuns[sessionId] = false
        // A cancel of the job ends the wait at once, and the run goes on (firstResult).
        let result = await firstResult(of: run, within: Self.rmTimeout + Self.rmGrace, on: clock)
        // A run that ended in the meantime is not in rmRuns, and stays out.
        if result == nil, rmRuns[sessionId] != nil { rmRuns[sessionId] = true }
        try checkCancel()
        guard let result, result.end != .timedOut else { throw .rmTooSlow }
        guard case .exited = result.end else { throw ClaudeOutput.claudeFailure(result) }
        return result
    }

    // The end of a claude rm. The lock of the session is free again.
    private func rmEnded(_ sessionId: String, _ end: ExecEnd) {
        guard let outlived = rmRuns.removeValue(forKey: sessionId) else { return }
        if outlived { log.record(.claudeRmEndedAfterItsJob(session: sessionId, end)) }
    }

    // MARK: - Take control

    // Take control: end the terminal process of an external session, and resume the session in
    // Bifrost. SIGTERM goes only to the claude process of this row, after each check. When the
    // process does not end in endWait, Bifrost starts no copy. Claude Code cannot resume a session
    // with no user message, so such a session gets no signal. Take control resumes the current ID,
    // the conversation after any /clear. The new job of that ID keeps the row ID, so the waits use
    // the row ID.
    private func takeControl(_ sessionId: String) async throws(ActionRefusal) {
        let row = try row(sessionId)
        try Self.checkTakeControl(row)
        let currentId = row.currentIdOrRow
        guard let current = SessionID(currentId) else { throw .badSessionId }
        guard let pid = row.pid else { throw .noPid }
        // PID 0 and -1 signal a group of processes, and PID 1 is launchd.
        guard pid > 1 else { throw .badPid }
        try await checkProjectFolder(row.cwd)
        let hasMessages = await TranscriptReader.hasMessages(
            projects: projects, sessionId: currentId)
        try checkCancel()
        guard hasMessages else { throw .noMessages }
        // Find claude before the signal: without claude, Bifrost cannot resume the session.
        let claude = try runner()
        let found = await probe.claudeProcess(pid)
        try checkCancel()
        guard let process = found else { throw .notClaudeProcess(pid: pid) }
        // The rows can change during the reads above. The process must still be the process of
        // this row and of no other row, and the rules must still apply. A /clear in that time
        // changes the current ID, and the resume would then take the old conversation.
        let rows = registry.rows
        guard let now = rows.first(where: { $0.sessionId == row.sessionId }),
            now.pid == process.pid, now.currentIdOrRow == currentId,
            !rows.contains(where: { $0.pid == process.pid && $0.sessionId != row.sessionId })
        else { throw .processChanged }
        try Self.checkTakeControl(now)
        try terminate(process)
        guard try await hasEnded(pid, within: Self.endWait) else { throw .notEnded }
        // A started session parks when it ends, so a failed resume leaves a parked row.
        registry.markStarted(row.sessionId)
        _ = try await startRun(claude, SessionCommandArgs.takeControl(current), in: row.cwd)
        try await waitResumed(row.sessionId)
        // The resumed session must still run after resumeSettle. Else it ended or parked before
        // it ran.
        try await sleep(Self.resumeSettle)
        let resumed = registry.rows.first { $0.sessionId == row.sessionId }
        guard let resumed, Self.runsAgain(row.sessionId, resumed), let newPid = resumed.pid,
            signals.isAlive(newPid)
        else { throw .resumeFailed(shortId: resumed?.shortId) }
    }

    // Take control is only for an external session that runs and is idle or has a yellow box. A
    // working session would stop its work, and a red box would lose the open prompt. Live state
    // is a hint, not an authority: a line of the mod (also a forged one) can give a yellow box to
    // a session that works. So the status of the session list must agree: busy refuses as
    // working, and waiting with a waitingFor refuses as an open prompt.
    nonisolated static func checkTakeControl(_ row: SessionRow) throws(ActionRefusal) {
        guard row.kind == .external, row.state != .parked else { throw .onlyExternal }
        if row.state == .working || row.status == .busy { throw .working }
        if case .red = row.alert { throw .openPrompt }
        if row.status == .waiting, row.waitingFor?.isEmpty == false { throw .openPrompt }
        let yellowBox = if case .yellow = row.alert { true } else { false }
        guard row.state == .idle || (row.state == .needsYou && yellowBox) else {
            throw .notIdle
        }
    }

    // SIGTERM to the claude process of the checks (SystemSignals.terminate). A process that ended
    // before the signal needs no signal: the kill gives ESRCH, or the read just before the kill
    // finds no process, and no process has the PID now.
    private func terminate(_ process: ClaudeProcess) throws(ActionRefusal) {
        do throws(ActionRefusal) {
            try signals.terminate(process)
        } catch .notClaudeProcess where !signals.isAlive(process.pid) {
            return
        }
    }

    // MARK: - The steps

    // True when a parked row has no process and the session list does not list it
    // (SessionRow.listedActive). Live state is a hint, not an authority: a SessionEnd line of
    // the mod parks a row at once, also a forged line. An entry of the active list has no pid and
    // no status for about 2.5 s after a start, so only the end of the entry in the active list
    // shows that the session stopped. Thus Resume never starts a copy of a session that runs,
    // and Delete of such a row stops it first, until the session list agrees. A row that an
    // --all read added with no pid counts as listed until an active list of a later turn also
    // lacks it: Resume, Resume all and Delete check the active list first (checkSessions). After
    // a stop, the entry stays in the active list for a short time with no pid: Resume then
    // refuses, and Delete of an owned row runs claude stop again and fails until the entry goes,
    // the safe side (docs/behaviour/live.md, "Live state is a hint, not an authority").
    private static func isStopped(_ row: SessionRow) -> Bool {
        row.state == .parked && row.pid == nil && !row.listedActive
    }

    // Check a parked row and run "claude --bg --resume" in its folder. Bifrost never resumes a
    // session that runs, because that starts a copy, and never a review session of a PR. The
    // session can run again during the folder check, so the row must still be parked after it.
    // The resumed job keeps its short ID, so its row keeps its row ID.
    private func startResume(_ claude: ClaudeRunner, _ row: SessionRow) async throws(ActionRefusal)
    {
        guard Self.isStopped(row) else { throw .notParked }
        guard !row.prSession else { throw .prResume }
        let args = try SessionCommandArgs.resume(row)
        try await checkProjectFolder(row.cwd)
        guard Self.isStopped(try self.row(row.sessionId)) else { throw .notParked }
        _ = try await startRun(claude, args, in: row.cwd)
    }

    // Wait until the row ID runs again as an owned row.
    private func waitResumed(_ sessionId: String) async throws(ActionRefusal) {
        _ = try await waitForRow(timeout: .notResumed) { Self.runsAgain(sessionId, $0) }
    }

    // Wait until the row ID runs again, then mark the session as started. The result is the
    // reason of a failed wait, or nil.
    private func markWhenResumed(_ sessionId: String) async -> ActionRefusal? {
        do throws(ActionRefusal) {
            try await waitResumed(sessionId)
        } catch {
            return error
        }
        registry.markStarted(sessionId)
        return nil
    }

    // Run a claude command that starts a session in the folder. A trust error gives the trust
    // text, and an exit code other than 0 gives the failure of claude. At the time limit and at
    // a cancel the start gets SIGTERM, not SIGKILL, so claude can end the start cleanly and leaves
    // no half started session. A start that still runs after the grace of the runner (5 s) gets
    // SIGKILL, so the job always ends. claude stop keeps SIGKILL.
    private func startRun(
        _ claude: ClaudeRunner, _ args: [String], in folder: String
    ) async throws(ActionRefusal) -> ExecResult {
        let result = await claude.run(
            args, directory: folder, timeout: Self.runTimeout, killSignal: .terminate)
        try checkCancel()
        if ClaudeOutput.isTrustError(result.stdout) || ClaudeOutput.isTrustError(result.stderr) {
            throw .trust(dir: folder)
        }
        guard result.succeeded else { throw ClaudeOutput.claudeFailure(result) }
        return result
    }

    // Wait for the first row that matches. The time limit gives the refusal of the rule. A stop
    // of the registry and a cancel of the job end the job.
    private func waitForRow(
        timeout refusal: ActionRefusal, where match: @escaping (SessionRow) -> Bool
    ) async throws(ActionRefusal) -> SessionRow {
        let row: SessionRow
        do throws(RowWaitError) {
            row = try await registry.waitForRow(timeout: Self.startTimeout, where: match)
        } catch .timeout {
            throw refusal
        } catch {
            throw .cancelled
        }
        try checkCancel()
        return row
    }

    // Run "claude stop" with the short ID. claude stop keeps SIGKILL at its limit.
    private func claudeStop(
        _ claude: ClaudeRunner, _ shortId: ShortID
    ) async throws(ActionRefusal) {
        let result = await claude.run(["stop", shortId.text], timeout: Self.runTimeout)
        try checkCancel()
        guard result.succeeded else { throw ClaudeOutput.claudeFailure(result) }
    }

    // Wait for the end of the process of the PID, up to the limit, on the exit event of the
    // kernel (SystemSignals.waitForEnd). True when no process has the PID. A cancel ends the job.
    private func hasEnded(_ pid: pid_t, within limit: Duration) async throws(ActionRefusal) -> Bool
    {
        let ended = await signals.waitForEnd(of: pid, within: limit, on: clock)
        try checkCancel()
        return ended
    }

    // Sleep on the clock. A cancel ends the job.
    private func sleep(_ duration: Duration) async throws(ActionRefusal) {
        do {
            try await clock.sleep(for: duration)
        } catch {
            throw .cancelled
        }
        try checkCancel()
    }

    private func checkProjectFolder(_ folder: String) async throws(ActionRefusal) {
        if folder.isEmpty { throw .noProjectFolder }
        // The probe gives missing for a relative path, with no read. Only the kind counts, so no
        // git runs.
        let kind = await probe.kind(folder)
        try checkCancel()
        guard kind == .dir else { throw .folderMissing(folder) }
    }

    private func runner() throws(ActionRefusal) -> ClaudeRunner {
        guard let claude = claude() else { throw .claudeNotFound }
        return claude
    }

    private func row(_ sessionId: String) throws(ActionRefusal) -> SessionRow {
        guard let row = registry.rows.first(where: { $0.sessionId == sessionId }) else {
            throw .unknownSession
        }
        return row
    }

    // A cancelled job, and each job after stop(), runs no more step.
    private func checkCancel() throws(ActionRefusal) {
        if stopped || Task.isCancelled { throw .cancelled }
    }

    // The row of a new session: an owned row with the short ID of the start, not parked, with a
    // PID.
    nonisolated static func isStart(of shortId: ShortID, _ row: SessionRow) -> Bool {
        row.shortId == shortId && row.kind == .owned && row.state != .parked && row.pid != nil
    }

    // The row of a resumed session: the row ID runs again as an owned row with a PID. A /clear
    // does not change the row ID.
    nonisolated static func runsAgain(_ sessionId: String, _ row: SessionRow) -> Bool {
        row.sessionId == sessionId && row.kind == .owned && row.state != .parked && row.pid != nil
    }

    // The worktree root of a row: from its folder, else from the worktree that Bifrost stored
    // while the session ran.
    nonisolated private static func worktree(of row: SessionRow) -> String? {
        WorktreeRoot(cwd: row.cwd, stored: row.worktree)?.worktree
    }

    // The path with one "/" less at its end, when it ends with "/".
    nonisolated private static func withoutSlash(_ path: String) -> String {
        guard path.unicodeScalars.last == "/" else { return path }
        var scalars = path.unicodeScalars
        scalars.removeLast()
        return String(scalars)
    }

    // MARK: - The log

    private func record(_ command: SessionCommand, _ result: Result<ActionDone, ActionRefusal>) {
        let (action, session): (ActionID, String?) =
            switch command {
            case .create: (.newSession, nil)
            case .stop(let sessionId): (.stop, sessionId)
            case .resume(let sessionId): (.resume, sessionId)
            case .resumeAll: (.resumeAll, nil)
            case .remove(let sessionId, _, _): (.delete, sessionId)
            case .takeControl(let sessionId, _): (.takeControl, sessionId)
            }
        switch result {
        case .success(.created(let sessionId)), .success(.tookControl(let sessionId)):
            log.record(.sessionCommandDone(action, session: sessionId))
        case .success(.resumedAll(let all)):
            for failure in all.failed {
                log.record(.sessionCommandFailed(action, session: failure.sessionId, failure.error))
            }
            log.record(.sessionCommandDone(action, session: nil))
        case .success(.done):
            log.record(.sessionCommandDone(action, session: session))
        case .failure(let refusal):
            log.record(.sessionCommandFailed(action, session: session, refusal))
        }
    }
}

extension ResumeFailure {
    fileprivate init(_ row: SessionRow, _ error: ActionRefusal) {
        self.init(sessionId: row.sessionId, name: row.name, error: error)
    }
}
