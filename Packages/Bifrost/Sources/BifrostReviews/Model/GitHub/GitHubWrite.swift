// Every write that Bifrost can make on GitHub (docs/behaviour/reviews.md, "Safety"). This file is
// the only code that names a GraphQL mutation or builds the argv of a write (the forbidden rule
// github-write). No case merges, dismisses, unresolves, closes or reopens a PR, edits a PR or a
// ref, or edits or deletes a comment that is not a part of the pending draft of Claude (the rule
// github-never). An approve or a change of the draft needs a UserClick, which only the Reviews
// panels make (the rule user-click).
//
// Each value goes in a variable of the JSON on the stdin of gh, never in the text of a mutation
// and never in the argv. The event of an approve and of a submit is a part of the text of its
// mutation, not a variable.
import BifrostFoundation
import Foundation

// The proof that the user clicked a button of the Reviews panels. Only the panels and the tests
// make one (the forbidden rule user-click).
package struct UserClick: Sendable, Equatable {
    package init() {}
}

// The event of a submit of the draft of Claude in the Review panel. Approve has its own writes.
package enum DraftEvent: String, Sendable {
    case comment = "COMMENT", requestChanges = "REQUEST_CHANGES"
}

// The side of the diff of a comment.
package enum DiffSide: String, Sendable, Codable {
    case left = "LEFT", right = "RIGHT"
}

// A comment of a draft review on one line of the diff, or on a range of lines of one side: from
// startLine to line. The first line of a range is on the side of the comment.
package struct DraftComment: Sendable, Equatable, Codable {
    package var path: String
    package var line: Int
    package var side: DiffSide
    package var startLine: Int?
    package var body: String

    package init(path: String, line: Int, side: DiffSide, startLine: Int? = nil, body: String) {
        self.path = path
        self.line = line
        self.side = side
        self.startLine = startLine
        self.body = body
    }
}

// One file of a signed commit: the new bytes, or nil for a delete.
package struct FileChange: Sendable, Equatable {
    package var path: String
    package var contents: Data?

    package init(path: String, contents: Data?) {
        self.path = path
        self.contents = contents
    }
}

// A commit that GitHub makes and signs on the branch (createCommitOnBranch). GitHub refuses it
// when the head of the branch is not expectedHead, so it never replaces a commit.
package struct SignedCommit: Sendable, Equatable {
    package var repo: RepoName
    package var branch: BranchName
    package var expectedHead: CommitID
    package var headline: String
    package var body: String
    package var changes: [FileChange]

    package init(
        repo: RepoName, branch: BranchName, expectedHead: CommitID, headline: String, body: String,
        changes: [FileChange]
    ) {
        self.repo = repo
        self.branch = branch
        self.expectedHead = expectedHead
        self.headline = headline
        self.body = body
        self.changes = changes
    }
}

