// The reads of the Approve button and of the Review panel (docs/behaviour/reviews.md, "Approve"
// and "The Review panel") on FakeGitHub: each is a read, and the draft read pages through the
// comments up to its limit. No test reaches GitHub.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@MainActor
@Suite("the reads of the panels", .timeLimit(.minutes(1)))
struct DraftQueriesTests {
    // Both texts are reads with each value in a variable, and the fresh read gives the PR.
    @Test func theFreshReadIsARead() async throws {
        let pr = try ReviewData.pr()
        let github = FakeGitHub(answers: [
            DraftQueries.freshName: .success(
                DraftAnswers.fresh(pr, head: try ReviewData.commit(), ci: "PENDING"))
        ])
        let fresh = try await DraftQueries.fresh(
            pr, viewer: Rows.viewer, on: GitHubClient(access: github))
        #expect(fresh.key == pr && fresh.ci == .running && fresh.pending == nil)
        #expect(github.calls == [.read(DraftQueries.freshName)])
        for text in [DraftQueries.freshText, DraftQueries.draftText] {
            #expect(GitHubQuery(name: "q", text: text, variables: [:]).isRead)
            #expect(!text.contains(pr.repo.owner) && !text.contains(Rows.viewer))
        }
    }

    // The draft read joins the comments of its pages. After the last page that it reads, a draft
    // with more comments is marked truncated.
    @Test func theDraftReadPagesUpToItsLimit() async throws {
        let commit = try ReviewData.commit()
        func page(_ number: Int, next: String?) throws -> Result<Data, GitHubError> {
            .success(
                DraftAnswers.draft(
                    "PRR_claude", body: "Sum.", commit: commit,
                    comments: [
                        DraftRead.Comment(
                            id: try ReviewData.node("C\(number)"), path: "a", line: number,
                            body: "x")
                    ], next: next))
        }
        let review = try ReviewData.node("PRR_claude")
        let short = FakeGitHub()
        short.queued[DraftQueries.draftName] = [try page(1, next: "c1"), try page(2, next: nil)]
        let two = try await DraftQueries.draft(review, on: GitHubClient(access: short))
        #expect(two.comments.map(\.line) == [1, 2] && !two.truncated)
        let long = FakeGitHub()
        long.queued[DraftQueries.draftName] = try (1...4).map { try page($0, next: "c\($0)") }
        let cut = try await DraftQueries.draft(review, on: GitHubClient(access: long))
        #expect(cut.comments.count == DraftEdits.maxComments / DraftEdits.pageSize)
        #expect(cut.truncated)
        #expect(long.calls.count == 3)
    }
}
