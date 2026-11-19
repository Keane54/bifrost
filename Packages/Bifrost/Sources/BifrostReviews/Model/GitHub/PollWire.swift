// The JSON of a poll answer, read leniently, and its change into PullRequest. One bad value
// never fails the answer: a bad item of a list is left out, and a bad PR is dropped by the
// caller. Every field is optional because GitHub can leave out any of them.
import BifrostFoundation
import Foundation

struct PollWire: Decodable {
    struct Failure: Decodable { var message: String? }
    struct Body: Decodable {
        var viewer: Viewer?
        var toReview: Search?
        var mine: Search?

        // A field of the wrong type reads as missing.
        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: AnyKey.self)
            viewer = fields.lenient(.viewer)
            toReview = fields.lenient(.toReview)
            mine = fields.lenient(.mine)
        }
    }
    struct Viewer: Decodable { var login: String? }

    var data: Body?
    var errors: [Failure]?

    // The list of a search: its PRs, still as wire values, and whether GitHub has more.
    struct Search: Decodable {
        var items: [Lenient<PullRequestWire>]
        var isCut: Bool

        init(from decoder: any Decoder) throws {
            let page = try Page<PullRequestWire>(from: decoder)
            items = page.items
            isCut = page.isCut
        }
    }
}

// The key of a field, by its name, for the lenient reads of a wire type.
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    static let viewer = AnyKey(stringValue: "viewer")
    static let toReview = AnyKey(stringValue: "toReview")
    static let mine = AnyKey(stringValue: "mine")
}

extension KeyedDecodingContainer where Key == AnyKey {
    // The value of a field, or nil when the field is missing, null or of the wrong type.
    func lenient<Value: Decodable>(_ key: AnyKey) -> Value? {
        (try? decodeIfPresent(Value.self, forKey: key)) ?? nil
    }

    func lenient<Value: Decodable>(_ name: String) -> Value? {
        lenient(AnyKey(stringValue: name))
    }
}

// A list of GitHub: nodes and the page info. A node that does not decode is left out of the
// list.
struct Page<Node: Decodable>: Decodable {
    var items: [Lenient<Node>] = []
    var isCut = false

    private enum Key: String, CodingKey { case nodes, pageInfo }
    private struct Info: Decodable { var hasNextPage, hasPreviousPage: Bool? }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        items = (try? container.decode([Lenient<Node>].self, forKey: .nodes)) ?? []
        let info = try? container.decode(Info.self, forKey: .pageInfo)
        isCut = info?.hasNextPage == true || info?.hasPreviousPage == true
    }

    var nodes: [Node] { items.compactMap(\.decoded) }
}

struct AuthorWire: Decodable {
    var login: String?
    var typename: String?
    private enum CodingKeys: String, CodingKey { case login, typename = "__typename" }
}

struct CommitWire: Decodable { var oid: String? }
struct IDWire: Decodable { var id: String? }

// A comment, a review or a thread comment: the fields that the three queries share.
struct CommentWire: Decodable {
    var id: String?
    var databaseId: Int?
    var author: AuthorWire?
    var authorAssociation: String?
    var body: String?
    var createdAt: String?
    var url: String?
    var pullRequestReview: IDWire?
}

struct ReviewWire: Decodable {
    var id: String?
    var databaseId: Int?
    var author: AuthorWire?
    var authorAssociation: String?
    var state: String?
    var body: String?
    var submittedAt: String?
    var commit: CommitWire?
    var url: String?
}

struct ThreadWire: Decodable {
    var id: String?
    var isResolved: Bool?
    var path: String?
    var line: Int?
    var comments: Page<CommentWire>?
}

struct ReviewerWire: Decodable {
    var typename: String?
    var login: String?
    var slug: String?
    private enum CodingKeys: String, CodingKey { case typename = "__typename", login, slug }
}

struct RequestWire: Decodable {
    var createdAt: String?
    var requestedReviewer: ReviewerWire?
}

struct CheckWire: Decodable {
    var typename: String?
    var conclusion: String?
    var state: String?
    private enum CodingKeys: String, CodingKey { case typename = "__typename", conclusion, state }
}

struct RollupWire: Decodable {
    var state: String?
    var contexts: Page<CheckWire>?
}

struct HeadCommitWire: Decodable {
    var oid: String?
    var statusCheckRollup: RollupWire?
}

