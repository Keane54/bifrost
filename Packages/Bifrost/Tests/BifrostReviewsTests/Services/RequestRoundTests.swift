// The request rounds (docs/behaviour/reviews.md, "Request rounds"), end to end: the real git on a
// local bare source with a PR head at refs/pull/7/head and at its branch feat, a Reviews store
// and a trusted clone in a temporary folder, the in-process FakeGitHub for the full read and the
// writes, and the real registry on scripted session lists with a fake claude (FakeActionDeps).
// The test plays the session: it shows its rows and writes its result file. A later round of
// the PR types its prompt into the same session through a fake text input. No test reaches
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
    // The lines of the Event log.
    let events = Recorder<String>()
    // The clock of the rounds: a sleep on it moves the time of the rounds at once.
    let clock = GapClock()
    // The text input of the sessions: it records each prompt that a round types.
    let prompts = RecordingPromptInput()
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
            polls: polls, events: events, prompts: prompts, clock: clock)
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
        notices: Recorder<ReviewsNotice>, polls: Recorder<Bool>, events: Recorder<String>,
        prompts: RecordingPromptInput, clock: GapClock
    ) -> ReviewRounds {
        let sessions = PRSessions(
            store: store, registry: deps.registry, actions: deps.makeActions(),
            claude: deps.claudeRunner(), clock: deps.clock, now: { Rows.now }, testPrefix: true,
            input: { prompts })
        let rounds = ReviewRounds(
            store: store, github: GitHubClient(access: github), repos: repos.store, setup: setup,
            sessions: sessions, skills: skills, userHome: home, config: config,
            now: { Rows.now }, clock: clock)
        rounds.answer = { answer }
        rounds.notify = { notices.record($0) }
        rounds.ended = { polls.record(true) }
        rounds.eventLine = { events.record($0) }
        return rounds
    }

    // A quit and a new start of Bifrost on the same state.
    func restart() async throws {
        rounds.stop()
        await rounds.waitForEnd()
        rounds = Self.rounds(
            store: store, deps: deps, github: github, repos: repos, setup: setup, skills: skills,
            home: home, config: config, answer: answer, notices: notices,
            polls: polls, events: events, prompts: prompts, clock: clock)
        rounds.start()
    }

    func end() async {
        rounds.stop()
        await rounds.waitForEnd()
        await store.close().value
        repos.folder.remove()
    }

    // The first page of the full read: the open PR of the author (the user) at the head.
    static func context(
        head: CommitID, state: String = "OPEN", author: String = Rows.viewer, fork: Bool = false
    ) -> Data {
        ReviewData.json([
            "data": [
                "repository": [
                    "pullRequest": [
                        "id": "PR_kwDOrepo7", "url": "https://github.com/Owner-A/Repo-A/pull/7",
                        "title": "Add the cache", "body": "The body.", "state": .string(state),
                        "author": ["login": .string(author)], "isCrossRepository": .bool(fork),
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
        await turnWaitSawWork()
    }

    // The wait for the end of the turn saw the working row: its timer is at the time limit of
    // the turn (RoundEnd rule 4), not at a time after an idle row. The clock did not move since
    // the start of the turn.
    func turnWaitSawWork() async {
        let limit = deps.clock.now.offset + ReviewRounds.requestLimit
        await waitUntil { self.deps.clock.nextDeadline?.offset == limit }
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

    // The files of the round that runs, from the token of the round in the state.
    func files() throws -> RoundFiles {
        let token = try #require(store.state.prs[pr]?.round?.token)
        return RoundFiles(folder: URL(filePath: input, directoryHint: .isDirectory), token: token)
    }

    // The names of the files in the round folder.
    var inputNames: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: input)) ?? [])
    }

    // The input file of the round.
    func inputFile() throws -> [String: JSONValue] {
        let data = try Data(contentsOf: try files().input)
        return try #require(try JSONDecoder().decode(JSONValue.self, from: data).object)
    }

    // A result file of the round with the items, the commit and the checks. The token of the
    // round comes from its input file, as the session reads it. head: the head of the round, by
    // default the head of the PR at the start of the test.
    func result(
        _ items: [JSONValue], commit: JSONValue = .null, checks: String = "none",
        head: CommitID? = nil
    ) throws -> Data {
        ReviewData.json([
            "version": 1, "pr": "Owner-A/Repo-A#7", "headSha": .string((head ?? self.head).hex),
            "round": try inputFile()["round"] ?? .null, "items": .array(items),
            "commit": commit, "checks": .string(checks),
        ])
    }

    // The turn ends: the good result file of the round lands and the row is idle.
    func endTurn(result: Data) async throws {
        try result.write(to: try files().result)
        await show(.idle)
    }

    // A later round of the PR types its prompt into the session: the send count reaches sends,
    // the round runs, and the row works.
    func typedTurnWorks(sends: Int) async {
        await waitUntil { self.prompts.sends.count == sends }
        await waitUntil { self.store.state.prs[self.pr]?.round?.phase == .running }
        await show(.busy)
        await turnWaitSawWork()
    }

    // The poll of the PR of the user with the threads of a member.
    func answer(threads: [String]) throws -> PollAnswer {
        Rows.answer(mine: [
            try Rows.pull(
                "Owner-A/Repo-A#7", author: Rows.viewer,
                threads: try threads.map {
                    try Rows.thread($0, by: Self.member, at: Self.threadTime)
                })
        ])
    }

    // A reviewer adds a thread: the full read and the poll show the threads, and the poll
    // queues an automatic round. The result is the task of the round.
    // The round starts at once, or, while an own request of the person runs, right after it.
    func newThreads(_ threads: [String]) async throws -> Task<Void, Never> {
        github.answers[RequestQueries.threadsName] = .success(Self.threads(threads))
        rounds.afterPoll(try answer(threads: threads))
        await waitUntil { self.rounds.queue.task(of: self.pr) != nil }
        return try #require(rounds.queue.task(of: pr))
    }

    // The claude --bg runs, in order.
    var bgRuns: [[String]] { deps.calls.claudeRuns.filter { $0.first == "--bg" } }

    // The names of the files of the round, with the full diff.
    func names(of files: RoundFiles) -> Set<String> {
        let id = files.id
        return ["input-\(id).json", "full-\(id).diff", "mode-\(id).md", "rules-\(id).md"]
    }

    // A person works in the session: a change of a file that git tracks, and a new file.
    func personWorks() throws {
        try "person\n".write(toFile: worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        try "work\n".write(toFile: worktree + "/notes.txt", atomically: false, encoding: .utf8)
    }

    // True when both changes of personWorks are in the worktree.
    var workOfThePersonStays: Bool {
        (try? String(contentsOfFile: worktree + "/src/a.swift", encoding: .utf8)) == "person\n"
            && FileManager.default.fileExists(atPath: worktree + "/notes.txt")
    }

    // A round of the PR ends with no action on PRRT_1, and its session stays idle.
    func firstRound() async throws -> RoundFiles {
        let first = try await poll()
        await sessionWorks()
        let made = try files()
        try await endTurn(result: result([["id": "PRRT_1", "outcome": "no-action"]]))
        await first.value
        return made
    }

    // A later round waits for the session: the timer of busyWait sleeps.
    func roundWaits() async {
        let deadline = deps.clock.now.offset + PRSessions.busyWait
        await waitUntil { self.deps.clock.nextDeadline?.offset == deadline }
    }

    var writes: [GitHubWrite] {
        github.calls.compactMap { if case .write(let write) = $0 { write } else { nil } }
    }

    // The count of the first pages of the full read: one for each round that read.
    var reads: Int {
        github.calls.count { $0 == .read(RequestQueries.contextName) }
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

    // MARK: - The own requests

    // The own request file of the PR, in its input folder.
    var ownRequestFile: String { input + "/" + OwnRequestFile.name }

    // The session writes the own request file: the paths and the message of the commit, on the
    // head (by default the head of the PR at the start of the test). extra adds fields.
    func writeOwnRequest(
        paths: [String], message: String = "refactor: rename the helper", head: CommitID? = nil,
        extra: [String: JSONValue] = [:]
    ) throws {
        var fields: [String: JSONValue] = [
            "version": 1, "pr": "Owner-A/Repo-A#7", "headSha": .string((head ?? self.head).hex),
            "commit": ["message": .string(message), "paths": .array(paths.map(JSONValue.string))],
        ]
        fields.merge(extra) { _, new in new }
        try ReviewData.json(.object(fields)).write(to: URL(filePath: ownRequestFile))
    }

    // A turn of the person in the session: the row works, the session changes the files (work),
    // and the row is idle again.
    func personTurn(_ work: () throws -> Void) async throws {
        await show(.busy)
        try work()
        await show(.idle)
    }

    // The own request that a turn of the person started ended: its line is in the Event log, and
    // its task ended. A file from the turn of a round has its own line.
    func ownEnded() async {
        await waitUntil {
            self.events.values.contains {
                $0.contains("the change you asked for") || $0.contains("while it worked on")
            } && self.rounds.ownRuns[self.pr] == nil
        }
    }

    // The commit that the worktree is at.
    func worktreeHead() async -> CommitID? { await repos.store.worktreeHead(pr) }

    // The line of the Event log for an own request of PR 7 that did not go.
    static func ownStopLine(_ reason: String) -> String {
        "Reviews: Bifrost didn't push the change you asked for on Owner-A/Repo-A#7. \(reason)"
    }

    // The text of src/a.swift in the worktree.
    var fileA: String? {
        try? String(contentsOfFile: worktree + "/src/a.swift", encoding: .utf8)
    }

    // The text of src/a.swift with line 11 set to the text.
    static func lineEleven(_ text: String) -> String {
        var lines = (1...20).map { "line \($0)" }
        lines[10] = text
        return lines.joined(separator: "\n") + "\n"
    }

    // The output of plain git in the bare source, with no white space at its ends.
    func sourceGit(_ args: [String]) async -> String {
        let bare = repos.root + "/sources/" + pr.repo.key + ".git"
        let result = await ProcessRunner().run(
            Command(
                "/usr/bin/git", ["-C", bare] + args, environment: repos.env,
                timeout: .seconds(30)))
        return result.stdout.trimmed()
    }

    // Another person pushes a commit to the branch feat that sets line 11 of src/a.swift to the
    // text. The result is the new head of the branch.
    func otherPush(lineEleven text: String) async throws -> CommitID {
        let work = repos.root + "/work/" + pr.repo.key
        try Self.lineEleven(text).write(
            toFile: work + "/src/a.swift", atomically: false, encoding: .utf8)
        try await repos.setup(["commit", "-q", "-am", "theirs"], in: work)
        try await repos.setup(
            ["push", "-q", repos.root + "/sources/" + pr.repo.key + ".git", "HEAD:refs/heads/feat"],
            in: work)
        return try await branch()
    }

    // GitHub moves refs/pull/7/head with the branch feat, and the full read gives its head.
    func followBranch() async throws {
        try await repos.setup(
            ["update-ref", "refs/pull/7/head", "refs/heads/feat"],
            in: repos.root + "/sources/" + pr.repo.key + ".git")
        github.answers[RequestQueries.contextName] = .success(
            Self.context(head: try await branch()))
    }

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
    // request flags and the sandbox of the clone, and reads the round folder with the input file
    // (the token and the items), the full diff, the mode and the rules, each with the round ID of
    // the token in its name. A fix ends with the commit of
    // the listed file on the branch, the "Fixed by" reply and the resolve; the item is handled,
    // and the next poll starts no round on it again by itself.
    @Test func aRoundStartsTheSessionWithTheSandboxInTheWorktree() async throws {
        let f = try await RequestFixture()
        let round = try await f.poll()
        await f.sessionWorks()
        let start = try #require(f.start)
        #expect(start.directory == f.worktree + "/")
        let clone = f.repos.layout.clone(f.pr.repo).plainPath
        let files = try f.files()
        let inputFile = files.input
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
        let id = files.id
        let prompt = "/bifrost-resolve-comments bifrost-input=\(f.input)/input-\(id).json"
        #expect(start.args.last == prompt)
        #expect(
            f.inputNames
                == ["input-\(id).json", "full-\(id).diff", "mode-\(id).md", "rules-\(id).md"])
        #expect(try String(contentsOf: files.file("mode", "md"), encoding: .utf8) == "The mode.\n")
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
        #expect(rows.first?.mineState?.claude == .needsYou(comments: 2, ci: false))
        f.rounds.afterPoll(f.answer)
        #expect(f.store.state.queue.isEmpty)
        #expect(f.notices.values.count == 1)
        // The session stays, so the user can read its chat.
        #expect(f.store.state.prs[f.pr]?.requestSession != nil)
        #expect(!f.deps.calls.claudeRuns.contains { $0.first == "rm" })
        await f.end()
    }

    // The round checks the bytes of the result that ended the turn. A session that writes
    // another text into its result file after the end (here at the count of the changes of the
    // worktree) changes nothing: the question of the good result is saved.
    @Test func aResultWrittenAfterTheTurnEndChangesNothing() async throws {
        let runner = RewritingRunner()
        let f = try await RequestFixture(runner: runner)
        let round = try await f.poll()
        await f.sessionWorks()
        let resultFile = try f.files().result.path(percentEncoded: false)
        runner.arm(file: resultFile, text: "{ not json")
        try await f.endTurn(
            result: f.result([
                ["id": "PRRT_1", "outcome": "needs-you", "question": "Rename it or keep it?"]
            ]))
        await round.value
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.round == nil && state.lastError == nil)
        #expect(state.questions[try f.node("PRRT_1")]?.text == "Rename it or keep it?")
        let rewritten = try String(contentsOfFile: resultFile, encoding: .utf8)
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

    // A full read that fails holds no item, so the next poll would queue the round again. The
    // poll waits WorkRule.readRetry instead: a read that keeps failing costs one read in each
    // wait, and a short error gives one good round after the wait.
    @Test func aFailedReadQueuesNoRoundUntilTheWaitEnds() async throws {
        let f = try await RequestFixture()
        f.github.answers[RequestQueries.contextName] = .failure(.unknownOutcome("Bad gateway"))
        await (try f.poll()).value
        let error = RoundFailure.readFailed(.unknownOutcome("Bad gateway"))
        #expect(f.store.state.prs[f.pr]?.lastError == error.message(for: .request))
        // The polls in the wait queue nothing and read nothing.
        f.rounds.afterPoll(f.answer)
        try await f.clock.sleep(for: WorkRule.readRetry - .seconds(1))
        f.rounds.afterPoll(f.answer)
        #expect(f.rounds.queue.task(of: f.pr) == nil)
        #expect(f.reads == 1)

        // After the wait, GitHub answers again: the next poll gives one good round.
        f.github.answers[RequestQueries.contextName] = .success(
            RequestFixture.context(head: f.head))
        try await f.clock.sleep(for: .seconds(1))
        _ = try await f.poll()
        await waitUntil { f.store.state.prs[f.pr]?.checkedAt != nil }
        #expect(f.reads == 2)
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

    // MARK: - The one session of the PR

    // Two rounds of a PR use one session: the first round starts it, and the second round types
    // its prompt into it, with no claude run. The second round reads its own files, with its own
    // round ID in their names, and the files of the first round are gone.
    @Test func twoRoundsUseOneSession() async throws {
        let f = try await RequestFixture()
        let first = try await f.poll()
        await f.sessionWorks()
        let one = try f.files()
        try await f.endTurn(result: f.result([["id": "PRRT_1", "outcome": "no-action"]]))
        await first.value
        #expect(f.store.state.prs[f.pr]?.handled[try f.node("PRRT_1")] != nil)
        let second = try await f.newThreads(["PRRT_1", "PRRT_2"])
        await f.typedTurnWorks(sends: 1)
        let two = try f.files()
        #expect(two.id != one.id)
        let prompt = PRSessionArgs.requestPrompt(two.input)
        #expect(f.prompts.sends == [.init(session: RequestFixture.id, text: prompt)])
        #expect(f.bgRuns.count == 1)
        let id = two.id
        #expect(
            f.inputNames
                == ["input-\(id).json", "full-\(id).diff", "mode-\(id).md", "rules-\(id).md"])
        #expect(try f.inputFile()["items"]?.array?.compactMap { $0.object?["id"] } == ["PRRT_2"])
        #expect(f.store.state.prs[f.pr]?.requestSession?.rounds == 2)
        try await f.endTurn(result: f.result([["id": "PRRT_2", "outcome": "no-action"]]))
        await second.value
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.handled[try f.node("PRRT_2")] != nil && state.lastError == nil)
        #expect(!f.deps.calls.claudeRuns.contains { $0.first == "rm" || $0.first == "stop" })
        await f.end()
    }

    // A late result of the last round never ends the next round: it lands under the round ID of
    // the last round, so the next round waits for its own file.
    @Test func aResultFileOfTheLastRoundNeverEndsTheNextRound() async throws {
        let f = try await RequestFixture()
        let first = try await f.poll()
        await f.sessionWorks()
        let one = try f.files()
        let late = try f.result([["id": "PRRT_1", "outcome": "no-action"]])
        try await f.endTurn(result: late)
        await first.value
        let second = try await f.newThreads(["PRRT_1", "PRRT_2"])
        await f.typedTurnWorks(sends: 1)
        let two = try f.files()
        // The session writes the result of the last round again, and gets idle.
        try late.write(to: one.result)
        await f.show(.idle)
        // With no good result of its own, the turn waits for the settle time after work.
        let settle = f.deps.clock.now.offset + RoundEnd.settle
        await waitUntil { f.deps.clock.nextDeadline?.offset == settle }
        #expect(f.store.state.prs[f.pr]?.round?.phase == .running)
        try f.result([["id": "PRRT_2", "outcome": "no-action"]]).write(to: two.result)
        await second.value
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.handled[try f.node("PRRT_2")] != nil && state.lastError == nil)
        await f.end()
    }

    // An answer in the Answer panel goes into the session that asked: the next round types its
    // prompt into the same session, and its input holds the question and the answer.
    @Test func anAnswerGoesIntoTheSessionThatAsked() async throws {
        let f = try await RequestFixture()
        let first = try await f.poll()
        await f.sessionWorks()
        try await f.endTurn(
            result: f.result([
                ["id": "PRRT_1", "outcome": "needs-you", "question": "Rename it or keep it?"]
            ]))
        await first.value
        let item = try f.node("PRRT_1")
        #expect(await f.rounds.answerQuestions(f.pr, [item: .text("Rename it.")]))
        let second = try #require(f.rounds.queue.task(of: f.pr))
        await f.typedTurnWorks(sends: 1)
        #expect(
            f.prompts.sends
                == [
                    .init(
                        session: RequestFixture.id,
                        text: PRSessionArgs.requestPrompt(try f.files().input))
                ])
        #expect(f.bgRuns.count == 1)
        let items = try #require(try f.inputFile()["items"]?.array?.compactMap { $0.object })
        #expect(items.map { $0["id"] } == ["PRRT_1"])
        #expect(items.first?["question"] == "Rename it or keep it?")
        #expect(items.first?["answer"] == "Rename it.")
        try await f.endTurn(result: f.result([["id": "PRRT_1", "outcome": "no-action"]]))
        await second.value
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.questions.isEmpty && state.handled[item] != nil)
        #expect(state.requestSession?.sessionID.text == RequestFixture.id)
        await f.end()
    }

    // A later round whose session stops to ask for approval ends at once as blocked, and the
    // round stops the session, as the reason says. The session stays the session of the PR, so
    // the next round can resume it with its history.
    @Test func aBlockedLaterTurnStopsTheSessionAndKeepsIt() async throws {
        let f = try await RequestFixture()
        let first = try await f.poll()
        await f.sessionWorks()
        try await f.endTurn(result: f.result([["id": "PRRT_1", "outcome": "no-action"]]))
        await first.value
        let second = try await f.newThreads(["PRRT_1", "PRRT_2"])
        await f.typedTurnWorks(sends: 1)
        await f.show(.waiting, waitingFor: "permission")
        await waitUntil {
            f.deps.calls.claudeRuns.contains(["stop", "abcdef12"])
                || f.store.state.prs[f.pr]?.round == nil
        }
        try #require(f.deps.calls.claudeRuns.contains(["stop", "abcdef12"]))
        await f.parkWaitStarted()
        f.deps.clock.advance(by: SessionActions.parkWait)
        await second.value
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.lastError == RoundFailure.blocked.message(for: .request))
        let item = try f.node("PRRT_2")
        #expect(state.round == nil && state.held == [item])
        #expect(state.requestSession?.sessionID.text == RequestFixture.id)
        #expect(!f.deps.calls.claudeRuns.contains { $0.first == "rm" })
        await f.end()
    }

    // A later round waits while a person works in the session, and fails as busy after
    // busyWait: nothing is typed, the item waits in held, and the session stays. The worktree
    // keeps the work of the person from before the round, and the round folder gets no file of
    // the round.
    @Test func aBusySessionFailsTheRoundAndKeepsTheWorktree() async throws {
        let f = try await RequestFixture()
        let one = try await f.firstRound()
        await f.show(.busy)
        try f.personWorks()
        let second = try await f.newThreads(["PRRT_1", "PRRT_2"])
        await f.roundWaits()
        f.deps.clock.advance(by: PRSessions.busyWait)
        await second.value
        let state = try #require(f.store.state.prs[f.pr])
        let item = try f.node("PRRT_2")
        #expect(state.lastError == RoundFailure.sessionBusy.message(for: .request))
        #expect(state.round == nil && state.held == [item])
        #expect(f.prompts.sends.isEmpty && f.bgRuns.count == 1)
        #expect(state.requestSession?.sessionID.text == RequestFixture.id)
        #expect(f.workOfThePersonStays)
        #expect(!f.inputNames.isEmpty && f.inputNames.allSatisfy { $0.contains(one.id) })
        await f.end()
    }

    // A later round waits while a person uses the session (it works, or it shows a box that the
    // person answers). Until the session is free, the round changes no file: the work of the
    // person stays, and the round folder gets no file of the round. When the row is idle with
    // no box, the safety net finds the changes that no round made (here with no own request
    // file): they stay, the round types nothing and holds its item, and the row needs the user
    // with the reason. Once the person undoes the changes, Handle now starts the round, and
    // the round resets the worktree, writes its files and types its prompt.
    @Test(arguments: ["working", "box"])
    func theSafetyNetKeepsTheWorkOfThePersonAndStartsNoRound(_ use: String) async throws {
        let f = try await RequestFixture()
        let one = try await f.firstRound()
        if use == "box" {
            await f.show(.waiting, waitingFor: "permission")
        } else {
            await f.show(.busy)
        }
        try f.personWorks()
        let second = try await f.newThreads(["PRRT_1", "PRRT_2"])
        await f.roundWaits()
        #expect(f.workOfThePersonStays)
        #expect(!f.inputNames.isEmpty && f.inputNames.allSatisfy { $0.contains(one.id) })
        #expect(f.prompts.sends.isEmpty)
        // The person is done: a box goes when the session works again, then the row is idle.
        if use == "box" { await f.show(.busy) }
        await f.show(.idle)
        await second.value
        let reason = RoundFailure.changesNotOnGitHub.message(for: .request)
        let state = try #require(f.store.state.prs[f.pr])
        let item = try f.node("PRRT_2")
        #expect(state.waitsForYou == reason && state.lastError == nil)
        #expect(state.waiting?.kind == .unpushedRequest)
        #expect(state.round == nil && state.held == [item])
        #expect(f.prompts.sends.isEmpty && f.writes.isEmpty)
        #expect(f.workOfThePersonStays)
        #expect(f.inputNames.allSatisfy { $0.contains(one.id) })
        let answer = try f.answer(threads: ["PRRT_1", "PRRT_2"])
        #expect(
            Rows.mine(answer, f.store.state).first?.mineState?.claude == .unpushedComments)
        // The reason keeps the files, so the row offers Discard these changes for them.
        #expect(state.waiting?.files == ["notes.txt", "src/a.swift"])
        #expect(Rows.mine(answer, f.store.state).first?.unsavedFiles == 2)
        // The person undoes the changes. Handle now starts the round again.
        try RequestFixture.lineEleven("line eleven").write(
            toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        try FileManager.default.removeItem(atPath: f.worktree + "/notes.txt")
        await f.rounds.handle(f.pr, copilot: false)
        let third = try #require(f.rounds.queue.task(of: f.pr))
        await f.typedTurnWorks(sends: 1)
        #expect(f.store.state.prs[f.pr]?.waitsForYou == nil)
        let two = try f.files()
        #expect(f.inputNames == f.names(of: two))
        try await f.endTurn(result: f.result([["id": "PRRT_2", "outcome": "no-action"]]))
        await third.value
        #expect(f.store.state.prs[f.pr]?.lastError == nil)
        await f.end()
    }

    // A round that fixed a file and left another file that it did not list: with nobody in the
    // session, the reset after the commit removes it. With a person in the session at that time,
    // the reset waits, and the next round still resets the leftover, because the round made it:
    // the safety net does not stop the round.
    @Test(arguments: [false, true])
    func theUnlistedLeftoversOfAFinishedRoundStillReset(_ inUse: Bool) async throws {
        let f = try await RequestFixture()
        let round = try await f.poll()
        await f.sessionWorks()
        let leftover = f.worktree + "/leftover.txt"
        try "fixed\n".write(toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        try "left\n".write(toFile: leftover, atomically: false, encoding: .utf8)
        if inUse {
            // The person types into the session while Bifrost reads the PR after the turn.
            f.github.onRead = { _ in
                f.github.onRead = nil
                await f.show(.busy)
            }
        }
        try await f.endTurn(
            result: f.result(
                [["id": "PRRT_1", "outcome": "fixed"]],
                commit: ["message": "fix: use the new name", "paths": ["src/a.swift"]],
                checks: "passed"))
        await round.value
        #expect(FileManager.default.fileExists(atPath: leftover) == inUse)
        #expect(try await f.branch() != f.head)
        // The person is done, with no change.
        if inUse { await f.show(.idle) }
        let second = try await f.newThreads(["PRRT_1", "PRRT_2"])
        await f.typedTurnWorks(sends: 1)
        #expect(!FileManager.default.fileExists(atPath: leftover))
        #expect(f.store.state.prs[f.pr]?.waitsForYou == nil)
        try await f.endTurn(result: f.result([["id": "PRRT_2", "outcome": "no-action"]]))
        await second.value
        #expect(f.store.state.prs[f.pr]?.lastError == nil)
        await f.end()
    }

    // An Interrupt of the person at the send stops the round, and leaves the session and its
    // worktree as the person left it: the round holds its item, and it stops and resets nothing.
    @Test func anInterruptAtTheSendKeepsTheWorktree() async throws {
        let f = try await RequestFixture()
        _ = try await f.firstRound()
        f.prompts.refusals = [.cancelled]
        f.prompts.onSend = { try? f.personWorks() }
        let second = try await f.newThreads(["PRRT_1", "PRRT_2"])
        await second.value
        let state = try #require(f.store.state.prs[f.pr])
        let item = try f.node("PRRT_2")
        #expect(state.lastError == RoundFailure.stopped.message(for: .request))
        #expect(state.round == nil && state.held == [item])
        #expect(f.prompts.sends.count == 1)
        #expect(f.workOfThePersonStays)
        #expect(!f.deps.calls.claudeRuns.contains { $0.first == "stop" || $0.first == "rm" })
        #expect(state.requestSession?.sessionID.text == RequestFixture.id)
        await f.end()
    }

    // Stop session on a round that still waits for a busy session: the round stops with nothing
    // posted and holds its item. Its turn never started, so it resets nothing.
    @Test func stopSessionWhileTheRoundWaitsKeepsTheWorktree() async throws {
        let f = try await RequestFixture()
        _ = try await f.firstRound()
        await f.show(.busy)
        try f.personWorks()
        let second = try await f.newThreads(["PRRT_1", "PRRT_2"])
        await f.roundWaits()
        let stop = Task { await f.rounds.stopSession(f.pr) }
        await second.value
        await f.parkWaitStarted()
        f.deps.clock.advance(by: SessionActions.parkWait)
        await stop.value
        let state = try #require(f.store.state.prs[f.pr])
        let item = try f.node("PRRT_2")
        #expect(state.lastError == RoundFailure.stopped.message(for: .request))
        #expect(state.round == nil && state.held == [item])
        #expect(f.prompts.sends.isEmpty && f.writes.isEmpty)
        #expect(f.workOfThePersonStays)
        await f.end()
    }

    // A person can use the session after its turn. While the row works, the round does not reset
    // the worktree after the turn, also not after the fix commit, so the work of the person
    // stays. The next round resets the worktree after its wait.
    @Test(arguments: [false, true])
    func aSessionInUseAfterItsTurnKeepsTheWorktree(_ fix: Bool) async throws {
        let f = try await RequestFixture()
        let round = try await f.poll()
        await f.sessionWorks()
        // The person types into the session while Bifrost reads the PR after the turn.
        let notes = f.worktree + "/notes.txt"
        f.github.onRead = { _ in
            f.github.onRead = nil
            await f.show(.busy)
            try? "work\n".write(toFile: notes, atomically: false, encoding: .utf8)
        }
        if fix {
            try "fixed\n".write(
                toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
            try await f.endTurn(
                result: f.result(
                    [["id": "PRRT_1", "outcome": "fixed"]],
                    commit: ["message": "fix: use the new name", "paths": ["src/a.swift"]],
                    checks: "passed"))
        } else {
            try await f.endTurn(result: f.result([["id": "PRRT_1", "outcome": "no-action"]]))
        }
        await round.value
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.round == nil && state.lastError == nil)
        #expect(state.handled[try f.node("PRRT_1")] != nil)
        #expect(FileManager.default.fileExists(atPath: notes))
        if fix { #expect(try await f.branch() != f.head) }
        await f.end()
    }

    // MARK: - The own requests of the user

    // Between rounds, the person asks Claude in the session for a change. At the end of that turn
    // (the row worked and is idle again), Bifrost commits the listed path with the message of the
    // own request file, as one commit on the head, and pushes it once. The file goes, the row
    // needs nothing, the Event log says that the change went, and no reply goes to GitHub. A
    // later poll finds no file and pushes nothing more.
    @Test func aValidOwnRequestCommitsTheListedPathAndPushesOnce() async throws {
        let f = try await RequestFixture()
        _ = try await f.firstRound()
        let notes = f.worktree + "/notes.txt"
        try await f.personTurn {
            try RequestFixture.lineEleven("line eleven, renamed").write(
                toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
            try "not listed\n".write(toFile: notes, atomically: false, encoding: .utf8)
            try f.writeOwnRequest(paths: ["src/a.swift"], message: "refactor: rename line 11")
        }
        await f.ownEnded()
        let pushed = try await f.branch()
        #expect(pushed != f.head)
        #expect(
            await f.sourceGit(["log", "-1", "--format=%P %s", pushed.hex])
                == "\(f.head.hex) refactor: rename line 11")
        #expect(
            await f.sourceGit(["diff", "--name-only", f.head.hex, pushed.hex]) == "src/a.swift")
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.outbox == nil && state.waitsForYou == nil && state.lastError == nil)
        #expect(!FileManager.default.fileExists(atPath: f.ownRequestFile))
        #expect(await f.worktreeHead() == pushed)
        #expect(f.writes.isEmpty && f.notices.values.isEmpty)
        #expect(
            f.events.values
                == [
                    "Reviews: Bifrost committed and pushed the change you asked for on "
                        + "Owner-A/Repo-A#7."
                ])
        f.rounds.afterPoll(f.answer)
        await waitUntil { f.rounds.ownRuns[f.pr] == nil }
        #expect(try await f.branch() == pushed)
        #expect(f.events.values.count == 1)
        // The change that the file does not list stays, so the next round asks the person.
        try #require(FileManager.default.fileExists(atPath: notes))
        let second = try await f.newThreads(["PRRT_1", "PRRT_2"])
        await second.value
        #expect(
            f.store.state.prs[f.pr]?.waitsForYou
                == RoundFailure.changesNotOnGitHub.message(for: .request))
        #expect(FileManager.default.fileExists(atPath: notes) && f.prompts.sends.isEmpty)
        await f.end()
    }

    // An own request file that breaks one rule is refused whole: Bifrost makes no commit and
    // pushes nothing, the change stays in the worktree, the file goes, and the row needs the
    // user with the reason. Each case breaks one rule: a message that skips CI, a message with a
    // control character, a path that did not change, a path in the .git folder, a path two
    // times, a field that an own request does not have, and the head of another commit.
    @Test(arguments: ["skip", "control", "unchanged", "git", "twice", "field", "head"])
    func anOwnRequestThatBreaksARuleIsRefusedWhole(_ broken: String) async throws {
        let f = try await RequestFixture()
        _ = try await f.firstRound()
        var (message, paths) = ("refactor: rename line 11", ["src/a.swift"])
        var (head, extra): (CommitID?, [String: JSONValue]) = (nil, [:])
        let refusal: String
        switch broken {
        case "skip":
            message = "refactor: rename line 11 [skip ci]"
            refusal = "the commit message asks to skip CI"
        case "control":
            message = "refactor: rename line 11\u{7}"
            refusal = "the commit message has a control character"
        case "unchanged":
            paths = ["src/a.swift", "src/b.swift"]
            refusal = "path 2 of the commit did not change"
        case "git":
            paths = [".git/config"]
            refusal = "path 1 of the commit is in a .git folder"
        case "twice":
            paths = ["src/a.swift", "src/a.swift"]
            refusal = "path 2 of the commit shows more than one time"
        case "field":
            extra = ["items": .array([])]
            refusal = "an unknown field"
        default:
            let other = try #require(CommitID(String(repeating: "e", count: 40)))
            head = other
            refusal = "the headSha field is not the commit of the pull request's copy"
        }
        let changed = RequestFixture.lineEleven("line eleven, renamed")
        try await f.personTurn {
            try changed.write(
                toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
            try f.writeOwnRequest(paths: paths, message: message, head: head, extra: extra)
        }
        await f.ownEnded()
        let reason = OwnRequestStop.badFile(ResultRefusal(refusal)).message
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.waitsForYou == reason && state.outbox == nil)
        #expect(try await f.branch() == f.head)
        #expect(await f.worktreeHead() == f.head)
        #expect(f.fileA == changed)
        #expect(!FileManager.default.fileExists(atPath: f.ownRequestFile))
        #expect(f.events.values == [RequestFixture.ownStopLine(reason)])
        #expect(Rows.mine(f.answer, f.store.state).first?.mineState?.claude == .waitsForYou(reason))
        await f.end()
    }

    // Bifrost acts on an own request only when nobody uses the session: while the row works or
    // shows a box, a poll and the turns change nothing, and the file waits.
    @Test(arguments: ["working", "box"])
    func nothingHappensWhileTheSessionIsInUse(_ use: String) async throws {
        let f = try await RequestFixture()
        _ = try await f.firstRound()
        if use == "box" {
            await f.show(.waiting, waitingFor: "permission")
        } else {
            await f.show(.busy)
        }
        try "changed\n".write(
            toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        try f.writeOwnRequest(paths: ["src/a.swift"])
        f.rounds.afterPoll(f.answer)
        f.rounds.checkOwnRequest(f.pr)
        #expect(f.rounds.ownRuns[f.pr] == nil)
        #expect(FileManager.default.fileExists(atPath: f.ownRequestFile))
        f.rounds.afterPoll(f.answer)
        await waitUntil { f.rounds.ownRuns[f.pr] == nil }
        #expect(try await f.branch() == f.head)
        #expect(f.store.state.prs[f.pr]?.outbox == nil)
        #expect(f.store.state.prs[f.pr]?.waitsForYou == nil)
        #expect(!f.events.values.contains { $0.contains("the change you asked for") })
        await f.end()
    }

    // A message that the person types while a round runs, here handled in the turn of the round
    // with its own request file: no poll acts on it while the round holds the session. At the end
    // of the turn nothing counts as a change of the round, so no reset removes the change, and
    // the file goes as an own request right after the round.
    @Test func anOwnRequestFromTheTurnOfARoundGoesAfterTheRound() async throws {
        let f = try await RequestFixture()
        let round = try await f.poll()
        await f.sessionWorks()
        let changed = RequestFixture.lineEleven("line eleven, renamed")
        try changed.write(toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        try f.writeOwnRequest(paths: ["src/a.swift"], message: "refactor: rename line 11")
        f.rounds.afterPoll(f.answer)
        #expect(f.rounds.ownRuns[f.pr] == nil)
        try await f.endTurn(result: f.result([["id": "PRRT_1", "outcome": "no-action"]]))
        await round.value
        await f.ownEnded()
        let pushed = try await f.branch()
        #expect(
            await f.sourceGit(["log", "-1", "--format=%P %s", pushed.hex])
                == "\(f.head.hex) refactor: rename line 11")
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.handled[try f.node("PRRT_1")] != nil)
        #expect(state.waitsForYou == nil && state.outbox == nil && state.lastError == nil)
        #expect(f.fileA == changed)
        // Bifrost can't tell whether a person asked for it, so the Event log says what it knows.
        #expect(
            f.events.values.last
                == "Reviews: Bifrost committed and pushed a change that Claude made while it "
                + "worked on Owner-A/Repo-A#7.")
        await f.end()
    }

    // Stop session in the turn of a round: with no own request file, the reset of the stop
    // removes the changes of the turn as before. With an own request file (a person asked for a
    // change in the turn), the change stays, and it goes as an own request after the round.
    @Test(arguments: [false, true])
    func stopSessionInATurnKeepsAChangeThatAPersonAskedFor(_ file: Bool) async throws {
        let f = try await RequestFixture()
        let round = try await f.poll()
        await f.sessionWorks()
        let changed = RequestFixture.lineEleven("line eleven, renamed")
        try changed.write(toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        if file { try f.writeOwnRequest(paths: ["src/a.swift"]) }
        let stop = Task { await f.rounds.stopSession(f.pr) }
        await round.value
        await f.parkWaitStarted()
        f.deps.clock.advance(by: SessionActions.parkWait)
        await stop.value
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.lastError == RoundFailure.stopped.message(for: .request))
        // The session no longer works.
        await f.show(.idle)
        if file {
            await f.ownEnded()
            #expect(f.fileA == changed)
            #expect(try await f.branch() != f.head)
        } else {
            #expect(f.fileA == RequestFixture.lineEleven("line eleven"))
            #expect(try await f.branch() == f.head)
        }
        await f.end()
    }

    // The person undoes the changes in the session after the safety net stopped the round, so
    // the files that the reason keeps are gone. A pick of Discard these changes then finds
    // nothing to discard: it says so, and the reason clears.
    @Test func aDiscardAfterTheChangesWentFindsNothing() async throws {
        let f = try await RequestFixture()
        _ = try await f.firstRound()
        try await f.personTurn { try f.personWorks() }
        let second = try await f.newThreads(["PRRT_1", "PRRT_2"])
        await second.value
        #expect(f.store.state.prs[f.pr]?.waiting?.files.count == 2)
        try await f.personTurn {
            try RequestFixture.lineEleven("line eleven").write(
                toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
            try FileManager.default.removeItem(atPath: f.worktree + "/notes.txt")
        }
        await waitUntil { f.rounds.ownRuns[f.pr] == nil }
        #expect(await f.rounds.changesToDiscard(f.pr) == .nothing)
        #expect(f.store.state.prs[f.pr]?.waiting == nil)
        #expect(await f.rounds.discardChanges(f.pr, click: UserClick()) == .notNow)
        await f.end()
    }

    // Discard these changes on a row that the safety net stopped: the files of the change go,
    // the reason clears, the Event log says so, and Handle now starts the round. Before the
    // reason shows, and while a round runs, the discard does nothing.
    @Test func discardTheseChangesResetsTheCopyAndClearsTheReason() async throws {
        let f = try await RequestFixture()
        _ = try await f.firstRound()
        try await f.personTurn { try f.personWorks() }
        #expect(await f.rounds.changesToDiscard(f.pr) == .notNow)
        #expect(await f.rounds.discardChanges(f.pr, click: UserClick()) == .notNow)
        #expect(f.workOfThePersonStays)
        let second = try await f.newThreads(["PRRT_1", "PRRT_2"])
        await second.value
        #expect(f.store.state.prs[f.pr]?.waitsForYou != nil)
        #expect(await f.rounds.changesToDiscard(f.pr) == .files(["notes.txt", "src/a.swift"]))
        #expect(await f.rounds.discardChanges(f.pr, click: UserClick()) == .discarded)
        #expect(f.fileA == RequestFixture.lineEleven("line eleven"))
        #expect(!FileManager.default.fileExists(atPath: f.worktree + "/notes.txt"))
        #expect(f.store.state.prs[f.pr]?.waitsForYou == nil)
        #expect(
            f.events.values.last
                == "Reviews: Bifrost discarded the changes in its copy of Owner-A/Repo-A#7.")
        await f.rounds.handle(f.pr, copilot: false)
        let third = try #require(f.rounds.queue.task(of: f.pr))
        await f.typedTurnWorks(sends: 1)
        try await f.endTurn(result: f.result([["id": "PRRT_2", "outcome": "no-action"]]))
        await third.value
        #expect(f.store.state.prs[f.pr]?.lastError == nil)
        await f.end()
    }

    // A prompt box refuses the send of the round, and a person works in the session through the
    // box. When the session is free again, the round checks the worktree again before it types:
    // the changes of the person stay, nothing more is typed, and the row needs the user.
    @Test func aPromptAtTheSendChecksTheWorktreeAgain() async throws {
        let f = try await RequestFixture()
        _ = try await f.firstRound()
        f.prompts.refusals = [.prompt]
        let second = try await f.newThreads(["PRRT_1", "PRRT_2"])
        await waitUntil { f.prompts.sends.count == 1 }
        await f.show(.busy)
        try f.personWorks()
        await f.show(.idle)
        await waitUntil {
            f.store.state.prs[f.pr]?.round == nil || f.prompts.sends.count == 2
        }
        try #require(f.prompts.sends.count == 1)
        await second.value
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.waitsForYou == RoundFailure.changesNotOnGitHub.message(for: .request))
        #expect(state.held == [try f.node("PRRT_2")] && state.lastError == nil)
        #expect(f.workOfThePersonStays)
        await f.end()
    }

    // Don't send the rest while an own request runs changes nothing: the row offers no item for
    // those writes, and a click that comes anyway keeps the outbox. The change goes to GitHub.
    @Test func dontSendTheRestDuringAnOwnRequestChangesNothing() async throws {
        let f = try await RequestFixture()
        _ = try await f.firstRound()
        let offered = Recorder<Bool>()
        f.github.onRead = { name in
            guard name == RequestQueries.contextName, f.store.state.prs[f.pr]?.outbox != nil
            else { return }
            f.github.onRead = nil
            offered.record(Rows.mine(f.answer, f.store.state).first?.unsentUpdates == true)
            await f.rounds.dropOutbox(f.pr, click: UserClick())
        }
        try await f.personTurn {
            try RequestFixture.lineEleven("line eleven, renamed").write(
                toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
            try f.writeOwnRequest(paths: ["src/a.swift"])
        }
        await f.ownEnded()
        #expect(offered.values == [false])
        let pushed = try await f.branch()
        #expect(pushed != f.head)
        #expect(await f.worktreeHead() == pushed)
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.outbox == nil && state.waitsForYou == nil)
        await f.end()
    }

    // Try again on a kept own outbox sends it through the own request: a push that goes clears
    // the reason and writes the line of the own request in the Event log; a conflict shows Needs
    // you with the text of the own request, not an error of a round, and keeps the change.
    @Test(arguments: [false, true])
    func tryAgainSendsAKeptOwnOutboxAsAnOwnRequest(_ conflict: Bool) async throws {
        let f = try await RequestFixture()
        _ = try await f.firstRound()
        let theirs = conflict ? try await f.otherPush(lineEleven: "line eleven, theirs") : nil
        let mine = RequestFixture.lineEleven("line eleven, mine")
        try mine.write(toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        let (pr, head) = (f.pr, f.head)
        await f.store.update { state in
            state.prs[pr]?.outbox = Outbox(
                headSHA: head, mergeBase: head, startedAt: Rows.at(-10), seen: [:],
                posts: [
                    OutboxPost(
                        id: OutboxRules.commitID, state: .todo,
                        write: .commit(paths: ["src/a.swift"], message: "fix: mine", commit: nil)),
                    OutboxPost(
                        id: OutboxRules.pushID, state: .todo,
                        write: .push(commit: nil, signed: false)),
                ],
                own: true)
            state.prs[pr]?.waitsForYou = "Bifrost couldn't push your change."
        }
        #expect(Rows.mine(f.answer, f.store.state).first?.unsentUpdates == true)
        await f.rounds.tryAgain(f.pr)
        await (try #require(f.rounds.queue.task(of: f.pr))).value
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.lastError == nil && state.outbox == nil && state.round == nil)
        if let theirs {
            let reason = OwnRequestStop.wrote(.pushFailed(.conflict)).message
            #expect(state.waitsForYou == reason)
            #expect(f.events.values.last == RequestFixture.ownStopLine(reason))
            #expect(try await f.branch() == theirs)
            #expect(await f.worktreeHead() == f.head && f.fileA == mine)
        } else {
            #expect(state.waitsForYou == nil)
            #expect(
                f.events.values.last
                    == "Reviews: Bifrost committed and pushed the change you asked for on "
                    + "Owner-A/Repo-A#7.")
            #expect(try await f.branch() != f.head)
        }
        await f.end()
    }

    // An own request that waits when a round gets the session goes first: the round changes
    // nothing, Bifrost commits and pushes the change, and the round starts again on the new head
    // of the PR, in the same session.
    @Test func aWaitingOwnRequestGoesBeforeTheRound() async throws {
        let f = try await RequestFixture()
        _ = try await f.firstRound()
        await f.show(.busy)
        try RequestFixture.lineEleven("line eleven, renamed").write(
            toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        try f.writeOwnRequest(paths: ["src/a.swift"])
        // GitHub moves the head of the PR with its branch.
        f.github.onRead = { name in
            guard name == RequestQueries.contextName else { return }
            try? await f.followBranch()
        }
        let second = try await f.newThreads(["PRRT_1", "PRRT_2"])
        await f.roundWaits()
        #expect(FileManager.default.fileExists(atPath: f.ownRequestFile))
        await f.show(.idle)
        await f.typedTurnWorks(sends: 1)
        let pushed = try await f.branch()
        #expect(pushed != f.head)
        #expect(
            await f.sourceGit(["log", "-1", "--format=%P %s", pushed.hex])
                == "\(f.head.hex) refactor: rename the helper")
        #expect(!FileManager.default.fileExists(atPath: f.ownRequestFile))
        #expect(try f.inputFile()["pr"]?.object?["headSha"] == .string(pushed.hex))
        #expect(f.bgRuns.count == 1)
        try await f.endTurn(
            result: f.result([["id": "PRRT_2", "outcome": "no-action"]], head: pushed))
        await second.value
        f.github.onRead = nil
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.handled[try f.node("PRRT_2")] != nil)
        #expect(state.lastError == nil && state.waitsForYou == nil && state.outbox == nil)
        await f.end()
    }

    // Someone pushed a change to the same line: the merge of the own change conflicts, so Bifrost
    // pushes nothing. The row needs the user with the reason, the Event log has it, and the change
    // stays in the worktree as changes on the head: its commit goes back to changes.
    @Test func aPushConflictKeepsTheChangeAndNeedsTheUser() async throws {
        let f = try await RequestFixture()
        _ = try await f.firstRound()
        let theirs = try await f.otherPush(lineEleven: "line eleven, theirs")
        let mine = RequestFixture.lineEleven("line eleven, mine")
        try await f.personTurn {
            try mine.write(toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
            try f.writeOwnRequest(paths: ["src/a.swift"])
        }
        await f.ownEnded()
        #expect(try await f.branch() == theirs)
        #expect(await f.worktreeHead() == f.head)
        #expect(f.fileA == mine)
        #expect(await f.repos.store.changedPaths(f.pr) == ["src/a.swift"])
        let reason = OwnRequestStop.wrote(.pushFailed(.conflict)).message
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.waitsForYou == reason && state.outbox == nil && state.lastError == nil)
        #expect(f.events.values.last == RequestFixture.ownStopLine(reason))
        await f.end()
    }

    // A PR from a fork never gets a push. With a poll that says fork, Bifrost does not act on
    // the own request. When the fresh read of GitHub says fork, the writes stop before the
    // commit: no commit, no push, and the change stays.
    @Test func aForkPRNeverPushes() async throws {
        let f = try await RequestFixture()
        _ = try await f.firstRound()
        let fork = Rows.answer(mine: [
            try Rows.pull("Owner-A/Repo-A#7", author: Rows.viewer, fork: true)
        ])
        // The last good poll says fork too.
        f.rounds.answer = { fork }
        let changed = RequestFixture.lineEleven("line eleven, renamed")
        try changed.write(toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        try f.writeOwnRequest(paths: ["src/a.swift"])
        f.rounds.afterPoll(fork)
        f.rounds.checkOwnRequest(f.pr, in: fork)
        #expect(f.rounds.ownRuns[f.pr] == nil)
        #expect(FileManager.default.fileExists(atPath: f.ownRequestFile))
        f.github.answers[RequestQueries.contextName] = .success(
            RequestFixture.context(head: f.head, fork: true))
        let answer = f.answer
        f.rounds.answer = { answer }
        f.rounds.checkOwnRequest(f.pr)
        await f.ownEnded()
        let reason = OwnRequestStop.wrote(.fork).message
        #expect(f.store.state.prs[f.pr]?.waitsForYou == reason)
        #expect(try await f.branch() == f.head)
        #expect(await f.worktreeHead() == f.head)
        #expect(f.fileA == changed)
        await f.end()
    }

    // The session stays after the rounds of the PR, and goes when the PR merges or closes, with
    // the worktree and the round folder.
    @Test func aClosedPRDeletesItsSession() async throws {
        let f = try await RequestFixture()
        let round = try await f.poll()
        await f.sessionWorks()
        try await f.endTurn(
            result: f.result([
                ["id": "PRRT_1", "outcome": "needs-you", "question": "Rename it or keep it?"]
            ]))
        await round.value
        #expect(f.store.state.prs[f.pr]?.requestSession != nil)
        #expect(!f.deps.calls.claudeRuns.contains { $0.first == "rm" })
        f.rounds.afterPoll(Rows.answer(mine: []))
        await waitUntil { f.store.state.prs[f.pr]?.questions.isEmpty == true }
        #expect(f.deps.calls.claudeRuns.contains(["rm", "abcdef12"]))
        #expect(f.store.state.prs[f.pr]?.requestSession == nil)
        #expect(!FileManager.default.fileExists(atPath: f.worktree))
        #expect(!FileManager.default.fileExists(atPath: f.input))
        await f.end()
    }

    // Remove all clones deletes the session that stays after the rounds of the PR.
    @Test func removeAllClonesDeletesTheSession() async throws {
        let f = try await RequestFixture()
        let round = try await f.poll()
        await f.sessionWorks()
        try await f.endTurn(result: f.result([["id": "PRRT_1", "outcome": "no-action"]]))
        await round.value
        #expect(f.store.state.prs[f.pr]?.requestSession != nil)
        #expect(await f.rounds.removeAll { nil } == nil)
        #expect(f.deps.calls.claudeRuns.contains(["rm", "abcdef12"]))
        #expect(f.store.state.prs[f.pr]?.requestSession == nil)
        await f.end()
    }
}
