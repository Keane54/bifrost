import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

// The poll of Reviews, with the GitHub of the tests: no gh and no network.

@MainActor
@Suite("the GitHub client", .timeLimit(.minutes(1)))
struct GitHubClientTests {
    @Test func thePollAsksOnceForBothLists() async throws {
        let github = FakeGitHub(answers: ["poll": .success(try FixtureFiles.data("poll-basic"))])
        let answer = try await GitHubClient(access: github).poll()
        #expect(github.calls == [.read("poll")])
        #expect(answer.toReview.count == 3 && answer.mine.count == 2)
    }

    @Test func thePollQueryIsAReadWithTheTwoSearchesAndTheLimits() {
        let query = PollQuery.query
        #expect(query.isRead)
        #expect(
            query.variables == [
                "toReview": .string("is:pr is:open review-requested:@me archived:false"),
                "mine": .string("is:pr is:open author:@me archived:false"),
            ])
        // Each limit of the design is in the text.
        for part in [
            "first: 50", "reviews(first: 30)", "latestOpinionatedReviews(first: 20)",
            "reviewThreads(last: 20)", "comments(first: 10)", "comments(last: 30)",
            "contexts(first: 20)", "headRefName", "headRefOid", "REVIEW_REQUESTED_EVENT",
        ] {
            #expect(query.text.contains(part), "\(part)")
        }
        // The searches are values, never text of the query.
        #expect(!query.text.contains("review-requested"))
    }

    @Test func aPartialAnswerKeepsItsDataAndItsErrors() async throws {
        let partial = try FixtureFiles.edited("poll-basic") {
            $0["errors"] = [["message": "Slow."]]
        }
        let github = FakeGitHub(answers: ["poll": .success(partial)])
        let answer = try await GitHubClient(access: github).poll()
        #expect(answer.errors == ["Slow."] && answer.mine.count == 2)
    }

    @Test func aLoggedOutGhGivesNotLoggedIn() async {
        let github = FakeGitHub(answers: ["poll": .failure(.notLoggedIn)])
        await #expect(throws: GitHubError.notLoggedIn) {
            try await GitHubClient(access: github).poll()
        }
    }

    @Test func anAnswerWithNoDataFailsThePoll() async {
        let github = FakeGitHub(answers: ["poll": .success(Data("[]".utf8))])
        await #expect(throws: GitHubError.badAnswer) {
            try await GitHubClient(access: github).poll()
        }
    }
}
