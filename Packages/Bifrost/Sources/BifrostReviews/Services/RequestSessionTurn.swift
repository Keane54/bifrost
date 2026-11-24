// The steps of a turn that the request round and the conflict round share. Both rounds run a turn
// in the one request session of a PR (docs/behaviour/reviews.md, "PR sessions"), and both must
// keep the work of the user. Each rule of that work lives here once: the safety net before the
// round changes the worktree, the sandbox of the turn, the wait for the end of the turn with
// its record, and the reset after the turn. A round keeps its own texts, its own result check
// and its own stops, and it passes them in.
import BifrostFoundation
import BifrostSessions
import Foundation
import OSLog

@MainActor
struct RequestSessionTurn {
    // How the wait for the end of a turn stopped before it gave an answer. The worktree is
    // already reset when it is timeout or stopped.
    enum Stopped: Error {
        // The time limit passed. The session is stopped.
        case timeout
        // A cancel that is not a halt (Stop session, or a wait that failed).
        case stopped
        // The task was cancelled (a halt or a quit). The worktree is not reset.
        case halted
    }

    // The kind of the round. Each rule that differs between the rounds comes from it, with no
    // default: a new kind must name its rule in each switch.
    enum Kind {
        case request
        // The conflicted files of the merge: only these changes count as changes of the round.
        case conflict(Set<String>)
    }

    // How the reset finds out whether a person uses the session.
    enum SessionUse {
        // The session of the round, by its ID.
        case session(String)
        // The request session of the PR.
        case request
    }

    // What the end of a turn gave.
    struct TurnEnded<Answer: Sendable> {
        // The value of the last result that passed the check of the round, or nil.
        var accepted: Answer?
        // True when the session showed a prompt. The session is stopped.
        var blocked: Bool
        // True when an own request file of the user waited at the end of the turn.
        var ownRequest: Bool
    }

    private static let logger = Logger(bifrost: "reviews")

    let pr: PRKey
    let kind: Kind
    let repos: RepoStore
    let sessions: PRSessions
    let own: OwnRequests
    let skills: URL
    // The home of the user in the user database, which holds the secret paths of the sandbox.
    let userHome: URL
    let model: ModelChoice

    // MARK: - Before the turn

    // The safety net before the round changes the worktree: an own request of the user goes
    // first (ownRequestWaits), and changes that no round made stay (changesNotOnGitHub, with the
    // sorted files in onUnknown). In both cases the round changes nothing.
    func checkWorktree(onUnknown: ([String]) -> Void) async throws(RoundFailure) {
        if await own.waits(pr) { throw .ownRequestWaits }
        guard let unknown = await repos.unknownChanges(pr) else { throw .prepareFailed }
        guard unknown.isEmpty else {
            onUnknown(unknown)
            Self.logger.notice(
                """
                The copy of \(self.pr.text, privacy: .private) has \
                \(unknown.count, privacy: .public) changes that no round made, so the \
                \(self.noun, privacy: .public) does not start.
                """)
            throw .changesNotOnGitHub
        }
    }

    // The sandbox of the turn. Claude Code compares real paths, so the rules name the real paths
    // of the folders and --add-dir gets the real path of the input folder. With no real path or
    // no settings, a rule can miss its path, so the session does not start.
    func sandboxTurn(
        worktree: WorktreePlace, resultFile: URL, prompt: String
    ) async throws(RoundFailure) -> MineTurn {
        let (clonePath, treePath, folderPath, reviewsPath, homePath) = (
            repos.layout.clone(pr.repo).plainPath, worktree.url.plainPath,
            resultFile.deletingLastPathComponent().plainPath,
            repos.layout.folder.plainPath, userHome.plainPath
        )
        let real = await BlockingExecutor.run {
            (
                RealPath.of(clonePath), RealPath.of(treePath), RealPath.of(folderPath),
                RealPath.of(reviewsPath), RealPath.of(homePath)
            )
        }
        guard let clone = real.0, let tree = real.1, let folder = real.2, let reviews = real.3,
            let home = real.4,
            let settings = RequestSandbox.settings(
                SessionPaths(
                    clone: clone, worktree: tree, inputFolder: folder, reviews: reviews,
                    home: home))
        else { throw .startFailed }
        return MineTurn(
            pr: pr, model: model, inputFolder: URL(filePath: folder, directoryHint: .isDirectory),
            skills: skills, settings: settings, prompt: prompt, worktree: worktree)
    }

    // The turn in the one session of the PR. A prepared turn that waits again checks the worktree
    // again before its next send (checkWorktree, in recheck).
    func begin(
        prepare: () async throws(RoundFailure) -> MineTurn,
        recheck: () async throws(RoundFailure) -> Void
    ) async throws(RoundFailure) -> BegunTurn {
        let worktree = repos.layout.worktree(pr.repo, number: pr.number)
        return try await sessions.beginTurn(
            pr, worktree: worktree, prepare: prepare, recheck: recheck)
    }

