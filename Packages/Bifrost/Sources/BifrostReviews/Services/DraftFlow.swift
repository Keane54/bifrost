// The Review panel of the To review tab (docs/behaviour/reviews.md, "The Review panel"): the user
// checks Claude's draft review (a Comment or a Request changes draft), edits it in Bifrost, and
// sends it, discards it or approves instead. Only a click of the user starts a write: each button
// makes the UserClick in its action. The edits stay in the panel until Send review.
// - The panel offers a draft while the PR has Claude's Comment or Request changes mark with a draft
//   review, and no round runs or waits (offeredMark).
// - The open reads the PR and the draft from GitHub (DraftQueries) and keeps what it showed
//   (OpenedDraft). Each action reads both again and refuses when they changed
//   (DraftEdits.refusal, DraftEdits.problem, DraftEdits.plan): a change on GitHub after the open
//   is never written over, and a delete never takes a comment that the panel didn't show.
// - Just before each edit of the summary or of a comment, a fresh read of the review checks that
//   it is still pending and the viewer's, because GitHub's update edits a submitted review too.
// - Each write goes through the guard (DraftEdits.write): only Claude's draft of the mark, on the
//   PR of the row and on the reviewed commit. A write that GitHub can have made is never sent
//   again by itself; a poll follows it, and each action that worked.
// - After a send or a discard the mark goes. Approve instead deletes the draft first, marks the
//   mark deleted, then approves the head with no text through the Approve button (ApproveFlow).
// - A send shows its progress on the row and in the panel (ReviewWrites.send): from the click to
//   the end of the writes, then the result for a short time after GitHub confirmed the submit.
//   After that, the row says You commented or You requested changes until a poll shows the
//   review. A refusal ends the progress at once.
import BifrostFoundation
import Foundation
import Observation

