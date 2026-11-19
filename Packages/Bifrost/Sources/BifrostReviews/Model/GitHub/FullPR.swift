// The full read of a PR of the user for a request round (docs/behaviour/reviews.md, "Request
// rounds"): the PR with every thread, comment and review, which RequestQueries reads with pages.
// The poll reads only the newest items, so a round chooses its work on these full lists. This file
// holds the values and the decode of one page; each list item is read leniently, as in the poll,
// so one bad item is left out. An answer with GraphQL errors fails, also when it has data, so a
// part of the data never looks whole.
import BifrostFoundation
import BifrostSessions
import Foundation

// A thread with the fields that only a round reads.
package struct FullThread: Sendable, Equatable {
    package var thread: PRThread
    // True when the code of the thread changed after its first comment.
    package var isOutdated: Bool
    // The part of the diff of the first comment. Empty when GitHub gives none.
    package var diffHunk: String
    package var viewerCanReply: Bool

    package init(thread: PRThread, isOutdated: Bool, diffHunk: String, viewerCanReply: Bool) {
        self.thread = thread
        self.isOutdated = isOutdated
        self.diffHunk = diffHunk
        self.viewerCanReply = viewerCanReply
    }
}

package struct FullPR: Sendable, Equatable {
    // The latest decision of one reviewer. userID is nil for a bot.
    package struct Decision: Sendable, Equatable {
        package var login: String
        package var userID: NodeID?
        package var isBot: Bool
        package var state: ReviewState

        package init(login: String, userID: NodeID?, isBot: Bool, state: ReviewState) {
            self.login = login
            self.userID = userID
            self.isBot = isBot
            self.state = state
        }
    }

    package var key: PRKey
    // The GraphQL node of the PR.
    package var id: NodeID?
    package var url: String
    package var title: String
    package var body: String
    package var author: String
    package var state: PRLifecycle
    package var isCrossRepository: Bool
    package var defaultBranch: String
    package var baseRef: String
    package var baseSHA: CommitID?
    package var headRef: String
    package var headSHA: CommitID
    package var updatedAt: Date?
    package var threads: [FullThread]
    package var comments: [PRComment]
    package var reviews: [PRReview]
    package var decisions: [Decision]
    // The logins of the users with an open review request.
    package var requested: [String]
    // True when the viewer has a pending review on the PR.
    package var viewerPending: Bool
    // True when a list had more items than Bifrost reads.
    package var truncated: Bool

    package init(
        key: PRKey, id: NodeID? = nil, url: String = "", title: String = "", body: String = "",
        author: String, state: PRLifecycle = .open, isCrossRepository: Bool = false,
        defaultBranch: String = "main", baseRef: String = "main", baseSHA: CommitID? = nil,
        headRef: String = "feature", headSHA: CommitID, updatedAt: Date? = nil,
        threads: [FullThread] = [], comments: [PRComment] = [], reviews: [PRReview] = [],
        decisions: [Decision] = [], requested: [String] = [], viewerPending: Bool = false,
        truncated: Bool = false
    ) {
        self.key = key
        self.id = id
        self.url = url
        self.title = title
        self.body = body
        self.author = author
        self.state = state
        self.isCrossRepository = isCrossRepository
        self.defaultBranch = defaultBranch
        self.baseRef = baseRef
        self.baseSHA = baseSHA
        self.headRef = headRef
        self.headSHA = headSHA
        self.updatedAt = updatedAt
        self.threads = threads
        self.comments = comments
        self.reviews = reviews
        self.decisions = decisions
        self.requested = requested
        self.viewerPending = viewerPending
        self.truncated = truncated
    }

    package var prThreads: [PRThread] { threads.map(\.thread) }

    // The GitHub times of the comments of an item, oldest first: each comment of a thread, or the
    // one comment or review. An item that GitHub no longer has gives none.
    package func times(of id: NodeID) -> [Date] {
        if let thread = threads.first(where: { $0.thread.id == id }) {
            return thread.thread.comments.map(\.createdAt)
        }
        if let comment = comments.first(where: { $0.id == id }) { return [comment.createdAt] }
        if let review = reviews.first(where: { $0.id == id }) {
            return [review.submittedAt ?? PullRequestWire.never]
        }
        return []
    }

    // The newest GitHub time of the comments of an item, or nil when GitHub no longer has it.
    package func newestTime(of id: NodeID) -> Date? {
        times(of: id).max()
    }

    // The comment that asks for the item: the first comment of a thread, or the PR comment or the
    // review body. nil when GitHub no longer has it.
    package func request(of id: NodeID) -> (comment: PRComment, inThread: Bool)? {
        if let thread = threads.first(where: { $0.thread.id == id }) {
            return thread.thread.comments.first.map { ($0, true) }
        }
        if let comment = comments.first(where: { $0.id == id }) { return (comment, false) }
        if let review = reviews.first(where: { $0.id == id }) {
            let comment = PRComment(
                id: review.id, databaseID: review.databaseID, author: review.author,
                body: review.body, createdAt: review.submittedAt ?? PullRequestWire.never,
                url: review.url)
            return (comment, false)
        }
        return nil
    }

    // The first Copilot review of the PR, by the rule of the open items.
    package var firstCopilotReview: NodeID? {
        OpenItems.firstCopilotReview(reviews)
    }
}

