// The progress and the result of the review writes of the To review rows
// (docs/behaviour/reviews.md, "Approve" and "The Review panel"): an approval of the Approve button
// (ApproveFlow), a send of Claude's draft review in the Review panel (DraftFlow) and a send of
// Claude's findings in the Review panel (FindingsFlow). One object serves the open store, so the
// flows, the rows and the Review panel read one model of a write on a row.
// - A PR has at most one write that runs. A second Approve waits for the result of the approval
//   that runs. Another write of the PR while one runs sends nothing.
// - The progress of each write shows on its row (ReviewWriteProgress): running while the reads
//   and the writes run, then confirmed for the time of hold on the injected clock after GitHub
//   confirmed it. A refusal ends the progress at once. While a PR has a progress, its row stays
//   when a poll drops the PR (held, ReviewRows.holding). At the end of a progress, progressEnded
//   builds the rows again, so such a row goes.
// - After GitHub confirmed a write, the To review row says You approved, You requested changes or
//   You commented until a poll shows that review on the head (reviewedHere). GitHub can take a
//   moment to list a new review, and the row must not offer the same write again in that time.
//   A new review round of the PR also ends it (forget): the user acts on the request again.
// - A review write of the findings form that GitHub may have made is never sent again by itself.
//   The PR then waits for a good answer of a poll that started after the result (waitsForPoll),
//   and the form sends nothing for it in that time.
// - A poll can't see a plain comment, so an unsure Comment waits for a check of the user's own
//   reviews on the PR instead, which runs after each good poll. If GitHub has it, the row says
//   You commented and nothing goes again for that head; if a good read doesn't find it, the wait
//   ends; if the read fails, the next poll tries again.
import BifrostFoundation
import Foundation
import Observation

