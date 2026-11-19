// The read of the answers of the reads of a review round (docs/behaviour/reviews.md, "Review
// rounds"), on the sample answers of GitHub in Fixtures/.
import BifrostFoundation
import Foundation
import Testing

@testable import BifrostReviews

@Suite("the answers of the review reads", .timeLimit(.minutes(1)))
struct ReviewContextTests {
    // Page 1 gives the PR and the pending review of the viewer only: a pending review of
    // another person is not the viewer's.
    @Test func theFirstPageGivesThePRAndThePendingReviewOfTheViewer() throws {
        let page = try ReviewAnswer.contextPage(
            try FixtureFiles.data("context-first"), pr: try ReviewData.pr(), withHead: true
        ).get()
        let head = try #require(page.head)
        #expect(head.state == .open)
        #expect(head.headSHA == (try ReviewData.commit(String(repeating: "b", count: 40))))
        #expect(head.baseRef == "main")
        #expect(head.author == "user-d")
        #expect(head.pending == nil)
        #expect(page.reviews.isEmpty)
        #expect(page.next == nil)
    }

    // A re-review: the pending review of the viewer, the reviews with a reply-only review, and
    // the cursor of the next page.
    @Test func aReReviewGivesTheReviewsAndTheCursor() throws {
        let file = try JSONDecoder().decode(
            JSONValue.self, from: try FixtureFiles.data("context-rereview"))
        let pages = try #require(file.object?["pages"]?.array)
        let encoder = JSONEncoder()
        let first = try ReviewAnswer.contextPage(
            try encoder.encode(pages[0]), pr: try ReviewData.pr(), withHead: true
        ).get()
        #expect(first.head?.pending?.id == (try ReviewData.node("PRR_mine")))
        #expect(first.reviews.map(\.replyOnly) == [false, true])
        #expect(first.next == "CUR1")
        let second = try ReviewAnswer.contextPage(
            try encoder.encode(pages[1]), pr: try ReviewData.pr(), withHead: false
        ).get()
        #expect(second.head == nil)
        #expect(second.reviews.map(\.state) == [.changesRequested])
        #expect(second.next == nil)
    }

    // An answer with errors fails, also next to data, so a part of the data never looks whole.
    // A PR with no state is a bad answer.
    @Test func anAnswerWithErrorsFails() throws {
        let errors = Data(
            (#"{"data":{"repository":{"pullRequest":{"state":"OPEN"}}},"#
                + #""errors":[{"message":"Rate"}]}"#).utf8)
        #expect(
            ReviewAnswer.contextPage(errors, pr: try ReviewData.pr(), withHead: true)
                == .failure(.refused("Rate")))
        let noState = Data(#"{"data":{"repository":{"pullRequest":{}}}}"#.utf8)
        #expect(
            ReviewAnswer.contextPage(noState, pr: try ReviewData.pr(), withHead: true)
                == .failure(.badAnswer))
    }

    // The threads that the viewer started, with any case of the login.
    @Test func theThreadsOfTheViewer() throws {
        let data = Data(
            """
            {"data":{"repository":{"pullRequest":{"reviewThreads":{
              "pageInfo":{"hasNextPage":false,"endCursor":null},
              "nodes":[
                {"isResolved":true,"isOutdated":false,"path":"a.swift","line":3,
                 "comments":{"nodes":[{"author":{"login":"User-V"},"body":"Why?","url":"u1"},
                                      {"author":{"login":"user-d"},"body":"Fixed.","url":"u2"}]}},
                {"isResolved":false,"isOutdated":true,"path":"b.swift","line":null,
                 "comments":{"nodes":[{"author":{"login":"user-d"},"body":"Note","url":"u3"}]}}
              ]}}}}}
            """.utf8)
        let page = try ReviewAnswer.threadsPage(data, viewer: "user-v").get()
        #expect(page.threads.count == 1)
        #expect(page.threads.first?.url == "u1")
        #expect(page.threads.first?.comments.count == 2)
    }

    // The state of a review now.
    @Test func theStateOfAReviewNow() throws {
        let data = ReviewData.json([
            "data": [
                "node": [
                    "state": "PENDING", "viewerDidAuthor": true,
                    "commit": ["oid": .string(ReviewData.headHex)],
                ]
            ]
        ])
        let now = try ReviewAnswer.reviewNow(data).get()
        let head = try ReviewData.commit()
        #expect(now.pending && now.ownedByViewer && now.commit == head)
        let submitted = ReviewData.json(
            ["data": ["node": ["state": "COMMENTED", "viewerDidAuthor": true]]])
        #expect(try ReviewAnswer.reviewNow(submitted).get().pending == false)
    }
}
