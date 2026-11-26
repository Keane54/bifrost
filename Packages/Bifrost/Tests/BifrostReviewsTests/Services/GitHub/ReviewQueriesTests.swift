// The reads of a review round (docs/behaviour/reviews.md, "Review rounds"): the pages of the
// context and of the threads, on the sample answers of Fixtures/. Each read is a query with its
// values in variables; no test reaches GitHub.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

// A GitHub of the test that gives the pages of each read in order, and records each query.
@MainActor
private final class PagedGitHub: GitHubAccess {
    var pages: [String: [Data]]
    private(set) var queries: [GitHubQuery] = []

    init(pages: [String: [Data]]) {
        self.pages = pages
    }

    @MainActor func read(_ query: GitHubQuery) async throws(GitHubError) -> Data {
        guard query.isRead else { throw .notSent }
        queries.append(query)
        guard var list = pages[query.name], !list.isEmpty else {
            throw .refused("No page for \(query.name).")
        }
        let page = list.removeFirst()
        pages[query.name] = list
        return page
    }

    @MainActor func write(_ write: GitHubWrite) async throws(GitHubError) -> Data {
        throw .notSent
    }

    @MainActor func fetch(_ read: GitHubRead) async throws(GitHubError) -> Data {
        throw .refused("No fetch in this test.")
    }
}

@MainActor
@Suite("the reads of a review round", .testTimeLimit)
struct ReviewQueriesTests {
    private func rereviewPages() throws -> [Data] {
        let file = try JSONDecoder().decode(
            JSONValue.self, from: try FixtureFiles.data("context-rereview"))
        let encoder = JSONEncoder()
        return try (file.object?["pages"]?.array ?? []).map { try encoder.encode($0) }
    }

    private let threads = Data(
        """
        {"data":{"repository":{"pullRequest":{"reviewThreads":{
          "pageInfo":{"hasNextPage":false,"endCursor":null},
          "nodes":[{"isResolved":false,"isOutdated":false,"path":"a.swift","line":3,
            "comments":{"nodes":[{"author":{"login":"user-v"},"body":"Why?","url":"u1"}]}}]
        }}}}}
        """.utf8)

    // A re-review reads the pages of the reviews of the viewer with its cursor, and the threads,
    // because the viewer has a submitted review. Page 1 reads the PR fields; page 2 does not.
    @Test func theContextReadsEachPageAndTheThreads() async throws {
        let github = PagedGitHub(pages: [
            ReviewQueries.contextName: try rereviewPages(), ReviewQueries.threadsName: [threads],
        ])
        let context = try await ReviewQueries.context(
            try ReviewData.pr(), viewer: "user-v", on: GitHubClient(access: github))
        #expect(context.reviews.map(\.state) == [.approved, .commented, .changesRequested])
        #expect(context.pending?.id == (try ReviewData.node("PRR_mine")))
        #expect(context.threads.map(\.url) == ["u1"])
        #expect(!context.truncated)
        let names = github.queries.map(\.name)
        #expect(names == ["reviewContext", "reviewContext", "reviewThreads"])
        #expect(github.queries[0].variables["head"] == .bool(true))
        #expect(github.queries[0].variables["after"] == .null)
        #expect(github.queries[1].variables["head"] == .bool(false))
        #expect(github.queries[1].variables["after"] == .string("CUR1"))
        #expect(github.queries[0].variables["login"] == .string("user-v"))
        #expect(github.queries[0].variables["number"] == .int(7))
        for query in github.queries {
            #expect(query.isRead)
            #expect(!query.text.contains("user-v") && !query.text.contains("Repo-A"))
        }
    }

    // A first review with no submitted review of the viewer reads no threads.
    @Test func aFirstReviewReadsNoThreads() async throws {
        let github = PagedGitHub(pages: [
            ReviewQueries.contextName: [try FixtureFiles.data("context-first")]
        ])
        let context = try await ReviewQueries.context(
            try ReviewData.pr(), viewer: "user-v", on: GitHubClient(access: github))
        #expect(context.threads.isEmpty)
        #expect(github.queries.map(\.name) == ["reviewContext"])
    }

    // A bad field of the linked issues goes to the log of the client one time in the run: a
    // second round reads the same fault and the client logs no new one.
    @Test func aBadLinkedIssueFieldGoesToTheLogOnce() async throws {
        let text =
            #"{"data":{"repository":{"pullRequest":{"state":"OPEN","#
            + #""headRefOid":"\#(String(repeating: "b", count: 40))","#
            + #""closingIssuesReferences":{"nodes":[{"title":"No number"}]}}}}}"#
        let github = PagedGitHub(pages: [
            ReviewQueries.contextName: [Data(text.utf8), Data(text.utf8)]
        ])
        let client = GitHubClient(access: github)
        #expect(client.loggedFaults.isEmpty)
        _ = try await ReviewQueries.context(try ReviewData.pr(), viewer: "user-v", on: client)
        #expect(client.loggedFaults == [.closingIssueNumber])
        #expect(client.newFaults([.closingIssueNumber]).isEmpty)
        _ = try await ReviewQueries.context(try ReviewData.pr(), viewer: "user-v", on: client)
        #expect(client.loggedFaults == [.closingIssueNumber])
    }

    // A failed page fails the whole read.
    @Test func aFailedPageFailsTheRead() async throws {
        let github = PagedGitHub(pages: [
            ReviewQueries.contextName: [try rereviewPages()[0]]
        ])
        await #expect(throws: GitHubError.refused("No page for reviewContext.")) {
            try await ReviewQueries.context(
                try ReviewData.pr(), viewer: "user-v", on: GitHubClient(access: github))
        }
    }

    // The fresh read of a review names it in a variable.
    @Test func theReadOfAReviewNamesItInAVariable() async throws {
        let answer = Data(#"{"data":{"node":{"state":"PENDING","viewerDidAuthor":true}}}"#.utf8)
        let github = PagedGitHub(pages: [ReviewQueries.reviewName: [answer]])
        let now = try await ReviewQueries.review(
            try ReviewData.node("PRR_mine"), on: GitHubClient(access: github))
        #expect(now.pending && now.ownedByViewer)
        #expect(github.queries.first?.variables == ["id": .string("PRR_mine")])
    }
}
