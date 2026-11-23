// What a review round reads from GitHub about one PR (docs/behaviour/reviews.md, "Review
// rounds"): the PR, the pending review of the viewer, and the earlier reviews and threads of the
// viewer. ReviewQueries runs the reads; this file reads their answers. Each answer is read field by
// field. An answer with GraphQL errors fails, also when it has data, so a part of the data never
// looks whole.
import BifrostFoundation
import Foundation

// The state of a PR on GitHub.
package enum PRLifecycle: String, Sendable, Equatable {
    case open = "OPEN", closed = "CLOSED", merged = "MERGED"
}

// A review of the viewer on the PR.
package struct ViewerReview: Sendable, Equatable {
    package var state: ReviewState
    package var body: String
    package var submittedAt: Date?
    package var url: String
    package var commit: CommitID?
    // A COMMENTED review with no body and only replies.
    package var replyOnly: Bool

    package init(
        state: ReviewState, body: String = "", submittedAt: Date? = nil, url: String = "",
        commit: CommitID? = nil, replyOnly: Bool = false
    ) {
        self.state = state
        self.body = body
        self.submittedAt = submittedAt
        self.url = url
        self.commit = commit
        self.replyOnly = replyOnly
    }

    // A submitted review that is not a reply-only review. A pending review does not count.
    package var isReal: Bool { state != .pending && !replyOnly }
}

// A thread that the viewer started on the PR.
package struct ViewerThread: Sendable, Equatable {
    package struct Comment: Sendable, Equatable {
        package var author: String
        package var body: String

        package init(author: String, body: String) {
            self.author = author
            self.body = body
        }
    }

    package var path: String
    package var line: Int?
    package var isResolved: Bool
    package var isOutdated: Bool
    package var url: String
    package var comments: [Comment]

    package init(
        path: String, line: Int?, isResolved: Bool, isOutdated: Bool, url: String,
        comments: [Comment]
    ) {
        self.path = path
        self.line = line
        self.isResolved = isResolved
        self.isOutdated = isOutdated
        self.url = url
        self.comments = comments
    }
}

// An issue that the PR closes. Its text is from other people: it is material to review.
package struct LinkedIssue: Sendable, Equatable {
    package var number: Int
    // The repository of the issue, as owner/name.
    package var repo: String
    package var title: String
    package var body: String
    package var url: String

    package init(
        number: Int, repo: String = "", title: String = "", body: String = "", url: String = ""
    ) {
        self.number = number
        self.repo = repo
        self.title = title
        self.body = body
        self.url = url
    }
}

// The pending review of the viewer: Bifrost adds its comments to it as new threads.
package struct PendingDraft: Sendable, Equatable {
    package var id: NodeID
    package var body: String
    package var commit: CommitID?

    package init(id: NodeID, body: String, commit: CommitID?) {
        self.id = id
        self.body = body
        self.commit = commit
    }
}

package struct ReviewContext: Sendable, Equatable {
    package var pr: PRKey
    package var url: String
    package var title: String
    package var body: String
    package var author: String
    package var state: PRLifecycle
    package var baseRef: String
    package var headRef: String
    package var headSHA: CommitID
    // The issues that the PR closes. An empty list when there are none or the read gave no field.
    package var linkedIssues: [LinkedIssue]
    package var pending: PendingDraft?
    // The reviews of the viewer, in the order of GitHub.
    package var reviews: [ViewerReview]
    // The threads that the viewer started. Only a PR with a submitted review of the viewer reads
    // them.
    package var threads: [ViewerThread]
    // True when a list had more pages than Bifrost reads.
    package var truncated: Bool

    package init(
        pr: PRKey, url: String = "", title: String = "", body: String = "", author: String = "",
        state: PRLifecycle = .open, baseRef: String = "main", headRef: String = "",
        headSHA: CommitID, linkedIssues: [LinkedIssue] = [], pending: PendingDraft? = nil,
        reviews: [ViewerReview] = [],
        threads: [ViewerThread] = [], truncated: Bool = false
    ) {
        self.pr = pr
        self.url = url
        self.title = title
        self.body = body
        self.author = author
        self.state = state
        self.baseRef = baseRef
        self.headRef = headRef
        self.headSHA = headSHA
        self.linkedIssues = linkedIssues
        self.pending = pending
        self.reviews = reviews
        self.threads = threads
        self.truncated = truncated
    }

    // The newest review of the viewer that counts as a baseline: submitted, and not reply-only.
    // Two reviews at the same time give the later one in the list.
    package var lastSubmittedReview: ViewerReview? {
        var best: ViewerReview?
        for review in reviews where review.isReal {
            let time = review.submittedAt ?? .distantPast
            if best == nil || time >= best?.submittedAt ?? .distantPast { best = review }
        }
        return best
    }
}

