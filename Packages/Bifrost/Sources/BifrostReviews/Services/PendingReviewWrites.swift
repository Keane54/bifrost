// The writes of the pending review of a review round (docs/behaviour/reviews.md, "Review
// rounds"): the only GitHub writes of a review round. Only the user submits the review.
// - A new pending review goes on the reviewed commit, with no event, so GitHub keeps it pending.
//   An answer that is not a pending review fails as notPending.
// - On a pending review of the user, each comment is a new thread, then the body is set. Just
//   before each of these writes, a fresh read of that review checks that it is still pending, by
//   the viewer, on the reviewed commit: GitHub's update edits a submitted review too.
// - A refusal of GitHub stops the writes with its reason. A write that GitHub may have made
//   (GitHubError.writeMayHaveHappened) stops the writes as postUnknown, and nothing sends it
//   again by itself.
// The caller saves the posting phase of the round before it calls send.
import BifrostFoundation
import Foundation

@MainActor
package struct PendingReviewWrites {
    private let github: GitHubClient

    package init(github: GitHubClient) {
        self.github = github
    }

    // Send the writes of the plan on the PR. The result is the pending review that holds the
    // draft.
    package func send(_ plan: PendingReviewPlan, pr: PRKey, head: CommitID)
        async throws(RoundFailure) -> NodeID
    {
        switch plan {
        case .nothing:
            throw .noResult
        case .create(let body, let comments):
            let write = GitHubWrite.createPendingReview(
                pr, commit: head, body: body, comments: comments)
            let data = try await send(write) { .postRefused($0) }
            guard let answer = write.answerNode(data), let state = answer["state"]?.string else {
                throw .postUnknown(.badAnswer)
            }
            guard state == "PENDING" else { throw .notPending }
            guard let id = answer["node_id"]?.string.flatMap(NodeID.init) else {
                throw .postUnknown(.badAnswer)
            }
            return id
        case .add(let review, let comments, let body):
            var added = 0
            for comment in comments {
                try await checkPending(review, head: head, added: added, total: comments.count)
                let write = GitHubWrite.addPendingThread(review: review, comment)
                let data = try await send(write) { line in
                    added == 0
                        ? .postRefused(line)
                        : .partlyAdded(added: added, total: comments.count, line)
                }
                guard write.answerNode(data)?["id"]?.string != nil else {
                    throw .postUnknown(.badAnswer)
                }
                added += 1
            }
            if let body {
                try await checkPending(review, head: head, added: added, total: comments.count)
                let write = GitHubWrite.setPendingBody(review: review, body: body)
                let data = try await send(write) { line in
                    added == 0 ? .postRefused(line) : .summaryRefused(line)
                }
                guard let node = write.answerNode(data), node["id"]?.string != nil else {
                    throw .postUnknown(.badAnswer)
                }
                guard node["state"] == .string("PENDING") else { throw .notPending }
            }
            return review
        }
    }

    // Just before a write to the pending review of the user: it must still be pending, by the
    // viewer, on the reviewed commit. Else nothing more goes to it. A review with no commit is
    // refused too: the plan refuses it.
    private func checkPending(_ review: NodeID, head: CommitID, added: Int, total: Int)
        async throws(RoundFailure)
    {
        let now: ReviewAnswer.ReviewNow
        do throws(GitHubError) {
            now = try await ReviewQueries.review(review, on: github)
        } catch {
            throw added == 0
                ? .readFailed(error) : .partlyAdded(added: added, total: total, error.message)
        }
        guard now.pending, now.ownedByViewer, now.commit == head else {
            throw .notPending
        }
    }

    // Send the write. A refusal of GitHub gives the failure of refused. A write that GitHub may
    // have made is never sent again by itself: it gives postUnknown.
    private func send(
        _ write: GitHubWrite, refused: (String) -> RoundFailure
    ) async throws(RoundFailure) -> Data {
        do throws(GitHubError) {
            return try await github.write(write)
        } catch {
            if error.writeMayHaveHappened { throw .postUnknown(error) }
            if case .refused(let line) = error { throw refused(line) }
            throw refused(error.message)
        }
    }
}