@MainActor
@Observable
package final class DraftFlow {
    // What the panel shows of Claude's mark: the recommendation, its reason, and whether the PR
    // changed after the review (then only Discard draft can go).
    package struct Shown: Sendable, Equatable {
        package var recommendation: Recommendation
        package var why: String
        package var headMoved: Bool
    }

    // The PR of the last open.
    package private(set) var pr: PRKey?
    // The mark and the draft that the open showed, or nil before a good open and after an action
    // that ended the draft.
    package private(set) var shown: Shown?
    // The summary and the comments in the panel, with the edits of the user.
    package var summary = ""
    package var comments: [DraftCommentEdit] = []
    // True while the open or an action runs.
    package private(set) var busy = false

    @ObservationIgnored private var mark: RecommendationMark?
    @ObservationIgnored private var opened: OpenedDraft?
    // The number of the last open. An open that ends after a newer one changes nothing.
    @ObservationIgnored private var opens = 0
    @ObservationIgnored private let store: ReviewsStore
    @ObservationIgnored private let github: GitHubClient
    @ObservationIgnored private let approver: ApproveFlow
    @ObservationIgnored private let writes: ReviewWrites
    @ObservationIgnored private let viewer: @MainActor () -> String?
    @ObservationIgnored private let ended: @MainActor () -> Void
    @ObservationIgnored private let eventLine: @MainActor (String) -> Void

    // approver approves for Approve instead. writes keeps the progress of a send on its row.
    // viewer gives the login of the last good poll. ended asks for a poll. eventLine adds a line
    // to the Event log.
    package init(
        store: ReviewsStore, github: GitHubClient, approver: ApproveFlow, writes: ReviewWrites,
        viewer: @escaping @MainActor () -> String?, ended: @escaping @MainActor () -> Void = {},
        eventLine: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.store = store
        self.github = github
        self.approver = approver
        self.writes = writes
        self.viewer = viewer
        self.ended = ended
        self.eventLine = eventLine
    }

    // True while the row still offers the draft that the open showed. False before a good open,
    // and after the mark changed (an action, a round, a newer draft of Claude).
    package var isCurrent: Bool {
        guard let pr, let mark else { return false }
        return offeredMark(pr) == mark
    }

    // Read Claude's draft of the PR from GitHub for the panel, with no edits.
    package func open(_ pr: PRKey) async throws(DraftRefusal) {
        opens += 1
        let number = opens
        self.pr = pr
        shown = nil
        mark = nil
        opened = nil
        summary = ""
        comments = []
        guard store.isOpen, let viewer = viewer(), let mark = offeredMark(pr) else {
            throw .notOffered
        }
        busy = true
        defer { busy = false }
        let fresh = try await readFresh(pr, viewer: viewer, mark: mark, needsHead: false)
        let draft = try await readDraft(pr, mark: mark)
        guard number == opens else { return }
        self.mark = mark
        opened = OpenedDraft(draft)
        shown = Shown(
            recommendation: mark.value, why: mark.why, headMoved: fresh.headSHA != mark.headSHA)
        summary = draft.body
        comments = DraftEdits.comments(draft, drafts: store.state.drafts)
    }

    // Send review: write the edits to the draft, then submit it with the event. The edits stay
    // after a failure, so the user can send again. The row and the panel show the progress from
    // the click on (ReviewWrites.send). A send of the PR that runs in another flow refuses this
    // one, and nothing is sent.
    package func send(_ event: DraftEvent, click: UserClick) async throws(DraftRefusal) {
        try await act { () async throws(DraftRefusal) in
            let (pr, mark, viewer) = try startWrite()
            try await writes.send(pr, event) { () async throws(DraftRefusal) -> String in
                let fresh = try await readFresh(pr, viewer: viewer, mark: mark, needsHead: true)
                let draft = try await readDraft(pr, mark: mark)
                guard offeredMark(pr) == mark, let opened else { throw .gone }
                let steps = try DraftEdits.plan(
                    draft, opened: opened, summary: summary, comments: comments, event: event
                ).get()
                for step in steps {
                    switch step {
                    case .body, .comment, .remove: try await checkPending(pr, mark: mark)
                    case .submit, .discard: break
                    }
                    try await write(
                        step, pr: pr, mark: mark, fresh: fresh, draft: draft, click: click)
                    remember(step)
                }
                // The review isn't a draft any more, so the mark goes.
                await setMark(pr, from: mark, to: nil)
                ended()
                // The submitted review is on the reviewed commit, which is the head of the PR
                // (DraftEdits.refusal with needsHead).
                return mark.headSHA.hex
            }
        }
    }

    // Discard draft: delete Claude's draft review. The mark goes.
    package func discard(click: UserClick) async throws(DraftRefusal) {
        try await act { () async throws(DraftRefusal) in
            try await delete(approve: false, click: click)
            ended()
        }
    }

    // Approve instead: delete Claude's draft review, mark the mark deleted, then approve the
    // reviewed commit with no text.
    package func approveInstead(click: UserClick) async throws(DraftRefusal) {
        try await act { () async throws(DraftRefusal) in
            let pr = try await delete(approve: true, click: click)
            do throws(ApproveRefusal) {
                try await approver.approve(pr, click: click)
            } catch {
                guard error.mayHaveApproved else {
                    // The delete is done, so a poll shows the row as it is now.
                    ended()
                    throw .insteadFailed
                }
                throw .insteadUnknown
            }
        }
    }

    // MARK: - The steps

    // Run an action: the panel waits while it runs, and a result that GitHub can have saved asks
    // for a poll. A second action while one runs sends nothing.
    private func act(_ work: () async throws(DraftRefusal) -> Void) async throws(DraftRefusal) {
        guard !busy else { throw .busy }
        busy = true
        defer { busy = false }
        do throws(DraftRefusal) {
            try await work()
        } catch {
            if error.mayHaveChanged { ended() }
            throw error
        }
    }

    // The start of a write: the row still offers the draft that the panel opened.
    private func startWrite() throws(DraftRefusal) -> (PRKey, RecommendationMark, String) {
        guard store.isOpen, let pr, let viewer = viewer(), let mark = offeredMark(pr),
            mark == self.mark, opened?.review == mark.reviewID
        else { throw .notOffered }
        return (pr, mark, viewer)
    }

    // Delete the draft of the mark. Approve instead needs the reviewed commit as the head, no
    // approval of the user on it yet, and CI that passed; it keeps the mark with deleted set. A
    // comment that the open didn't give stops the delete, because the panel didn't warn about it.
    @discardableResult
    private func delete(approve: Bool, click: UserClick) async throws(DraftRefusal) -> PRKey {
        let (pr, mark, viewer) = try startWrite()
        let fresh = try await readFresh(pr, viewer: viewer, mark: mark, needsHead: approve)
        let draft = try await readDraft(pr, mark: mark)
        guard offeredMark(pr) == mark, let opened else { throw .gone }
        if draft.comments.contains(where: { opened.comments[$0.id] == nil }) { throw .edited }
        if approve {
            if ToReviewRules.approvedOnHead(fresh.opinions, head: fresh.headSHA.hex) {
                throw .approveRefused(.alreadyApproved)
            }
            switch fresh.ci {
            case .failing?: throw .approveRefused(.ciFailing)
            case .running?: throw .approveRefused(.ciRunning)
            case .passed?, nil: break
            }
        }
        try await write(.discard, pr: pr, mark: mark, fresh: fresh, draft: draft, click: click)
        self.opened = nil
        shown = nil
        let deleted = RecommendationMark(
            value: mark.value, why: mark.why, headSHA: mark.headSHA, reviewID: nil, at: mark.at,
            deleted: true)
        await setMark(pr, from: mark, to: approve ? deleted : nil)
        return pr
    }

    // The mark of the PR while the row offers the draft: Claude's Comment or Request changes
    // mark with a draft review, and no round of the PR that runs or waits. Else nil.
    private func offeredMark(_ pr: PRKey) -> RecommendationMark? {
        let state = store.state
        guard let prState = state.prs[pr], let mark = prState.recommendation,
            mark.reviewID != nil, !ApproveGuard.isApprovable(mark), prState.round == nil,
            !state.queue.contains(where: { $0.pr == pr })
        else { return nil }
        return mark
    }

    // The PR as GitHub gives it now, checked for the action.
    private func readFresh(
        _ pr: PRKey, viewer: String, mark: RecommendationMark, needsHead: Bool
    ) async throws(DraftRefusal) -> FreshPR {
        let fresh: FreshPR
        do throws(GitHubError) {
            fresh = try await DraftQueries.fresh(pr, viewer: viewer, on: github)
        } catch {
            event("Reviews: GitHub couldn't load \(pr.text). It said: \(error.message)")
            throw .readFailed(error)
        }
        if let refusal = DraftEdits.refusal(fresh, viewer: viewer, mark: mark, needsHead: needsHead)
        {
            throw refusal
        }
        return fresh
    }

    // The draft of the mark as GitHub gives it now, checked.
    private func readDraft(_ pr: PRKey, mark: RecommendationMark) async throws(DraftRefusal)
        -> DraftRead
    {
        guard let review = mark.reviewID else { throw .gone }
        let draft: DraftRead
        do throws(GitHubError) {
            draft = try await DraftQueries.draft(review, on: github)
        } catch {
            event(
                "Reviews: GitHub couldn't load the draft review of \(pr.text). It said: "
                    + error.message)
            throw .readFailed(error)
        }
        if let problem = DraftEdits.problem(draft, mark: mark) { throw problem }
        return draft
    }

    // Just before an edit of the summary or of a comment: the review of the mark must still be
    // pending, by the viewer, on the reviewed commit.
    private func checkPending(_ pr: PRKey, mark: RecommendationMark) async throws(DraftRefusal) {
        guard let review = mark.reviewID else { throw .gone }
        let now: ReviewAnswer.ReviewNow
        do throws(GitHubError) {
            now = try await ReviewQueries.review(review, on: github)
        } catch {
            event(
                "Reviews: GitHub couldn't load the draft review of \(pr.text). It said: "
                    + error.message)
            throw .readFailed(error)
        }
        guard now.pending, now.ownedByViewer, now.commit == mark.headSHA else {
            throw .notPending
        }
    }

    // Send the one write of the step through the guard, and check the answer of GitHub.
    private func write(
        _ step: DraftStep, pr: PRKey, mark: RecommendationMark, fresh: FreshPR, draft: DraftRead,
        click: UserClick
    ) async throws(DraftRefusal) {
        guard
            let write = DraftEdits.write(
                step, pr: pr, mark: mark, fresh: fresh, draft: draft, click: click)
        else { throw .guardRefused }
        guard store.isOpen else { throw .notOffered }
        let answer: Data
        do throws(GitHubError) {
            answer = try await github.write(write)
        } catch {
            let refusal = DraftEdits.failure(error, of: step)
            event(
                refusal.mayHaveChanged
                    ? "Reviews: Bifrost couldn't tell if GitHub saved a change to the draft review "
                        + "of \(pr.text). It said: \(error.message)"
                    : "Reviews: GitHub didn't take a change to the draft review of \(pr.text). It "
                        + "said: \(error.message)")
            throw refusal
        }
        if let refusal = DraftEdits.outcome(answer, of: step, write: write) { throw refusal }
    }

    // After a good edit write, the opened draft holds the text that Bifrost wrote, so a second
    // Send after a partial failure does not take it for a change on GitHub.
    private func remember(_ step: DraftStep) {
        switch step {
        case .body(let text): opened?.body = text
        case .comment(let comment, let text): opened?.comments[comment] = text
        case .remove, .submit, .discard: break
        }
    }

    // Set the mark of the PR, while it is still the mark of the action. A failed save leaves the
    // change on GitHub, and the next poll shows it. The Event log gets a line for it.
    private func setMark(_ pr: PRKey, from mark: RecommendationMark, to next: RecommendationMark?)
        async
    {
        let saved = await store.update { state in
            guard state.prs[pr]?.recommendation == mark else { return }
            state.prs[pr]?.recommendation = next
        }
        if !saved { event("Reviews: Bifrost couldn't save the draft change of \(pr.text).") }
    }

    // A line for the Event log, with each secret hidden.
    private func event(_ text: String) {
        eventLine(TokenMask.mask(text, token: nil))
    }
}