// The answer of one page of a read, in the shapes that ReviewQueries reads.
package enum ReviewAnswer {
    // The first page of the context: the PR, its pending reviews, and the first reviews of the
    // viewer. A later page has only the reviews.
    package struct ContextPage: Sendable, Equatable {
        package var head: ReviewContext?
        package var reviews: [ViewerReview]
        package var next: String?
    }

    // One page of the threads of the PR, with only the threads that the viewer started.
    package struct ThreadsPage: Sendable, Equatable {
        package var threads: [ViewerThread]
        package var next: String?
    }

    // The state of a review now: GitHub's update edits a submitted review too, so Bifrost reads
    // the state just before each write to the pending review of the viewer.
    package struct ReviewNow: Sendable, Equatable {
        package var pending: Bool
        package var ownedByViewer: Bool
        package var commit: CommitID?
    }

    // The first page of the context. withHead reads the PR fields: only page 1 has them.
    package static func contextPage(_ data: Data, pr: PRKey, withHead: Bool)
        -> Result<ContextPage, GitHubError>
    {
        pullRequest(data).flatMap { node in
            let reviews = node["reviews"].nodes.compactMap(review)
            let next = cursor(node["reviews"])
            guard withHead else { return .success(ContextPage(reviews: reviews, next: next)) }
            guard let state = node["state"]?.string.flatMap(PRLifecycle.init(rawValue:)),
                let head = node["headRefOid"]?.string.flatMap(CommitID.init)
            else { return .failure(.badAnswer) }
            let pending = node["pending"].nodes.lazy.compactMap { item -> PendingDraft? in
                guard item["viewerDidAuthor"] == .bool(true),
                    let id = item["id"]?.string.flatMap(NodeID.init)
                else { return nil }
                return PendingDraft(
                    id: id, body: item["body"]?.string ?? "",
                    commit: item["commit"]?.object?["oid"]?.string.flatMap(CommitID.init))
            }.first
            let context = ReviewContext(
                pr: pr, url: node["url"]?.string ?? "", title: node["title"]?.string ?? "",
                body: node["body"]?.string ?? "",
                author: node["author"]?.object?["login"]?.string ?? "", state: state,
                baseRef: node["baseRefName"]?.string ?? "",
                headRef: node["headRefName"]?.string ?? "", headSHA: head,
                linkedIssues: node["closingIssuesReferences"].nodes.compactMap(linkedIssue),
                pending: pending)
            return .success(ContextPage(head: context, reviews: reviews, next: next))
        }
    }

    // One page of the threads. A thread counts when the viewer wrote its first comment (the case
    // of the login does not count).
    package static func threadsPage(_ data: Data, viewer: String)
        -> Result<ThreadsPage, GitHubError>
    {
        pullRequest(data).map { node in
            let list = node["reviewThreads"]
            let threads = list.nodes.compactMap { item -> ViewerThread? in
                let comments = item["comments"].nodes
                let author = comments.first?["author"]?.object?["login"]?.string ?? ""
                guard author.lowercased() == viewer.lowercased() else { return nil }
                return ViewerThread(
                    path: item["path"]?.string ?? "", line: item["line"]?.wholeNumber,
                    isResolved: item["isResolved"] == .bool(true),
                    isOutdated: item["isOutdated"] == .bool(true),
                    url: comments.first?["url"]?.string ?? "",
                    comments: comments.map {
                        ViewerThread.Comment(
                            author: $0["author"]?.object?["login"]?.string ?? "",
                            body: $0["body"]?.string ?? "")
                    })
            }
            return ThreadsPage(threads: threads, next: cursor(list))
        }
    }

    // The state of one review. A node that is not a review gives a bad answer.
    package static func reviewNow(_ data: Data) -> Result<ReviewNow, GitHubError> {
        fields(of: data).flatMap { fields in
            guard let node = fields["node"]?.object,
                let state = node["state"]?.string.flatMap(ReviewState.init(rawValue:))
            else { return .failure(.badAnswer) }
            return .success(
                ReviewNow(
                    pending: state == .pending,
                    ownedByViewer: node["viewerDidAuthor"] == .bool(true),
                    commit: node["commit"]?.object?["oid"]?.string.flatMap(CommitID.init)))
        }
    }

    // MARK: - The parts

    // The data of the answer. Errors fail with their first message, also next to data.
    static func fields(of data: Data) -> Result<[String: JSONValue], GitHubError> {
        guard let answer = (try? JSONDecoder().decode(JSONValue.self, from: data))?.object else {
            return .failure(.badAnswer)
        }
        if let errors = answer["errors"]?.array, !errors.isEmpty {
            let message = errors.first?.object?["message"]?.string ?? ""
            return .failure(.refused(String(message.prefix(200))))
        }
        guard let fields = answer["data"]?.object else { return .failure(.badAnswer) }
        return .success(fields)
    }

    // The pull request object of the answer.
    static func pullRequest(_ answer: Data) -> Result<[String: JSONValue], GitHubError> {
        fields(of: answer).flatMap { fields in
            guard let node = fields["repository"]?.object?["pullRequest"]?.object else {
                return .failure(.badAnswer)
            }
            return .success(node)
        }
    }

    // An issue that the PR closes. A node with no number is not an issue, so the read drops it.
    private static func linkedIssue(_ item: [String: JSONValue]) -> LinkedIssue? {
        guard let number = item["number"]?.wholeNumber else { return nil }
        return LinkedIssue(
            number: number, repo: item["repository"]?.object?["nameWithOwner"]?.string ?? "",
            title: item["title"]?.string ?? "", body: item["body"]?.string ?? "",
            url: item["url"]?.string ?? "")
    }

    private static func review(_ item: [String: JSONValue]) -> ViewerReview? {
        guard let state = item["state"]?.string.flatMap(ReviewState.init(rawValue:)) else {
            return nil
        }
        let body = item["body"]?.string ?? ""
        let comments = item["comments"].nodes
        return ViewerReview(
            state: state, body: body,
            submittedAt: item["submittedAt"]?.string.flatMap { try? Date($0, strategy: .iso8601) },
            url: item["url"]?.string ?? "",
            commit: item["commit"]?.object?["oid"]?.string.flatMap(CommitID.init),
            replyOnly: state == .commented && body.trimmed().isEmpty && !comments.isEmpty
                && comments.allSatisfy { ($0["replyTo"] ?? .null) != .null })
    }

    // The cursor of the next page, or nil when the list ends.
    static func cursor(_ list: JSONValue?) -> String? {
        guard let info = list?.object?["pageInfo"]?.object, info["hasNextPage"] == .bool(true)
        else { return nil }
        return info["endCursor"]?.string
    }
}

extension Optional where Wrapped == JSONValue {
    // The objects of the nodes list of a connection.
    var nodes: [[String: JSONValue]] {
        self?.object?["nodes"]?.array?.compactMap(\.object) ?? []
    }
}
