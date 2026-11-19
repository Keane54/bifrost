// The Approve button of the To review tab (docs/behaviour/reviews.md, "Approve"). Only a click of
// the user starts an approval: the button makes the UserClick in its action.
// - The row offers Approve while the PR has a mark that lets the user approve (Claude suggests
//   Approve, or the user deleted Claude's draft with Approve instead) and no round runs or waits.
// - Just before the write, Bifrost reads the PR again (DraftQueries.fresh) and refuses when the PR
//   or the draft changed (ApproveGuard.refusal). The mark must still be the mark of the click.
// - The one write approves the reviewed commit with no text, or submits Claude's draft as the
//   approval with its body as it is (ApproveGuard.write).
// - A write that GitHub can have made is never sent again by itself. A poll follows an approval
//   and an unknown result, so the row shows the true state on GitHub.
// - A call while an approval of the PR runs sends nothing: it waits for that approval and gives
//   its result, so Approve instead of the Review panel never reports an approval that didn't go.
//   The approval leaves the running step in its own task, when it ends, so a later call never
//   gets the result of an approval that ended.
// - The progress of each approval shows on its row (ApproveProgress): approving while the read
//   and the write run, then approved for the time of hold on the injected clock after GitHub
//   confirmed it. A refusal ends the progress at once. While a PR has a progress, its row stays
//   when a poll drops the PR (held, ReviewRows.holding). At the end of a progress, progressEnded
//   builds the rows again, so such a row goes.
// - After GitHub confirmed an approval, the To review row says You approved until a poll shows
//   the approval itself (approvedHere). GitHub can take a moment to list a new review, and the
//   row must not offer Approve again in that time.
// - The reason of GitHub goes to the Event log; the refusal gives the friendly text.
import BifrostFoundation
import Foundation
import Observation

