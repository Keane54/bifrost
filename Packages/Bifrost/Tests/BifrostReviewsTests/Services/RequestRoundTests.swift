// The request rounds (docs/behaviour/reviews.md, "Request rounds"), end to end: the real git on a
// local bare source with a PR head at refs/pull/7/head and at its branch feat, a Reviews store
// and a trusted clone in a temporary folder, the in-process FakeGitHub for the full read and the
// writes, and the real registry on scripted session lists with a fake claude (FakeActionDeps).
// The test plays the session: it shows its rows and writes its result file. No test reaches
// GitHub, runs claude or reads the real ~/.claude or ~/.claude.json.
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@MainActor
private final class RequestFixture {
    static let id = "22222222-3333-4444-5555-666666666666"
    static let name = "bifrost-test-Repo-A-7-request"
    static let shortID = ShortID("abcdef12")
    // The time of the threads of the PR: after the start of new work of the default state.
    static let threadTime = Rows.at(-120)
    static let member = Rows.person("user-b")

    let repos: RepoFixture
    let deps = FakeActionDeps()
    let store: ReviewsStore
    let github: FakeGitHub
    let setup: RepoSetup
    private(set) var rounds: ReviewRounds
    let skills: URL
    // The home of the user for the sandbox of the sessions.
    let home: URL
    let config: ReviewsConfig
    // The last good poll of the rounds: PR 7 of the user with the threads.
    let answer: PollAnswer
    let notices = Recorder<ReviewsNotice>()
    let polls = Recorder<Bool>()
    let pr: PRKey
    let head: CommitID

