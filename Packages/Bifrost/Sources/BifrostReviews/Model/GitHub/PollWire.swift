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

    // The list of a search: its PRs, still as wire values, and whether it can lack PRs (GitHub
    // has more, or Bifrost can't read its nodes or its page info).
    struct Search: Decodable {
        var items: [Lenient<PullRequestWire>]
        var isCut: Bool
        // True when Bifrost can't read the nodes or the page info.
        var unread: Bool

        init(from decoder: any Decoder) throws {
            let page = try Page<PullRequestWire>(from: decoder)
            items = page.items
            isCut = page.mayLack
            unread = page.unread
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

    // True when the field is there and is not null, also when it has the wrong type.
    func present(_ name: String) -> Bool {
        let key = AnyKey(stringValue: name)
        return contains(key) && (try? decodeNil(forKey: key)) == false
    }
}

// A list of GitHub: nodes and the page info. A node that does not decode is left out of the
// list. Nodes or page info that Bifrost can't read never make the list look whole (mayLack).
struct Page<Node: Decodable>: Decodable {
    var items: [Lenient<Node>] = []
    // True when the page info says that GitHub has more items.
    var isCut = false
    // False when nodes is missing, null or not a list.
    var readNodes = false
    // False when pageInfo is missing, null or has no readable hasNextPage or hasPreviousPage.
    var readInfo = false

    private enum Key: String, CodingKey { case nodes, pageInfo }
    private struct Info: Decodable { var hasNextPage, hasPreviousPage: Bool? }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let list = try? container.decode([Lenient<Node>].self, forKey: .nodes)
        items = list ?? []
        readNodes = list != nil
        let info = try? container.decode(Info.self, forKey: .pageInfo)
        readInfo = info?.hasNextPage != nil || info?.hasPreviousPage != nil
        isCut = info?.hasNextPage == true || info?.hasPreviousPage == true
    }

    var nodes: [Node] { items.compactMap(\.decoded) }

    // True when Bifrost can't read the nodes or the page info. Only a list that the query reads
    // with its page info uses it.
    var unread: Bool { !readNodes || !readInfo }

    // True when the list can lack items: GitHub has more, or the list is unread.
    var mayLack: Bool { isCut || unread }
}

extension Optional {
    // True when a list that the query asks for is unread. A list that GitHub did not give, or
    // that has the wrong type, is unread too.
    func unread<Node>(asked: Bool = true) -> Bool where Wrapped == Page<Node> {
        map(\.unread) ?? asked
    }

    // True when a list that the query asks for can lack items: it is unread, or GitHub has more.
    func mayLack<Node>(asked: Bool = true) -> Bool where Wrapped == Page<Node> {
        map(\.mayLack) ?? asked
    }
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

// A node of the checks: a check run or a commit status. Each field reads leniently.
struct CheckWire: Decodable {
    struct Suite: Decodable {
        struct App: Decodable {
            var slug: String?

            init(from decoder: any Decoder) throws {
                slug = try decoder.container(keyedBy: AnyKey.self).lenient("slug")
            }
        }
        struct Run: Decodable {
            var databaseId: Int?

            init(from decoder: any Decoder) throws {
                databaseId = try decoder.container(keyedBy: AnyKey.self).lenient("databaseId")
            }
        }
        var app: App?
        var workflowRun: Run?

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: AnyKey.self)
            app = fields.lenient("app")
            workflowRun = fields.lenient("workflowRun")
        }
    }
    var typename: String?
    // A check run.
    var name: String?
    var status: String?
    var conclusion: String?
    var databaseId: Int?
    var detailsUrl: String?
    var checkSuite: Suite?
    // A commit status.
    var context: String?
    var state: String?
    var targetUrl: String?

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: AnyKey.self)
        typename = fields.lenient("__typename")
        name = fields.lenient("name")
        status = fields.lenient("status")
        conclusion = fields.lenient("conclusion")
        databaseId = fields.lenient("databaseId")
        detailsUrl = fields.lenient("detailsUrl")
        checkSuite = fields.lenient("checkSuite")
        context = fields.lenient("context")
        state = fields.lenient("state")
        targetUrl = fields.lenient("targetUrl")
    }
}

// The combined result of the checks of a commit. A field of the wrong type reads as missing, so
// a bad list of checks keeps the state.
struct RollupWire: Decodable {
    var state: String?
    var contexts: Page<CheckWire>?

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: AnyKey.self)
        state = fields.lenient("state")
        contexts = fields.lenient("contexts")
    }
}

struct HeadCommitWire: Decodable {
    var oid: String?
    var statusCheckRollup: RollupWire?
    // True when GitHub gave a rollup that Bifrost can't read. A null rollup is a commit with no
    // checks.
    var rollupUnread = false

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: AnyKey.self)
        oid = fields.lenient("oid")
        statusCheckRollup = fields.lenient("statusCheckRollup")
        rollupUnread = statusCheckRollup == nil && fields.present("statusCheckRollup")
    }
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
    var baseRefOid: String?
    var isCrossRepository: Bool?
    var mergeable: String?

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
        baseRefOid = fields.lenient("baseRefOid")
        isCrossRepository = fields.lenient("isCrossRepository")
        mergeable = fields.lenient("mergeable")
    }
}

