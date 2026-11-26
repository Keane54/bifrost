// The Approve button of the To review tab and of the Review panel (docs/behaviour/reviews.md,
// "Approve"). Only a click of the user starts an approval: the button makes the UserClick in its
// action.
// - The flow approves while the PR has a mark with no draft that lets the user approve (Claude
//   suggests Approve, or the user deleted Claude's draft with Approve instead) and no round runs
//   or waits. Approve never submits a draft review: on Claude's old Approve draft, and on a
//   finding above a nit, the row opens the Review panel first (ReviewsPanelModel.approve).
// - Just before the write, Bifrost reads the PR again (DraftQueries.fresh) and refuses when the PR
//   changed (ApproveGuard.refusal). The mark must still be the mark of the click.
// - The one write approves the reviewed commit with no text, or posts the findings that the user
//   ticked in the Review panel with the approval (ApproveGuard.write).
// - While a review write of the findings form of the PR may have gone and no poll after it has
//   shown the true state (ReviewWrites.waitsForPoll), nothing goes. The click asks for a poll.
// - An approval of the Review panel that GitHub can have saved starts that wait before it asks
//   for its poll (ReviewWrites.mayHaveGone), so the answer of that poll ends the wait.
// - An approval of the Review panel (PanelApproval) goes only for the mark that the panel showed.
//   It never waits for an approval of the PR that runs, because that approval does not post what
//   the panel showed.
// - A write that GitHub can have made is never sent again by itself. A poll follows an approval
//   and an unknown result, so the row shows the true state on GitHub.
// - A call with no panel while an approval of the PR runs sends nothing: it waits for that
//   approval and gives its result, so Approve instead of the Review panel never reports an
//   approval that didn't go.
// - ReviewWrites runs each approval in its own task and keeps the progress that the row shows,
//   the hold after GitHub confirmed it, and You approved until a poll shows the approval.
// - The reason of GitHub goes to the Event log; the refusal gives the friendly text.
import BifrostFoundation
import Foundation

@MainActor
package final class ApproveFlow {
    private let store: ReviewsStore
    private let github: GitHubClient
    private let writes: ReviewWrites
    private let viewer: @MainActor () -> String?
    private let ended: @MainActor () -> Void
    private let eventLine: @MainActor (String) -> Void

    // writes keeps the progress of each approval on its row. viewer gives the login of the last
    // good poll. ended asks for a poll. eventLine adds a line to the Event log.
    package init(
        store: ReviewsStore, github: GitHubClient, writes: ReviewWrites,
        viewer: @escaping @MainActor () -> String?,
        ended: @escaping @MainActor () -> Void = {},
        eventLine: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.store = store
        self.github = github
        self.writes = writes
        self.viewer = viewer
        self.ended = ended
        self.eventLine = eventLine
    }

    // Approve the PR. With no panel, a call while an approval of the PR runs sends nothing, and
    // gives the result of that approval when it ends. An approval of the Review panel sends its
    // post with the approval, and refuses while a write of the PR runs.
    package func approve(
        _ pr: PRKey, panel: PanelApproval? = nil, click: UserClick
    ) async throws(ApproveRefusal) {
        if let approval = writes.approval(pr) {
            guard panel == nil else { throw .busy }
            try await approval.value.get()
            return
        }
        guard store.isOpen, let viewer = viewer() else { throw .notReady }
        if writes.waitsForPoll(pr) {
            ended()
            throw .waitsForPoll
        }
        guard let mark = offeredMark(pr) else { throw .notSuggested }
        if let panel, panel.mark != mark { throw .notSuggested }
        // The result is nil while a send of a review of the PR runs. The mark of Claude's draft
        // does not let the user approve, and the Review panel sends one write at a time.
        let approval = writes.approve(pr) { () async throws(ApproveRefusal) -> String in
            try await self.send(pr, viewer: viewer, mark: mark, post: panel?.post, click: click)
        }
        guard let approval else { throw panel == nil ? .notSuggested : .busy }
        try await approval.value.get()
    }

    // The approval itself: the fresh read, the checks and the one write. The result is the head
    // commit that the write approved: the guard refuses a head that is not the reviewed one.
    private func send(
        _ pr: PRKey, viewer: String, mark: RecommendationMark, post: ReviewPost?,
        click: UserClick
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
        guard
            let write = ApproveGuard.write(fresh, pr: pr, mark: mark, post: post, click: click)
        else { throw .guardRefused }
        guard store.isOpen else { throw .notReady }
        let answer: Data
        do throws(GitHubError) {
            answer = try await github.write(write)
        } catch {
            throw failure(error, pr: pr, panel: post != nil)
        }
        let refusal = ApproveGuard.outcome(answer, of: write)
        if refusal?.mayHaveApproved == true, post != nil { writes.mayHaveGone(pr) }
        // The next poll shows the true state on GitHub.
        ended()
        if let refusal { throw refusal }
        return fresh.headSHA.hex
    }

    // The mark of the PR while Approve approves: a mark with no draft that lets the user approve,
    // and no round of the PR that runs or waits. Else nil.
    private func offeredMark(_ pr: PRKey) -> RecommendationMark? {
        let state = store.state
        guard let prState = state.prs[pr], let mark = prState.recommendation,
            ApproveGuard.isApprovable(mark), mark.reviewID == nil, prState.round == nil,
            !state.queue.contains(where: { $0.pr == pr })
        else { return nil }
        return mark
    }

    // The refusal of a write that failed. A write that GitHub can have made asks for a poll. For
    // an approval of the Review panel, the PR waits for that poll first.
    private func failure(_ error: GitHubError, pr: PRKey, panel: Bool) -> ApproveRefusal {
        if error.writeMayHaveHappened {
            event(
                "Reviews: Bifrost couldn't tell if GitHub saved the approval of \(pr.text). It "
                    + "said: \(error.message)")
            if panel { writes.mayHaveGone(pr) }
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