    // threads: the IDs of the threads of a member on the PR. saved: the state that the store
    // holds before the start of the rounds; by default the user confirmed the automatic rounds
    // and new work starts one day before now.
    init(
        config: ReviewsConfig = .init(), threads: [String] = ["PRRT_1"],
        runner: any CommandRunner = ProcessRunner(),
        saved: (inout ReviewsState) -> Void = { _ in }
    ) async throws {
        self.config = config
        repos = try RepoFixture(runner: runner)
        let repo = try #require(RepoName("Owner-A/Repo-A"))
        pr = try #require(PRKey(repo: repo, number: 7))
        let lines = (1...20).map { "line \($0)" }
        try await repos.source(repo, files: ["src/a.swift": lines.joined(separator: "\n") + "\n"])
        // The head of the PR: a second commit, at refs/pull/7/head of the source.
        let work = repos.root + "/work/" + repo.key
        var changed = lines
        changed[10] = "line eleven"
        try (changed.joined(separator: "\n") + "\n").write(
            toFile: work + "/src/a.swift", atomically: false, encoding: .utf8)
        try await repos.setup(["commit", "-q", "-am", "two"], in: work)
        try await repos.setup(
            [
                "push", "-q", repos.root + "/sources/" + repo.key + ".git",
                "HEAD:refs/pull/7/head", "HEAD:refs/heads/feat",
            ],
            in: work)
        let parsed = await ProcessRunner().run(
            Command(
                "/usr/bin/git", ["-C", work, "rev-parse", "HEAD"], environment: repos.env,
                timeout: .seconds(30)))
        head = try #require(CommitID(parsed.stdout.trimmed()))
        store = try await ReviewsStore.open(layout: repos.layout, log: Recorder<StoreEvent>())
        // Claude Code trusts the clone (the .claude.json of the temporary home).
        let clone = String(repos.clone(repo).dropLast())
        try "{\"projects\": {\"\(clone)\": {\"hasTrustDialogAccepted\": true}}}".write(
            toFile: repos.root + "/.claude.json", atomically: false, encoding: .utf8)
        let skillsPath = repos.root + "/skills"
        skills = URL(filePath: skillsPath, directoryHint: .isDirectory)
        for (path, text) in [
            "skills/bifrost-resolve-comments/bifrost-mode.md": "The mode.\n",
            "skills/bifrost-humanise/rules.md": "The rules.\n",
        ] {
            let file = skillsPath + "/" + path
            try FileManager.default.createDirectory(
                atPath: (file as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try text.write(toFile: file, atomically: false, encoding: .utf8)
        }
        home = URL(filePath: repos.root, directoryHint: .isDirectory)
        github = FakeGitHub(answers: [
            RequestQueries.contextName: .success(Self.context(head: head)),
            RequestQueries.threadsName: .success(Self.threads(threads)),
            RequestQueries.commentsName: .success(Self.comments()),
            RequestQueries.stateName: .success(WritesData.lifecycle()),
            "addPullRequestReviewThreadReply": .success(WritesData.replied("PRRC_R1")),
            "resolveReviewThread": .success(WritesData.resolved("PRRT_1")),
        ])
        answer = Rows.answer(mine: [
            try Rows.pull(
                "Owner-A/Repo-A#7", author: Rows.viewer,
                threads: try threads.map {
                    try Rows.thread($0, by: Self.member, at: Self.threadTime)
                })
        ])
        let notices = notices
        setup = RepoSetup(
            repos: repos.store, store: store, ptys: nil,
            home: URL(filePath: repos.root, directoryHint: .isDirectory),
            notify: { notices.record($0) }, now: { Rows.now })
        rounds = Self.rounds(
            store: store, deps: deps, github: github, repos: repos, setup: setup, skills: skills,
            home: home, config: config, answer: answer, notices: notices,
            polls: polls)
        deps.calls.answerClaude { args in
            args.first == "--bg"
                ? ExecResult(.exited(0), stdout: "backgrounded \u{B7} abcdef12 \u{B7} name\n")
                : ExecResult(.exited(0))
        }
        await store.update { state in
            state.turnedOnAt = Rows.at(-2 * 24 * 60)
            state.fixFrom = Rows.at(-24 * 60)
            state.autoFixConsent = true
            saved(&state)
        }
        await deps.start()
        rounds.start()
    }

    private static func rounds(
        store: ReviewsStore, deps: FakeActionDeps, github: FakeGitHub, repos: RepoFixture,
        setup: RepoSetup, skills: URL, home: URL, config: ReviewsConfig, answer: PollAnswer,
        notices: Recorder<ReviewsNotice>, polls: Recorder<Bool>
    ) -> ReviewRounds {
        let sessions = PRSessions(
            store: store, registry: deps.registry, actions: deps.makeActions(),
            claude: deps.claudeRunner(), clock: deps.clock, now: { Rows.now }, testPrefix: true)
        let rounds = ReviewRounds(
            store: store, github: GitHubClient(access: github), repos: repos.store, setup: setup,
            sessions: sessions, skills: skills, userHome: home, config: config,
            now: { Rows.now }, clock: GapClock())
        rounds.answer = { answer }
        rounds.notify = { notices.record($0) }
        rounds.ended = { polls.record(true) }
        return rounds
    }

    // A quit and a new start of Bifrost on the same state.
    func restart() async throws {
        rounds.stop()
        await rounds.waitForEnd()
        rounds = Self.rounds(
            store: store, deps: deps, github: github, repos: repos, setup: setup, skills: skills,
            home: home, config: config, answer: answer, notices: notices,
            polls: polls)
        rounds.start()
    }

    func end() async {
        rounds.stop()
        await rounds.waitForEnd()
        await store.close().value
        repos.folder.remove()
    }

    // The first page of the full read: the open PR of the author (the user) at the head.
    static func context(head: CommitID, state: String = "OPEN", author: String = Rows.viewer)
        -> Data
    {
        ReviewData.json([
            "data": [
                "repository": [
                    "pullRequest": [
                        "id": "PR_kwDOrepo7", "url": "https://github.com/Owner-A/Repo-A/pull/7",
                        "title": "Add the cache", "body": "The body.", "state": .string(state),
                        "author": ["login": .string(author)], "isCrossRepository": false,
                        "baseRefName": "main", "headRefName": "feat",
                        "headRefOid": .string(head.hex), "updatedAt": "2026-11-10T11:30:00Z",
                        "repository": ["defaultBranchRef": ["name": "main"]],
                        "pending": ["nodes": []],
                        "reviews": [
                            "nodes": [], "pageInfo": ["hasNextPage": false, "endCursor": .null],
                        ],
                    ]
                ]
            ]
        ])
    }

    // The threads of a member on line 12 of src/a.swift. cut: GitHub has more threads, but gives
    // no cursor for them.
    static func threads(_ ids: [String], cut: Bool = false) -> Data {
        let time = Self.threadTime.formatted(.iso8601)
        let nodes: [JSONValue] = ids.map { id in
            [
                "id": .string(id), "isResolved": false, "isOutdated": false,
                "path": "src/a.swift", "line": 12, "viewerCanReply": true,
                "comments": [
                    "nodes": [
                        [
                            "id": .string(id + "c"), "databaseId": 1,
                            "author": ["login": "user-b", "__typename": "User"],
                            "authorAssociation": "MEMBER", "body": "Fix this.",
                            "createdAt": .string(time), "diffHunk": "@@ -10,3 +10,3 @@",
                            "url": .string("https://github.com/Owner-A/Repo-A/pull/7#\(id)"),
                        ]
                    ],
                    "pageInfo": ["hasNextPage": false, "endCursor": .null],
                ],
            ]
        }
        return ReviewData.json([
            "data": [
                "repository": [
                    "pullRequest": [
                        "reviewThreads": [
                            "nodes": .array(nodes),
                            "pageInfo": ["hasNextPage": .bool(cut), "endCursor": .null],
                        ]
                    ]
                ]
            ]
        ])
    }

    static func comments() -> Data {
        ReviewData.json([
            "data": [
                "repository": [
                    "pullRequest": [
                        "comments": [
                            "nodes": [], "pageInfo": ["hasNextPage": false, "endCursor": .null],
                        ]
                    ]
                ]
            ]
        ])
    }

    var input: String { repos.layout.inputFolder(pr.repo, number: 7).plainPath }
    var worktree: String { GitPlace.worktree(pr, repos.layout) }

    // A good poll, and the task of the round that it queued.
    func poll() async throws -> Task<Void, Never> {
        rounds.afterPoll(answer)
        return try #require(rounds.queue.task(of: pr))
    }

    // The head of the branch feat of the source: the branch on GitHub.
    func branch() async throws -> CommitID {
        let bare = repos.root + "/sources/" + pr.repo.key + ".git"
        let parsed = await ProcessRunner().run(
            Command(
                "/usr/bin/git", ["-C", bare, "rev-parse", "refs/heads/feat"],
                environment: repos.env, timeout: .seconds(30)))
        return try #require(CommitID(parsed.stdout.trimmed()))
    }

    // The session starts: claude --bg ran, and its row works.
    func sessionWorks() async {
        await waitUntil {
            self.deps.calls.claudeRuns.contains { $0.first == "--bg" }
        }
        await show(.busy)
        await waitUntil {
            self.store.state.prs[self.pr]?.round?.phase == .running
        }
    }

    func show(_ status: AgentStatus, waitingFor: String? = nil) async {
        let entry = AgentEntry(
            sessionId: Self.id, cwd: worktree, isBackground: true, startedAt: 1, name: Self.name,
            status: status, pid: 4242, id: Self.shortID, waitingFor: waitingFor)
        await deps.show([entry]) { rows in
            rows.contains {
                $0.sessionId == Self.id && ($0.state == .working) == (status == .busy)
                    && $0.alert.blocksPrompt == (waitingFor != nil)
            }
        }
    }

    // The input.json of the round.
    func inputFile() throws -> [String: JSONValue] {
        let data = try Data(contentsOf: URL(filePath: input + "/input.json"))
        return try #require(try JSONDecoder().decode(JSONValue.self, from: data).object)
    }

    // A result file of the round with the items, the commit and the checks. The token of the
    // round comes from its input.json, as the session reads it.
    func result(
        _ items: [JSONValue], commit: JSONValue = .null, checks: String = "none"
    ) throws -> Data {
        ReviewData.json([
            "version": 1, "pr": "Owner-A/Repo-A#7", "headSha": .string(head.hex),
            "round": try inputFile()["round"] ?? .null, "items": .array(items),
            "commit": commit, "checks": .string(checks),
        ])
    }

    // The turn ends: the good result file lands and the row is idle.
    func endTurn(result: Data) async throws {
        try result.write(to: URL(filePath: input + "/result.json"))
        await show(.idle)
    }

    var writes: [GitHubWrite] {
        github.calls.compactMap { if case .write(let write) = $0 { write } else { nil } }
    }

    // The arguments and the folder of the start of the session.
    var start: (args: [String], directory: String?)? {
        for call in deps.calls.all {
            if case .claude(let args, let directory, _, _, _) = call, args.first == "--bg" {
                return (args, directory)
            }
        }
        return nil
    }

    func node(_ text: String) throws -> NodeID { try #require(NodeID(text)) }

    // The stop of the session ran, and its wait for the park sleeps on the clock, so a move of the
    // clock by the park wait ends it.
    func parkWaitStarted() async {
        await waitUntil { self.deps.calls.claudeRuns.contains(["stop", "abcdef12"]) }
        await waitUntil {
            self.deps.clock.nextDeadline?.offset
                == self.deps.clock.now.offset + SessionActions.parkWait
        }
    }
}

@MainActor
@Suite("the request rounds", .serialized, .timeLimit(.minutes(3)), .tags(.realProcess))
struct RequestRoundTests {
    // A poll with new work starts a round: the session runs in the worktree of the PR with the
    // request flags and the sandbox of the clone, and reads an input folder with input.json (the
    // token and the items), the full diff, the mode and the rules. A fix ends with the commit of
    // the listed file on the branch, the "Fixed by" reply and the resolve; the item is handled,
    // and the next poll starts no round on it again by itself.
    @Test func aRoundStartsTheSessionWithTheSandboxInTheWorktree() async throws {
        let f = try await RequestFixture()
        let round = try await f.poll()
        await f.sessionWorks()
        let start = try #require(f.start)
        #expect(start.directory == f.worktree + "/")
        let clone = f.repos.layout.clone(f.pr.repo).plainPath
        let inputFile = URL(filePath: f.input + "/input.json")
        let paths = SessionPaths(
            clone: clone, worktree: f.worktree, inputFolder: f.input,
            reviews: f.repos.layout.folder.plainPath, home: f.home.plainPath)
        let settings = try #require(RequestSandbox.settings(paths))
        #expect(
            start.args
                == PRSessionArgs.request(
                    name: RequestFixture.name, model: .standard,
                    inputFolder: URL(filePath: f.input, directoryHint: .isDirectory),
                    skills: f.skills, settings: settings,
                    prompt: PRSessionArgs.requestPrompt(inputFile)))
        #expect(start.args.contains("Bash") && start.args.contains("--restricted"))
        #expect(start.args.last == "/bifrost-resolve-comments bifrost-input=\(f.input)/input.json")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: f.input)) ?? []
        #expect(Set(names) == ["input.json", "full.diff", "mode.md", "humanise-rules.md"])
        #expect(try String(contentsOfFile: f.input + "/mode.md", encoding: .utf8) == "The mode.\n")
        let input = try f.inputFile()
        let round1 = try #require(f.store.state.prs[f.pr]?.round)
        #expect(round1.kind == .request && round1.headSHA == f.head)
        #expect(input["round"] == .text(round1.token))
        #expect(round1.items == [try f.node("PRRT_1"): RequestFixture.threadTime])
        let items = try #require(input["items"]?.array?.compactMap { $0.object })
        #expect(items.map { $0["id"] } == ["PRRT_1"])
        #expect(items.first?["comments"]?.array?.first?.object?["trusted"] == true)
        #expect(f.store.state.prs[f.pr]?.requestSession?.name == RequestFixture.name)
        // The session fixes the file and lists it.
        try "fixed\n".write(toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        try await f.endTurn(
            result: f.result(
                [["id": "PRRT_1", "outcome": "fixed"]],
                commit: ["message": "fix: use the new name", "paths": ["src/a.swift"]],
                checks: "passed"))
        await round.value
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.round == nil && state.lastError == nil && state.outbox == nil)
        let fix = try await f.branch()
        let item = try f.node("PRRT_1")
        #expect(fix != f.head)
        #expect(
            f.writes == [
                .replyToThread(thread: item, body: "Fixed by \(fix.short)"), .resolveThread(item),
            ])
        #expect(state.handled[item] != nil && state.held.isEmpty)
        let fixed = try String(contentsOfFile: f.worktree + "/src/a.swift", encoding: .utf8)
        #expect(fixed == "fixed\n")
        #expect(f.notices.values.isEmpty && f.polls.values.count == 1)
        f.rounds.afterPoll(f.answer)
        #expect(f.store.state.queue.isEmpty && f.rounds.queue.task(of: f.pr) == nil)
        await f.end()
    }

    // Two questions of one round give one notification. Each question has the place of its item
    // and the quote of the request, and the row needs the user. A later poll notifies nothing
    // more and starts no round while the questions wait.
    @Test func needsYouNotifiesOncePerRound() async throws {
        let f = try await RequestFixture(threads: ["PRRT_1", "PRRT_2"])
        let round = try await f.poll()
        await f.sessionWorks()
        try await f.endTurn(
            result: f.result([
                ["id": "PRRT_1", "outcome": "needs-you", "question": "Rename it or keep it?"],
                ["id": "PRRT_2", "outcome": "needs-you", "question": "Is the limit 10?"],
            ]))
        await round.value
        #expect(f.notices.values == [.needsYou(f.pr, questions: 2)])
        let question = try #require(f.store.state.prs[f.pr]?.questions[try f.node("PRRT_1")])
        #expect(question.text == "Rename it or keep it?" && question.place == "src/a.swift line 12")
        #expect(question.author == "user-b" && question.body == "Fix this.")
        #expect(question.kind == .thread)
        #expect(question.url?.absoluteString == "https://github.com/Owner-A/Repo-A/pull/7#PRRT_1")
        #expect(question.seenUntil == RequestFixture.threadTime && question.answer == nil)
        let rows = Rows.mine(f.answer, f.store.state)
        #expect(rows.first?.mineState?.claude == .needsYou(2))
        f.rounds.afterPoll(f.answer)
        #expect(f.store.state.queue.isEmpty)
        #expect(f.notices.values.count == 1)
        // The session stays, so the user can read its chat.
        #expect(f.store.state.prs[f.pr]?.requestSession != nil)
        #expect(!f.deps.calls.claudeRuns.contains { $0.first == "rm" })
        await f.end()
    }

    // The round checks the bytes of the result that ended the turn. A session that writes
    // another text into result.json after the end (here at the count of the changes of the
    // worktree) changes nothing: the question of the good result is saved.
    @Test func aResultWrittenAfterTheTurnEndChangesNothing() async throws {
        let runner = RewritingRunner()
        let f = try await RequestFixture(runner: runner)
        let round = try await f.poll()
        await f.sessionWorks()
        runner.arm(file: f.input + "/result.json", text: "{ not json")
        try await f.endTurn(
            result: f.result([
                ["id": "PRRT_1", "outcome": "needs-you", "question": "Rename it or keep it?"]
            ]))
        await round.value
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.round == nil && state.lastError == nil)
        #expect(state.questions[try f.node("PRRT_1")]?.text == "Rename it or keep it?")
        let rewritten = try String(contentsOfFile: f.input + "/result.json", encoding: .utf8)
        #expect(rewritten == "{ not json")
        await f.end()
    }

