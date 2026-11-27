// The GitHub of the tests of the writes of a request round: the pages of the full read of PR 7 of
// the viewer, and the answers of the writes, for FakeGitHub.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

enum WritesData {
    static let viewer = Rows.viewer
    static let prNode = "PR_kwDOrepo7"

    // A comment of a thread or of the PR.
    struct Comment {
        var id: String
        var login: String
        var typename = "User"
        var association = "MEMBER"
        var body: String
        var at: Date

        var json: JSONValue {
            [
                "id": .string(id), "databaseId": 1,
                "author": ["login": .string(login), "__typename": .string(typename)],
                "authorAssociation": .string(association), "body": .string(body),
                "createdAt": .string(at.formatted(.iso8601)),
                "url": .string("https://github.com/Owner-A/Repo-A/pull/7#\(id)"),
            ]
        }
    }

    struct Thread {
        var id: String
        var resolved = false
        var comments: [Comment]
    }

    // A latest decision of a reviewer.
    struct Decision {
        var login: String
        var typename = "User"
        var state = "CHANGES_REQUESTED"
    }

    // The first page of the full read: PR 7 of the viewer on the head, from feat into main.
    static func context(
        head: CommitID, state: String = "OPEN", author: String = viewer,
        decisions: [Decision] = [], requested: [String] = [], pending: Bool = false,
        fork: Bool = false
    ) -> Data {
        let decided: [JSONValue] = decisions.map { decision in
            [
                "state": .string(decision.state),
                "author": [
                    "login": .string(decision.login), "__typename": .string(decision.typename),
                    "id": .string("U_\(decision.login)"),
                ],
            ]
        }
        let asked: [JSONValue] = requested.map {
            ["requestedReviewer": ["__typename": "User", "login": .string($0)]]
        }
        return ReviewData.json([
            "data": [
                "repository": [
                    "pullRequest": [
                        "id": .string(prNode), "url": "https://github.com/Owner-A/Repo-A/pull/7",
                        "title": "Add the cache", "body": "The body.", "state": .string(state),
                        "author": ["login": .string(author)], "isCrossRepository": .bool(fork),
                        "baseRefName": "main", "headRefName": "feat",
                        "headRefOid": .string(head.hex), "updatedAt": "2026-11-10T11:30:00Z",
                        "repository": ["defaultBranchRef": ["name": "main"]],
                        "latestOpinionatedReviews": [
                            "nodes": .array(decided), "pageInfo": ["hasNextPage": false],
                        ],
                        "reviewRequests": [
                            "nodes": .array(asked), "pageInfo": ["hasNextPage": false],
                        ],
                        "pending": ["nodes": pending ? [["viewerDidAuthor": true]] : []],
                        "reviews": [
                            "nodes": [], "pageInfo": ["hasNextPage": false, "endCursor": .null],
                        ],
                    ]
                ]
            ]
        ])
    }

    static func threads(_ threads: [Thread]) -> Data {
        let nodes: [JSONValue] = threads.map { thread in
            [
                "id": .string(thread.id), "isResolved": .bool(thread.resolved),
                "isOutdated": false, "path": "src/a.swift", "line": 12, "viewerCanReply": true,
                "comments": [
                    "nodes": .array(thread.comments.map(\.json)),
                    "pageInfo": ["hasNextPage": false, "endCursor": .null],
                ],
            ]
        }
        return page("reviewThreads", nodes)
    }

    static func comments(_ comments: [Comment]) -> Data {
        page("comments", comments.map(\.json))
    }

    // The answer of the read of the state of the PR before a write.
    static func lifecycle(_ state: String = "OPEN") -> Data {
        ReviewData.json(["data": ["repository": ["pullRequest": ["state": .string(state)]]]])
    }

    private static func page(_ list: String, _ nodes: [JSONValue]) -> Data {
        ReviewData.json([
            "data": [
                "repository": [
                    "pullRequest": [
                        list: [
                            "nodes": .array(nodes),
                            "pageInfo": ["hasNextPage": false, "endCursor": .null],
                        ]
                    ]
                ]
            ]
        ])
    }

    // The answers of the writes.
    static func replied(_ id: String, state: String = "SUBMITTED") -> Data {
        answer(
            "addPullRequestReviewThreadReply",
            ["comment": ["id": .string(id), "createdAt": "2026-11-10T12:00:00Z",
                "state": .string(state)]])
    }

    static func resolved(_ id: String) -> Data {
        answer("resolveReviewThread", ["thread": ["id": .string(id), "isResolved": true]])
    }

    static func commented(_ id: String) -> Data {
        answer(
            "addComment",
            ["commentEdge": ["node": ["id": .string(id), "createdAt": "2026-11-10T12:00:00Z"]]])
    }

    static let requestedAgain = answer("requestReviews", ["pullRequest": ["id": .string(prNode)]])

    static func signed(_ oid: CommitID) -> Data {
        answer("createCommitOnBranch", ["commit": ["oid": .string(oid.hex)]])
    }

    private static func answer(_ field: String, _ value: JSONValue) -> Data {
        ReviewData.json(["data": .object([field: value])])
    }

    // The fresh read of the head of PR 7, open and of the user, that an own outbox makes.
    static func headRead(
        head: CommitID, author: String = Rows.viewer, fork: Bool = false, state: String = "OPEN"
    ) -> Data {
        ReviewData.json([
            "data": [
                "repository": [
                    "pullRequest": [
                        "state": .string(state), "author": ["login": .string(author)],
                        "repository": ["defaultBranchRef": ["name": "main"]],
                        "mergeable": "MERGEABLE", "baseRefOid": .string(head.hex),
                        "headRefName": "feat", "headRefOid": .string(head.hex),
                        "baseRefName": "main", "isCrossRepository": .bool(fork),
                        "commits": ["nodes": []],
                    ]
                ]
            ]
        ])
    }

