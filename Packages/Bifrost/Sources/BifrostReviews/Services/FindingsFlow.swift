// The findings form of the Review panel (docs/behaviour/reviews.md, "The Review panel"): the user
// reads Claude's note and findings of an Approve mark, ticks the findings to post, can type a
// summary, and then approves, comments or requests changes. Only a click of the user starts a
// write: each button makes the UserClick in its action.
// - The form offers the findings while the PR has Claude's Approve mark with no draft, the mark
//   is not a mark of a deleted draft, and no round runs or waits (offeredMark).
// - The open reads only the state: the mark keeps the note and the findings. The bug and minor
//   findings start ticked, the nits do not.
// - Each action posts only the summary that the user typed and the findings that the user
//   ticked (FindingsPlan.post), as one write. The private note never goes into a write.
// - Approve goes through the Approve button flow (ApproveFlow) with the post: nothing ticked and
//   no summary is a plain approval with no text.
// - Comment and Request changes read the PR again just before the write and refuse when the PR
//   or the mark changed (FindingsPlan.refusal). The guard (FindingsPlan.write) sends the write
//   only to the PR of the row, on the reviewed commit, with no pending review of the user, and
//   with only line comments of the findings of the mark.
// - Request changes needs a summary that the user typed (FindingsPlan.problem).
// - A write that GitHub can have made is never sent again by itself; a poll follows it, and each
//   action that worked. Until a poll that started after such a result gives a good answer, the
//   form sends nothing for the PR, also after a new open (ReviewWrites.waitsForPoll). An approval
//   starts its wait and asks for its poll itself (ApproveFlow). A poll never shows a plain
//   comment, so an unsure Comment waits for a check of your own reviews instead, and once that
//   check finds it on GitHub the form sends nothing more for that head.
// - The row shows the progress of a send (ReviewWrites.send). After a good action the mark stays,
//   and the row shows You approved or You commented until a poll shows the review
//   (ReviewWrites.reviewedHere).
import BifrostFoundation
import Foundation
import Observation