    // A session that works past 30 minutes gets a stop; the round posts nothing, holds its item
    // and sends no notification. The next poll starts no round on the held item.
    @Test func aRoundStopsAfter30MinutesAndPostsNothing() async throws {
        let f = try await RequestFixture()
        let round = try await f.poll()
        await f.sessionWorks()
        let limit = f.deps.clock.now.offset + ReviewRounds.requestLimit
        await waitUntil { f.deps.clock.nextDeadline?.offset == limit }
        f.deps.clock.advance(by: ReviewRounds.requestLimit)
        await f.parkWaitStarted()
        f.deps.clock.advance(by: SessionActions.parkWait)
        await round.value
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.lastError == RoundFailure.timeout.message(for: .request))
        let item = try f.node("PRRT_1")
        #expect(state.round == nil && state.held == [item])
        #expect(f.writes.isEmpty && f.notices.values.isEmpty)
        f.rounds.afterPoll(f.answer)
        #expect(f.store.state.queue.isEmpty)
        await f.end()
    }

    // The PR merges or closes while its round runs: the round stops, its session, worktree and
    // request fields go, and nothing is posted. A PR that is closed at the read starts no session.
    @Test func aClosedPRStopsTheRound() async throws {
        let f = try await RequestFixture()
        let round = try await f.poll()
        await f.sessionWorks()
        f.rounds.afterPoll(Rows.answer(mine: []))
        await round.value
        #expect(f.deps.calls.claudeRuns.contains(["stop", "abcdef12"]))
        #expect(f.deps.calls.claudeRuns.contains(["rm", "abcdef12"]))
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.round == nil && state.lastError == nil && state.requestSession == nil)
        #expect(state.held.isEmpty && state.questions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.worktree))
        #expect(f.writes.isEmpty && f.notices.values.isEmpty)
        await f.end()

        let g = try await RequestFixture()
        g.github.answers[RequestQueries.contextName] = .success(
            RequestFixture.context(head: g.head, state: "MERGED"))
        await (try g.poll()).value
        #expect(g.start == nil)
        #expect(g.store.state.prs[g.pr]?.round == nil && g.store.state.prs[g.pr]?.lastError == nil)
        await g.end()
    }

    // With "Handle comments on my PRs automatically" off, a poll with new work starts no round;
    // Handle now still starts one, and its start spends the click.
    @Test func theSettingOffStartsNoRoundButHandleNowDoes() async throws {
        var config = ReviewsConfig()
        config.autoFix = false
        let f = try await RequestFixture(config: config)
        f.rounds.afterPoll(f.answer)
        #expect(f.store.state.queue.isEmpty)
        await f.rounds.handle(f.pr, copilot: false)
        let round = try #require(f.rounds.queue.task(of: f.pr))
        await f.sessionWorks()
        #expect(try f.inputFile()["items"]?.array?.first?.object?["id"] == "PRRT_1")
        #expect(f.store.state.prs[f.pr]?.handleOlder == false)
        try await f.endTurn(result: f.result([["id": "PRRT_1", "outcome": "no-action"]]))
        await round.value
        #expect(f.store.state.prs[f.pr]?.handled[try f.node("PRRT_1")] != nil)
        #expect(f.writes.isEmpty)
        await f.end()
    }

    // The take-over of an Electron state with the setting on: the consent waits for the confirm
    // in this app, so a trusted comment after the Electron start of new work starts no round.
    // After the confirm, a trusted reply from before it starts no round on the item that the
    // take-over held (PRRT_1) or on the item that the Electron app handled (PRRT_2). Handle now
    // still starts one.
    @Test func theTakeOverStartsNoAutomaticRound() async throws {
        let (pr, held, handled) = (
            try ReviewData.pr(), try ReviewData.node("PRRT_1"), try ReviewData.node("PRRT_2")
        )
        // The Electron round read the PR, and replied to PRRT_2, one hour ago.
        let read = Rows.at(-60)
        let f = try await RequestFixture(threads: ["PRRT_1", "PRRT_2"]) { state in
            state.autoFixConsent = nil
            var prState = PRState()
            prState.round = ActiveRound(
                phase: .running, startedAt: read, at: read, kind: .request,
                items: [held: RequestFixture.threadTime])
            prState.checkedAt = read
            prState.handled[handled] = Handled(at: read, lastReplyAt: read)
            state.prs[pr] = prState
            state.takeOver(now: Rows.at(-10))
        }
        #expect(f.config.autoFix && f.store.state.autoFixConsent == false)
        #expect(RequestFixture.threadTime > Rows.at(-24 * 60))
        #expect(f.store.state.prs[f.pr]?.held == [held])
        f.rounds.afterPoll(f.answer)
        #expect(f.store.state.queue.isEmpty)
        // A member replied on both threads after the Electron read and before the take-over.
        let member = RequestFixture.member
        let replied = Rows.answer(mine: [
            try Rows.pull(
                "Owner-A/Repo-A#7", author: Rows.viewer,
                threads: try ["PRRT_1", "PRRT_2"].map {
                    let reply = try Rows.comment($0 + "r", by: member, at: Rows.at(-30))
                    return try Rows.thread(
                        $0, by: member, at: RequestFixture.threadTime, replies: [reply])
                })
        ])
        await f.store.update { $0.consentToAutoFix(now: Rows.at(-5)) }
        #expect(f.store.state.allowsAutoFix(f.config.autoFix))
        f.rounds.afterPoll(replied)
        #expect(f.store.state.queue.isEmpty)
        #expect(f.start == nil)
        // Handle now takes the held item. The full read shows no newer comment on PRRT_2, so it
        // stays handled.
        await f.rounds.handle(f.pr, copilot: false)
        let round = try #require(f.rounds.queue.task(of: f.pr))
        await f.sessionWorks()
        let items = try f.inputFile()["items"]?.array?.compactMap { $0.object?["id"] }
        #expect(items == ["PRRT_1"])
        try await f.endTurn(result: f.result([["id": "PRRT_1", "outcome": "no-action"]]))
        await round.value
        #expect(f.writes.isEmpty)
        await f.end()
    }

    // The take-over of a PR with no round and no queue entry, where the Electron app kept a
    // Handle now and a Handle Copilot comments click (after a failed read), a held item (PRRT_1),
    // an answered question (PRRT_2) and an old item (PRRT_3). The clicks go and the answered
    // question is held, so after the confirm a poll starts no round. A click after the confirm
    // still takes them all, with the answer.
    @Test func anImportedClickOrAnswerStartsNoRoundAfterTheConfirm() async throws {
        let (pr, held, asked) = (
            try ReviewData.pr(), try ReviewData.node("PRRT_1"), try ReviewData.node("PRRT_2")
        )
        let f = try await RequestFixture(threads: ["PRRT_1", "PRRT_2", "PRRT_3"]) { state in
            state.autoFixConsent = nil
            var prState = PRState()
            prState.handleOlder = true
            prState.handleCopilot = true
            prState.held = [held]
            prState.checkedAt = Rows.at(-60)
            prState.questions[asked] = Question(
                text: "Rename it?", place: "src/a.swift line 12", at: Rows.at(-60),
                answer: "Rename it.", seenUntil: RequestFixture.threadTime)
            state.prs[pr] = prState
            state.takeOver(now: Rows.at(-10))
        }
        let taken = try #require(f.store.state.prs[f.pr])
        #expect(!taken.handleOlder && !taken.handleCopilot && taken.held == [held, asked])
        await f.store.update { $0.consentToAutoFix(now: Rows.at(-5)) }
        #expect(f.store.state.allowsAutoFix(f.config.autoFix))
        f.rounds.afterPoll(f.answer)
        #expect(f.store.state.queue.isEmpty)
        #expect(f.start == nil)
        await f.rounds.handle(f.pr, copilot: false)
        let round = try #require(f.rounds.queue.task(of: f.pr))
        await f.sessionWorks()
        let items = try #require(try f.inputFile()["items"]?.array?.compactMap { $0.object })
        #expect(items.map { $0["id"] } == ["PRRT_1", "PRRT_2", "PRRT_3"])
        #expect(items[1]["answer"] == "Rename it.")
        try await f.endTurn(
            result: f.result(
                ["PRRT_1", "PRRT_2", "PRRT_3"].map { id -> JSONValue in
                    ["id": .string(id), "outcome": "no-action"]
                }))
        await round.value
        #expect(f.store.state.prs[f.pr]?.held.isEmpty == true && f.writes.isEmpty)
        await f.end()
    }

    // An answer starts one round also with the automatic rounds off: the input has the question
    // and the answer. An item that the user handles is handled with no round, and a bad answer
    // changes nothing.
    @Test func anAnswerStartsOneRound() async throws {
        var config = ReviewsConfig()
        config.autoFix = false
        let (pr, first, second) = (
            try ReviewData.pr(), try ReviewData.node("PRRT_1"), try ReviewData.node("PRRT_2")
        )
        let f = try await RequestFixture(config: config, threads: ["PRRT_1", "PRRT_2"]) { state in
            var prState = PRState()
            for item in [first, second] {
                prState.questions[item] = Question(
                    text: "Rename it?", place: "src/a.swift line 12", at: Rows.at(-60),
                    seenUntil: RequestFixture.threadTime)
            }
            state.prs[pr] = prState
        }
        #expect(await f.rounds.answerQuestions(f.pr, [first: .text("  ")]) == false)
        let unknown = try f.node("PRRT_9")
        #expect(await f.rounds.answerQuestions(f.pr, [unknown: .handleMyself]) == false)
        #expect(f.store.state.queue.isEmpty)
        let answered = await f.rounds.answerQuestions(
            f.pr, [first: .text(" Rename it. "), second: .handleMyself])
        #expect(answered)
        let round = try #require(f.rounds.queue.task(of: f.pr))
        await f.sessionWorks()
        let items = try #require(try f.inputFile()["items"]?.array?.compactMap { $0.object })
        #expect(items.map { $0["id"] } == ["PRRT_1"])
        #expect(items.first?["question"] == "Rename it?" && items.first?["answer"] == "Rename it.")
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.handled[second]?.lastReplyAt == RequestFixture.threadTime)
        #expect(state.questions[second] == nil)
        try await f.endTurn(result: f.result([["id": "PRRT_1", "outcome": "no-action"]]))
        await round.value
        #expect(f.store.state.prs[f.pr]?.questions.isEmpty == true)
        #expect(f.notices.values.isEmpty)
        await f.end()
    }

    // A Fixed item that names an earlier commit needs a commit of the PR: after the merge base
    // and in the head of the round. The merge base and a commit that the clone does not have
    // refuse the result: the round holds its item and writes nothing. The head passes: the
    // earlier commit already holds the fix, so the round makes no commit and pushes nothing, and
    // its writes reply "Fixed by" that commit and resolve the thread, so the item is handled.
    @Test(arguments: ["base", "unknown", "head"])
    func aByCommitMustBeInThePR(_ by: String) async throws {
        let refused = RoundFailure.badResult(
            ResultRefusal("a by commit that is not in the pull request")
        ).message(for: .request)
        let f = try await RequestFixture()
        let round = try await f.poll()
        await f.sessionWorks()
        let base = try #require(f.store.state.prs[f.pr]?.round?.baseSHA)
        let commit = [
            "base": base.hex, "unknown": String(repeating: "e", count: 40), "head": f.head.hex,
        ][by]
        try await f.endTurn(
            result: f.result([["id": "PRRT_1", "outcome": "fixed", "by": .text(commit)]]))
        await round.value
        let state = try #require(f.store.state.prs[f.pr])
        let item = try f.node("PRRT_1")
        #expect(state.round == nil && state.outbox == nil && f.notices.values.isEmpty)
        // The branch on GitHub (feat of the local source) stays at the head: nothing is pushed.
        #expect(try await f.branch() == f.head)
        if by == "head" {
            #expect(state.lastError == nil && state.held.isEmpty && state.handled[item] != nil)
            #expect(
                f.writes == [
                    .replyToThread(thread: item, body: "Fixed by \(f.head.short)"),
                    .resolveThread(item),
                ])
        } else {
            #expect(state.lastError == refused)
            #expect(state.held == [item] && state.handled[item] == nil)
            #expect(f.writes.isEmpty)
        }
        await f.end()
    }

    // A cut full read with work fails before the session: the round holds each item that it
    // wants, also past the 30 of one round, and spends the click.
    @Test func aCutReadHoldsEachWantedItem() async throws {
        var config = ReviewsConfig()
        config.autoFix = false
        let ids = (1...31).map { "PRRT_\($0)" }
        let f = try await RequestFixture(config: config, threads: ids)
        f.github.answers[RequestQueries.threadsName] = .success(
            RequestFixture.threads(ids, cut: true))
        await f.rounds.handle(f.pr, copilot: false)
        await (try #require(f.rounds.queue.task(of: f.pr))).value
        #expect(f.start == nil && f.writes.isEmpty && f.notices.values.isEmpty)
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.lastError == RoundFailure.tooManyComments.message(for: .request))
        let wanted = Set(try ids.map(f.node))
        #expect(state.held.count == 31 && Set(state.held) == wanted)
        #expect(!state.handleOlder && state.round == nil && state.checkedAt != nil)
        await f.end()
    }

    // A PR of another author fails at the full read: no session starts, and the round holds no
    // item, because it chose none.
    @Test func aPRThatIsNotYoursFails() async throws {
        let f = try await RequestFixture()
        f.github.answers[RequestQueries.contextName] = .success(
            RequestFixture.context(head: f.head, author: "user-b"))
        await (try f.poll()).value
        #expect(f.start == nil && f.writes.isEmpty && f.notices.values.isEmpty)
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.lastError == RoundFailure.notYours.message(for: .request))
        #expect(state.held.isEmpty && state.round == nil)
        await f.end()
    }

    // Under --restricted a write to a settings, git or tool configuration file asks a person for
    // approval. The session row shows the prompt, and the round ends at once: the session stops,
    // the round holds its item, posts nothing and gives the reason, with no wait on a timer.
    @Test func anApprovalPromptStopsTheRound() async throws {
        let f = try await RequestFixture()
        let round = try await f.poll()
        await f.sessionWorks()
        try "changed\n".write(
            toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        await f.show(.waiting, waitingFor: "permission")
        await f.parkWaitStarted()
        f.deps.clock.advance(by: SessionActions.parkWait)
        await round.value
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.lastError == RoundFailure.blocked.message(for: .request))
        let item = try f.node("PRRT_1")
        #expect(state.round == nil && state.held == [item])
        #expect(f.writes.isEmpty && f.notices.values.isEmpty)
        // The worktree goes back to the head: the change of the session is gone.
        let file = try String(contentsOfFile: f.worktree + "/src/a.swift", encoding: .utf8)
        #expect(file != "changed\n")
        await f.end()
    }

    // A round that was posting when Bifrost quit sends the rest of its writes at the next start:
    // only the writes that are not done. Then the round ends, and its item is handled.
    @Test func aPostingRoundSendsTheRestOfItsWritesAtStart() async throws {
        let (pr, item, head) = (
            try ReviewData.pr(), try ReviewData.node("PRRT_1"), try ReviewData.commit()
        )
        let sent = try #require(NodeID("PRRC_SENT"))
        let f = try await RequestFixture { state in
            var prState = PRState()
            prState.round = ActiveRound(
                phase: .posting, startedAt: Rows.at(-20), at: Rows.at(-30), headSHA: head,
                baseSHA: head, kind: .request, items: [item: RequestFixture.threadTime])
            prState.outbox = Outbox(
                headSHA: head, mergeBase: head, startedAt: Rows.at(-10),
                seen: [item: RequestFixture.threadTime],
                posts: [
                    OutboxPost(
                        id: "reply:PRRT_1", state: .done,
                        write: .reply(item: item, text: "We keep it.", by: nil, comment: sent)),
                    OutboxPost(id: "resolve:PRRT_1", state: .todo, write: .resolve(item: item)),
                    OutboxPost(id: "rerequest", state: .todo, write: .rerequest(logins: nil)),
                ])
            state.prs[pr] = prState
        }
        await waitUntil { f.store.state.prs[f.pr]?.round == nil }
        #expect(f.writes == [.resolveThread(item)])
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.outbox == nil && state.lastError == nil && state.handled[item] != nil)
        #expect(f.store.state.posted.map(\.id) == [sent])
        #expect(f.start == nil)
        await f.end()
    }

    // The writes of an earlier round that Try again sends first: Stop session, a drop of the PR
    // and Remove all clones do not cancel them. Each write goes, and then the round stops with no
    // session, as the halt asks.
    @Test(arguments: ["stop", "drop", "remove"])
    func aHaltWaitsForTheWritesOfAnEarlierRound(_ halt: String) async throws {
        let (pr, head) = (try ReviewData.pr(), try ReviewData.commit())
        let (first, second) = (try ReviewData.node("PRRT_1"), try ReviewData.node("PRRT_2"))
        let outbox = Outbox(
            headSHA: head, mergeBase: head, startedAt: Rows.at(-10),
            seen: [first: RequestFixture.threadTime, second: RequestFixture.threadTime],
            posts: [
                try Posts.reply("PRRT_1", "We keep it."), try Posts.resolve("PRRT_1"),
                try Posts.reply("PRRT_2", "No change needed."), try Posts.resolve("PRRT_2"),
            ])
        let f = try await RequestFixture(threads: ["PRRT_1", "PRRT_2"]) { state in
            var prState = PRState()
            prState.outbox = outbox
            prState.lastError = "GitHub stopped after 0 of 4 updates."
            state.prs[pr] = prState
        }
        let (rounds, removal) = (f.rounds, Recorder<Task<String?, Never>>())
        f.github.onWrite = { write in
            guard case .replyToThread(first, _) = write else { return }
            switch halt {
            case "stop": await rounds.stopSession(pr)
            case "drop": rounds.afterPoll(Rows.answer(mine: []))
            default: removal.record(Task { await rounds.removeAll { nil } })
            }
        }
        await f.rounds.tryAgain(f.pr)
        await (try #require(f.rounds.queue.task(of: f.pr))).value
        for task in removal.values { #expect(await task.value == nil) }
        #expect(
            f.writes == [
                .replyToThread(thread: first, body: "We keep it."), .resolveThread(first),
                .replyToThread(thread: second, body: "No change needed."), .resolveThread(second),
            ])
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.round == nil && state.outbox == nil && f.start == nil)
        // After a Stop session the row says that the earlier updates went and Claude did not
        // start, not that nothing was posted.
        if halt == "stop" {
            #expect(
                state.lastError
                    == "You stopped the round after Bifrost sent the rest of the earlier updates, "
                    + "so Claude didn't start. Choose Try again to start over.")
            #expect(state.lastError?.contains("posted nothing") == false)
        }
        f.github.onWrite = nil
        await f.end()
    }

    // Don't send the rest drops a kept outbox with a click: the item whose writes went is
    // handled, the other item waits in held, the reason of the stop clears, and nothing goes to
    // GitHub.
    @Test func dontSendTheRestDropsAKeptOutbox() async throws {
        let (pr, head) = (try ReviewData.pr(), try ReviewData.commit())
        let (first, second) = (try ReviewData.node("PRRT_1"), try ReviewData.node("PRRT_2"))
        let outbox = Outbox(
            headSHA: head, mergeBase: head, startedAt: Rows.at(-10),
            seen: [first: RequestFixture.threadTime, second: RequestFixture.threadTime],
            posts: [
                try Posts.reply("PRRT_1", "We keep it.", .done), try Posts.resolve("PRRT_1", .done),
                try Posts.reply("PRRT_2", "No change needed.", .sending),
                try Posts.resolve("PRRT_2"), Posts.rerequest(),
            ])
        let f = try await RequestFixture(threads: ["PRRT_1", "PRRT_2"]) { state in
            var prState = PRState()
            prState.outbox = outbox
            prState.lastError = "GitHub stopped after 2 of 5 updates."
            state.prs[pr] = prState
        }
        await f.rounds.dropOutbox(f.pr, click: UserClick())
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.outbox == nil && state.lastError == nil)
        #expect(state.handled[first] != nil && state.held == [second])
        #expect(f.writes.isEmpty && f.rounds.queue.task(of: f.pr) == nil)
        await f.end()
    }

    // A round whose session ran when Bifrost quit waits for the end of that session after the
    // next start, and checks its result against the saved items and token.
    @Test func aRunningRoundGoesOnAfterARestart() async throws {
        let f = try await RequestFixture()
        _ = try await f.poll()
        await f.sessionWorks()
        try await f.restart()
        #expect(f.store.state.prs[f.pr]?.round?.phase == .running)
        let round = try #require(f.rounds.queue.task(of: f.pr))
        try await f.endTurn(result: f.result([["id": "PRRT_1", "outcome": "no-action"]]))
        await round.value
        #expect(f.store.state.prs[f.pr]?.handled[try f.node("PRRT_1")] != nil)
        #expect(f.store.state.prs[f.pr]?.round == nil)
        #expect(f.deps.calls.claudeRuns.filter { $0.first == "--bg" }.count == 1)
        await f.end()
    }
}