package enum GitHubWrite: Sendable, Equatable {
    // A pending review with its comments: REST POST, with no event, so GitHub keeps it pending.
    case createPendingReview(PRKey, commit: CommitID, body: String, comments: [DraftComment])
    // A thread on the pending review of the user.
    case addPendingThread(review: NodeID, DraftComment)
    // The body of the pending review of the user.
    case setPendingBody(review: NodeID, body: String)
    case replyToThread(thread: NodeID, body: String)
    case resolveThread(NodeID)
    case addPRComment(pr: NodeID, body: String)
    // union: true adds the reviewers and keeps the other review requests.
    case requestReviews(pr: NodeID, users: [NodeID])
    // The body holds the files, so it goes on stdin (--input -), never in the argv.
    case createSignedCommit(SignedCommit)
    // addPullRequestReview with the event APPROVE: an approval with no text.
    case approveCommit(pr: NodeID, commit: CommitID, click: UserClick)
    // submitPullRequestReview with the event APPROVE: the draft of Claude as an approval.
    case approveDraft(review: NodeID, click: UserClick)
    case editDraftBody(review: NodeID, body: String, click: UserClick)
    case editDraftComment(comment: NodeID, body: String, click: UserClick)
    case removeDraftComment(comment: NodeID, click: UserClick)
    case discardDraft(review: NodeID, click: UserClick)
    case submitDraft(review: NodeID, event: DraftEvent, click: UserClick)

    // The GraphQL field of the write, or nil for the REST create of a pending review.
    package var mutation: String? {
        switch self {
        case .createPendingReview: nil
        case .addPendingThread: "addPullRequestReviewThread"
        case .setPendingBody, .editDraftBody: "updatePullRequestReview"
        case .replyToThread: "addPullRequestReviewThreadReply"
        case .resolveThread: "resolveReviewThread"
        case .addPRComment: "addComment"
        case .requestReviews: "requestReviews"
        case .createSignedCommit: "createCommitOnBranch"
        case .approveCommit: "addPullRequestReview"
        case .approveDraft, .submitDraft: "submitPullRequestReview"
        case .editDraftComment: "updatePullRequestReviewComment"
        case .removeDraftComment: "deletePullRequestReviewComment"
        case .discardDraft: "deletePullRequestReview"
        }
    }

    // The argv of gh. Each write sends its JSON on stdin.
    package var arguments: [String] {
        guard case .createPendingReview(let pr, _, _, _) = self else {
            return ["api", "graphql", "--input", "-"]
        }
        // RepoName and PRKey allow only characters that are safe in a path.
        let path = "repos/\(pr.repo.owner)/\(pr.repo.name)/pulls/\(pr.number)/reviews"
        return ["api", "--method", "POST", path, "--input", "-"]
    }

    // The JSON on the stdin of gh.
    package var input: Data { GitHubJSON.encode(body) }

    // The object that GitHub gave back for the write, with fields such as id, node_id and state:
    // the review of a REST create, or the one object below the field of a GraphQL write (the
    // thread of a new thread, the review of a new body). nil for an answer with no such object.
    package func answerNode(_ answer: Data) -> [String: JSONValue]? {
        guard let root = (try? JSONDecoder().decode(JSONValue.self, from: answer))?.object else {
            return nil
        }
        guard let mutation else { return root }
        guard let field = root["data"]?.object?[mutation]?.object,
            field.count == 1, let node = field.values.first?.object
        else { return nil }
        return node
    }

    // The REST body of a new pending review. With no "event" key, GitHub keeps the review
    // pending. An empty summary and an empty list of comments are left out.
    private static func pendingReview(_ commit: CommitID, body: String, comments: [DraftComment])
        -> JSONValue
    {
        var fields: [String: JSONValue] = ["commit_id": .string(commit.hex)]
        if !body.trimmed().isEmpty { fields["body"] = .string(body) }
        if !comments.isEmpty {
            fields["comments"] = .array(
                comments.map { comment in
                    var fields: [String: JSONValue] = [
                        "path": .string(comment.path), "line": .int(comment.line),
                        "side": .string(comment.side.rawValue), "body": .string(comment.body),
                    ]
                    if let start = comment.startLine {
                        fields["start_line"] = .int(start)
                        fields["start_side"] = .string(comment.side.rawValue)
                    }
                    return .object(fields)
                })
        }
        return .object(fields)
    }

    // The body of a GraphQL write: the text of its one mutation and its variables.
    private static func request(_ text: String, _ variables: [String: JSONValue]) -> JSONValue {
        ["query": .string(text), "variables": .object(variables)]
    }

    // The JSON body of the write.
    private var body: JSONValue {
        switch self {
        case .createPendingReview(_, let commit, let body, let comments):
            Self.pendingReview(commit, body: body, comments: comments)
        case .addPendingThread(let review, let comment):
            // The first line of a range goes only with a range comment.
            Self.request(
                """
                mutation AddThread(
                  $review: ID!, $path: String!, $line: Int!, $side: DiffSide!, $startLine: Int,
                  $startSide: DiffSide, $body: String!
                ) {
                  addPullRequestReviewThread(input: {
                    pullRequestReviewId: $review, path: $path, line: $line, side: $side,
                    startLine: $startLine, startSide: $startSide, body: $body
                  }) { thread { id } }
                }
                """,
                [
                    "review": .string(review.text), "path": .string(comment.path),
                    "line": .int(comment.line), "side": .string(comment.side.rawValue),
                    "body": .string(comment.body),
                ].merging(
                    comment.startLine.map {
                        ["startLine": .int($0), "startSide": .string(comment.side.rawValue)]
                    } ?? [:]
                ) { first, _ in first }
            )
        case .setPendingBody(let review, let body), .editDraftBody(let review, let body, _):
            Self.request(
                """
                mutation SetBody($review: ID!, $body: String!) {
                  updatePullRequestReview(input: { pullRequestReviewId: $review, body: $body }) {
                    pullRequestReview { id state }
                  }
                }
                """,
                ["review": .string(review.text), "body": .string(body)]
            )
        case .replyToThread(let thread, let body):
            Self.request(
                """
                mutation ReplyToThread($thread: ID!, $body: String!) {
                  addPullRequestReviewThreadReply(input: {
                    pullRequestReviewThreadId: $thread, body: $body
                  }) { comment { id createdAt state } }
                }
                """,
                ["thread": .string(thread.text), "body": .string(body)]
            )
        case .resolveThread(let thread):
            Self.request(
                """
                mutation ResolveThread($thread: ID!) {
                  resolveReviewThread(input: { threadId: $thread }) { thread { id isResolved } }
                }
                """,
                ["thread": .string(thread.text)]
            )
        case .addPRComment(let pr, let body):
            Self.request(
                """
                mutation CommentOnPR($subject: ID!, $body: String!) {
                  addComment(input: { subjectId: $subject, body: $body }) {
                    commentEdge { node { id createdAt } }
                  }
                }
                """,
                ["subject": .string(pr.text), "body": .string(body)]
            )
        case .requestReviews(let pr, let users):
            Self.request(
                """
                mutation RequestReviews($pr: ID!, $users: [ID!]!) {
                  requestReviews(input: { pullRequestId: $pr, userIds: $users, union: true }) {
                    pullRequest { id }
                  }
                }
                """,
                ["pr": .string(pr.text), "users": .array(users.map { .string($0.text) })]
            )
        case .createSignedCommit(let commit):
            Self.request(
                """
                mutation CommitOnBranch($input: CreateCommitOnBranchInput!) {
                  createCommitOnBranch(input: $input) { commit { oid } }
                }
                """,
                ["input": Self.signedInput(commit)]
            )
        case .approveCommit(let pr, let commit, _):
            Self.request(
                """
                mutation ApproveCommit($pr: ID!, $commit: GitObjectID!) {
                  addPullRequestReview(input: {
                    pullRequestId: $pr, commitOID: $commit, event: APPROVE
                  }) { pullRequestReview { id state } }
                }
                """,
                ["pr": .string(pr.text), "commit": .string(commit.hex)]
            )
        case .approveDraft(let review, _):
            Self.request(
                """
                mutation ApproveDraft($review: ID!) {
                  submitPullRequestReview(input: {
                    pullRequestReviewId: $review, event: APPROVE
                  }) { pullRequestReview { id state } }
                }
                """,
                ["review": .string(review.text)]
            )
        case .editDraftComment(let comment, let body, _):
            Self.request(
                """
                mutation EditComment($comment: ID!, $body: String!) {
                  updatePullRequestReviewComment(input: {
                    pullRequestReviewCommentId: $comment, body: $body
                  }) { pullRequestReviewComment { id } }
                }
                """,
                ["comment": .string(comment.text), "body": .string(body)]
            )
        case .removeDraftComment(let comment, _):
            Self.request(
                """
                mutation RemoveComment($comment: ID!) {
                  deletePullRequestReviewComment(input: { id: $comment }) {
                    pullRequestReview { id }
                  }
                }
                """,
                ["comment": .string(comment.text)]
            )
        case .discardDraft(let review, _):
            Self.request(
                """
                mutation DiscardDraft($review: ID!) {
                  deletePullRequestReview(input: { pullRequestReviewId: $review }) {
                    pullRequestReview { id }
                  }
                }
                """,
                ["review": .string(review.text)]
            )
        case .submitDraft(let review, .comment, _):
            Self.request(
                """
                mutation SendComment($review: ID!) {
                  submitPullRequestReview(input: {
                    pullRequestReviewId: $review, event: COMMENT
                  }) { pullRequestReview { id state } }
                }
                """,
                ["review": .string(review.text)]
            )
        case .submitDraft(let review, .requestChanges, _):
            Self.request(
                """
                mutation SendChanges($review: ID!) {
                  submitPullRequestReview(input: {
                    pullRequestReviewId: $review, event: REQUEST_CHANGES
                  }) { pullRequestReview { id state } }
                }
                """,
                ["review": .string(review.text)]
            )
        }
    }

    // The CreateCommitOnBranchInput of a signed commit. Each file goes as base64. A headline
    // with no body sends no body.
    private static func signedInput(_ commit: SignedCommit) -> JSONValue {
        var message: [String: JSONValue] = ["headline": .string(commit.headline)]
        if !commit.body.isEmpty { message["body"] = .string(commit.body) }
        var additions: [JSONValue] = []
        var deletions: [JSONValue] = []
        for change in commit.changes {
            if let contents = change.contents {
                let encoded = contents.base64EncodedString()
                additions.append(["path": .string(change.path), "contents": .string(encoded)])
            } else {
                deletions.append(["path": .string(change.path)])
            }
        }
        return [
            "branch": [
                "repositoryNameWithOwner": .string(commit.repo.description),
                "branchName": .string(commit.branch.text),
            ],
            "expectedHeadOid": .string(commit.expectedHead.hex),
            "fileChanges": ["additions": .array(additions), "deletions": .array(deletions)],
            "message": .object(message),
        ]
    }
}