    // A fake GitHub with the full read, the read of the state of the PR, and an answer for each
    // write: reply R1, resolve, comment C1 and the review request.
    @MainActor
    static func github(
        head: CommitID, threads: [Thread], comments: [Comment] = [],
        decisions: [Decision] = [], requested: [String] = [], state: String = "OPEN"
    ) -> FakeGitHub {
        FakeGitHub(answers: [
            RequestQueries.contextName: .success(
                context(head: head, state: state, decisions: decisions, requested: requested)),
            RequestQueries.threadsName: .success(Self.threads(threads)),
            RequestQueries.commentsName: .success(Self.comments(comments)),
            RequestQueries.stateName: .success(lifecycle(state)),
            "addPullRequestReviewThreadReply": .success(replied("PRRC_R1")),
            "resolveReviewThread": .success(resolved("PRRT_1")),
            "addComment": .success(commented("IC_C1")),
            "requestReviews": .success(requestedAgain),
        ])
    }

    // The thread of a member on PR 7, with its first comment two hours before now.
    static func thread(_ id: String, replies: [Comment] = [], resolved: Bool = false) -> Thread {
        Thread(
            id: id, resolved: resolved,
            comments: [
                Comment(id: id + "c", login: "user-b", body: "Fix this.", at: Rows.at(-120))
            ] + replies)
    }
}

// The writes of a request round on PR 7: a Reviews store in a temporary folder, the fake GitHub,
// and the repo store of a PushTestRepo (for the fix commit and the push) or of an empty folder
// (for writes with no fix commit). The wait between two writes runs on a GapClock by default.
@MainActor
final class WritesFixture {
    let store: ReviewsStore
    let github: FakeGitHub
    let repos: RepoStore
    let lines = Recorder<String>()
    let writes: RoundWrites
    let pr: PRKey
    let head: CommitID
    private let folder: TemporaryFolder?

    init(
        repo: PushTestRepo? = nil, head: CommitID? = nil, clock: any Clock<Duration> = GapClock(),
        github: (CommitID) -> FakeGitHub
    ) async throws {
        let layout: ReviewsLayout
        let git: RepoGit
        let address: URL
        if let repo {
            folder = nil
            (layout, git, address) = (repo.repo.layout, repo.git, repo.address)
        } else {
            let made = try TemporaryFolder()
            folder = made
            layout = ReviewsLayout(
                folder: URL(filePath: made.realPath + "/reviews", directoryHint: .isDirectory))
            git = RepoGit(
                path: testGit, environment: [:], layout: layout, runner: ProcessRunner())
            address = URL(filePath: made.realPath + "/source")
        }
        pr = try ReviewData.pr()
        self.head = try head ?? repo?.head ?? ReviewData.commit()
        store = try await ReviewsStore.open(layout: layout, log: Recorder<StoreEvent>())
        repos = RepoStore(
            layout: layout, git: git, cloneAddress: { _ in address }, clock: ManualClock(),
            log: Recorder<ReviewsLogEvent>())
        self.github = github(self.head)
        let lines = lines
        writes = RoundWrites(
            store: store, github: GitHubClient(access: self.github), repos: repos, clock: clock,
            now: { Rows.now }, viewer: { WritesData.viewer }, eventLine: { lines.record($0) })
    }

    // Save the outbox in the state of the PR, with a posting round when posting is true.
    func save(_ outbox: Outbox, posting: Bool = false, items: [NodeID: Date] = [:]) async {
        let pr = pr
        await store.update { state in
            var prState = state.prs[pr] ?? PRState()
            prState.outbox = outbox
            if posting {
                prState.round = ActiveRound(
                    phase: .posting, startedAt: Rows.at(-20), at: Rows.at(-30),
                    headSHA: outbox.headSHA, baseSHA: outbox.mergeBase, kind: .request,
                    items: items)
            }
            state.prs[pr] = prState
        }
    }

    var state: PRState? { store.state.prs[pr] }

    var written: [GitHubWrite] {
        github.calls.compactMap { if case .write(let write) = $0 { write } else { nil } }
    }

    func end() async {
        await ended(store.close())
        folder?.remove()
    }

    // An outbox of the writes on the head, started ten minutes before now.
    func outbox(_ posts: [OutboxPost], seen: [NodeID: Date] = [:]) -> Outbox {
        Outbox(
            headSHA: head, mergeBase: head, startedAt: Rows.at(-10), seen: seen, posts: posts)
    }
}

// The writes of an outbox of the tests.
enum Posts {
    static func reply(_ item: String, _ text: String?, _ state: PostState = .todo) throws
        -> OutboxPost
    {
        OutboxPost(
            id: "reply:\(item)", state: state,
            write: .reply(item: try ReviewData.node(item), text: text, by: nil, comment: nil))
    }

    static func resolve(_ item: String, _ state: PostState = .todo) throws -> OutboxPost {
        OutboxPost(
            id: "resolve:\(item)", state: state, write: .resolve(item: try ReviewData.node(item)))
    }

    static func rerequest(_ state: PostState = .todo) -> OutboxPost {
        OutboxPost(id: OutboxRules.rerequestID, state: state, write: .rerequest(logins: nil))
    }

    static func commit(_ paths: [String]) -> OutboxPost {
        OutboxPost(
            id: OutboxRules.commitID, state: .todo,
            write: .commit(paths: paths, message: "fix: the review comments", commit: nil))
    }

    static func push(signed: Bool = false) -> OutboxPost {
        OutboxPost(id: OutboxRules.pushID, state: .todo, write: .push(commit: nil, signed: signed))
    }
}