// The change of the wire values into the types of Reviews.
extension PullRequestWire {
    // nil when the PR cannot get a valid key: it is then dropped, because the state and the
    // writes take only a valid PR key. faults gets the merge and check fields that read as
    // missing.
    func pullRequest(viewer: String, isToReview: Bool, faults: inout WireFaults) -> PullRequest? {
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

        // A To review PR does not ask for the reviews, the threads or the comments.
        let mine = !isToReview
        var threadList: [PRThread] = [], threadCut = reviewThreads.mayLack(asked: mine)
        for node in reviewThreads?.nodes ?? [] {
            guard let thread = node.thread else { continue }
            threadList.append(thread)
            threadCut = threadCut || node.comments.mayLack()
            if node.comments.unread() { faults.add(.threadComments) }
        }
        if reviewThreads.unread(asked: mine) { faults.add(.threads) }
        if reviews.unread(asked: mine) { faults.add(.reviews) }
        if comments.unread(asked: mine) { faults.add(.comments) }
        if latestOpinionatedReviews.unread() { faults.add(.opinions) }

        let head = commits?.nodes?.first?.decoded?.commit
        let rollupFailed = Self.failedStates.contains(head?.statusCheckRollup?.state ?? "")
        let opinions = latestOpinionatedReviews?.nodes ?? []
        let headSHA = headRefOid ?? ""
        let headChecks = self.headChecks(&faults)
        if mine {
            if baseRefOid == nil { faults.add(.baseRefOid) }
            if headRefName == nil { faults.add(.headRefName) }
            if baseRefName == nil { faults.add(.baseRefName) }
        }

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
            failedChecks: max(headChecks.checks.count(where: \.isFailed), rollupFailed ? 1 : 0),
            ci: CIState(
                rollup: head?.statusCheckRollup?.state, commit: head?.oid, head: headSHA),
            checks: headChecks, headRef: headRefName ?? "", headSHA: headSHA,
            baseRef: baseRefName ?? "", baseSHA: baseRefOid ?? "",
            mergeable: mine ? mergeState(&faults) : nil,
            isCrossRepository: isCrossRepository ?? false,
            viewerPendingReviewID: pendingReviews?.nodes.first?.id.flatMap(NodeID.init),
            viewerReviews: isToReview ? opinions.compactMap { $0.opinion(of: viewer) } : [],
            approvals: isToReview ? opinions.filter { $0.approves(otherThan: viewer) }.count : 0,
            truncatedThreads: threadCut,
            truncatedReviews: reviews.mayLack(asked: mine) || latestOpinionatedReviews.mayLack(),
            truncatedComments: comments.mayLack(asked: mine), truncatedChecks: headChecks.cut)
    }

    // The merge state, or nil when GitHub gave none or a value that Bifrost does not know.
    func mergeState(_ faults: inout WireFaults) -> Mergeable? {
        guard let state = mergeable.flatMap(Mergeable.init(rawValue:)) else {
            faults.add(.mergeable)
            return nil
        }
        return state
    }

    // The checks of the newest commit. The list is cut, so the checks never look settled, when
    // Bifrost can't read the rollup, its list of checks, the nodes or the page info of that list,
    // or one node (a node that is not a check run or a status). With no commit, no commit ID or
    // no head, the checks are not of the head.
    func headChecks(_ faults: inout WireFaults) -> HeadChecks {
        let commit = commits?.nodes?.first?.decoded?.commit
        if commit == nil { faults.add(.commit) }
        if commit != nil && commit?.oid == nil { faults.add(.commitOid) }
        if headRefOid == nil { faults.add(.headRefOid) }
        let rollup = commit?.statusCheckRollup
        var unread = false
        if commit?.rollupUnread == true {
            faults.add(.rollup)
            unread = true
        }
        if let rollup, rollup.contexts == nil {
            faults.add(.contexts)
            unread = true
        }
        if let contexts = rollup?.contexts {
            if !contexts.readNodes { faults.add(.contextsNodes) }
            if !contexts.readInfo { faults.add(.contextsPageInfo) }
            unread = unread || !contexts.readNodes || !contexts.readInfo
        }
        var list: [HeadCheck] = []
        for item in rollup?.contexts?.items ?? [] {
            guard let check = item.decoded?.check(&faults) else {
                faults.add(.checkNode)
                unread = true
                continue
            }
            list.append(check)
        }
        let head = headRefOid ?? ""
        return HeadChecks(
            checks: list, cut: unread || (rollup?.contexts?.isCut ?? false),
            onHead: !head.isEmpty && commit?.oid == head)
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
    // The app of the check runs of GitHub Actions.
    static let actionsApp = "github-actions"

    // The check, or nil for a node of another type. A failed check run or a failed status is
    // failed, also when the check is optional. A field that GitHub always gives and that reads as
    // missing goes to faults.
    func check(_ faults: inout WireFaults) -> HeadCheck? {
        switch typename {
        case "CheckRun":
            if name == nil { faults.add(.checkRunName) }
            return HeadCheck(
                name: name ?? "", outcome: runOutcome(&faults), source: runSource(&faults),
                url: Self.address(detailsUrl))
        case "StatusContext":
            if context == nil { faults.add(.statusContext) }
            return HeadCheck(
                name: context ?? "", outcome: statusOutcome(&faults), source: .status,
                url: Self.address(targetUrl))
        default:
            return nil
        }
    }

    // A check run has a conclusion only when it is done. With no conclusion, a run that is not
    // COMPLETED (or with no readable status) is running.
    private func runOutcome(_ faults: inout WireFaults) -> CheckOutcome {
        guard let conclusion else {
            if status == nil { faults.add(.checkRunStatus) }
            guard status == "COMPLETED" else { return .running }
            faults.add(.checkRunConclusion)
            return .other
        }
        switch conclusion {
        case "SUCCESS", "NEUTRAL", "SKIPPED": return .passed
        case "FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED":
            return .failed(conclusion)
        default: return .other
        }
    }

    // A status with no readable state is running.
    private func statusOutcome(_ faults: inout WireFaults) -> CheckOutcome {
        guard let state else {
            faults.add(.statusState)
            return .running
        }
        switch state {
        case "SUCCESS": return .passed
        case "PENDING", "EXPECTED": return .running
        case "FAILURE", "ERROR": return .failed(state)
        default: return .other
        }
    }

    // A job of GitHub Actions needs its job ID and the ID of its workflow run. A check run of
    // GitHub Actions without them is a check of an app, so Bifrost shows only its state.
    private func runSource(_ faults: inout WireFaults) -> CheckSource {
        guard let suite = checkSuite else {
            faults.add(.checkSuite)
            return .app("")
        }
        let slug = suite.app?.slug ?? ""
        if suite.app != nil && suite.app?.slug == nil { faults.add(.appSlug) }
        guard slug == Self.actionsApp else { return .app(slug) }
        let job = databaseId.flatMap(JobID.init)
        let run = suite.workflowRun?.databaseId.flatMap(RunID.init)
        if job == nil { faults.add(.jobID) }
        if run == nil { faults.add(.runID) }
        guard let job, let run else { return .app(slug) }
        return .actions(job: job, run: run)
    }

    // Only an http or https address.
    private static func address(_ text: String?) -> URL? {
        guard let url = text.flatMap(URL.init(string:)),
            let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }
}

