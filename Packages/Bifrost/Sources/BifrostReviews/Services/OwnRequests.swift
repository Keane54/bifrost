// The own requests of the user (docs/behaviour/reviews.md, "Your own requests"). Between rounds,
// the user can ask Claude in the request session of a PR for a change. Claude makes the change and
// writes the own request file (OwnRequestFile) with the paths and a commit message. Claude never
// commits or pushes, and never reaches GitHub: Bifrost commits and pushes the change through the
// writes of the fix of a round (RoundWrites), with an outbox that holds only the commit and the
// push (Outbox.own). So the change gets the same file rules, the same signed commit, the same
// checks of the push target, the same fetch and the same outcomes as a fix. After the commit, the
// changes that the file does not list stay in the worktree (a ruling of the user): the next round
// then stops with Needs you, so the user decides about them.
// - The caller runs run(_:) only while no round of the PR holds its session and nobody uses the
//   session (ReviewRounds.checkOwnRequest), or in a round before the round changes the worktree
//   (the own request goes first, then the round starts again).
// - The file goes before the commit, also after a refusal, so no later run or round reads it
//   again. The check is as strict as the check of a round result: the PR, the commit that the
//   worktree is at, and the rules of the commit of a round (OwnRequestFile).
// - A refusal or writes that stop give the row Needs you with the reason (PRState.waitsForYou),
//   and the change stays in the worktree: a commit that did not reach GitHub becomes changes
//   again (RoundWrites, RepoStore.uncommit). Each outcome goes to the Event log.
// - The worktree can hold the merge with the markers of a conflict round, which is not on GitHub.
//   An own request on it is refused (OwnRequestStop.conflictMerge): a commit on it would push
//   that merge. A conflict round that finds the file at the end of its turn refuses it too
//   (refuse).
// - An own outbox that a quit cut off (with no reason on the row) sends the rest at the next run.
//   An outbox that waits for Try again, or the outbox of a round, stays as it is. Try again
//   sends a kept own outbox through resend, from the first step of a round.
import BifrostFoundation
import Foundation
import OSLog

@MainActor
final class OwnRequests {
    private static let logger = Logger(bifrost: "reviews")

    private let store: ReviewsStore
    private let repos: RepoStore
    private let writes: RoundWrites
    private let now: () -> Date
    // The setting "Sign commits through GitHub" now. The outbox keeps it.
    private let signed: () -> Bool
    // A line for the user in the Event log.
    private let eventLine: (String) -> Void
    private let changed: () -> Void
    // The PRs whose own request file a turn of a round left. Bifrost can't tell whether a person
    // asked for it (no hook runs in a PR session), so its Event log line says so.
    private var fromRounds: Set<PRKey> = []

    init(
        store: ReviewsStore, repos: RepoStore, writes: RoundWrites, now: @escaping () -> Date,
        signed: @escaping () -> Bool, eventLine: @escaping (String) -> Void,
        changed: @escaping () -> Void
    ) {
        self.store = store
        self.repos = repos
        self.writes = writes
        self.now = now
        self.signed = signed
        self.eventLine = eventLine
        self.changed = changed
    }

    // True when an item is at the path of the own request file of the PR.
    func waits(_ pr: PRKey) async -> Bool {
        await repos.hasOwnRequest(pr)
    }

    // The turn of a round of the PR left an own request file.
    func cameFromRound(_ pr: PRKey) {
        fromRounds.insert(pr)
    }

    // The own request file of the PR went with no run (a discard, a drop): the mark of a file
    // from a round goes too, so the next file of the user gets its own line.
    func forgetRoundMark(_ pr: PRKey) {
        fromRounds.remove(pr)
    }

    // Act on the own request file of the PR, or send the rest of an own outbox that a quit cut
    // off. A cancel (a quit) keeps the outbox for the next run.
    func run(_ pr: PRKey) async {
        if let outbox = store.state.prs[pr]?.outbox {
            guard outbox.own, store.state.prs[pr]?.waitsForYou == nil else { return }
            _ = await send(outbox, for: pr)
            return
        }
        let read = await repos.readOwnRequest(pr)
        let fromRound = fromRounds.remove(pr) != nil
        if read == .missing { return }
        // The file goes now, so no later run or round reads it again.
        await repos.removeOwnRequest(pr)
        let plan: CommitPlan
        let head: CommitID
        do throws(OwnRequestStop) {
            (plan, head) = try await check(read, pr)
        } catch {
            await stop(pr, error, fromRound: fromRound)
            return
        }
        // An own request has no diff, so the merge base of its outbox is its head.
        let outbox = Outbox(
            headSHA: head, mergeBase: head, startedAt: now(), seen: [:],
            posts: [
                OutboxPost(
                    id: OutboxRules.commitID, state: .todo,
                    write: .commit(paths: plan.paths, message: plan.message, commit: nil)),
                OutboxPost(
                    id: OutboxRules.pushID, state: .todo,
                    write: .push(commit: nil, signed: signed())),
            ],
            own: true)
        let saved = await store.update { state in
            var prState = state.prs[pr] ?? PRState()
            guard prState.outbox == nil else { return }
            prState.outbox = outbox
            prState.waitsForYou = nil
            state.prs[pr] = prState
        }
        guard saved, store.state.prs[pr]?.outbox == outbox else {
            await stop(pr, .notSaved, fromRound: fromRound)
            return
        }
        changed()
        Self.logger.info(
            "Bifrost commits and pushes an own request of \(pr.text, privacy: .private).")
        _ = await send(outbox, for: pr, fromRound: fromRound)
    }

