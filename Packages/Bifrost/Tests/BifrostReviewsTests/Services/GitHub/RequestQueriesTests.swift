// The full read of a PR of the user before a request round (docs/behaviour/reviews.md, "Request
// rounds"): the pages of each list, the later comments of a long thread, and the limits of the
// pages and of the calls. The pages come from Fixtures/ or from the test; no test reaches GitHub.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

// A GitHub of the test that answers each read with the next of its pages, or with answer, and
// records each query.
@MainActor
private final class AnsweringGitHub: GitHubAccess {
    private var pages: [String: [Data]] = [:]
    private let answer: @MainActor (GitHubQuery) throws(GitHubError) -> Data
    private(set) var queries: [GitHubQuery] = []

    init(_ answer: @escaping @MainActor (GitHubQuery) throws(GitHubError) -> Data) {
        self.answer = answer
    }

    // The pages of each read in order.
    init(pages: [String: [Data]]) {
        self.pages = pages
        answer = { query throws(GitHubError) in throw .refused("No page for \(query.name).") }
    }

    @MainActor func read(_ query: GitHubQuery) async throws(GitHubError) -> Data {
        guard query.isRead else { throw .notSent }
        queries.append(query)
        if var list = pages[query.name], !list.isEmpty {
            let page = list.removeFirst()
            pages[query.name] = list
            return page
        }
        return try answer(query)
    }

    @MainActor func write(_ write: GitHubWrite) async throws(GitHubError) -> Data {
        throw .notSent
    }

    func names() -> [String] { queries.map(\.name) }
}

// The answer of one page of a list of the PR, with nodes and a cursor.
private func page(_ list: String, nodes: [JSONValue], next: String?) -> Data {
    ReviewData.json([
        "data": [
            "repository": [
                "pullRequest": [
                    list: [
                        "nodes": .array(nodes),
                        "pageInfo": ["hasNextPage": .bool(next != nil), "endCursor": .text(next)],
                    ]
                ]
            ]
        ]
    ])
}

// A thread with one comment, whose comments have a next page when more is true.
private func thread(_ id: String, more: Bool) -> JSONValue {
    [
        "id": .string(id), "isResolved": false, "isOutdated": false, "path": "a.txt", "line": 1,
        "viewerCanReply": true,
        "comments": [
            "nodes": [
                [
                    "id": .string(id + "c"), "databaseId": 1, "author": ["login": "user-a"],
                    "authorAssociation": "MEMBER", "body": "Fix this.",
                    "createdAt": "2026-11-11T09:00:00Z",
                ]
            ],
            "pageInfo": ["hasNextPage": .bool(more), "endCursor": more ? "C1" : .null],
        ],
    ]
}

