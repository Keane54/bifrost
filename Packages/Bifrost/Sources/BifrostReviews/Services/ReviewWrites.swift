// The progress and the result of the review writes of the To review rows
// (docs/behaviour/reviews.md, "Approve" and "The Review panel"): an approval of the Approve button
// (ApproveFlow) and a send of Claude's draft review in the Review panel (DraftFlow). One object
// serves the open store, so the two flows, the rows and the Review panel read one model of a write
// on a row.
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
import BifrostFoundation
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
        // A send of Claude's draft review with the event runs. Its flow refuses a second action.
        case sending(DraftEvent)
        case confirmed(ReviewVerdict, TimerSlot)
    }

    // The write of each PR with a progress.
    private var writes: [PRKey: Write] = [:]

    // The review that the user gave here on each PR, after GitHub confirmed the write, until a
    // poll shows it. Only in memory: after a start, the polls decide.
    @ObservationIgnored private var reviewedHeads: [PRKey: ConfirmedReview] = [:]

    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let progressEnded: @MainActor () -> Void

    // The clock runs the time of hold. progressEnded builds the rows again, with no poll.
    package init(
        clock: any Clock<Duration>, progressEnded: @escaping @MainActor () -> Void = {}
    ) {
        self.clock = clock
        self.progressEnded = progressEnded
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

    // Send Claude's draft review of the PR with the event: work runs the reads and the writes and
    // gives the head commit that the submitted review is on. A write of the PR that runs refuses
    // the send, and nothing is sent. The progress starts before the first suspension, so the
    // click that calls this shows it at once.
    func send(
        _ pr: PRKey, _ event: DraftEvent, _ work: () async throws(DraftRefusal) -> String
    ) async throws(DraftRefusal) {
        guard !isRunning(pr) else { throw .busy }
        stopHold(pr)
        writes[pr] = .sending(event)
        let head: String
        do throws(DraftRefusal) {
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