// The pages of the full read, in the shapes that RequestQueries reads.
package enum FullPRAnswer {
    // The first page has the PR fields (head); a later page has only the reviews.
    package struct ContextPage: Sendable, Equatable {
        package var head: FullPR?
        package var reviews: [PRReview]
        package var next: String?
        // True when the list has more items but no cursor, or another list of the head was cut.
        package var cut: Bool
    }

    // A thread of a page, with the cursor of the next page of its comments. cut: its comments
    // have more items but no cursor.
    package struct ThreadEntry: Sendable, Equatable {
        package var thread: FullThread
        package var moreComments: String?
        package var cut: Bool
    }

    // One page of the threads.
    package struct ThreadsPage: Sendable, Equatable {
        package var threads: [ThreadEntry]
        package var next: String?
        package var cut: Bool
    }

    // One page of comments: the PR comments, or the later comments of one thread.
    package struct CommentsPage: Sendable, Equatable {
        package var comments: [PRComment]
        package var next: String?
        package var cut: Bool
    }

    // The first page of the context. withHead reads the PR fields: only page 1 has them. A first
    // page with no known state or no head commit is a bad answer.
    package static func contextPage(_ data: Data, pr: PRKey, withHead: Bool)
        -> Result<ContextPage, GitHubError>
    {
        pullRequest(data).flatMap { node in
            let reviews = (node.reviews?.nodes ?? []).compactMap(\.review)
            let (next, cut) = node.reviews?.next ?? CursorPage<ReviewWire>.end
            guard withHead else {
                return .success(ContextPage(reviews: reviews, next: next, cut: cut))
            }
            guard let state = node.state.flatMap(PRLifecycle.init(rawValue:)),
                let head = node.headRefOid.flatMap(CommitID.init)
            else { return .failure(.badAnswer) }
            let full = FullPR(
                key: pr, id: node.id.flatMap(NodeID.init), url: node.url ?? "",
                title: node.title ?? "", body: node.body ?? "", author: node.author?.login ?? "",
                state: state, isCrossRepository: node.isCrossRepository ?? false,
                defaultBranch: node.repository?.defaultBranchRef?.name ?? "",
                baseRef: node.baseRefName ?? "", baseSHA: node.baseRefOid.flatMap(CommitID.init),
                headRef: node.headRefName ?? "", headSHA: head,
                updatedAt: PullRequestWire.date(node.updatedAt),
                decisions: (node.latestOpinionatedReviews?.nodes ?? []).compactMap(\.decision),
                requested: (node.reviewRequests?.nodes ?? []).compactMap {
                    $0.requestedReviewer?.user
                },
                viewerPending: (node.pending?.nodes ?? []).contains { $0.viewerDidAuthor == true })
            let more =
                node.latestOpinionatedReviews?.hasNextPage == true
                || node.reviewRequests?.hasNextPage == true
            return .success(ContextPage(head: full, reviews: reviews, next: next, cut: cut || more))
        }
    }

    package static func threadsPage(_ data: Data) -> Result<ThreadsPage, GitHubError> {
        pullRequest(data).map { node in
            let threads = (node.reviewThreads?.nodes ?? []).compactMap {
                wire -> ThreadEntry? in
                guard let thread = wire.thread else { return nil }
                let (next, cut) = wire.comments?.next ?? CursorPage<ThreadCommentWire>.end
                return ThreadEntry(thread: thread, moreComments: next, cut: cut)
            }
            let (next, cut) = node.reviewThreads?.next ?? CursorPage<FullThreadWire>.end
            return ThreadsPage(threads: threads, next: next, cut: cut)
        }
    }

    package static func commentsPage(_ data: Data) -> Result<CommentsPage, GitHubError> {
        pullRequest(data).map { node in
            let (next, cut) = node.comments?.next ?? CursorPage<CommentWire>.end
            return CommentsPage(
                comments: (node.comments?.nodes ?? []).compactMap(\.comment), next: next, cut: cut)
        }
    }

    // A later page of the comments of a thread (the node read). A node that is not a thread is a
    // bad answer.
    package static func threadCommentsPage(_ data: Data) -> Result<CommentsPage, GitHubError> {
        body(data).flatMap { body in
            guard let list = body.node?.comments else { return .failure(.badAnswer) }
            let (next, cut) = list.next
            return .success(
                CommentsPage(
                    comments: list.nodes.compactMap(\.comment.comment), next: next, cut: cut))
        }
    }

    // MARK: - The wire

    private static func body(_ data: Data) -> Result<FullWire.Body, GitHubError> {
        guard let wire = try? JSONDecoder().decode(FullWire.self, from: data) else {
            return .failure(.badAnswer)
        }
        if let errors = wire.errors, !errors.isEmpty {
            let message = withoutHiddenCharacters(errors.first?.message ?? "").trimmed()
            return .failure(.refused(String(message.prefix(PollAnswer.errorLimit))))
        }
        guard let body = wire.data else { return .failure(.badAnswer) }
        return .success(body)
    }

    private static func pullRequest(_ data: Data) -> Result<FullWire.Pull, GitHubError> {
        body(data).flatMap { body in
            guard let pull = body.repository?.pullRequest else { return .failure(.badAnswer) }
            return .success(pull)
        }
    }
}