@MainActor
@Suite("the full read of a request round", .timeLimit(.minutes(1)))
struct RequestQueriesTests {
    // The read takes the PR fields with the first page of the reviews, then each page of the
    // threads with the later comments of a long thread, and the PR comments. Each value goes in a
    // variable.
    @Test func theFullReadReadsEveryPage() async throws {
        let github = AnsweringGitHub(pages: [
            RequestQueries.contextName: [try FixtureFiles.data("request-context-1")],
            RequestQueries.threadsName: [
                try FixtureFiles.data("request-threads-1"),
                try FixtureFiles.data("request-threads-2"),
            ],
            RequestQueries.threadCommentsName: [try FixtureFiles.data("thread-comments-1")],
            RequestQueries.commentsName: [try FixtureFiles.data("request-comments-1")],
        ])
        let pr = try ReviewData.pr("owner-a/repo-a#9")
        let full = try await RequestQueries.full(pr, client: GitHubClient(access: github))
        #expect(
            github.names() == [
                RequestQueries.contextName, RequestQueries.threadsName, RequestQueries.threadsName,
                RequestQueries.commentsName, RequestQueries.threadCommentsName,
            ])
        #expect(github.queries[0].variables["head"] == .bool(true))
        #expect(github.queries[0].variables["number"] == .int(9))
        #expect(github.queries[2].variables["after"] == .string("THREADS_1"))
        let long: [String: GraphQLValue] = ["id": .string("PRRT_long1"), "after": .string("LONG_1")]
        #expect(github.queries[4].variables == long)
        #expect(full.key == pr && full.id?.text == "PR_kwDOowner-a9" && full.state == .open)
        #expect(full.author == "user-d" && !full.isCrossRepository && full.defaultBranch == "main")
        #expect(full.headSHA.hex == String(repeating: "b", count: 40))
        #expect(full.baseSHA?.hex == String(repeating: "a", count: 40))
        #expect(full.updatedAt == (try Date("2026-11-12T10:00:00Z", strategy: .iso8601)))
        #expect(full.reviews.map(\.id.text) == ["PRR_copilot1", "PRR_user-a1"])
        #expect(full.firstCopilotReview?.text == "PRR_copilot1")
        #expect(
            full.decisions == [
                FullPR.Decision(
                    login: "user-a", userID: try ReviewData.node("U_kgDOuser-a"), isBot: false,
                    state: .changesRequested)
            ])
        #expect(full.requested == ["user-c"] && !full.viewerPending)
        #expect(
            full.threads.map(\.thread.id.text) == [
                "PRRT_user-a1", "PRRT_copilot1", "PRRT_old1", "PRRT_long1",
            ])
        #expect(full.threads[0].diffHunk.hasPrefix("@@ -10,3 +10,4 @@"))
        #expect(full.threads[0].thread.reviewID?.text == "PRR_user-a1")
        #expect(full.threads[2].isOutdated && full.threads[2].thread.line == nil)
        let longComments = full.threads[3].thread.comments
        #expect(longComments.count == 52 && longComments.last?.id.text == "PRRC_long52")
        #expect(full.comments.map(\.id.text) == ["IC_member1", "IC_none1"])
        #expect(full.comments[1].author.association == .none)
        #expect(!full.truncated)
        // The times and the request of an item, for the questions of a round.
        #expect(full.times(of: try ReviewData.node("PRRT_user-a1")).count == 2)
        #expect(full.request(of: try ReviewData.node("PRR_user-a1"))?.inThread == false)
        #expect(full.request(of: try ReviewData.node("IC_gone")) == nil)
    }

    // A list stops after 10 pages, and a list with more items but no cursor stops too: either
    // way the read is cut.
    @Test func aListOfMoreThanTenPagesIsCut() async throws {
        let context = try FixtureFiles.data("request-context-1")
        let comments = page("comments", nodes: [], next: nil)
        let endless = AnsweringGitHub { query throws(GitHubError) in
            switch query.name {
            case RequestQueries.contextName: return context
            case RequestQueries.threadsName:
                return page("reviewThreads", nodes: [thread("PRRT_x", more: false)], next: "N")
            default: return comments
            }
        }
        let pr = try ReviewData.pr("owner-a/repo-a#9")
        let full = try await RequestQueries.full(pr, client: GitHubClient(access: endless))
        #expect(endless.names().filter { $0 == RequestQueries.threadsName }.count == 10)
        #expect(full.truncated && full.threads.count == 10)
        let noCursor = AnsweringGitHub { query throws(GitHubError) in
            switch query.name {
            case RequestQueries.contextName: return context
            case RequestQueries.threadsName: return page("reviewThreads", nodes: [], next: nil)
            default:
                return ReviewData.json([
                    "data": [
                        "repository": [
                            "pullRequest": [
                                "comments": ["nodes": [], "pageInfo": ["hasNextPage": true]]
                            ]
                        ]
                    ]
                ])
            }
        }
        let cut = try await RequestQueries.full(pr, client: GitHubClient(access: noCursor))
        #expect(cut.truncated && noCursor.queries.count == 3)
    }

    // The long threads share what is left of 200 calls after the main lists, so a busy PR costs
    // at most 200 calls, and the read is cut.
    @Test func oneReadMakesAtMost200Calls() async throws {
        let context = try FixtureFiles.data("request-context-1")
        let threads = page(
            "reviewThreads", nodes: (0..<50).map { thread("PRRT_\($0)", more: true) }, next: nil)
        let comments = page("comments", nodes: [], next: nil)
        let more = ReviewData.json([
            "data": [
                "node": [
                    "comments": [
                        "nodes": [], "pageInfo": ["hasNextPage": true, "endCursor": "C2"],
                    ]
                ]
            ]
        ])
        let github = AnsweringGitHub { query throws(GitHubError) in
            switch query.name {
            case RequestQueries.contextName: context
            case RequestQueries.threadsName: threads
            case RequestQueries.commentsName: comments
            default: more
            }
        }
        let full = try await RequestQueries.full(
            try ReviewData.pr("owner-a/repo-a#9"), client: GitHubClient(access: github))
        #expect(github.queries.count == RequestQueries.maxCalls)
        #expect(full.truncated && full.threads.count == 50)
    }

    // An answer with errors fails also when it has data, and a first page with no head commit is
    // a bad answer.
    @Test func aBadAnswerFailsTheRead() async throws {
        let pr = try ReviewData.pr("owner-a/repo-a#9")
        let errors = AnsweringGitHub { _ throws(GitHubError) in
            ReviewData.json([
                "data": ["repository": ["pullRequest": ["state": "OPEN"]]],
                "errors": [["message": "Something went wrong."]],
            ])
        }
        await #expect(throws: GitHubError.refused("Something went wrong.")) {
            _ = try await RequestQueries.full(pr, client: GitHubClient(access: errors))
        }
        let noHead = AnsweringGitHub { _ throws(GitHubError) in
            ReviewData.json(["data": ["repository": ["pullRequest": ["state": "OPEN"]]]])
        }
        await #expect(throws: GitHubError.badAnswer) {
            _ = try await RequestQueries.full(pr, client: GitHubClient(access: noHead))
        }
    }
}