@MainActor
@Observable
package final class FindingsFlow {
    // What the form shows of Claude's mark: the reason, the private note and each finding.
    package struct Shown: Sendable, Equatable {
        package var why: String
        package var note: String
        package var findings: [Finding]
    }

    // The PR of the last open.
    package private(set) var pr: PRKey?
    // The mark that the open showed, or nil before a good open.
    package private(set) var shown: Shown?
    // The indexes in shown.findings of the findings that the user ticks.
    package var ticked: Set<Int> = []
    // The summary that the user types.
    package var summary = ""
    // True while an action runs.
    package private(set) var busy = false

    @ObservationIgnored private var mark: RecommendationMark?
    @ObservationIgnored private let store: ReviewsStore
    @ObservationIgnored private let github: GitHubClient
    @ObservationIgnored private let approver: ApproveFlow
    @ObservationIgnored private let writes: ReviewWrites
    @ObservationIgnored private let viewer: @MainActor () -> String?
    @ObservationIgnored private let ended: @MainActor () -> Void
    @ObservationIgnored private let eventLine: @MainActor (String) -> Void

    // approver approves with the post. writes keeps the progress of a send on its row. viewer
    // gives the login of the last good poll. ended asks for a poll. eventLine adds a line to the
    // Event log.
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

    // True while the row still offers the mark that the open showed. False before a good open,
    // and after the mark changed (a new round, a newer mark of Claude).
    package var isCurrent: Bool {
        guard let pr, let mark else { return false }
        return offeredMark(pr) == mark
    }

    // What an action posts now: the summary and the ticked findings.
    package var post: ReviewPost {
        FindingsPlan.post(shown?.findings ?? [], ticked: ticked, summary: summary)
    }

    // True while a review write of the PR may have gone and no poll after it has shown the true
    // state on GitHub. Each action then sends nothing.
    package var waitsForPoll: Bool {
        guard let pr else { return false }
        return writes.waitsForPoll(pr)
    }

    // True when a check found an unsure Comment of yours on the head that this form shows, so
    // the form can't send anything more for it.
    package var commentFound: Bool {
        guard let pr, let mark else { return false }
        return writes.commented(pr, on: mark.headSHA.hex)
    }

    // Show the note and the findings of the mark of the PR, with the bug and minor findings
    // ticked and no summary. The mark is in the state, so the open reads nothing from GitHub.
    package func open(_ pr: PRKey) throws(FindingsRefusal) {
        self.pr = pr
        shown = nil
        mark = nil
        ticked = []
        summary = ""
        guard store.isOpen, let mark = offeredMark(pr) else { throw .notOffered }
        self.mark = mark
        shown = Shown(why: mark.why, note: mark.note, findings: mark.findings)
        ticked = Set(mark.findings.indices.filter { mark.findings[$0].kind != .nit })
    }

    // Approve with the post: the ticked findings and the summary go with the approval, and an
    // empty post is a plain approval with no text (ApproveFlow).
    package func approve(click: UserClick) async throws(FindingsRefusal) {
        try await act { () async throws(FindingsRefusal) in
            let (pr, mark, _) = try startWrite()
            let (post, summary) = (post, summary)
            if let problem = FindingsPlan.problem(post, summary: summary, event: .approve) {
                throw problem
            }
            // An approval from the row gets its own text; any other write is still sending.
            if writes.approval(pr) != nil { throw .approveRefused(.busy) }
            if writes.running.contains(pr) { throw .busy }
            // An approval that GitHub can have saved makes the PR wait for a poll. ApproveFlow
            // starts that wait before it asks for the poll, so the answer of that poll ends it.
            do throws(ApproveRefusal) {
                try await approver.approve(
                    pr, panel: PanelApproval(mark: mark, post: post), click: click)
            } catch {
                throw .approveRefused(error)
            }
        }
    }

    // Comment or Request changes: one review write of the post with the event. The row and the
    // form show the progress from the click on (ReviewWrites.send). A write of the PR that runs
    // refuses this one, and nothing is sent.
    package func send(_ event: DraftEvent, click: UserClick) async throws(FindingsRefusal) {
        try await act { () async throws(FindingsRefusal) in
            let (pr, mark, viewer) = try startWrite()
            let (post, summary) = (post, summary)
            let problem = FindingsPlan.problem(post, summary: summary, event: ReviewEvent(event))
            if let problem { throw problem }
            do throws(FindingsRefusal) {
                try await sendReview(
                    pr, event, mark: mark, viewer: viewer, post: post, click: click)
            } catch {
                // The poll that act asks for starts after this, so its answer ends the wait. A
                // poll can't see a comment, so an unsure Comment waits for the check instead.
                if error == .unknown, event == .comment {
                    writes.commentMayHaveGone(pr, head: mark.headSHA.hex)
                } else if error.mayHaveChanged {
                    writes.mayHaveGone(pr)
                }
                throw error
            }
        }
    }

    // MARK: - The steps

    // The one review write of Comment or Request changes, with the progress on the row
    // (ReviewWrites.send): the fresh read, the checks, the guard and the write.
    private func sendReview(
        _ pr: PRKey, _ event: DraftEvent, mark: RecommendationMark, viewer: String,
        post: ReviewPost, click: UserClick
    ) async throws(FindingsRefusal) {
        try await writes.send(pr, event, busy: .busy) {
            () async throws(FindingsRefusal) -> String in
            let fresh = try await readFresh(pr, viewer: viewer)
            if let refusal = FindingsPlan.refusal(fresh, viewer: viewer, mark: mark) {
                throw refusal
            }
            // A round can start or end during the read and change the mark.
            guard offeredMark(pr) == mark else { throw .notOffered }
            guard
                let write = FindingsPlan.write(
                    fresh, pr: pr, mark: mark, post: post, event: event, click: click)
            else { throw .guardRefused }
            guard store.isOpen else { throw .notOffered }
            let answer: Data
            do throws(GitHubError) {
                answer = try await github.write(write)
            } catch {
                throw failure(error, pr: pr)
            }
            // A refusal of the answer asks for the poll in act.
            if let refusal = FindingsPlan.outcome(answer, of: write, event: event) {
                throw refusal
            }
            ended()
            // The review is on the reviewed commit, which is the head of the PR
            // (FindingsPlan.refusal).
            return mark.headSHA.hex
        }
    }

    // Run an action: the form waits while it runs, and a result that GitHub can have saved asks
    // for a poll. A second action while one runs sends nothing.
    private func act(_ work: () async throws(FindingsRefusal) -> Void)
        async throws(FindingsRefusal)
    {
        guard !busy else { throw .busy }
        busy = true
        defer { busy = false }
        do throws(FindingsRefusal) {
            try await work()
        } catch {
            // ApproveFlow asks for the poll of an approval itself.
            let approval = if case .approveRefused = error { true } else { false }
            if error.mayHaveChanged, !approval { ended() }
            throw error
        }
    }

    // The start of a write: Reviews runs, a poll gave the viewer, the row still offers the mark
    // that the form opened, and no check found an unsure Comment of yours on its head. While an
    // earlier write of the PR may have gone, nothing goes.
    private func startWrite() throws(FindingsRefusal) -> (PRKey, RecommendationMark, String) {
        guard store.isOpen, let pr, let viewer = viewer(), let mark, offeredMark(pr) == mark,
            !writes.commented(pr, on: mark.headSHA.hex)
        else { throw .notOffered }
        if writes.waitsForPoll(pr) { throw .unknown }
        return (pr, mark, viewer)
    }

    // The mark of the PR while the form offers its findings: Claude's Approve mark with no draft
    // that is not a mark of a deleted draft, and no round of the PR that runs or waits. Else nil.
    private func offeredMark(_ pr: PRKey) -> RecommendationMark? {
        let state = store.state
        guard let prState = state.prs[pr], let mark = prState.recommendation,
            FindingsPlan.offers(mark), prState.round == nil,
            !state.queue.contains(where: { $0.pr == pr })
        else { return nil }
        return mark
    }

    // The PR as GitHub gives it now.
    private func readFresh(_ pr: PRKey, viewer: String) async throws(FindingsRefusal) -> FreshPR {
        do throws(GitHubError) {
            return try await DraftQueries.fresh(pr, viewer: viewer, on: github)
        } catch {
            event("Reviews: GitHub couldn't load \(pr.text). It said: \(error.message)")
            throw .readFailed(error)
        }
    }

    // The refusal of a write that failed, with its line for the Event log. A write that GitHub
    // can have made asks for a poll in act.
    private func failure(_ error: GitHubError, pr: PRKey) -> FindingsRefusal {
        let refusal = FindingsPlan.failure(error)
        switch (refusal, error) {
        case (.unknown, _):
            event(
                "Reviews: Bifrost can't tell whether GitHub saved the review of \(pr.text): "
                    + error.message)
        case (.refusedByGitHub, .refused(let line)):
            event("Reviews: GitHub rejected the review of \(pr.text): \(line)")
        default:
            break
        }
        return refusal
    }

    // A line for the Event log, with each secret hidden.
    private func event(_ text: String) {
        eventLine(TokenMask.mask(text, token: nil))
    }
}