@MainActor
@Observable
package final class ApproveFlow {
    // The time that a row shows "Approved" and stays after GitHub confirmed its approval.
    nonisolated package static let hold = Duration.seconds(3)

    // The approval of a PR: it runs, with its result, or GitHub confirmed it and the timer ends
    // the time that its row shows that.
    private enum Approval {
        case running(Task<Result<Void, ApproveRefusal>, Never>)
        case approved(TimerSlot)
    }

    // The approval of each PR with a progress.
    private var approvals: [PRKey: Approval] = [:]

    // The head commit of each PR that the user approved here, after GitHub confirmed the write,
    // until a poll shows that approval. Only in memory: after a start, the polls decide.
    @ObservationIgnored private var approvedHeads: [PRKey: String] = [:]

    // The PRs whose approval runs now.
    package var running: Set<PRKey> {
        Set(approvals.compactMap { pr, approval in
            if case .running = approval { pr } else { nil }
        })
    }

    // The PRs with a progress. Their rows stay when a poll drops them (ReviewRows.holding).
    package var held: Set<PRKey> { Set(approvals.keys) }

    @ObservationIgnored private let store: ReviewsStore
    @ObservationIgnored private let github: GitHubClient
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let viewer: @MainActor () -> String?
    @ObservationIgnored private let ended: @MainActor () -> Void
    @ObservationIgnored private let progressEnded: @MainActor () -> Void
    @ObservationIgnored private let eventLine: @MainActor (String) -> Void

    // The clock runs the time of hold. viewer gives the login of the last good poll. ended asks
    // for a poll. progressEnded builds the rows again, with no poll. eventLine adds a line to the
    // Event log.
    package init(
        store: ReviewsStore, github: GitHubClient, clock: any Clock<Duration>,
        viewer: @escaping @MainActor () -> String?,
        ended: @escaping @MainActor () -> Void = {},
        progressEnded: @escaping @MainActor () -> Void = {},
        eventLine: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.store = store
        self.github = github
        self.clock = clock
        self.viewer = viewer
        self.ended = ended
        self.progressEnded = progressEnded
        self.eventLine = eventLine
    }

    // The progress of the approval of the PR, or nil.
    package func progress(_ pr: PRKey) -> ApproveProgress? {
        switch approvals[pr] {
        case .running?: .approving
        case .approved?: .approved
        case nil: nil
        }
    }

    // The approvals of the user that GitHub confirmed and that the answer does not show yet, by
    // PR, with the head commit of each (ToReviewRules: You approved). An approval that the answer
    // shows, a PR that is not in the answer and a PR with a new head leave the list.
    package func approvedHere(_ answer: PollAnswer) -> [PRKey: String] {
        approvedHeads = approvedHeads.filter { pr, head in
            guard let request = answer.toReview.first(where: { $0.key == pr }),
                request.headSHA == head
            else { return false }
            return !ToReviewRules.approvedOnHead(request.viewerReviews, head: head)
        }
        return approvedHeads
    }

    // The task of the timer of the approved PR, or nil. A test waits for it.
    package func holdTask(_ pr: PRKey) -> Task<Void, Never>? {
        if case .approved(let timer)? = approvals[pr] { timer.task } else { nil }
    }

    // Approve the PR. A call while an approval of the PR runs sends nothing, and gives the
    // result of that approval when it ends.
    package func approve(_ pr: PRKey, click: UserClick) async throws(ApproveRefusal) {
        if case .running(let approval)? = approvals[pr] {
            try await approval.value.get()
            return
        }
        guard store.isOpen, let viewer = viewer() else { throw .notReady }
        guard let mark = offeredMark(pr) else { throw .notSuggested }
        // A new approval ends the time that the row shows an earlier one.
        if case .approved(let timer)? = approvals[pr] { timer.stop() }
        // The task runs on the main actor after this call stored it, so its end changes it.
        let approval = Task { () async -> Result<Void, ApproveRefusal> in
            do throws(ApproveRefusal) {
                let head = try await self.send(pr, viewer: viewer, mark: mark, click: click)
                self.confirmed(pr, head: head)
                return .success(())
            } catch {
                self.endProgress(pr)
                return .failure(error)
            }
        }
        approvals[pr] = .running(approval)
        try await approval.value.get()
    }

    // GitHub confirmed the approval of the head of the PR. The row shows Approved for the time
    // of hold, then You approved until a poll shows the approval (approvedHere). A refusal ends
    // the progress at once (endProgress).
    private func confirmed(_ pr: PRKey, head: String) {
        approvedHeads[pr] = head
        let timer = TimerSlot(clock: clock)
        approvals[pr] = .approved(timer)
        timer.start(after: Self.hold) { [weak self] in self?.endProgress(pr) }
    }

    // Remove the progress of the PR, and build the rows again.
    private func endProgress(_ pr: PRKey) {
        approvals[pr] = nil
        progressEnded()
    }

    // The approval itself: the fresh read, the checks and the one write. The result is the head
    // commit that the write approved: the guard refuses a head that is not the reviewed one.
    private func send(
        _ pr: PRKey, viewer: String, mark: RecommendationMark, click: UserClick
    ) async throws(ApproveRefusal) -> String {
        let fresh: FreshPR
        do throws(GitHubError) {
            fresh = try await DraftQueries.fresh(pr, viewer: viewer, on: github)
        } catch {
            event("Reviews: GitHub couldn't load \(pr.text). It said: \(error.message)")
            throw .readFailed(error)
        }
        // A round can start or end during the read and change the mark.
        guard offeredMark(pr) == mark else { throw .notSuggested }
        if let refusal = ApproveGuard.refusal(fresh, viewer: viewer, mark: mark) { throw refusal }
        guard let write = ApproveGuard.write(fresh, pr: pr, mark: mark, click: click) else {
            throw .guardRefused
        }
        guard store.isOpen else { throw .notReady }
        let answer: Data
        do throws(GitHubError) {
            answer = try await github.write(write)
        } catch {
            throw failure(error, pr: pr)
        }
        // The next poll shows the true state on GitHub.
        ended()
        if let refusal = ApproveGuard.outcome(answer, of: write) { throw refusal }
        return fresh.headSHA.hex
    }

    // The mark of the PR while the row offers Approve: a mark that lets the user approve, and no
    // round of the PR that runs or waits. Else nil.
    private func offeredMark(_ pr: PRKey) -> RecommendationMark? {
        let state = store.state
        guard let prState = state.prs[pr], let mark = prState.recommendation,
            ApproveGuard.isApprovable(mark), prState.round == nil,
            !state.queue.contains(where: { $0.pr == pr })
        else { return nil }
        return mark
    }

    // The refusal of a write that failed. A write that GitHub can have made asks for a poll.
    private func failure(_ error: GitHubError, pr: PRKey) -> ApproveRefusal {
        if error.writeMayHaveHappened {
            event(
                "Reviews: Bifrost couldn't tell if GitHub saved the approval of \(pr.text). It "
                    + "said: \(error.message)")
            ended()
            return .unknown
        }
        if case .refused(let line) = error, !line.isEmpty {
            event("Reviews: GitHub didn't take the approval of \(pr.text). It said: \(line)")
            return .refusedByGitHub
        }
        return .notSent(error)
    }

    // A line for the Event log, with each secret hidden.
    private func event(_ text: String) {
        eventLine(TokenMask.mask(text, token: nil))
    }
}