// The JSON of the pages of the full read. Each field is optional and lenient, as in the poll.
private struct FullWire: Decodable {
    struct Body: Decodable {
        struct Repository: Decodable { var pullRequest: Pull? }
        struct Node: Decodable { var comments: CursorPage<ThreadCommentWire>? }
        var repository: Repository?
        var node: Node?

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: AnyKey.self)
            repository = fields.lenient("repository")
            node = fields.lenient("node")
        }
    }

    struct Pull: Decodable {
        struct DefaultBranch: Decodable {
            struct Ref: Decodable { var name: String? }
            var defaultBranchRef: Ref?
        }
        struct Pending: Decodable { var viewerDidAuthor: Bool? }
        var id, url, title, body, state: String?
        var author: AuthorWire?
        var isCrossRepository: Bool?
        var baseRefName, baseRefOid, headRefName, headRefOid, updatedAt: String?
        var repository: DefaultBranch?
        var latestOpinionatedReviews: CursorPage<DecisionWire>?
        var reviewRequests: CursorPage<RequestWire>?
        var pending: CursorPage<Pending>?
        var reviews: CursorPage<ReviewWire>?
        var reviewThreads: CursorPage<FullThreadWire>?
        var comments: CursorPage<CommentWire>?

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: AnyKey.self)
            id = fields.lenient("id")
            url = fields.lenient("url")
            title = fields.lenient("title")
            body = fields.lenient("body")
            state = fields.lenient("state")
            author = fields.lenient("author")
            isCrossRepository = fields.lenient("isCrossRepository")
            baseRefName = fields.lenient("baseRefName")
            baseRefOid = fields.lenient("baseRefOid")
            headRefName = fields.lenient("headRefName")
            headRefOid = fields.lenient("headRefOid")
            updatedAt = fields.lenient("updatedAt")
            repository = fields.lenient("repository")
            latestOpinionatedReviews = fields.lenient("latestOpinionatedReviews")
            reviewRequests = fields.lenient("reviewRequests")
            pending = fields.lenient("pending")
            reviews = fields.lenient("reviews")
            reviewThreads = fields.lenient("reviewThreads")
            comments = fields.lenient("comments")
        }
    }

    var data: Body?
    var errors: [PollWire.Failure]?
}

