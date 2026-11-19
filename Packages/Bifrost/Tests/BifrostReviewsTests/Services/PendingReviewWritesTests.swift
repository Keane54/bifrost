// The writes of the pending review of a review round (docs/behaviour/reviews.md, "Review
// rounds"), on FakeGitHub: each failure branch, and the fresh read before each write to a pending
// review of the user. No test reaches GitHub.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private typealias D = ReviewData

@MainActor
@Suite("the writes of the pending review", .testTimeLimit)
struct PendingReviewWritesTests {
    private let threadKey = "addPullRequestReviewThread"
    private let bodyKey = "updatePullRequestReview"
    private let first = DraftComment(path: "src/a.swift", line: 11, side: .right, body: "One.")
    private let second = DraftComment(path: "src/a.swift", line: 12, side: .right, body: "Two.")

    private func send(_ plan: PendingReviewPlan, on github: FakeGitHub)
        async throws -> Result<NodeID, RoundFailure>
    {
        let writes = PendingReviewWrites(github: GitHubClient(access: github))
        let (pr, head) = (try D.pr(), try D.commit())
        do throws(RoundFailure) {
            return .success(try await writes.send(plan, pr: pr, head: head))
        } catch {
            return .failure(error)
        }
    }

    private func created(_ state: String, id: JSONValue = "PRR_new") -> Result<Data, GitHubError> {
        .success(D.json(["state": .string(state), "node_id": id, "id": 1]))
    }

    // The answer of the fresh read of the pending review of the user.
    private func now(_ state: String = "PENDING", commit: JSONValue = .string(D.headHex))
        -> Result<Data, GitHubError>
    {
        .success(
            D.json([
                "data": [
                    "node": [
                        "state": .string(state), "viewerDidAuthor": true,
                        "commit": ["oid": commit],
                    ]
                ]
            ]))
    }

    private let thread: Result<Data, GitHubError> = .success(
        ReviewData.json(["data": ["addPullRequestReviewThread": ["thread": ["id": "PRRT_1"]]]]))

    private func body(_ state: String) -> Result<Data, GitHubError> {
        .success(
            D.json([
                "data": [
                    "updatePullRequestReview": [
                        "pullRequestReview": ["id": "PRR_mine", "state": .string(state)]
                    ]
                ]
            ]))
    }

    private func mine() throws -> NodeID { try D.node("PRR_mine") }

    private func writes(_ github: FakeGitHub) -> [GitHubWrite] {
        github.calls.compactMap { if case .write(let write) = $0 { write } else { nil } }
    }