    // Try again on a PR with a kept own outbox: send the rest of its writes. The result is true
    // when they went (or the PR has no own outbox), and false when they stopped, with the reason
    // on the row, or when a cancel (a quit) stopped them.
    func resend(_ pr: PRKey) async -> Bool {
        guard let outbox = store.state.prs[pr]?.outbox, outbox.own else { return true }
        await store.update { $0.prs[pr]?.waitsForYou = nil }
        changed()
        return await send(outbox, for: pr)
    }

    // A conflict round found the own request file of the PR at the end of its turn: the file goes
    // with no commit, and the row shows Needs you with the reason. Bifrost can't tell whether a
    // person asked for the change, so the Event log line says that Claude made it.
    func refuse(_ pr: PRKey, _ reason: OwnRequestStop) async {
        forgetRoundMark(pr)
        guard await repos.removeOwnRequest(pr) else { return }
        await stop(pr, reason, fromRound: true)
    }

    // The commit of the file, and the commit that the worktree is at.
    private func check(_ read: ResultRead, _ pr: PRKey) async throws(OwnRequestStop)
        -> (CommitPlan, CommitID)
    {
        let data: Data
        switch read {
        case .data(let bytes): data = bytes
        case .tooLarge:
            throw .badFile(
                ResultRefusal(
                    "the file is larger than \(ReviewResult.count(RequestResult.maxBytes)) bytes"))
        case .notRegular, .missing:
            throw .badFile(ResultRefusal("the file is not a regular file"))
        }
        guard let at = await repos.worktreeCommit(pr), let changed = await repos.changedPaths(pr)
        else { throw .noWorktree }
        if at.conflictHead != nil { throw .conflictMerge }
        let head = at.commit
        switch OwnRequestFile.check(data, pr: pr, head: head, changed: changed) {
        case .success(let plan): return (plan, head)
        case .failure(let refusal): throw .badFile(refusal)
        }
    }

    // Send the commit and the push of the outbox. A good end clears the reason of the row. The
    // result is true when the writes went. fromRound: the file came from the turn of a round.
    private func send(_ outbox: Outbox, for pr: PRKey, fromRound: Bool = false) async -> Bool {
        do throws(RoundFailure) {
            try await writes.run(outbox, for: pr)
        } catch {
            // A quit: the outbox stays, and the next run sends the rest.
            if Task.isCancelled { return false }
            await stop(pr, .wrote(error), fromRound: fromRound)
            return false
        }
        await store.update { $0.prs[pr]?.waitsForYou = nil }
        changed()
        eventLine(
            fromRound
                ? "Reviews: Bifrost committed and pushed a change that Claude made while it "
                    + "worked on \(pr.text)."
                : "Reviews: Bifrost committed and pushed the change you asked for on \(pr.text).")
        return true
    }

    // The own request did not go: the row shows Needs you with the reason, and the Event log
    // gets it too.
    // The reason keeps the changed files of the worktree at this time (after a commit went back
    // to changes), so the row can offer Discard these changes for them. fromRound: the file came
    // from the turn of a round.
    private func stop(_ pr: PRKey, _ reason: OwnRequestStop, fromRound: Bool) async {
        let text = reason.message
        let files = (await repos.changedPaths(pr) ?? []).sorted()
        await store.update { state in
            var prState = state.prs[pr] ?? PRState()
            prState.waiting = WaitsForYou(
                reason: text, files: files, kind: reason == .conflictMerge ? .askAgain : .other)
            state.prs[pr] = prState
        }
        changed()
        Self.logger.notice(
            """
            An own request of \(pr.text, privacy: .private) did not go. \
            \(text, privacy: .private)
            """)
        eventLine(
            fromRound
                ? "Reviews: Bifrost didn't push a change that Claude made while it worked on "
                    + "\(pr.text). \(text)"
                : "Reviews: Bifrost didn't push the change you asked for on \(pr.text). \(text)")
    }
}