// A field of the poll or the head read that GitHub left out or gave in a form that Bifrost can't
// read: a search, a list of a PR, the merge state, the head or the checks. Each such field reads
// as missing, and each such list as cut. The raw value is the path of the field in the query: a
// fixed word, so the log shows it.
package enum WireFault: String, Sendable, Comparable, CaseIterable {
    case mergeable, baseRefOid, headRefOid, headRefName, baseRefName
    // A search, or a list of a PR, that is missing or whose nodes or page info Bifrost can't read.
    // Bifrost then marks it cut.
    case toReview, mine, reviews, comments
    case opinions = "latestOpinionatedReviews"
    case threads = "reviewThreads"
    case threadComments = "reviewThreads.comments"
    case defaultBranch = "repository.defaultBranchRef.name"
    case commit = "commits.nodes.commit"
    case commitOid = "commits.nodes.commit.oid"
    case rollup = "statusCheckRollup"
    case contexts = "statusCheckRollup.contexts"
    case contextsNodes = "contexts.nodes"
    case contextsPageInfo = "contexts.pageInfo"
    // A node of the checks that is not an object, or not a CheckRun or a StatusContext.
    case checkNode = "contexts.nodes[]"
    case checkRunName = "CheckRun.name"
    case checkRunStatus = "CheckRun.status"
    case checkRunConclusion = "CheckRun.conclusion"
    case checkSuite = "CheckRun.checkSuite"
    case appSlug = "CheckRun.checkSuite.app.slug"
    case jobID = "CheckRun.databaseId"
    case runID = "CheckRun.checkSuite.workflowRun.databaseId"
    case statusContext = "StatusContext.context"
    case statusState = "StatusContext.state"
    // The issues that a PR closes, in the read of a review round: the list, a node that is not an
    // issue (no number), and a field of an issue that is missing or not a text.
    case closingIssues = "closingIssuesReferences"
    case closingIssueNumber = "closingIssuesReferences.nodes.number"
    case closingIssueRepo = "closingIssuesReferences.nodes.repository.nameWithOwner"
    case closingIssueTitle = "closingIssuesReferences.nodes.title"
    case closingIssueBody = "closingIssuesReferences.nodes.body"
    case closingIssueURL = "closingIssuesReferences.nodes.url"

    package static func < (left: WireFault, right: WireFault) -> Bool {
        left.rawValue < right.rawValue
    }
}

// The faults of one answer, each one time. The services log them.
struct WireFaults {
    private var found: Set<WireFault> = []

    mutating func add(_ fault: WireFault) { found.insert(fault) }

    // Each fault one time, in the order of its path.
    var sorted: [WireFault] { found.sorted() }
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
