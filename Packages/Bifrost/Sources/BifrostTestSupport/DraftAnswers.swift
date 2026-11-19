import BifrostFoundation
import BifrostReviews
import Foundation

// The answers of GitHub for the tests of the Approve button, the Review panel and the Answer
// panel, for FakeGitHub: the fresh read of a PR (DraftQueries.fresh), the read of a draft review
// (DraftQueries.draft), the state of a review now (ReviewQueries.review) and the answer of a
// write. The answer of a write takes the field of its GraphQL write from GitHubWrite.mutation, so
// this file names no mutation.
package enum DraftAnswers {
    // A pending review in the fresh read.
    package struct Pending {
        package var id: String
        package var body: String
        package var commit: CommitID?
        package var mine: Bool

        package init(id: String, body: String = "", commit: CommitID?, mine: Bool = true) {
            self.id = id
            self.body = body
            self.commit = commit
            self.mine = mine
        }
    }

    // An opinion of the viewer in the fresh read.
    package struct Opinion {
        package var state: String
        package var commit: CommitID
        package var at: Date

        package init(state: String, commit: CommitID, at: Date) {
            self.state = state
            self.commit = commit
            self.at = at
        }
    }

    // The fresh read of the PR: open, by user-a, with no CI, no pending review and no opinion.
    package static func fresh(
        _ pr: PRKey, id: String = "PR_node7", url: String? = nil, state: String = "OPEN",
        author: String = "user-a", head: CommitID, ci: String? = nil, pending: Pending? = nil,
        opinions: [Opinion] = []
    ) -> Data {
        let commit: JSONValue =
            ci.map { ["oid": .string(head.hex), "statusCheckRollup": ["state": .string($0)]] }
            ?? ["oid": .string(head.hex), "statusCheckRollup": .null]
        let pendings: [JSONValue] = pending.map {
            [
                [
                    "id": .string($0.id), "body": .string($0.body),
                    "viewerDidAuthor": .bool($0.mine),
                    "commit": $0.commit.map { ["oid": .string($0.hex)] } ?? .null,
                ]
            ]
        } ?? []
        let opinionList: [JSONValue] = opinions.map {
            [
                "state": .string($0.state), "submittedAt": .string($0.at.formatted(.iso8601)),
                "commit": ["oid": .string($0.commit.hex)],
            ]
        }
        return json([
            "data": [
                "repository": [
                    "pullRequest": [
                        "id": .string(id), "url": .string(url ?? pr.webURL.absoluteString),
                        "state": .string(state), "headRefOid": .string(head.hex),
                        "author": ["login": .string(author)],
                        "commits": ["nodes": [["commit": commit]]],
                        "pending": ["nodes": .array(pendings)],
                        "opinions": ["nodes": .array(opinionList)],
                    ]
                ]
            ]
        ])
    }

    // One page of the read of a draft review: pending, by the viewer, on the commit.
    package static func draft(
        _ id: String, state: String = "PENDING", body: String, commit: CommitID?, mine: Bool = true,
        comments: [DraftRead.Comment], next: String? = nil
    ) -> Data {
        let nodes: [JSONValue] = comments.map { comment in
            [
                "id": .string(comment.id.text), "path": .string(comment.path),
                "line": comment.line.map(JSONValue.int) ?? .null,
                "startLine": comment.startLine.map(JSONValue.int) ?? .null,
                "originalLine": .null, "originalStartLine": .null,
                "diffHunk": .string(comment.hunk), "body": .string(comment.body),
            ]
        }
        let pageInfo: JSONValue =
            next.map { ["hasNextPage": true, "endCursor": .string($0)] } ?? ["hasNextPage": false]
        return json([
            "data": [
                "node": [
                    "id": .string(id), "state": .string(state), "body": .string(body),
                    "viewerDidAuthor": .bool(mine),
                    "commit": commit.map { ["oid": .string($0.hex)] } ?? .null,
                    "comments": ["pageInfo": pageInfo, "nodes": .array(nodes)],
                ]
            ]
        ])
    }

    // The state of a review now.
    package static func reviewNow(
        state: String = "PENDING", mine: Bool = true, commit: CommitID?
    ) -> Data {
        json([
            "data": [
                "node": [
                    "state": .string(state), "viewerDidAuthor": .bool(mine),
                    "commit": commit.map { ["oid": .string($0.hex)] } ?? .null,
                ]
            ]
        ])
    }

    // The answer of a write that GitHub made: its review with the state (or no state), or the
    // comment of an edit of a comment.
    package static func written(_ write: GitHubWrite, id: String = "PRR_done", state: String? = nil)
        -> Data
    {
        var object: [String: JSONValue] = ["id": .string(id)]
        if let state { object["state"] = .string(state) }
        let field = write.mutation ?? ""
        let key: String =
            if case .editDraftComment = write { "pullRequestReviewComment" } else {
                "pullRequestReview"
            }
        return json(["data": .object([field: .object([key: .object(object)])])])
    }

    package static func json(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }
}