@MainActor
@Observable
package final class ReviewWrites {
    // The time that a row shows the result of a write and stays after GitHub confirmed it.
    nonisolated package static let hold = Duration.seconds(3)

    // The write of a PR: it runs, or GitHub confirmed it and the timer ends the time that its row
    // shows that.
    private enum Write {
        // An approval runs, with its result. A second Approve waits for it.
        case approving(Task<Result<Void, ApproveRefusal>, Never>)
        // A send of a review with the event runs. Its flow refuses a second action.
        case sending(DraftEvent)
        case confirmed(ReviewVerdict, TimerSlot)
    }

    // The write of each PR with a progress.
    private var writes: [PRKey: Write] = [:]

    // The review that the user gave here on each PR, after GitHub confirmed the write, until a
    // poll shows it. Only in memory: after a start, the polls decide.
    @ObservationIgnored private var reviewedHeads: [PRKey: ConfirmedReview] = [:]

    // The PRs whose last review write of the findings form may have gone, each with the number of
    // the last poll that started before its result. Only in memory.
    private var unsure: [PRKey: Int] = [:]

    // An unsure Comment of the findings form: the head it went on and when we heard back.
    private struct UnsureComment: Equatable {
        let head: String
        let at: Date
    }

    // The unsure Comments that no check has settled yet, by PR. Only in memory.
    private var unsureComments: [PRKey: UnsureComment] = [:]
    // The heads that a check found an unsure Comment of the user on, by PR. Nothing of the
    // findings form goes again for that head.
    private var foundComments: [PRKey: String] = [:]
    // The check of each PR while it runs. A test waits for it.
    @ObservationIgnored private var checks: [PRKey: Task<Void, Never>] = [:]

    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let polls: @MainActor () -> PollCount
    @ObservationIgnored private let progressEnded: @MainActor () -> Void
    @ObservationIgnored private let ownReviews: @MainActor (PRKey) async -> [ViewerOpinion]?
    @ObservationIgnored private let now: () -> Date

    // The clock runs the time of hold. polls gives the polls of the watcher (ReviewsWatcher.polls).
    // With the default, no poll starts, so a wait for a poll never ends. progressEnded builds the
    // rows again, with no poll. ownReviews reads the user's own reviews on a PR for the check of an
    // unsure Comment, and gives nil when the read fails; with the default every check fails, so
    // such a wait never ends. now gives the wall time.
    package init(
        clock: any Clock<Duration>, polls: @escaping @MainActor () -> PollCount = { PollCount() },
        progressEnded: @escaping @MainActor () -> Void = {},
        ownReviews: @escaping @MainActor (PRKey) async -> [ViewerOpinion]? = { _ in nil },
        now: @escaping () -> Date = Date.init
    ) {
        self.clock = clock
        self.polls = polls
        self.progressEnded = progressEnded
        self.ownReviews = ownReviews
        self.now = now
    }

    // The progress of the write of the PR, or nil.
    package func progress(_ pr: PRKey) -> ReviewWriteProgress? {
        switch writes[pr] {
        case .approving?: .running(.approve)
        case .sending(let event)?: .running(ReviewVerdict(event))
        case .confirmed(let review, _)?: .confirmed(review)
        case nil: nil
        }
    }

    // The PRs whose write runs now.
    package var running: Set<PRKey> {
        Set(writes.keys.filter(isRunning))
    }

    // The PRs with a progress. Their rows stay when a poll drops them (ReviewRows.holding).
    package var held: Set<PRKey> { Set(writes.keys) }

    // The task of the timer of the confirmed write of the PR, or nil. A test waits for it.
    package func holdTask(_ pr: PRKey) -> Task<Void, Never>? {
        if case .confirmed(_, let timer)? = writes[pr] { timer.task } else { nil }
    }

    // The reviews of the user that GitHub confirmed and that the answer does not show yet, by PR,
    // each with its head commit (ToReviewRules: You approved, You requested changes and You
    // commented). A review that the answer shows on its head, a PR that is not in the answer and a
    // PR with a new head leave the list.
    package func reviewedHere(_ answer: PollAnswer) -> [PRKey: ConfirmedReview] {
        reviewedHeads = reviewedHeads.filter { pr, review in
            guard let request = answer.toReview.first(where: { $0.key == pr }),
                request.headSHA == review.head
            else { return false }
            return ToReviewRules.reviewOnHead(request.viewerReviews, head: review.head)
                != review.verdict
        }
        return reviewedHeads
    }

    // A new review round of the PR starts (ReviewRounds.reviewStarted): the user acts on the
    // request again, so the review that GitHub confirmed here no longer decides the row. The
    // round and the polls give the state again, so the draft of the new round shows at its end.
    // A poll never shows a comment, so without this a kept comment would hide that draft until
    // the head moves.
    package func forget(_ pr: PRKey) {
        reviewedHeads[pr] = nil
        foundComments[pr] = nil
    }

    // True while a review write of the findings form of the PR may have gone and we don't know
    // yet: until a poll that started after the result gave a good answer, or for an unsure
    // Comment until a check settles it.
    package func waitsForPoll(_ pr: PRKey) -> Bool {
        if unsureComments[pr] != nil { return true }
        guard let started = unsure[pr] else { return false }
        return polls().answered <= started
    }

    // True when a check found the unsure Comment of the findings form on this head of the PR, so
    // nothing of the form may go again for it.
    package func commented(_ pr: PRKey, on head: String) -> Bool {
        foundComments[pr] == head
    }

    // A Comment of the findings form on the head of the PR may have reached GitHub. A poll can't
    // show it, so the PR waits until a check of your own reviews settles it (checkComments).
    package func commentMayHaveGone(_ pr: PRKey, head: String) {
        unsureComments[pr] = UnsureComment(head: head, at: now())
    }

    // Check each unsure Comment against your own reviews on GitHub. The shell calls this after
    // each good poll, so the poll that a send asks for and a click on Refresh both check. A check
    // that still runs isn't started twice.
    package func checkComments() {
        for (pr, comment) in unsureComments where checks[pr] == nil {
            checks[pr] = Task { [weak self, ownReviews] in
                let reviews = await ownReviews(pr)
                self?.checked(pr, comment, reviews)
            }
        }
    }

    // The check of the PR while it runs, or nil. A test waits for it.
    package func checkTask(_ pr: PRKey) -> Task<Void, Never>? { checks[pr] }

    // A review of yours on that head from the time of the send on is the comment (or what GitHub
    // made of it): the row shows it with the usual You commented, and nothing goes again for that
    // head. A good read without one means it didn't go, so the wait ends. A failed read keeps the
    // wait for the next poll.
    private func checked(_ pr: PRKey, _ comment: UnsureComment, _ reviews: [ViewerOpinion]?) {
        checks[pr] = nil
        guard unsureComments[pr] == comment, let reviews else { return }
        unsureComments[pr] = nil
        let slack = Double(FindingsPlan.savedSlack.components.seconds)
        let since = comment.at.addingTimeInterval(-slack)
        guard let saved = FindingsPlan.savedReview(reviews, head: comment.head, since: since) else {
            return
        }
        reviewedHeads[pr] = ConfirmedReview(saved, head: comment.head)
        foundComments[pr] = comment.head
        progressEnded()
    }

    // A review write of the findings form of the PR may have gone: the PR waits for a good answer
    // of a poll that starts after now. A wait that a poll ended goes.
    package func mayHaveGone(_ pr: PRKey) {
        let count = polls()
        unsure = unsure.filter { count.answered <= $0.value }
        unsure[pr] = count.started
    }

    // MARK: - The writes

    // The approval of the PR that runs, or nil.
    func approval(_ pr: PRKey) -> Task<Result<Void, ApproveRefusal>, Never>? {
        if case .approving(let approval)? = writes[pr] { approval } else { nil }
    }

    // Start an approval of the PR: work runs in its own task and gives the head commit that GitHub
    // confirmed the approval of. nil when a write of the PR runs: then nothing starts. The task
    // runs on the main actor after this call stored it, so its end changes it.
    func approve(
        _ pr: PRKey, _ work: @escaping @MainActor () async throws(ApproveRefusal) -> String
    ) -> Task<Result<Void, ApproveRefusal>, Never>? {
        guard !isRunning(pr) else { return nil }
        stopHold(pr)
        let approval = Task { () async -> Result<Void, ApproveRefusal> in
            do throws(ApproveRefusal) {
                let head = try await work()
                self.confirmed(pr, .approve, head: head)
                return .success(())
            } catch {
                self.endProgress(pr)
                return .failure(error)
            }
        }
        writes[pr] = .approving(approval)
        return approval
    }

    // Send a review of the PR with the event: work runs the reads and the writes and gives the
    // head commit that the review is on. A write of the PR that runs refuses the send with busy,
    // and nothing is sent. The progress starts before the first suspension, so the click that
    // calls this shows it at once.
    func send<Failure: Error>(
        _ pr: PRKey, _ event: DraftEvent, busy: Failure,
        _ work: () async throws(Failure) -> String
    ) async throws(Failure) {
        guard !isRunning(pr) else { throw busy }
        stopHold(pr)
        writes[pr] = .sending(event)
        let head: String
        do throws(Failure) {
            head = try await work()
        } catch {
            endProgress(pr)
            throw error
        }
        confirmed(pr, ReviewVerdict(event), head: head)
    }

    // MARK: - The steps

    private func isRunning(_ pr: PRKey) -> Bool {
        switch writes[pr] {
        case .approving?, .sending?: true
        case .confirmed?, nil: false
        }
    }

    // A new write ends the time that the row shows an earlier one.
    private func stopHold(_ pr: PRKey) {
        if case .confirmed(_, let timer)? = writes[pr] { timer.stop() }
    }

    // GitHub confirmed the write of the review on the head of the PR. The row shows it for the
    // time of hold, then the state of the review until a poll shows it (reviewedHere). A refusal
    // ends the progress at once (endProgress).
    private func confirmed(_ pr: PRKey, _ review: ReviewVerdict, head: String) {
        reviewedHeads[pr] = ConfirmedReview(review, head: head)
        let timer = TimerSlot(clock: clock)
        writes[pr] = .confirmed(review, timer)
        timer.start(after: Self.hold) { [weak self] in self?.endProgress(pr) }
    }

    // Remove the progress of the PR, and build the rows again.
    private func endProgress(_ pr: PRKey) {
        writes[pr] = nil
        progressEnded()
    }
}