    // A step of the repo store in the preparation of the turn. A failure goes to the log, and the
    // row gets a fixed text.
    static func repoStep<Value>(_ step: () async throws(RepoError) -> Value)
        async throws(RoundFailure) -> Value
    {
        do throws(RepoError) {
            return try await step()
        } catch {
            logger.error("\(error.message, privacy: .private)")
            throw .prepareFailed
        }
    }

    // The start of a turn on the clock of the sessions, for a round that went on after a restart.
    func resumedStart(since startedAt: Date, now: Date) -> Duration {
        sessions.time - Duration.seconds(max(now.timeIntervalSince(startedAt), 0))
    }

    // MARK: - The end of the turn

    // The wait for the end of the turn on the result file, then its record (afterTurn). A session
    // that shows a prompt is stopped, and its answer counts only when it is good. A cancel ends
    // the wait. The record runs in a task of its own, so git still runs, and the reset of the
    // stop can use it. A time out gets its record before the stop of the session, or after it
    // (a conflict round: Claude can still write until the stop). reset runs after a time out and
    // after a cancel that is not a halt (stoppedIt: true after a time out).
    func waitForEnd<Answer: Sendable>(
        session: String, startedAt: Duration, resultFile: URL, begun: SessionRow?,
        check: @escaping @Sendable (Data) -> Answer?,
        reset: (_ stoppedIt: Bool) async -> Void
    ) async throws(Stopped) -> TurnEnded<Answer> {
        do throws(RoundFailure) {
            let end: TurnEnd<Answer>
            do throws(RoundFailure) {
                end = try await sessions.waitForTurnEnd(
                    id: session, startedAt: startedAt, resultFile: resultFile,
                    limit: ReviewRounds.limit, begun: begun, check: check)
            } catch {
                if !(recordsAfterStop && error == .timeout) {
                    _ = await Task { await self.afterTurn() }.value
                }
                throw error
            }
            let ownRequest = await afterTurn()
            switch end {
            case .ended(let answer):
                return TurnEnded(accepted: answer, blocked: false, ownRequest: ownRequest)
            case .blocked(let answer):
                // A session of a round must never ask. Its result counts only when it is good.
                await sessions.stop(id: session)
                return TurnEnded(accepted: answer, blocked: true, ownRequest: ownRequest)
            }
        } catch .timeout {
            await sessions.stop(id: session)
            if recordsAfterStop { _ = await afterTurn() }
            await reset(true)
            throw .timeout
        } catch {
            if Task.isCancelled { throw .halted }
            await reset(false)
            throw .stopped
        }
    }

    // At the end of the turn, each change of the worktree (of the conflicted files only, for a
    // conflict round) is a change of the round, so a reset can remove it
    // (RepoStore.markLeftovers). An own request file shows that a request of the user ran in the
    // turn. Then no change counts as a change of the round, no reset removes the changes of the
    // user, and the result is true. A request round also tells the own requests that the file
    // came from a round: the file goes as an own request after the round. A conflict round
    // refuses the file itself.
    func afterTurn() async -> Bool {
        guard await own.waits(pr) else {
            switch kind {
            case .request: await repos.markLeftovers(pr)
            case .conflict(let conflicted): await repos.markLeftovers(pr, only: conflicted)
            }
            return false
        }
        switch kind {
        case .conflict:
            Self.logger.notice(
                """
                The turn of a conflict round of \(self.pr.text, privacy: .private) left an own \
                request file, so Bifrost keeps the worktree.
                """)
        case .request:
            own.cameFromRound(pr)
            Self.logger.notice(
                """
                A request of the user ran in the turn of a round of \
                \(self.pr.text, privacy: .private), so Bifrost keeps the worktree.
                """)
        }
        return true
    }

    // MARK: - After the turn

    // Reset the worktree, so the files of the session go. A person can use the session after its
    // turn: while its row works or shows a box (inUse), the reset does not run. The reset also
    // does not run while the worktree has a change that no round made (RepoStore.resetIfKnown).
    // stoppedIt: the round stopped the session (a time limit or a prompt), so no person uses it,
    // also while a list still shows its row. The result is true when the reset ran.
    @discardableResult
    func reset(to commit: CommitID? = nil, use: SessionUse, stoppedIt: Bool) async -> Bool {
        let inUse =
            switch use {
            case .session(let id): sessions.inUse(id: id)
            case .request: sessions.requestInUse(pr)
            }
        if !stoppedIt, inUse {
            Self.logger.notice(
                """
                A person uses the session of \(self.pr.text, privacy: .private), so Bifrost \
                keeps its worktree as it is.
                """)
            return false
        }
        return await repos.resetIfKnown(pr, to: commit)
    }

    // A conflict round records a timed-out turn after the stop of the session.
    private var recordsAfterStop: Bool {
        switch kind {
        case .request: false
        case .conflict: true
        }
    }

    private var noun: String {
        switch kind {
        case .request: "round"
        case .conflict: "conflict round"
        }
    }
}
