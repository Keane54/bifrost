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

    // Approve the PR. A call while an approval of the PR runs sends nothing, and gives the
    // result of that approval when it ends.
    package func approve(_ pr: PRKey, click: UserClick) async throws(ApproveRefusal) {
        if let approval = writes.approval(pr) {
            try await approval.value.get()
            return
        }
        guard store.isOpen, let viewer = viewer() else { throw .notReady }
        guard let mark = offeredMark(pr) else { throw .notSuggested }
        // The result is nil while a send of Claude's draft of the PR runs. The mark of that draft
        // does not let the user approve.
        let approval = writes.approve(pr) { () async throws(ApproveRefusal) -> String in
            try await self.send(pr, viewer: viewer, mark: mark, click: click)
        }
        guard let approval else { throw .notSuggested }
        try await approval.value.get()
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