// A list of GitHub with its cursor. A node that does not decode is left out.
private struct CursorPage<Node: Decodable>: Decodable {
    var nodes: [Node] = []
    var hasNextPage = false
    var endCursor: String?

    private enum Key: String, CodingKey { case nodes, pageInfo }
    private struct Info: Decodable {
        var hasNextPage: Bool?
        var endCursor: String?
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        nodes = ((try? container.decode([Lenient<Node>].self, forKey: .nodes)) ?? [])
            .compactMap(\.decoded)
        let info = try? container.decode(Info.self, forKey: .pageInfo)
        hasNextPage = info?.hasNextPage == true
        endCursor = info?.endCursor
    }

    // The value of a list that GitHub did not give: no next page.
    static var end: (next: String?, cut: Bool) { (nil, false) }

    // The cursor of the next page, and whether the list is cut: it has more items, but no
    // cursor to read them.
    var next: (next: String?, cut: Bool) {
        guard hasNextPage else { return (nil, false) }
        guard let cursor = endCursor, !cursor.isEmpty else { return (nil, true) }
        return (cursor, false)
    }
}

// A comment of a thread: the fields of a comment and the part of the diff it is on.
private struct ThreadCommentWire: Decodable {
    var comment: CommentWire
    var diffHunk: String?

    init(from decoder: any Decoder) throws {
        comment = try CommentWire(from: decoder)
        diffHunk = try decoder.container(keyedBy: AnyKey.self).lenient("diffHunk")
    }
}

private struct FullThreadWire: Decodable {
    var id: String?
    var isResolved: Bool?
    var isOutdated: Bool?
    var path: String?
    var line: Int?
    var viewerCanReply: Bool?
    var comments: CursorPage<ThreadCommentWire>?

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: AnyKey.self)
        id = fields.lenient("id")
        isResolved = fields.lenient("isResolved")
        isOutdated = fields.lenient("isOutdated")
        path = fields.lenient("path")
        line = fields.lenient("line")
        viewerCanReply = fields.lenient("viewerCanReply")
        comments = fields.lenient("comments")
    }

    // nil when the thread has no valid ID. A bad comment of the thread is left out.
    var thread: FullThread? {
        guard let id = id.flatMap(NodeID.init) else { return nil }
        let first = comments?.nodes.first
        let thread = PRThread(
            id: id, isResolved: isResolved ?? false, path: path ?? "", line: line,
            reviewID: first?.comment.pullRequestReview?.id.flatMap(NodeID.init),
            comments: (comments?.nodes ?? []).compactMap(\.comment.comment))
        return FullThread(
            thread: thread, isOutdated: isOutdated ?? false, diffHunk: first?.diffHunk ?? "",
            viewerCanReply: viewerCanReply ?? false)
    }
}

private struct DecisionWire: Decodable {
    struct Who: Decodable {
        var login: String?
        var typename: String?
        var id: String?
        private enum CodingKeys: String, CodingKey { case login, typename = "__typename", id }
    }
    var state: String?
    var author: Who?

    // nil for a review with an unknown state or no author.
    var decision: FullPR.Decision? {
        guard let state = state.flatMap(ReviewState.init(rawValue:)), let login = author?.login
        else { return nil }
        let user = author?.typename == "User"
        return FullPR.Decision(
            login: login, userID: user ? author?.id.flatMap(NodeID.init) : nil,
            isBot: author?.typename == "Bot", state: state)
    }
}