    // A new review goes on the reviewed commit and must come back pending; else the round fails
    // and sends the user to GitHub. A refusal posts nothing; a write that may have happened is
    // never sent again.
    @Test func theCreateOfAPendingReview() async throws {
        let plan = PendingReviewPlan.create(body: "Summary.", comments: [first])
        let good = FakeGitHub(answers: [FakeGitHub.pendingReviewKey: created("PENDING")])
        #expect(try await send(plan, on: good) == .success(try D.node("PRR_new")))
        #expect(
            writes(good) == [
                .createPendingReview(
                    try D.pr(), commit: try D.commit(), body: "Summary.", comments: [first])
            ])
        let submitted = FakeGitHub(answers: [FakeGitHub.pendingReviewKey: created("COMMENTED")])
        #expect(try await send(plan, on: submitted) == .failure(.notPending))
        let noID = FakeGitHub(
            answers: [FakeGitHub.pendingReviewKey: created("PENDING", id: .null)])
        #expect(try await send(plan, on: noID) == .failure(.postUnknown(.badAnswer)))
        let refused = FakeGitHub(
            answers: [FakeGitHub.pendingReviewKey: .failure(.refused("Validation Failed"))])
        #expect(try await send(plan, on: refused) == .failure(.postRefused("Validation Failed")))
        let late = FakeGitHub(answers: [FakeGitHub.pendingReviewKey: .failure(.timedOut)])
        #expect(try await send(plan, on: late) == .failure(.postUnknown(.timedOut)))
        #expect(writes(late).count == 1)
    }

    // On a pending review of the user, each thread comes after a fresh read. A refusal of the
    // first thread posts nothing; a refusal after one thread says how many went in; a write that
    // may have happened stops the writes.
    @Test func theThreadsOfAPendingReviewOfTheUser() async throws {
        let plan = PendingReviewPlan.add(review: try mine(), comments: [first, second], body: nil)
        let good = FakeGitHub(answers: [ReviewQueries.reviewName: now(), threadKey: thread])
        #expect(try await send(plan, on: good) == .success(try mine()))
        let read = FakeGitHub.Call.read(ReviewQueries.reviewName)
        #expect(
            good.calls == [
                read, .write(.addPendingThread(review: try mine(), first)),
                read, .write(.addPendingThread(review: try mine(), second)),
            ])
        let refusedFirst = FakeGitHub(answers: [
            ReviewQueries.reviewName: now(), threadKey: .failure(.refused("Bad line")),
        ])
        #expect(try await send(plan, on: refusedFirst) == .failure(.postRefused("Bad line")))
        let refusedSecond = FakeGitHub(answers: [ReviewQueries.reviewName: now()])
        refusedSecond.queued[threadKey] = [thread, .failure(.refused("Bad line"))]
        #expect(
            try await send(plan, on: refusedSecond)
                == .failure(.partlyAdded(added: 1, total: 2, "Bad line")))
        let unknown = FakeGitHub(answers: [ReviewQueries.reviewName: now()])
        unknown.queued[threadKey] = [thread, .failure(.unknownOutcome("HTTP 502"))]
        #expect(
            try await send(plan, on: unknown)
                == .failure(.postUnknown(.unknownOutcome("HTTP 502"))))
        #expect(writes(unknown).count == 2)
    }

    // A submitted review, a review of another commit and a read that fails stop the writes before
    // the next one.
    @Test func theFreshReadStopsTheWrites() async throws {
        let plan = PendingReviewPlan.add(review: try mine(), comments: [first], body: "Below.")
        let submitted = FakeGitHub(answers: [threadKey: thread, bodyKey: body("PENDING")])
        submitted.queued[ReviewQueries.reviewName] = [now(), now("COMMENTED")]
        #expect(try await send(plan, on: submitted) == .failure(.notPending))
        #expect(writes(submitted) == [.addPendingThread(review: try mine(), first)])
        let moved = FakeGitHub(answers: [
            ReviewQueries.reviewName: now(commit: .string(D.oldHex)), threadKey: thread,
        ])
        #expect(try await send(plan, on: moved) == .failure(.notPending))
        #expect(writes(moved).isEmpty)
        let lost = FakeGitHub(answers: [threadKey: thread])
        lost.queued[ReviewQueries.reviewName] = [now(), .failure(.timedOut)]
        #expect(
            try await send(plan, on: lost)
                == .failure(
                    .partlyAdded(added: 1, total: 1, GitHubError.timedOut.message)))
        let noCommit = FakeGitHub(answers: [
            ReviewQueries.reviewName: now(commit: .null), threadKey: thread,
        ])
        #expect(try await send(plan, on: noCommit) == .failure(.notPending))
        #expect(writes(noCommit).isEmpty)
        let unread = FakeGitHub(answers: [ReviewQueries.reviewName: .failure(.timedOut)])
        #expect(try await send(plan, on: unread) == .failure(.readFailed(.timedOut)))
        #expect(writes(unread).isEmpty)
    }

    // The body of the pending review of the user: after all the threads, a refusal of the body
    // says that only the summary is missing; a body that GitHub did not keep pending fails.
    @Test func theBodyOfAPendingReviewOfTheUser() async throws {
        let plan = PendingReviewPlan.add(review: try mine(), comments: [first], body: "Below.")
        let good = FakeGitHub(answers: [
            ReviewQueries.reviewName: now(), threadKey: thread, bodyKey: body("PENDING"),
        ])
        #expect(try await send(plan, on: good) == .success(try mine()))
        #expect(writes(good).last == .setPendingBody(review: try mine(), body: "Below."))
        let refused = FakeGitHub(answers: [
            ReviewQueries.reviewName: now(), threadKey: thread,
            bodyKey: .failure(.refused("Too long")),
        ])
        #expect(try await send(plan, on: refused) == .failure(.summaryRefused("Too long")))
        let submitted = FakeGitHub(answers: [
            ReviewQueries.reviewName: now(), threadKey: thread, bodyKey: body("COMMENTED"),
        ])
        #expect(try await send(plan, on: submitted) == .failure(.notPending))
        let onlyBody = PendingReviewPlan.add(review: try mine(), comments: [], body: "Below.")
        let refusedFirst = FakeGitHub(answers: [
            ReviewQueries.reviewName: now(), bodyKey: .failure(.refused("Too long")),
        ])
        #expect(try await send(onlyBody, on: refusedFirst) == .failure(.postRefused("Too long")))
    }
}