struct PullRequestWire: Decodable {
    struct Repository: Decodable {
        struct Owner: Decodable { var login: String? }
        var name: String?
        var owner: Owner?
    }
    struct Commits: Decodable {
        struct Node: Decodable { var commit: HeadCommitWire? }
        var nodes: [Lenient<Node>]?
    }
    var number: Int?
    var title: String?
    var isDraft: Bool?
    var additions: Int?
    var deletions: Int?
    var createdAt: String?
    var updatedAt: String?
    var repository: Repository?
    var author: AuthorWire?
    var reviewDecision: String?
    var reviewRequests: Page<RequestWire>?
    var timelineItems: Page<RequestWire>?
    var pendingReviews: Page<IDWire>?
    var latestOpinionatedReviews: Page<ReviewWire>?
    var reviews: Page<ReviewWire>?
    var reviewThreads: Page<ThreadWire>?
    var comments: Page<CommentWire>?
    var commits: Commits?
    var headRefName: String?
    var headRefOid: String?
    var baseRefName: String?
    var isCrossRepository: Bool?

    // A field of the wrong type reads as missing, so the PR stays with that field empty.
    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: AnyKey.self)
        number = fields.lenient("number")
        title = fields.lenient("title")
        isDraft = fields.lenient("isDraft")
        additions = fields.lenient("additions")
        deletions = fields.lenient("deletions")
        createdAt = fields.lenient("createdAt")
        updatedAt = fields.lenient("updatedAt")
        repository = fields.lenient("repository")
        author = fields.lenient("author")
        reviewDecision = fields.lenient("reviewDecision")
        reviewRequests = fields.lenient("reviewRequests")
        timelineItems = fields.lenient("timelineItems")
        pendingReviews = fields.lenient("pendingReviews")
        latestOpinionatedReviews = fields.lenient("latestOpinionatedReviews")
        reviews = fields.lenient("reviews")
        reviewThreads = fields.lenient("reviewThreads")
        comments = fields.lenient("comments")
        commits = fields.lenient("commits")
        headRefName = fields.lenient("headRefName")
        headRefOid = fields.lenient("headRefOid")
        baseRefName = fields.lenient("baseRefName")
        isCrossRepository = fields.lenient("isCrossRepository")
    }
}

// The change of the wire values into the types of Reviews.
extension PullRequestWire {
    // nil when the PR cannot get a valid key: it is then dropped, because the state and the
    // writes take only a valid PR key.
    func pullRequest(viewer: String, isToReview: Bool) -> PullRequest? {
        guard let number, let owner = repository?.owner?.login, let name = repository?.name,
            let repo = RepoName(owner: owner, name: name),
            let key = PRKey(repo: repo, number: number)
        else { return nil }
        let created = Self.date(createdAt) ?? Self.never

        var users: [String] = [], teams: [String] = []
        for node in reviewRequests?.nodes ?? [] {
            if let user = node.requestedReviewer?.user { users.append(user) }
            if let team = node.requestedReviewer?.team { teams.append(team) }
        }
        let isDirect = users.contains { Self.same($0, viewer) }
        // A direct request counts only its own events, and a team request any team event.
        let requested = (timelineItems?.nodes ?? []).compactMap { event -> Date? in
            guard let reviewer = event.requestedReviewer, let at = Self.date(event.createdAt)
            else { return nil }
            let counts = isDirect ? reviewer.user.map { Self.same($0, viewer) } ?? false
                : reviewer.team != nil
            return counts ? at : nil
        }.max()

        var threadList: [PRThread] = [], threadCut = reviewThreads?.isCut ?? false
        for node in reviewThreads?.nodes ?? [] {
            guard let thread = node.thread else { continue }
            threadList.append(thread)
            threadCut = threadCut || (node.comments?.isCut ?? false)
        }

        let head = commits?.nodes?.first?.decoded?.commit
        let checks = head?.statusCheckRollup?.contexts
        let rollupFailed = Self.failedStates.contains(head?.statusCheckRollup?.state ?? "")
        let opinions = latestOpinionatedReviews?.nodes ?? []
        let headSHA = headRefOid ?? ""

        return PullRequest(
            key: key, title: title ?? "", author: author?.login ?? "ghost",
            isDraft: isDraft ?? false, additions: additions ?? 0, deletions: deletions ?? 0,
            createdAt: created, updatedAt: Self.date(updatedAt) ?? created,
            reviewDecision: reviewDecision.flatMap(ReviewDecision.init(rawValue:)),
            requestedUsers: users, requestedTeams: teams, isDirectRequest: isDirect,
            requestedAt: requested ?? created,
            reviews: (reviews?.nodes ?? []).compactMap(\.review),
            decisions: isToReview ? [] : opinions.compactMap(\.review),
            threads: threadList, comments: (comments?.nodes ?? []).compactMap(\.comment),
            // The rollup state counts the checks that the query does not read. A failed rollup
            // with no failed check in the first page gives one failed check.
            failedChecks: max(
                (checks?.nodes ?? []).filter(\.isFailed).count, rollupFailed ? 1 : 0),
            ci: CIState(
                rollup: head?.statusCheckRollup?.state, commit: head?.oid, head: headSHA),
            headRef: headRefName ?? "", headSHA: headSHA,
            baseRef: baseRefName ?? "", isCrossRepository: isCrossRepository ?? false,
            viewerPendingReviewID: pendingReviews?.nodes.first?.id.flatMap(NodeID.init),
            viewerReviews: isToReview ? opinions.compactMap { $0.opinion(of: viewer) } : [],
            approvals: isToReview ? opinions.filter { $0.approves(otherThan: viewer) }.count : 0,
            truncatedThreads: threadCut,
            truncatedReviews: (reviews?.isCut ?? false)
                || (latestOpinionatedReviews?.isCut ?? false),
            truncatedComments: comments?.isCut ?? false, truncatedChecks: checks?.isCut ?? false)
    }

