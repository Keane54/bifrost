// The read of the answers of the reads of a review round (docs/behaviour/reviews.md, "Review
// rounds"), on the sample answers of GitHub in Fixtures/.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@Suite("the answers of the review reads", .testTimeLimit)
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

    // The query asks for the issues that the PR closes, on page 1 only.
    @Test @MainActor func theQueryAsksForTheClosingIssues() {
        let text = ReviewQueries.contextText
        #expect(text.contains("closingIssuesReferences(first: 10) @include(if: $head)"))
        for field in ["number", "title", "body", "url", "repository { nameWithOwner }"] {
            #expect(text.contains(field), "\(field)")
        }
    }

    // The issues that the PR closes stay in the context. A missing or bad field, or a node with
    // no number, gives no issue and no failure.
    @Test func theLinkedIssuesStayAndABadFieldGivesNone() throws {
        func page(_ field: String) throws -> ReviewContext {
            let text =
                #"{"data":{"repository":{"pullRequest":{"state":"OPEN","#
                + #""headRefOid":"\#(String(repeating: "b", count: 40))"\#(field)}}}}"#
            let page = try ReviewAnswer.contextPage(
                Data(text.utf8), pr: try ReviewData.pr(), withHead: true
            ).get()
            return try #require(page.head)
        }
        let good = try page(
            #","closingIssuesReferences":{"nodes":["#
                + #"{"number":4,"title":"Retry","body":"Retry twice.","url":"https://x/4","#
                + #""repository":{"nameWithOwner":"o/r"}},{"title":"No number"}]}"#)
        #expect(
            good.linkedIssues == [
                LinkedIssue(
                    number: 4, repo: "o/r", title: "Retry", body: "Retry twice.",
                    url: "https://x/4")
            ])
        #expect(try page("").linkedIssues.isEmpty)
        #expect(try page(#","closingIssuesReferences":"bad""#).linkedIssues.isEmpty)
        #expect(try page(#","closingIssuesReferences":{"nodes":7}"#).linkedIssues.isEmpty)
    }

    // A missing or bad field of the linked issues gives a fault, each one time. A good list and an
    // empty list give none.
    @Test func aBadLinkedIssueFieldGivesAFault() throws {
        func faults(_ field: String) throws -> [WireFault] {
            let text =
                #"{"data":{"repository":{"pullRequest":{"state":"OPEN","#
                + #""headRefOid":"\#(String(repeating: "b", count: 40))"\#(field)}}}}"#
            return try ReviewAnswer.contextPage(
                Data(text.utf8), pr: try ReviewData.pr(), withHead: true
            ).get().faults
        }
        let issue =
            #"{"number":4,"title":"T","body":"B","url":"u","#
            + #""repository":{"nameWithOwner":"o/r"}}"#
        #expect(try faults(#","closingIssuesReferences":{"nodes":[\#(issue)]}"#).isEmpty)
        #expect(try faults(#","closingIssuesReferences":{"nodes":[]}"#).isEmpty)
        #expect(try faults("") == [.closingIssues])
        #expect(try faults(#","closingIssuesReferences":{"nodes":7}"#) == [.closingIssues])
        #expect(
            try faults(#","closingIssuesReferences":{"nodes":[{"title":"x"},3]}"#)
                == [.closingIssueNumber])
        #expect(
            try faults(#","closingIssuesReferences":{"nodes":[{"number":4}]}"#)
                == [
                    .closingIssueBody, .closingIssueRepo, .closingIssueTitle, .closingIssueURL,
                ])
        // A later page has no PR fields, so it has no fault of the issues.
        let later = try ReviewAnswer.contextPage(
            Data(#"{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[]}}}}}"#.utf8),
            pr: try ReviewData.pr(), withHead: false
        ).get()
        #expect(later.faults.isEmpty)
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