    private static let failedStates: Set<String> = ["FAILURE", "ERROR"]
    // The time that a missing or bad time gives.
    static let never = Date(timeIntervalSince1970: 0)

    // GitHub ignores the case of a login.
    static func same(_ left: String, _ right: String) -> Bool {
        left.lowercased() == right.lowercased()
    }

    static func date(_ text: String?) -> Date? {
        text.flatMap { try? Date($0, strategy: .iso8601) }
    }

}

extension ReviewerWire {
    var user: String? { typename == "User" ? login : nil }
    var team: String? { typename == "Team" ? slug : nil }
}

extension CheckWire {
    // A failed check run, or a failed status. An optional check counts too.
    var isFailed: Bool {
        switch typename {
        case "CheckRun":
            ["FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED"]
                .contains(conclusion ?? "")
        case "StatusContext": ["FAILURE", "ERROR"].contains(state ?? "")
        default: false
        }
    }
}

extension AuthorWire {
    func author(association: String?) -> Author {
        Author(
            login: login ?? "ghost", isBot: typename == "Bot",
            association: association.flatMap(AuthorAssociation.init(rawValue:)) ?? .none)
    }
}

extension Optional where Wrapped == AuthorWire {
    func author(association: String?) -> Author {
        (self ?? AuthorWire()).author(association: association)
    }
}

extension CommentWire {
    // nil when the comment has no valid ID.
    var comment: PRComment? {
        guard let id = id.flatMap(NodeID.init) else { return nil }
        return PRComment(
            id: id, databaseID: databaseId ?? 0,
            author: author.author(association: authorAssociation), body: body ?? "",
            createdAt: PullRequestWire.date(createdAt) ?? PullRequestWire.never,
            url: url.flatMap(URL.init(string:)))
    }
}

extension ReviewWire {
    // nil when the review has no valid ID or no known state.
    var review: PRReview? {
        guard let id = id.flatMap(NodeID.init),
            let state = state.flatMap(ReviewState.init(rawValue:))
        else { return nil }
        return PRReview(
            id: id, databaseID: databaseId ?? 0,
            author: author.author(association: authorAssociation), state: state,
            body: body ?? "", submittedAt: PullRequestWire.date(submittedAt), commit: commit?.oid,
            url: url.flatMap(URL.init(string:)))
    }

    // The opinion of the viewer, or nil for a review of another author or with an unknown state.
    func opinion(of viewer: String) -> ViewerOpinion? {
        guard let login = author?.login, PullRequestWire.same(login, viewer),
            let state = state.flatMap(ReviewState.init(rawValue:))
        else { return nil }
        return ViewerOpinion(
            state: state, commit: commit?.oid, submittedAt: PullRequestWire.date(submittedAt))
    }

    // An approval of a reviewer that is not the viewer. A review with no author does not count.
    func approves(otherThan viewer: String) -> Bool {
        guard let login = author?.login else { return false }
        return state == "APPROVED" && !PullRequestWire.same(login, viewer)
    }
}

extension ThreadWire {
    // nil when the thread has no valid ID. A bad comment of the thread is left out.
    var thread: PRThread? {
        guard let id = id.flatMap(NodeID.init) else { return nil }
        let first = comments?.nodes.first
        return PRThread(
            id: id, isResolved: isResolved ?? false, path: path ?? "", line: line,
            reviewID: first?.pullRequestReview?.id.flatMap(NodeID.init),
            comments: (comments?.nodes ?? []).compactMap(\.comment))
    }
}
