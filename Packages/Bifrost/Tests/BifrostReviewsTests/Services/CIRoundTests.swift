// The CI rounds (docs/behaviour/reviews.md, "My PRs"), end to end: the real git on a local bare
// source that plays GitHub, where the branch feat (the head of PR 7, also at refs/pull/7/head)
// changes line 11 of src/a.swift, a Reviews store and a trusted clone in a temporary folder, the
// in-process FakeGitHub for the poll, the fresh head reads, the job logs and the re-run writes,
// and the real registry on scripted session lists with a fake claude (FakeActionDeps). The test
// plays the session: it shows its rows, edits the worktree and writes the result file. A later
// round types its prompt through a fake text input. No test reaches GitHub, runs claude or reads
// the real ~/.claude or ~/.claude.json, and each test removes its folder at its end.
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostReviews

// The runner of git of the CI tests: it runs a one-time action after the first git status that
// follows its arm (the record of the changes at the end of the turn). The action plays a person.
private final class CIHookRunner: CommandRunner {
    private let real = ProcessRunner()
    private let afterStatus = Mutex<(@Sendable () -> Void)?>(nil)

    func afterFirstStatus(_ action: @escaping @Sendable () -> Void) {
        afterStatus.withLock { $0 = action }
    }

    func run(_ command: Command) async -> ExecResult {
        let result = await real.run(command)
        if command.arguments.contains("status"), let action = afterStatus.withLock({ $0.take() }) {
            action()
        }
        return result
    }
}

// A failed job of GitHub Actions on the head: its job ID, the ID of its workflow run and its
// name.
private struct CIJob: Sendable {
    var id: Int
    var run: Int
    var name: String
}

@MainActor
private final class CIFixture {
    static let id = "33333333-4444-5555-6666-777777777777"
    static let name = "bifrost-test-Repo-A-7-request"
    static let shortID = ShortID("abcdef12")
    // The failed job of the head, unless the test gives other jobs.
    static let test = CIJob(id: 101, run: 9001, name: "test")

    let repos: RepoFixture
    let deps = FakeActionDeps()
    let store: ReviewsStore
    let github: FakeGitHub
    let setup: RepoSetup
    private(set) var rounds: ReviewRounds
    let skills: URL
    let home: URL
    let config: ReviewsConfig
    let polls = Recorder<Bool>()
    let events = Recorder<String>()
    let notices = Recorder<ReviewsNotice>()
    let clock = GapClock()
    let prompts = RecordingPromptInput()
    let pr: PRKey
    // The head of feat and the tip of main at the start of the test.
    let head: CommitID
    let base: CommitID
    // The failed jobs that GitHub shows now.
    private(set) var jobs: [CIJob]
    // The last good poll of the rounds.
    var poll: PollAnswer

    // consent: the user confirmed the CI rounds. file: the bytes of state.json before the open of
    // the store.
    init(
        config: ReviewsConfig = ReviewsConfig(fixCI: true), consent: Bool = true,
        jobs: [CIJob] = [CIFixture.test], runner: any CommandRunner = ProcessRunner(),
        file: String? = nil
    ) async throws {
        self.config = config
        self.jobs = jobs
        repos = try RepoFixture(runner: runner)
        let repo = try #require(RepoName("Owner-A/Repo-A"))
        pr = try #require(PRKey(repo: repo, number: 7))
        base = try await repos.source(repo, files: ["src/a.swift": Self.lines()])
        let work = repos.root + "/work/" + repo.key
        try await repos.setup(["checkout", "-q", "-b", "feat"], in: work)
        head = try await Self.commit(
            repos, work, [11: "line eleven feat"], refs: ["refs/pull/7/head", "refs/heads/feat"])
        try await repos.setup(["checkout", "-q", "main"], in: work)
        if let file {
            try FileManager.default.createDirectory(
                at: repos.layout.folder, withIntermediateDirectories: true)
            try file.write(to: repos.layout.stateFile, atomically: false, encoding: .utf8)
        }
        store = try await ReviewsStore.open(layout: repos.layout, log: Recorder<StoreEvent>())
        // Claude Code trusts the clone (the .claude.json of the temporary home).
        let clone = String(repos.clone(repo).dropLast())
        try "{\"projects\": {\"\(clone)\": {\"hasTrustDialogAccepted\": true}}}".write(
            toFile: repos.root + "/.claude.json", atomically: false, encoding: .utf8)
        let skillsPath = repos.root + "/skills"
        skills = URL(filePath: skillsPath, directoryHint: .isDirectory)
        let file = skillsPath + "/" + CIRound.modeFile
        try FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "The CI mode.\n".write(toFile: file, atomically: false, encoding: .utf8)
        home = URL(filePath: repos.root, directoryHint: .isDirectory)
        github = FakeGitHub(answers: [
            HeadQueries.name: .success(Self.headRead(head: head, base: base, jobs: jobs)),
            FakeGitHub.rerunKey: .success(Data()),
        ])
        for job in jobs { github.answers["job-log \(job.id)"] = .success(Self.log(job)) }
        poll = try Self.answer(head: head, base: base, jobs: jobs)
        setup = RepoSetup(
            repos: repos.store, store: store, ptys: nil, home: home, notify: { _ in },
            now: { Rows.now })
        rounds = ReviewRounds(
            store: store, github: GitHubClient(access: github), repos: repos.store, setup: setup,
            sessions: PRSessions(
                store: store, registry: deps.registry, actions: deps.makeActions(),
                claude: deps.claudeRunner(), clock: deps.clock, now: { Rows.now },
                testPrefix: true, input: { [prompts] in prompts }),
            skills: skills, userHome: home, config: config, now: { Rows.now }, clock: clock)
        wire()
        deps.calls.answerClaude { args in
            args.first == "--bg"
                ? ExecResult(.exited(0), stdout: "backgrounded \u{B7} abcdef12 \u{B7} name\n")
                : ExecResult(.exited(0))
        }
        await store.update { state in
            state.turnedOnAt = Rows.at(-2 * 24 * 60)
            state.fixFrom = Rows.at(-24 * 60)
            if consent { state.consentToCIFix() }
        }
        await deps.start()
        rounds.start()
    }

    private func wire() {
        rounds.answer = { [weak self] in self?.poll }
        rounds.ended = { [polls] in polls.record(true) }
        rounds.eventLine = { [events] in events.record($0) }
        rounds.notify = { [notices] in notices.record($0) }
    }

    // A quit and a new start of Bifrost on the same state.
    func restart() async {
        rounds.stop()
        await rounds.waitForEnd()
        rounds = ReviewRounds(
            store: store, github: GitHubClient(access: github), repos: repos.store, setup: setup,
            sessions: PRSessions(
                store: store, registry: deps.registry, actions: deps.makeActions(),
                claude: deps.claudeRunner(), clock: deps.clock, now: { Rows.now },
                testPrefix: true, input: { [prompts] in prompts }),
            skills: skills, userHome: home, config: config, now: { Rows.now }, clock: clock)
        wire()
        rounds.start()
    }

    func end() async {
        rounds.stop()
        await rounds.waitForEnd()
        await store.close().value
        repos.folder.remove()
    }

    // MARK: - The data

    // The 20 lines of src/a.swift, with the changed lines by number.
    static func lines(_ changed: [Int: String] = [:]) -> String {
        (1...20).map { changed[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
    }

    // A commit of src/a.swift with the lines in the work repository, pushed to the refs of the
    // bare source. The result is the commit.
    static func commit(
        _ repos: RepoFixture, _ work: String, _ changed: [Int: String], refs: [String]
    ) async throws -> CommitID {
        try lines(changed).write(toFile: work + "/src/a.swift", atomically: false, encoding: .utf8)
        try await repos.setup(["commit", "-q", "-am", "change"], in: work)
        let bare = repos.root + "/sources/Owner-A/Repo-A.git"
        try await repos.setup(["push", "-q", "-f", bare] + refs.map { "HEAD:" + $0 }, in: work)
        let parsed = await ProcessRunner().run(
            Command(
                "/usr/bin/git", ["-C", work, "rev-parse", "HEAD"], environment: repos.env,
                timeout: .seconds(30)))
        return try #require(CommitID(parsed.stdout.trimmed()))
    }

    // The check of a failed job as the poll and the head read give it.
    static func check(_ job: CIJob) throws -> HeadCheck {
        HeadCheck(
            name: job.name, outcome: .failed("FAILURE"),
            source: .actions(job: try #require(JobID(job.id)), run: try #require(RunID(job.run))))
    }

    // The log of a failed job.
    static func log(_ job: CIJob) -> Data {
        Data("Run swift test --filter \(job.name)\nerror: line eleven is wrong\n".utf8)
    }

    // The fresh read of the head of PR 7 as GitHub gives it, with a check run of GitHub Actions
    // for each job: failed when the checks are done, else in progress. others: more check nodes.
    static func headRead(
        head: CommitID, base: CommitID, jobs: [CIJob], state: String = "OPEN",
        mergeable: String = "MERGEABLE", done: Bool = true, others: [JSONValue] = []
    ) -> Data {
        let nodes: [JSONValue] = jobs.map { job in
            [
                "__typename": "CheckRun", "name": .string(job.name),
                "status": done ? "COMPLETED" : "IN_PROGRESS",
                "conclusion": done ? "FAILURE" : .null, "databaseId": .int(job.id),
                "detailsUrl": .string(
                    "https://github.com/Owner-A/Repo-A/actions/runs/\(job.run)/job/\(job.id)"),
                "checkSuite": [
                    "app": ["slug": "github-actions"], "workflowRun": ["databaseId": .int(job.run)],
                ],
            ]
        }
        let commit: JSONValue = [
            "commit": [
                "oid": .string(head.hex),
                "statusCheckRollup": [
                    "state": "FAILURE",
                    "contexts": [
                        "pageInfo": ["hasNextPage": false], "nodes": .array(nodes + others),
                    ],
                ],
            ]
        ]
        return ReviewData.json([
            "data": [
                "repository": [
                    "pullRequest": [
                        "state": .string(state), "author": ["login": .string(Rows.viewer)],
                        "repository": ["defaultBranchRef": ["name": "main"]],
                        "mergeable": .string(mergeable), "baseRefOid": .string(base.hex),
                        "headRefName": "feat", "headRefOid": .string(head.hex),
                        "baseRefName": "main", "isCrossRepository": false,
                        "commits": ["nodes": [commit]],
                    ]
                ]
            ]
        ])
    }

    // The poll with PR 7 of the user at the head, with the failed jobs.
    static func answer(head: CommitID, base: CommitID, jobs: [CIJob]) throws -> PollAnswer {
        var pull = try Rows.pull(
            "Owner-A/Repo-A#7", author: Rows.viewer, ci: jobs.isEmpty ? .passed : .failing,
            failedChecks: jobs.count, mergeable: .mergeable, base: base.hex,
            checks: HeadChecks(checks: try jobs.map(check), onHead: true))
        pull.headSHA = head.hex
        pull.headRef = "feat"
        return Rows.answer(mine: [pull])
    }

    // GitHub shows the PR at the head with the failed jobs: the poll, the fresh read and a log
    // for each job.
    func github(head: CommitID, jobs: [CIJob]? = nil) throws {
        if let jobs { self.jobs = jobs }
        poll = try Self.answer(head: head, base: base, jobs: self.jobs)
        github.answers[HeadQueries.name] = .success(
            Self.headRead(head: head, base: base, jobs: self.jobs))
        for job in self.jobs where github.answers["job-log \(job.id)"] == nil {
            github.answers["job-log \(job.id)"] = .success(Self.log(job))
        }
    }

    // GitHub makes the signed commit on feat of the source, as createCommitOnBranch does: it
    // refuses a branch that is not at the expected head, else it commits the changes of the write
    // on that head.
    func playSignedCommits() {
        let (repos, work, bare) = (repos, work, bare)
        github.onWrite = { [weak self] write in
            guard case .createSignedCommit(let commit) = write, let self else { return }
            guard (try? await self.branch()) == commit.expectedHead else {
                self.github.answers["createCommitOnBranch"] = .failure(
                    .refused("Expected branch to point to \(commit.expectedHead.hex)"))
                return
            }
            try? await repos.setup(["checkout", "-q", "feat"], in: work)
            for change in commit.changes {
                let file = URL(filePath: work + "/" + change.path)
                if let contents = change.contents {
                    try? contents.write(to: file)
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            try? await repos.setup(["add", "-A"], in: work)
            // GitHub signs these commits as itself. Using its identity here also keeps the hash
            // apart from Bifrost's local fix commit, which has the same tree, parent and message
            // and could land in the same second.
            try? await repos.setup(
                [
                    "-c", "user.name=GitHub", "-c", "user.email=noreply@github.com", "commit", "-q",
                    "-m", commit.headline,
                ], in: work)
            try? await repos.setup(["push", "-q", "-f", bare, "HEAD:refs/heads/feat"], in: work)
            try? await repos.setup(["checkout", "-q", "main"], in: work)
            guard let made = try? await self.branch() else { return }
            self.github.answers["createCommitOnBranch"] = .success(WritesData.signed(made))
        }
    }

    // The user turns the setting off at the first change of the state of the PR that meets the
    // rule, for example right after a save of the round.
    func closeGate(when rule: @escaping @MainActor (PRState) -> Bool) {
        let (store, pr) = (store, pr)
        let closed = Mutex(false)
        rounds.changed = { [weak rounds] in
            guard !closed.withLock({ $0 }), let state = store.state.prs[pr], rule(state) else {
                return
            }
            closed.withLock { $0 = true }
            rounds?.apply(ReviewsConfig(fixCI: false))
        }
    }

    // MARK: - The git of the source

    var bare: String { repos.root + "/sources/" + pr.repo.key + ".git" }
    var work: String { repos.root + "/work/" + pr.repo.key }
    var input: String { repos.layout.inputFolder(pr.repo, number: 7).plainPath }
    var worktree: String { GitPlace.worktree(pr, repos.layout) }
    var ownFile: String { input + "/" + OwnRequestFile.name }

    // The output of plain git in the bare source, with no white space at its ends.
    func sourceGit(_ args: [String]) async -> String {
        let result = await ProcessRunner().run(
            Command(
                "/usr/bin/git", ["-C", bare] + args, environment: repos.env,
                timeout: .seconds(30)))
        return result.stdout.trimmed()
    }

    // The head of the branch feat of the source: the branch on GitHub.
    func branch() async throws -> CommitID {
        try #require(CommitID(await sourceGit(["rev-parse", "refs/heads/feat"])))
    }

    // The raw form of a commit of the source.
    func object(_ commit: CommitID) async throws -> CommitObject {
        try #require(CommitObject(await sourceGit(["cat-file", "commit", commit.hex]) + "\n"))
    }

    // GitHub moves refs/pull/7/head with the branch feat.
    func followBranch() async throws {
        try await repos.setup(["update-ref", "refs/pull/7/head", "refs/heads/feat"], in: bare)
    }

    // The user (or another person) pushes a commit to feat that changes line 2. The result is
    // the new head.
    func userPush() async throws -> CommitID {
        try await repos.setup(["checkout", "-q", "feat"], in: work)
        let pushed = try await Self.commit(
            repos, work, [2: "line two", 11: "line eleven feat"],
            refs: ["refs/heads/feat", "refs/pull/7/head"])
        try await repos.setup(["checkout", "-q", "main"], in: work)
        return pushed
    }

    // Bifrost's copy has the worktree of an earlier round at the head.
    func placeCopy() async throws {
        let store = repos.store
        try await store.ensureClone(pr.repo)
        _ = try await store.fetchPR(pr, base: try #require(BranchName("main")))
        _ = try await store.roundFolder(pr)
        _ = try await store.placeWorktree(pr, head: head)
    }

    // MARK: - The session

    // A good poll, and the task of the round that it queued.
    func pollNow() throws -> Task<Void, Never> {
        rounds.afterPoll(poll)
        return try #require(rounds.queue.task(of: pr))
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

    // The round starts the session (a claude --bg run), its row works, and the round runs.
    func sessionWorks() async {
        await waitUntil { self.deps.calls.claudeRuns.contains { $0.first == "--bg" } }
        await show(.busy)
        await waitUntil { self.store.state.prs[self.pr]?.round?.phase == .running }
        await turnWaitSawWork()
    }

    // A later round types its prompt into the session: the send count reaches sends, the round
    // runs, and the row works.
    func typedTurnWorks(sends: Int) async {
        await waitUntil { self.prompts.sends.count == sends }
        await waitUntil { self.store.state.prs[self.pr]?.round?.phase == .running }
        await show(.busy)
        await turnWaitSawWork()
    }

    // The wait for the end of the turn saw the working row: its timer is at the time limit.
    func turnWaitSawWork() async {
        let limit = deps.clock.now.offset + ReviewRounds.limit
        await waitUntil { self.deps.clock.nextDeadline?.offset == limit }
    }

    // The files of the round that runs, from the token of the round in the state.
    func files() throws -> RoundFiles {
        let token = try #require(store.state.prs[pr]?.round?.token)
        return RoundFiles(folder: URL(filePath: input, directoryHint: .isDirectory), token: token)
    }

    // The fields of the input file of the round that runs.
    func inputFile() throws -> [String: JSONValue] {
        let data = try Data(contentsOf: try files().input)
        return try #require(try JSONDecoder().decode(JSONValue.self, from: data).object)
    }

    // The session fixes line 11 in the worktree, as Claude does.
    func fix(_ text: String = "line eleven fixed") throws {
        try Self.lines([11: text]).write(
            toFile: worktree + "/src/a.swift", atomically: false, encoding: .utf8)
    }

    // A result file of the round: fix with src/a.swift, retry, or needs-you with the question.
    // The token and the head come from the input file, as the session reads them.
    func result(_ outcome: String = "fix", question: String = "Is the network down?") throws
        -> Data
    {
        let input = try inputFile()
        var fields: [String: JSONValue] = [
            "version": 1, "pr": "Owner-A/Repo-A#7",
            "headSha": input["pr"]?.object?["headSha"] ?? .null, "round": input["round"] ?? .null,
            "outcome": .string(outcome), "reason": "The test expects line eleven.",
        ]
        switch outcome {
        case "fix":
            fields["commit"] = ["message": "fix: correct line eleven", "paths": ["src/a.swift"]]
            fields["checks"] = "passed"
        case "needs-you":
            fields["question"] = .string(question)
        default:
            break
        }
        return ReviewData.json(.object(fields))
    }

    // The turn ends: the result file lands and the row is idle.
    func endTurn(result: Data) async throws {
        try result.write(to: try files().result)
        await show(.idle)
    }

    // A round of a new failure that fixes line 11 and pushes the fix. The result is the head of
    // feat after the round.
    func fixedRound(typed sends: Int? = nil) async throws -> CommitID {
        let round = try pollNow()
        if let sends { await typedTurnWorks(sends: sends) } else { await sessionWorks() }
        try fix()
        try await endTurn(result: result())
        await ended(round)
        return try await branch()
    }

    // The state of a round that was posting its fix when Bifrost quit: the fix is committed in the
    // worktree, and the round keeps it. pushed: the fix is on GitHub already. The result is the
    // fix.
    func postingFix(pushed: Bool) async throws -> CommitID {
        let store = repos.store
        try await placeCopy()
        try fix()
        let fix = try await FixCommit.make(
            paths: ["src/a.swift"], message: "fix: correct line eleven", head: head, pr: pr,
            git: store.git)
        if pushed {
            try await repos.setup(
                ["push", "-q", bare, "\(fix.hex):refs/heads/feat"], in: repos.clone(pr.repo))
        }
        let (pr, head) = (pr, head)
        let key = [try #require(JobID(101))]
        await self.store.update { state in
            var prState = PRState()
            prState.round = ActiveRound(
                phase: .posting, startedAt: Rows.now, at: Rows.now, headSHA: head, baseSHA: head,
                kind: .ci, fixSHA: fix, token: "t1")
            prState.ci = CIMark(chain: [head], fixes: 1, handledHead: head, handled: key)
            state.prs[pr] = prState
        }
        return fix
    }

    // A round of the failure of the poll in which Claude asks "Is the network down?".
    func askedRound() async throws {
        let round = try pollNow()
        await sessionWorks()
        try await endTurn(result: result("needs-you"))
        await ended(round)
    }

    // A poll starts a round that types its prompt into the session of the PR, and the input of
    // the round holds the question and the answer of the user. Claude then asks again.
    func roundReadsTheAnswer(_ answer: String) async throws {
        let round = try pollNow()
        await typedTurnWorks(sends: 1)
        #expect(
            try inputFile()["answer"]
                == ["question": "Is the network down?", "answer": .string(answer)])
        try await endTurn(result: result("needs-you", question: "Is the runner down?"))
        await ended(round)
    }

    // The own request file of the PR, with the commit of the worktree as its head.
    func writeOwnRequest(head: CommitID) throws {
        try ReviewData.json([
            "version": 1, "pr": "Owner-A/Repo-A#7", "headSha": .string(head.hex),
            "commit": ["message": "refactor: rename the helper", "paths": ["src/a.swift"]],
        ]).write(to: URL(filePath: ownFile))
    }

    var bgRuns: [[String]] { deps.calls.claudeRuns.filter { $0.first == "--bg" } }

    // The runs of the re-run writes, in their order.
    var reruns: [RunID] {
        github.calls.compactMap { call in
            if case .write(.rerunFailedJobs(_, let run, _)) = call { run } else { nil }
        }
    }

    var signedWrites: Int {
        github.calls.count { call in
            if case .write(.createSignedCommit) = call { true } else { false }
        }
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

    var mark: CIMark? { store.state.prs[pr]?.ci }

    // The text of src/a.swift in the worktree.
    var fileA: String? { try? String(contentsOfFile: worktree + "/src/a.swift", encoding: .utf8) }

    // The commit that the worktree is at.
    func worktreeHead() async -> CommitID? { await repos.store.worktreeHead(pr) }

    // The Claude state of the row of the PR.
    var claude: ClaudeState? {
        Rows.mine(poll, store.state, config).first?.mineState?.claude
    }
}

// The end of a task of the test, such as the task of a round. A cancel of the test (its time
// limit) cancels the task too, so a round that never ends cannot hold the test.
private func ended(_ task: Task<Void, Never>?) async {
    guard let task else { return }
    await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

private func job(_ id: Int) throws -> JobID {
    try #require(JobID(id))
}

private func run(_ id: Int) throws -> RunID {
    try #require(RunID(id))
}

@MainActor
@Suite("the CI rounds", .serialized, .timeLimit(.minutes(3)), .tags(.realProcess))
struct CIRoundTests {
    // MARK: - One round

    // A poll that shows a failed Actions job starts one round. The key of the failure is saved
    // before the turn, and the session starts in the worktree at the head with the CI prompt, the
    // input, the mode, the full diff and the log of the job. Claude fixes the file. Bifrost
    // commits the fix on the head (unsigned) and pushes it to feat; the fix joins the chain, the
    // count goes up, nothing goes to lastError, and a poll runs at once. A later failure on the
    // fix types its prompt into the live session.
    @Test func aFailedJobGetsOneRoundThatPushesAFix() async throws {
        let f = try await CIFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        #expect(f.store.state.queue.isEmpty)
        #expect(f.store.state.prs[f.pr]?.round?.kind == .ci)
        let key = [try job(101)]
        #expect(f.mark?.handledHead == f.head && f.mark?.handled == key)
        let files = try f.files()
        let start = try #require(f.bgRuns.first)
        #expect(start.last == PRSessionArgs.ciPrompt(files.input))
        #expect(start.contains("--restricted"))
        #expect(await f.worktreeHead() == f.head)
        let input = try f.inputFile()
        #expect(input["allowed"] == ["fix", "retry"])
        #expect(input["tried"] == ["fixes": 0, "retries": 0] && input["answer"] == .null)
        let failed = try #require(input["failed"]?.array?.first?.object)
        #expect(failed["name"] == "test" && failed["logCut"] == .bool(false))
        let id = files.id
        let names = (try? FileManager.default.contentsOfDirectory(atPath: f.input)) ?? []
        #expect(
            Set(names) == [
                "input-\(id).json", "mode-\(id).md", "full-\(id).diff", "log-101-\(id).txt",
            ])
        let log = try String(
            contentsOf: CIInput.Files.log(files, job: try job(101)), encoding: .utf8)
        #expect(log == String(decoding: CIFixture.log(CIFixture.test), as: UTF8.self))
        try f.fix()
        try await f.endTurn(result: f.result())
        await ended(round)
        let fix = try await f.branch()
        let object = try await f.object(fix)
        #expect(object.parents == [f.head] && !object.signed)
        #expect(object.message.trimmed() == "fix: correct line eleven")
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.ci?.chain == [f.head, fix] && state.ci?.fixes == 1)
        #expect(state.ci?.retries == 0 && state.ci?.question == nil)
        #expect(state.round == nil && state.lastError == nil && state.waiting == nil)
        #expect(f.polls.values.count == 1 && f.events.values.isEmpty)
        #expect(f.notices.values.isEmpty)
        // The fix fails another job: the round types its prompt into the session.
        try await f.followBranch()
        try f.github(head: fix, jobs: [CIJob(id: 102, run: 9002, name: "lint")])
        let again = try f.pollNow()
        await f.typedTurnWorks(sends: 1)
        let sent = try #require(f.prompts.sends.first)
        #expect(sent.session == CIFixture.id && f.bgRuns.count == 1)
        let typed = PRSessionArgs.ciPrompt(try f.files().input)
        #expect(sent.text == typed)
        #expect(try f.inputFile()["tried"] == ["fixes": 1, "retries": 0])
        try await f.endTurn(result: f.result("needs-you"))
        await ended(again)
        #expect(f.mark?.chain == [f.head, fix] && f.mark?.question?.head == fix)
        await f.end()
    }

    // With Sign commits through GitHub on, the fix goes as one createCommitOnBranch write, and
    // the chain gets the commit that GitHub made.
    @Test func theFixGoesThroughGitHubWithSignCommitsOn() async throws {
        let f = try await CIFixture(config: ReviewsConfig(fixCI: true, signedCommits: true))
        f.playSignedCommits()
        let made = try await f.fixedRound()
        #expect(f.signedWrites == 1)
        #expect(try await f.object(made).parents == [f.head])
        #expect(f.mark?.chain == [f.head, made] && f.mark?.fixes == 1)
        #expect(f.store.state.prs[f.pr]?.round == nil && f.mark?.question == nil)
        await f.end()
    }

    // Claude asks for a re-run: Bifrost re-runs the failed jobs of each workflow run one time,
    // in the order of the run IDs, with the gap between two writes. The re-run counts, and the
    // row shows Retrying CI.
    @Test func aRetryReRunsOnlyTheFailedRunsOnce() async throws {
        let jobs = [
            CIJob(id: 101, run: 9002, name: "test"), CIJob(id: 102, run: 9001, name: "lint"),
            CIJob(id: 103, run: 9002, name: "build"),
        ]
        let f = try await CIFixture(jobs: jobs)
        let round = try f.pollNow()
        await f.sessionWorks()
        try await f.endTurn(result: f.result("retry"))
        await ended(round)
        let runs = [try run(9001), try run(9002)]
        #expect(f.reruns == runs)
        #expect(f.clock.spans == [RoundWrites.postGap])
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.ci?.retries == 1 && state.ci?.retrying == f.head && state.ci?.fixes == 0)
        #expect(state.round == nil && state.ci?.question == nil && state.lastError == nil)
        #expect(f.claude == .retryingCI)
        #expect(try await f.branch() == f.head && f.polls.values.count == 1)
        await f.end()
    }

    // The same head with the same failed jobs never starts a second round. Other failed jobs on
    // the same head are a new failure.
    @Test func theSameFailedJobsNeverStartASecondRound() async throws {
        let f = try await CIFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try await f.endTurn(result: f.result("retry"))
        await ended(round)
        f.rounds.afterPoll(f.poll)
        #expect(f.store.state.queue.isEmpty && f.rounds.queue.task(of: f.pr) == nil)
        #expect(f.reruns.count == 1 && f.bgRuns.count == 1)
        // The poll also looked for an own request file of the session: that check ends first.
        await waitUntil { f.rounds.ownRuns[f.pr] == nil }
        try f.github(head: f.head, jobs: [CIJob(id: 104, run: 9003, name: "test")])
        f.rounds.afterPoll(f.poll)
        #expect(f.rounds.queue.task(of: f.pr) != nil)
        await f.end()
    }

    // A chain with two fixes and one re-run gets the limits question at its next failure, with no
    // session and no send, and one notification.
    @Test func afterTheLimitsTheQuestionComesWithNoSession() async throws {
        let f = try await CIFixture()
        let (pr, head) = (f.pr, f.head)
        await f.store.update { state in
            var prState = PRState()
            prState.ci = CIMark(chain: [head], fixes: 2, retries: 1)
            state.prs[pr] = prState
        }
        await ended(try f.pollNow())
        #expect(f.bgRuns.isEmpty && f.prompts.sends.isEmpty)
        let question = try #require(f.mark?.question)
        #expect(question.text == CIStop.limits.question && !question.byClaude)
        #expect(question.head == f.head && question.jobs == ["test"])
        let key = [try job(101)]
        #expect(f.mark?.handledHead == f.head && f.mark?.handled == key)
        #expect(f.notices.values == [.needsYou(f.pr, questions: 1)])
        #expect(f.store.state.prs[f.pr]?.round == nil)
        #expect(f.rounds.ciQuestion(of: f.pr)?.question == question)
        f.rounds.afterPoll(f.poll)
        #expect(f.rounds.queue.task(of: f.pr) == nil)
        await f.end()
    }

    // A new commit of the user starts a new chain with a fresh budget.
    @Test func aNewCommitOfTheUserStartsAFreshBudget() async throws {
        let f = try await CIFixture()
        let (pr, head) = (f.pr, f.head)
        let key = [try job(101)]
        await f.store.update { state in
            var prState = PRState()
            prState.ci = CIMark(
                chain: [head], fixes: 2, retries: 1, handledHead: head, handled: key)
            state.prs[pr] = prState
        }
        let next = try await f.userPush()
        try f.github(head: next)
        let round = try f.pollNow()
        await f.sessionWorks()
        #expect(try f.inputFile()["allowed"] == ["fix", "retry"])
        #expect(try f.inputFile()["tried"] == ["fixes": 0, "retries": 0])
        #expect(f.mark?.chain == [next] && f.mark?.fixes == 0 && f.mark?.retries == 0)
        try await f.endTurn(result: f.result("needs-you"))
        await ended(round)
        #expect(f.mark?.question?.head == next)
        await f.end()
    }

    // MARK: - The questions

    // Claude asks the user: the question goes to the Answer panel with the head and the names of
    // the failed jobs, the row needs the user, one notification goes out, and the copy goes back
    // to the head.
    @Test func needsYouPutsTheQuestionInTheAnswerPanel() async throws {
        let f = try await CIFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.fix()
        try await f.endTurn(result: f.result("needs-you", question: "Is the runner down?"))
        await ended(round)
        let open = try #require(f.rounds.ciQuestion(of: f.pr))
        #expect(open.question.text == "Is the runner down?" && open.question.byClaude)
        #expect(open.question.head == f.head && open.question.jobs == ["test"])
        #expect(open.failedJobs == ["test"])
        #expect(f.notices.values == [.needsYou(f.pr, questions: 1)])
        #expect(f.claude == .needsYou(comments: 0, ci: true))
        #expect(Rows.mine(f.poll, f.store.state, f.config).first?.questions == 1)
        #expect(try await f.branch() == f.head && f.polls.values.isEmpty)
        #expect(await f.worktreeHead() == f.head)
        #expect(f.fileA == CIFixture.lines([11: "line eleven feat"]))
        #expect(f.store.state.prs[f.pr]?.lastError == nil)
        await f.end()
    }

    // An answer queues one round into the same session. The input holds the question and the
    // answer, and the answer allows one more fix also at the limits. The answered question goes
    // at the end of the round.
    @Test func anAnswerSendsOneRoundIntoTheSameSession() async throws {
        let f = try await CIFixture()
        let first = try f.pollNow()
        await f.sessionWorks()
        try await f.endTurn(result: f.result("needs-you"))
        await ended(first)
        let pr = f.pr
        await f.store.update { state in
            state.prs[pr]?.ci?.fixes = 2
            state.prs[pr]?.ci?.retries = 1
            // An old reason to wait: the files of a safety net that the user then undid.
            state.prs[pr]?.waiting = WaitsForYou(
                reason: RoundFailure.changesNotOnGitHub.message(for: .ci), files: ["old.swift"],
                kind: .unpushedCI)
        }
        #expect(await f.rounds.answerCI(f.pr, .text("  No, fix the test.  ")))
        #expect(f.mark?.question?.answer == "No, fix the test.")
        #expect(f.store.state.queue.filter { $0.kind == .ci }.count == 1)
        #expect(f.rounds.ciQuestion(of: f.pr) == nil)
        #expect(await f.rounds.answerCI(f.pr, .text("Again.")) == false)
        let again = try #require(f.rounds.queue.task(of: f.pr))
        await f.typedTurnWorks(sends: 1)
        #expect(f.prompts.sends.first?.session == CIFixture.id && f.bgRuns.count == 1)
        let input = try f.inputFile()
        #expect(
            input["answer"] == ["question": "Is the network down?", "answer": "No, fix the test."])
        #expect(input["allowed"] == ["fix"])
        try f.fix()
        try await f.endTurn(result: f.result())
        await ended(again)
        let fix = try await f.branch()
        #expect(f.mark?.chain == [f.head, fix] && f.mark?.fixes == 3)
        #expect(f.mark?.question == nil)
        // The round proved the copy clean, so the old reason goes.
        #expect(f.store.state.prs[f.pr]?.waiting == nil)
        await f.end()
    }

    // The round of an answer meets the safety net: it changes nothing, and the row shows
    // Unpushed changes. The answer cleared the key of the failure, so after Discard changes the
    // next poll starts a round that reads the answer.
    @Test func anAnswerThatMeetsTheSafetyNetGoesAfterDiscard() async throws {
        let f = try await CIFixture()
        try await f.askedRound()
        try "person\n".write(
            toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        #expect(await f.rounds.answerCI(f.pr, .text("Fix the test.")))
        await ended(f.rounds.queue.task(of: f.pr))
        #expect(f.store.state.prs[f.pr]?.waiting?.kind == .unpushedCI && f.prompts.sends.isEmpty)
        #expect(f.mark?.handledHead == nil && f.mark?.question?.answer == "Fix the test.")
        #expect(await f.rounds.discardChanges(f.pr, click: UserClick()) == .discarded)
        try await f.roundReadsTheAnswer("Fix the test.")
        await f.end()
    }

    // The user turns the setting off before the round of an answer starts: the round ends with
    // no text. When the setting is on again, the next poll starts a round that reads the answer.
    @Test func anAnswerGoesWhenTheGateOpensAgain() async throws {
        let f = try await CIFixture()
        try await f.askedRound()
        #expect(await f.rounds.answerCI(f.pr, .text("Fix the test.")))
        f.rounds.apply(ReviewsConfig(fixCI: false))
        await ended(f.rounds.queue.task(of: f.pr))
        #expect(f.prompts.sends.isEmpty && f.mark?.handledHead == nil)
        #expect(f.store.state.prs[f.pr]?.round == nil)
        f.rounds.apply(f.config)
        try await f.roundReadsTheAnswer("Fix the test.")
        await f.end()
    }

    // The round of an answer finds writes that wait (an outbox): it ends with no text. Once the
    // writes went and the retry time passed, the next poll starts a round that reads the answer.
    @Test func anAnswerGoesAfterTheWritesThatWait() async throws {
        let f = try await CIFixture()
        try await f.askedRound()
        let (pr, head, base) = (f.pr, f.head, f.base)
        let node = try #require(NodeID("PRRT_4"))
        await f.store.update { state in
            state.prs[pr]?.outbox = Outbox(
                headSHA: head, mergeBase: base, startedAt: Rows.now, seen: [:],
                posts: [OutboxPost(id: "1", state: .todo, write: .resolve(item: node))])
        }
        #expect(await f.rounds.answerCI(f.pr, .text("Fix the test.")))
        await ended(f.rounds.queue.task(of: f.pr))
        #expect(f.prompts.sends.isEmpty && f.mark?.handledHead == nil)
        await f.store.update { $0.prs[pr]?.outbox = nil }
        try await f.clock.sleep(for: WorkRule.readRetry)
        try await f.roundReadsTheAnswer("Fix the test.")
        await f.end()
    }

    // The user answers, but a push moves the head before the round of the answer runs (for
    // example, the request round of the same Send pushes its fix). The question was about the old
    // head: the round reads the new head and ends with no text, and the answer is not used. When
    // CI fails on the new head, the head gets its own round with a fresh budget.
    @Test func anAnswerForAHeadThatMovedIsNotUsedOnTheNewHead() async throws {
        let f = try await CIFixture()
        try await f.askedRound()
        let next = try await f.userPush()
        f.github.answers[HeadQueries.name] = .success(
            CIFixture.headRead(head: next, base: f.base, jobs: [CIFixture.test], done: false))
        #expect(await f.rounds.answerCI(f.pr, .text("Fix the test.")))
        await ended(f.rounds.queue.task(of: f.pr))
        #expect(f.prompts.sends.isEmpty && f.mark?.question?.head == f.head)
        #expect(f.store.state.prs[f.pr]?.round == nil && f.store.state.queue.isEmpty)
        try f.github(head: next, jobs: [CIJob(id: 105, run: 9005, name: "test")])
        #expect(f.rounds.ciQuestion(of: f.pr) == nil)
        let round = try f.pollNow()
        await f.typedTurnWorks(sends: 1)
        let input = try f.inputFile()
        #expect(input["answer"] == .null && input["allowed"] == ["fix", "retry"])
        #expect(input["tried"] == ["fixes": 0, "retries": 0])
        try await f.endTurn(result: f.result("needs-you", question: "Is the runner down?"))
        await ended(round)
        #expect(f.mark?.chain == [next] && f.mark?.question?.head == next)
        #expect(f.mark?.question?.answer == nil)
        await f.end()
    }

    // A poll while the round of an answer waits in the queue starts no second round: the answer
    // cleared the key of the failure, so the queued entry stops the rule.
    @Test func aPollWhileTheRoundOfAnAnswerWaitsStartsNoSecondRound() async throws {
        let f = try await CIFixture()
        try await f.askedRound()
        f.rounds.queue.isReady = { _ in false }
        #expect(await f.rounds.answerCI(f.pr, .text("Fix the test.")))
        #expect(f.mark?.handledHead == nil)
        let pull = try #require(f.poll.mine.first)
        let state = f.store.state
        #expect(
            !CIRule.startsRound(
                pull, state.prs[f.pr] ?? PRState(), state: state, config: f.config, busy: false))
        f.rounds.afterPoll(f.poll)
        #expect(f.store.state.queue.filter { $0.pr == f.pr && $0.kind == .ci }.count == 1)
        #expect(f.rounds.queue.waiting == [f.pr] && f.rounds.queue.task(of: f.pr) == nil)
        await f.end()
    }

    // I handle it myself: the head is the user's, the question goes, and no round starts on that
    // head, also for other failed jobs.
    @Test func handleMyselfStopsTheRoundsOnThatHead() async throws {
        let f = try await CIFixture()
        let first = try f.pollNow()
        await f.sessionWorks()
        try await f.endTurn(result: f.result("needs-you"))
        await ended(first)
        #expect(await f.rounds.answerCI(f.pr, .handleMyself))
        #expect(f.mark?.userHandles == f.head && f.mark?.question == nil)
        #expect(f.store.state.queue.isEmpty && f.rounds.queue.task(of: f.pr) == nil)
        #expect(f.rounds.ciQuestion(of: f.pr) == nil)
        try f.github(head: f.head, jobs: [CIJob(id: 104, run: 9003, name: "test")])
        f.rounds.afterPoll(f.poll)
        #expect(f.rounds.queue.task(of: f.pr) == nil && f.bgRuns.count == 1)
        await f.end()
    }

    // With the setting off or with no consent, the CI question hides and an answer does nothing.
    // A blank answer and an answer over the limit do nothing either.
    @Test func theCIQuestionHidesWithoutConsent() async throws {
        let f = try await CIFixture()
        let first = try f.pollNow()
        await f.sessionWorks()
        try await f.endTurn(result: f.result("needs-you"))
        await ended(first)
        #expect(f.rounds.ciQuestion(of: f.pr) != nil)
        f.rounds.apply(ReviewsConfig(fixCI: false))
        #expect(f.rounds.ciQuestion(of: f.pr) == nil)
        #expect(await f.rounds.answerCI(f.pr, .text("Fix it.")) == false)
        #expect(await f.rounds.answerCI(f.pr, .handleMyself) == false)
        f.rounds.apply(ReviewsConfig(fixCI: true))
        await f.store.update { $0.ciConsent = nil }
        #expect(f.rounds.ciQuestion(of: f.pr) == nil)
        #expect(await f.rounds.answerCI(f.pr, .text("Fix it.")) == false)
        await f.store.update { $0.consentToCIFix() }
        #expect(await f.rounds.answerCI(f.pr, .text("   ")) == false)
        let long = String(repeating: "a", count: Question.maxAnswer + 1)
        #expect(await f.rounds.answerCI(f.pr, .text(long)) == false)
        #expect(f.mark?.question?.answer == nil && f.mark?.userHandles == nil)
        #expect(f.store.state.queue.isEmpty && f.rounds.queue.task(of: f.pr) == nil)
        await f.end()
    }

    // MARK: - The gate

    // A failed status of another CI service, or a failed check run of another app, is status
    // only: no round starts, and nothing reads GitHub.
    @Test func otherCIServicesAreStatusOnly() async throws {
        let f = try await CIFixture(jobs: [])
        f.poll.mine[0].checks = HeadChecks(
            checks: [
                HeadCheck(name: "ci/legacy", outcome: .failed("FAILURE"), source: .status),
                HeadCheck(name: "deploy", outcome: .failed("FAILURE"), source: .app("other-app")),
            ], onHead: true)
        f.poll.mine[0].failedChecks = 2
        f.poll.mine[0].ci = .failing
        f.rounds.afterPoll(f.poll)
        #expect(f.store.state.queue.isEmpty && f.rounds.queue.task(of: f.pr) == nil)
        #expect(f.github.calls.isEmpty && f.bgRuns.isEmpty)
        let row = try #require(Rows.mine(f.poll, f.store.state, f.config).first)
        #expect(row.mineState?.claude == .waiting && row.tag != nil)
        // A failed Actions job next to them starts a round.
        f.poll.mine[0].checks.checks.append(try CIFixture.check(CIFixture.test))
        f.rounds.afterPoll(f.poll)
        #expect(f.rounds.queue.task(of: f.pr) != nil)
        await f.end()
    }

    // A PR with conflicts gets no CI round: with the conflict setting off nothing starts, and with
    // it on the conflict round goes first.
    @Test func aConflictingPRWaitsForTheConflictRound() async throws {
        let f = try await CIFixture()
        f.poll.mine[0].mergeable = .conflicting
        f.rounds.afterPoll(f.poll)
        #expect(f.store.state.queue.isEmpty && f.rounds.queue.task(of: f.pr) == nil)
        // With no conflicts, the same failure starts a round.
        f.poll.mine[0].mergeable = .mergeable
        f.rounds.afterPoll(f.poll)
        #expect(f.rounds.queue.task(of: f.pr) != nil)
        await f.end()

        let g = try await CIFixture(config: ReviewsConfig(resolveConflicts: true, fixCI: true))
        await g.store.update { $0.consentToConflictFix() }
        g.poll.mine[0].mergeable = .conflicting
        g.rounds.afterPoll(g.poll)
        #expect(g.store.state.queue.map(\.kind) == [.conflict])
        // The fresh read sees no conflicts, so the conflict round ends with no text, and the CI
        // rule still waits for the poll to show no conflicts.
        await ended(g.rounds.queue.task(of: g.pr))
        g.rounds.afterPoll(g.poll)
        #expect(g.rounds.queue.task(of: g.pr) == nil && g.mark == nil)
        await g.end()
    }

    // MARK: - The checks before the writes

    // Another person pushes to feat during the turn: the push finds new commits and pushes
    // nothing (BranchMoved.stop), with no question, and the copy goes back to the head.
    @Test func aBranchThatMovesDuringTheRoundGetsNoFix() async throws {
        let f = try await CIFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        let moved = try await f.userPush()
        try f.fix()
        try await f.endTurn(result: f.result())
        await ended(round)
        #expect(try await f.branch() == moved)
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.ci?.question == nil && state.round == nil && state.lastError == nil)
        #expect(state.ci?.chain == [f.head])
        #expect(await f.worktreeHead() == f.head)
        await f.end()
    }

    // The user turns the setting off during the turn: the round checks the gate again before the
    // re-run and before the push, so nothing goes to GitHub, with no text.
    @Test func turningTheSettingOffStopsTheRerunAndThePush() async throws {
        let f = try await CIFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        f.rounds.apply(ReviewsConfig(fixCI: false))
        try await f.endTurn(result: f.result("retry"))
        await ended(round)
        #expect(f.reruns.isEmpty && f.mark?.retries == 0 && f.mark?.retrying == nil)
        #expect(f.mark?.question == nil && f.store.state.prs[f.pr]?.round == nil)
        #expect(f.store.state.prs[f.pr]?.lastError == nil)
        await f.end()

        let g = try await CIFixture()
        let fix = try g.pollNow()
        await g.sessionWorks()
        try g.fix()
        g.rounds.apply(ReviewsConfig(fixCI: false))
        try await g.endTurn(result: g.result())
        await ended(fix)
        #expect(try await g.branch() == g.head)
        #expect(g.mark?.fixes == 0 && g.mark?.question == nil)
        #expect(g.store.state.prs[g.pr]?.round == nil)
        #expect(await g.worktreeHead() == g.head)
        await g.end()
    }

    // The user turns the setting off while the first re-run write runs: the gate is checked again
    // just before the next write, after the gap, so only the first run is re-run. The round ends
    // as a re-run.
    @Test func theGateIsCheckedAgainBeforeEachRerun() async throws {
        let jobs = [
            CIJob(id: 101, run: 9001, name: "test"), CIJob(id: 102, run: 9002, name: "lint"),
        ]
        let f = try await CIFixture(jobs: jobs)
        let round = try f.pollNow()
        await f.sessionWorks()
        let rounds = f.rounds
        f.github.onWrite = { write in
            if case .rerunFailedJobs = write { rounds.apply(ReviewsConfig(fixCI: false)) }
        }
        try await f.endTurn(result: f.result("retry"))
        await ended(round)
        #expect(f.reruns == [try run(9001)])
        #expect(f.clock.spans == [RoundWrites.postGap])
        #expect(f.mark?.retries == 1 && f.mark?.retrying == f.head)
        #expect(f.store.state.prs[f.pr]?.round == nil && f.mark?.question == nil)
        #expect(f.polls.values.count == 1)
        await f.end()
    }

    // The user turns the setting off right after the save of the re-run: no write goes, the
    // round ends with no text, and the row doesn't show Retrying CI. The re-run stays spent.
    @Test func aGateThatClosesAfterTheRerunSaveSendsNothing() async throws {
        let f = try await CIFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        f.closeGate { $0.round?.phase == .posting }
        try await f.endTurn(result: f.result("retry"))
        await ended(round)
        #expect(f.reruns.isEmpty && f.mark?.retries == 1 && f.mark?.retrying == nil)
        #expect(f.mark?.question == nil && f.store.state.prs[f.pr]?.round == nil)
        #expect(f.claude != .retryingCI && f.polls.values.isEmpty)
        await f.end()
    }

    // The user turns the setting off right after the save of the fix: the gate is checked again
    // just before the push, so nothing goes to GitHub, and the copy goes back to the head. The
    // fix stays spent.
    @Test func aGateThatClosesAfterTheFixSavePushesNothing() async throws {
        let f = try await CIFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.fix()
        f.closeGate { $0.round?.fixSHA != nil }
        try await f.endTurn(result: f.result())
        await ended(round)
        #expect(try await f.branch() == f.head)
        #expect(f.mark?.fixes == 1 && f.mark?.chain == [f.head] && f.mark?.question == nil)
        #expect(f.store.state.prs[f.pr]?.round == nil && f.polls.values.isEmpty)
        #expect(await f.worktreeHead() == f.head)
        await f.end()
    }

    // GitHub refuses the fix because the gh login has no workflow scope: nothing is pushed, the
    // question says what to run, and the Event log keeps the line of GitHub.
    @Test func aPushThatLacksTheWorkflowScopeNamesTheCommand() async throws {
        let f = try await CIFixture(config: ReviewsConfig(fixCI: true, signedCommits: true))
        let line =
            "refusing to allow an OAuth App to create or update workflow without workflow scope"
        f.github.answers["createCommitOnBranch"] = .failure(.refused(line))
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.fix()
        try await f.endTurn(result: f.result())
        await ended(round)
        #expect(try await f.branch() == f.head && f.signedWrites == 1)
        let question = try #require(f.mark?.question)
        #expect(
            question.text
                == "GitHub refused Claude's fix because it changes a workflow file and your "
                + "GitHub login can't push workflow changes, so run gh auth refresh -h github.com "
                + "-s workflow in a terminal. Tell Claude what to try next, or fix it yourself.")
        #expect(question.head == f.head && !question.byClaude)
        #expect(f.events.values.contains { $0.contains(line) })
        #expect(f.store.state.prs[f.pr]?.lastError == nil)
        await f.end()
    }

    // A re-run write that times out may have reached GitHub: the question sends the user to
    // GitHub, and Bifrost never sends it again: not after a restart in posting (the same question
    // comes again), not at the next poll, and not for an answer (the round of the answer may not
    // give a re-run).
    @Test func aRerunThatMayHaveGoneIsNeverSentAgain() async throws {
        let f = try await CIFixture()
        f.github.answers[FakeGitHub.rerunKey] = .failure(.timedOut)
        let round = try f.pollNow()
        await f.sessionWorks()
        try await f.endTurn(result: f.result("retry"))
        await ended(round)
        #expect(f.reruns.count == 1)
        #expect(f.mark?.question?.text == CIStop.rerun(.timedOut).question)
        #expect(f.mark?.question?.byClaude == false)
        #expect(f.mark?.retries == 1 && f.mark?.retrying == f.head)
        #expect(f.polls.values.count == 1 && f.events.values.count == 1)
        #expect(f.store.state.prs[f.pr]?.lastError == nil)
        let (pr, head) = (f.pr, f.head)
        await f.store.update { state in
            state.prs[pr]?.round = ActiveRound(
                phase: .posting, startedAt: Rows.now, at: Rows.now, headSHA: head, kind: .ci)
        }
        await f.restart()
        #expect(f.store.state.prs[f.pr]?.round == nil && f.rounds.queue.task(of: f.pr) == nil)
        #expect(f.mark?.retrying == nil)
        #expect(f.mark?.question?.text == CIStop.unknownRerun.question)
        f.rounds.afterPoll(f.poll)
        #expect(f.rounds.queue.task(of: f.pr) == nil && f.reruns.count == 1)
        #expect(await f.rounds.answerCI(f.pr, .text("Try it again.")))
        let again = try #require(f.rounds.queue.task(of: f.pr))
        await f.typedTurnWorks(sends: 1)
        #expect(try f.inputFile()["allowed"] == ["fix"])
        try await f.endTurn(result: f.result("needs-you", question: "Is the runner down?"))
        await ended(again)
        #expect(f.reruns.count == 1 && f.mark?.retries == 1)
        #expect(f.mark?.question?.text == "Is the runner down?")
        await f.end()
    }

    // A fix that was posting when Bifrost quit pushes after the next start. A fix that reached
    // GitHub before the quit goes no second time: the push checks the branch first.
    @Test(arguments: [false, true])
    func aPostingFixPushesAfterARestart(_ alreadyPushed: Bool) async throws {
        let f = try await CIFixture()
        let fix = try await f.postingFix(pushed: alreadyPushed)
        await f.restart()
        let round = try #require(f.rounds.queue.task(of: f.pr))
        await ended(round)
        #expect(try await f.branch() == fix)
        #expect(try await f.object(fix).parents == [f.head])
        #expect(f.mark?.chain == [f.head, fix] && f.mark?.fixes == 1)
        #expect(f.store.state.prs[f.pr]?.round == nil && f.mark?.question == nil)
        #expect(f.bgRuns.isEmpty && f.polls.values.count == 1)
        await f.end()
    }

    // A posting fix with Sign commits through GitHub on goes after the next start as one
    // createCommitOnBranch write with the paths of the fix, and GitHub's commit joins the chain.
    @Test func aSignedPostingFixPushesAfterARestart() async throws {
        let f = try await CIFixture(config: ReviewsConfig(fixCI: true, signedCommits: true))
        f.playSignedCommits()
        let fix = try await f.postingFix(pushed: false)
        await f.restart()
        await ended(f.rounds.queue.task(of: f.pr))
        let paths = f.github.calls.compactMap { call -> [String]? in
            if case .write(.createSignedCommit(let commit)) = call {
                commit.changes.map(\.path)
            } else {
                nil
            }
        }
        #expect(paths == [["src/a.swift"]])
        let made = try await f.branch()
        #expect(made != fix && made != f.head)
        #expect(try await f.object(made).parents == [f.head])
        #expect(f.mark?.chain == [f.head, made] && f.mark?.fixes == 1)
        #expect(f.store.state.prs[f.pr]?.round == nil && f.mark?.question == nil)
        await f.end()
    }

    // A posting fix whose fresh read fails after the next start pushes nothing: the copy goes
    // back to the head, and the CI question says why.
    @Test func aPostingFixWhoseReadFailsGoesBackToTheHead() async throws {
        let f = try await CIFixture()
        let fix = try await f.postingFix(pushed: false)
        #expect(await f.worktreeHead() == fix)
        f.github.answers[HeadQueries.name] = .failure(.timedOut)
        await f.restart()
        await ended(f.rounds.queue.task(of: f.pr))
        #expect(await f.worktreeHead() == f.head)
        #expect(try await f.branch() == f.head)
        #expect(f.mark?.question?.text == CIStop.session(.readFailed(.timedOut)).question)
        #expect(f.store.state.prs[f.pr]?.round == nil)
        await f.end()
    }

    // A re-run that was posting when Bifrost quit can be on GitHub: the next start sends nothing,
    // and the question of its head sends the user to GitHub. The row needs the user and doesn't
    // show Retrying CI, and no round starts on the head.
    @Test func aPostingRerunAtAStartAsksAndSendsNothing() async throws {
        let f = try await CIFixture()
        let (pr, head) = (f.pr, f.head)
        let key = [try job(101)]
        await f.store.update { state in
            var prState = PRState()
            prState.round = ActiveRound(
                phase: .posting, startedAt: Rows.now, at: Rows.now, headSHA: head, kind: .ci)
            prState.ci = CIMark(
                chain: [head], retries: 1, handledHead: head, handled: key, retrying: head)
            state.prs[pr] = prState
        }
        await f.restart()
        let question = try #require(f.mark?.question)
        #expect(
            question.text
                == "Bifrost can't tell whether GitHub re-ran the failed jobs, so check the pull "
                + "request there.")
        #expect(question.head == f.head && !question.byClaude && question.answer == nil)
        #expect(f.mark?.retrying == nil && f.mark?.retries == 1)
        #expect(f.store.state.prs[f.pr]?.round == nil && f.store.state.queue.isEmpty)
        #expect(f.reruns.isEmpty && f.claude == .needsYou(comments: 0, ci: true))
        f.rounds.afterPoll(f.poll)
        #expect(f.rounds.queue.task(of: f.pr) == nil)
        await f.end()
    }

    // A fix that was posting when Bifrost quit meets a closed gate at the next start: nothing is
    // pushed, the copy goes back to the head, and the key of the failure goes back. When the gate
    // opens again, the next poll starts a round, and the fix stays counted.
    @Test func aPostingFixThatMeetsAClosedGateStartsAgainWhenItOpens() async throws {
        let f = try await CIFixture()
        _ = try await f.postingFix(pushed: false)
        await f.store.update { $0.ciConsent = nil }
        await f.restart()
        await ended(f.rounds.queue.task(of: f.pr))
        #expect(try await f.branch() == f.head)
        #expect(await f.worktreeHead() == f.head)
        #expect(f.mark?.handledHead == nil && f.mark?.fixes == 1 && f.mark?.question == nil)
        #expect(f.store.state.prs[f.pr]?.round == nil)
        await f.store.update { $0.consentToCIFix() }
        let round = try f.pollNow()
        await f.sessionWorks()
        #expect(try f.inputFile()["tried"] == ["fixes": 1, "retries": 0])
        try await f.endTurn(result: f.result("needs-you"))
        await ended(round)
        await f.end()
    }

    // MARK: - The logs

    // A log over the limit goes in cut: its file starts with the cut note, and the input says so.
    // A job whose log GitHub does not give has no file, and the input names the reason.
    @Test func aLogOverTheLimitGoesInCut() async throws {
        let jobs = [CIFixture.test, CIJob(id: 102, run: 9001, name: "lint")]
        let f = try await CIFixture(jobs: jobs)
        let line = String(repeating: "x", count: 99) + "\n"
        f.github.answers["job-log 101"] = .success(Data(String(repeating: line, count: 2_100).utf8))
        f.github.answers["job-log 102"] = nil
        let round = try f.pollNow()
        await f.sessionWorks()
        let files = try f.files()
        let file = CIInput.Files.log(files, job: try job(101))
        let log = try String(contentsOf: file, encoding: .utf8)
        #expect(log.hasPrefix(CILog.cutNote))
        #expect(log.utf8.count <= CILog.keptBytes + CILog.cutNote.utf8.count)
        let failed = try #require(f.inputFile()["failed"]?.array)
        #expect(failed.first?.object?["logCut"] == .bool(true))
        #expect(failed.first?.object?["log"]?.string == file.path(percentEncoded: false))
        #expect(failed.last?.object?["logMissing"] == "gone")
        #expect(failed.last?.object?["log"] == .null)
        let other = CIInput.Files.log(files, job: try job(102))
        #expect(!FileManager.default.fileExists(atPath: other.path(percentEncoded: false)))
        try await f.endTurn(result: f.result("needs-you"))
        await ended(round)
        await f.end()
    }

    // MARK: - The work of a person

    // The safety net: changes in the copy that no round made stop the round before it moves the
    // copy. They stay, no session starts, and the row shows Unpushed changes with the files. The
    // key of the failure goes back, so after Discard changes the next poll starts the round.
    @Test func theSafetyNetKeepsTheWorkOfThePersonAndStartsNoRound() async throws {
        let f = try await CIFixture()
        try await f.placeCopy()
        try "person\n".write(
            toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        await ended(try f.pollNow())
        #expect(f.bgRuns.isEmpty && f.prompts.sends.isEmpty)
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.waiting?.reason == RoundFailure.changesNotOnGitHub.message(for: .ci))
        #expect(state.waiting?.kind == .unpushedCI && state.waiting?.files == ["src/a.swift"])
        #expect(state.round == nil && state.lastError == nil && state.ci?.question == nil)
        #expect(state.ci?.handledHead == nil && state.ci?.handled == [])
        #expect(f.fileA == "person\n")
        #expect(f.claude == .unpushedCI)
        #expect(Rows.mine(f.poll, f.store.state, f.config).first?.unsavedFiles == 1)
        f.rounds.afterPoll(f.poll)
        #expect(f.rounds.queue.task(of: f.pr) == nil)
        #expect(await f.rounds.discardChanges(f.pr, click: UserClick()) == .discarded)
        #expect(f.store.state.prs[f.pr]?.waiting == nil)
        let again = try f.pollNow()
        await f.sessionWorks()
        try await f.endTurn(result: f.result("needs-you"))
        await ended(again)
        #expect(f.mark?.question?.head == f.head)
        await f.end()
    }

    // A person adds a file to the copy after the end of the turn and before the commit of the
    // fix: nothing is pushed, the copy keeps the change and the file, and the row shows Unpushed
    // changes with the file.
    @Test func aChangeAfterTheTurnBeforeTheFixNeedsYou() async throws {
        let runner = CIHookRunner()
        let f = try await CIFixture(runner: runner)
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.fix()
        let file = f.worktree + "/person.txt"
        runner.afterFirstStatus {
            try? "mine\n".write(toFile: file, atomically: false, encoding: .utf8)
        }
        try await f.endTurn(result: f.result())
        await ended(round)
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.waiting?.kind == .unpushedCI && state.waiting?.files == ["person.txt"])
        #expect(state.round == nil && state.lastError == nil && state.ci?.question == nil)
        #expect(state.ci?.fixes == 0 && state.ci?.handledHead == nil)
        #expect(try await f.branch() == f.head)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(f.fileA == CIFixture.lines([11: "line eleven fixed"]))
        await f.end()
    }

    // The user asks Claude for a change while the round runs (an own request file at the end of
    // the turn): the CI fix does not go, the own request goes alone at the end of the job, and
    // the key of the failure goes back.
    @Test func anOwnRequestInTheTurnGoesAloneAndTheFailureWaits() async throws {
        let f = try await CIFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.fix("line eleven renamed")
        try f.writeOwnRequest(head: f.head)
        try await f.endTurn(result: f.result())
        await ended(round)
        let (pr, own) = (f.pr, f.ownFile)
        await waitUntil {
            !FileManager.default.fileExists(atPath: own) && f.rounds.ownRuns[pr] == nil
                && f.store.state.prs[pr]?.outbox == nil
        }
        let pushed = try await f.branch()
        #expect(
            await f.sourceGit(["log", "-1", "--format=%P %s", pushed.hex])
                == "\(f.head.hex) refactor: rename the helper")
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.ci?.fixes == 0 && state.ci?.handledHead == nil)
        #expect(state.ci?.question == nil && state.round == nil && state.lastError == nil)
        await f.end()
    }

    // The user's own request waits when a CI round gets the session: the round changes nothing,
    // the own request goes first and pushes alone on the head, and then the round starts again
    // and takes the failure.
    @Test func anOwnRequestThatWaitsGoesFirstThenTheRoundStarts() async throws {
        let f = try await CIFixture()
        try await f.placeCopy()
        try f.fix("line eleven renamed")
        try f.writeOwnRequest(head: f.head)
        let round = try f.pollNow()
        await f.sessionWorks()
        let pushed = try await f.branch()
        #expect(
            await f.sourceGit(["log", "-1", "--format=%P %s", pushed.hex])
                == "\(f.head.hex) refactor: rename the helper")
        #expect(!FileManager.default.fileExists(atPath: f.ownFile))
        let key = [try job(101)]
        #expect(f.mark?.handledHead == f.head && f.mark?.handled == key && f.bgRuns.count == 1)
        try await f.endTurn(result: f.result("needs-you"))
        await ended(round)
        #expect(f.mark?.question?.byClaude == true && f.mark?.question?.head == f.head)
        await f.end()
    }

    // The user asks Claude for a change while the round runs, and Claude asks for a re-run: the
    // re-run still goes, the reset before it keeps the change of the user, and the own request
    // then goes alone at the end of the job.
    @Test func anOwnRequestInTheTurnLetsARetryGoAndKeepsItsChange() async throws {
        let f = try await CIFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.fix("line eleven renamed")
        try f.writeOwnRequest(head: f.head)
        try await f.endTurn(result: f.result("retry"))
        await ended(round)
        #expect(f.reruns == [try run(9001)] && f.mark?.retries == 1)
        let (pr, own) = (f.pr, f.ownFile)
        await waitUntil {
            !FileManager.default.fileExists(atPath: own) && f.rounds.ownRuns[pr] == nil
                && f.store.state.prs[pr]?.outbox == nil
        }
        let pushed = try await f.branch()
        #expect(
            await f.sourceGit(["log", "-1", "--format=%P %s", pushed.hex])
                == "\(f.head.hex) refactor: rename the helper")
        #expect(f.fileA == CIFixture.lines([11: "line eleven renamed"]))
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.ci?.question == nil && state.round == nil && state.lastError == nil)
        await f.end()
    }

    // A person uses the session when an automatic round reaches its turn: the failure is not
    // tried. The round ends with no text and no question, the key goes back, and the next free
    // poll starts the round.
    @Test func aBusySessionLeavesTheFailureUntried() async throws {
        let f = try await CIFixture()
        let first = try f.pollNow()
        await f.sessionWorks()
        try await f.endTurn(result: f.result("needs-you"))
        await ended(first)
        await f.show(.busy)
        let next = try await f.userPush()
        try f.github(head: next)
        let finished = Recorder<Bool>()
        let job = QueuedJob(pr: f.pr, kind: .ci, since: Rows.now)
        let run = Task {
            await f.rounds.runCI(job, saved: nil)
            finished.record(true)
        }
        var turns = 0
        while finished.values.isEmpty, turns < 2000 {
            f.deps.clock.advance(by: .seconds(30))
            try await Task.sleep(for: .milliseconds(2))
            turns += 1
        }
        await ended(run)
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.round == nil && state.waiting == nil && state.lastError == nil)
        #expect(state.ci?.chain == [next] && state.ci?.question == nil)
        #expect(state.ci?.handledHead == nil && state.ci?.handled == [])
        await f.show(.idle)
        f.rounds.afterPoll(f.poll)
        #expect(f.rounds.queue.task(of: f.pr) != nil)
        await f.end()
    }

    // Stop session in a turn: nothing is pushed, the copy goes back to the head, and the CI
    // question gets the text of the stop. Nothing goes to lastError, and no automatic round
    // starts on the head.
    @Test func stopSessionAsksWithTheStopText() async throws {
        let f = try await CIFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.fix()
        let stop = Task { await f.rounds.stopSession(f.pr) }
        await ended(round)
        await f.parkWaitStarted()
        f.deps.clock.advance(by: SessionActions.parkWait)
        await ended(stop)
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.ci?.question?.text == CIStop.session(.stopped).question)
        #expect(state.ci?.question?.byClaude == false && state.ci?.question?.head == f.head)
        #expect(state.round == nil && state.lastError == nil)
        #expect(await f.worktreeHead() == f.head)
        #expect(f.fileA == CIFixture.lines([11: "line eleven feat"]))
        #expect(try await f.branch() == f.head)
        f.rounds.afterPoll(f.poll)
        #expect(f.store.state.queue.isEmpty)
        await f.end()
    }

    // MARK: - The start and the end of the rounds

    // A start of Bifrost takes over the CI rounds of the state: a preparing round goes back to
    // the queue, and the key of its head clears, so the queued round takes the failure again; a
    // running round waits for its session; a posting fix pushes; a posting re-run sends nothing
    // again and asks; and a stopped round gets the stop question, never lastError.
    @Test func aStartTakesOverTheCIRoundsOfTheState() async throws {
        let f = try await CIFixture()
        let (pr, head) = (f.pr, f.head)
        let key = [try job(101)]
        func round(_ phase: RoundPhase, stopped: Bool = false, at head: CommitID?) -> ActiveRound {
            ActiveRound(
                phase: phase, startedAt: Rows.now, at: Rows.now, headSHA: head,
                stoppedByUser: stopped, kind: .ci)
        }
        // The fresh read shows the checks passed now, so the queued round ends with no text.
        f.github.answers[HeadQueries.name] = .success(
            CIFixture.headRead(head: head, base: f.base, jobs: []))
        await f.store.update { state in
            var prState = PRState()
            prState.round = round(.preparing, at: head)
            prState.ci = CIMark(chain: [head], handledHead: head, handled: key)
            state.prs[pr] = prState
        }
        await f.restart()
        var state = try #require(f.store.state.prs[pr])
        #expect(state.round == nil && f.store.state.queue.map(\.kind) == [.ci])
        #expect(state.ci?.handledHead == nil && state.ci?.handled == [])
        await ended(f.rounds.queue.task(of: pr))
        // A re-run that was posting goes, nothing is sent again, and its head asks.
        await f.store.update { state in
            var prState = PRState()
            prState.round = round(.posting, at: head)
            prState.ci = CIMark(
                chain: [head], retries: 1, handledHead: head, handled: key, retrying: head)
            state.prs[pr] = prState
        }
        await f.restart()
        state = try #require(f.store.state.prs[pr])
        #expect(state.round == nil && f.store.state.queue.isEmpty && f.reruns.isEmpty)
        #expect(state.ci?.retrying == nil)
        #expect(state.ci?.question?.text == CIStop.unknownRerun.question)
        // A stopped round gets the stop question on its head; with no head, no question.
        for phase in [RoundPhase.preparing, .running] {
            await f.store.update { state in
                var prState = PRState()
                prState.round = round(phase, stopped: true, at: head)
                state.prs[pr] = prState
            }
            await f.restart()
            state = try #require(f.store.state.prs[pr])
            #expect(state.round == nil && state.lastError == nil && f.store.state.queue.isEmpty)
            #expect(state.ci?.question?.text == CIStop.session(.stopped).question)
            #expect(state.ci?.question?.head == head)
        }
        await f.store.update { state in
            var prState = PRState()
            prState.round = round(.preparing, stopped: true, at: nil)
            state.prs[pr] = prState
        }
        await f.restart()
        state = try #require(f.store.state.prs[pr])
        #expect(state.round == nil && state.ci == nil && state.lastError == nil)
        await f.end()

        // A running round waits for the end of its session.
        let g = try await CIFixture()
        _ = try g.pollNow()
        await g.sessionWorks()
        await g.restart()
        #expect(g.store.state.prs[g.pr]?.round?.phase == .running)
        let resumed = try #require(g.rounds.queue.task(of: g.pr))
        try await g.endTurn(result: g.result("needs-you", question: "Is the runner down?"))
        await ended(resumed)
        #expect(g.mark?.question?.text == "Is the runner down?" && g.bgRuns.count == 1)
        await g.end()

        // A posting fix pushes.
        let h = try await CIFixture()
        let fix = try await h.postingFix(pushed: false)
        await h.restart()
        await ended(h.rounds.queue.task(of: h.pr))
        #expect(try await h.branch() == fix && h.mark?.chain == [h.head, fix])
        await h.end()
    }

    // A record of the PR that did not read in full ("ci": null in the file) spends the CI budget
    // of the head that the first poll lists: the failure gets the limits question, not a round.
    @Test func aRecordInDoubtSpendsTheCIBudgetOfTheHead() async throws {
        let f = try await CIFixture(
            file: "{\"version\": 1, \"prs\": {\"Owner-A/Repo-A#7\": {\"ci\": null}}}")
        #expect(f.store.state.prs[f.pr]?.markInDoubt == true)
        _ = try f.pollNow()
        // The wait ends at the question, so a round that starts a session by mistake fails here
        // and does not wait for the end of its turn. The end of the fixture stops the round.
        await waitUntil { f.mark?.question != nil }
        #expect(f.bgRuns.isEmpty && f.prompts.sends.isEmpty)
        #expect(f.mark?.question?.text == CIStop.limits.question)
        #expect(f.mark?.chain == [f.head])
        #expect(f.mark?.fixes == CIRule.maxFixes && f.mark?.retries == CIRule.maxRetries)
        #expect(f.store.state.prs[f.pr]?.markInDoubt == false)
        await f.end()
    }

    // The poll shows a failed job and the fresh read does not (the checks still run): the round
    // ends with no text. The next polls on the same head and jobs queue nothing until
    // WorkRule.readRetry has passed.
    @Test func aQuietEndWaitsForTheRetryTime() async throws {
        let f = try await CIFixture()
        f.github.answers[HeadQueries.name] = .success(
            CIFixture.headRead(head: f.head, base: f.base, jobs: [CIFixture.test], done: false))
        await ended(try f.pollNow())
        #expect(f.mark == nil && f.store.state.queue.isEmpty && f.bgRuns.isEmpty)
        #expect(f.store.state.prs[f.pr]?.round == nil)
        f.rounds.afterPoll(f.poll)
        #expect(f.rounds.queue.task(of: f.pr) == nil)
        try await f.clock.sleep(for: WorkRule.readRetry - .seconds(1))
        f.rounds.afterPoll(f.poll)
        #expect(f.rounds.queue.task(of: f.pr) == nil)
        try await f.clock.sleep(for: .seconds(2))
        f.rounds.afterPoll(f.poll)
        let again = try #require(f.rounds.queue.task(of: f.pr))
        await ended(again)
        await f.end()
    }

    // Remove all clones while a CI round runs: the round goes, the key of the failure goes back,
    // nothing is pushed, and the next poll starts the round again. The same holds for a round
    // that goes on after a restart.
    @Test(arguments: [false, true])
    func removeAllClonesLeavesTheFailureUntried(_ afterRestart: Bool) async throws {
        let f = try await CIFixture()
        var round = try f.pollNow()
        await f.sessionWorks()
        #expect(f.mark?.handledHead == f.head)
        if afterRestart {
            await f.restart()
            round = try #require(f.rounds.queue.task(of: f.pr))
            await f.turnWaitSawWork()
        }
        #expect(await f.rounds.removeAll(then: { nil }) == nil)
        await ended(round)
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.round == nil && state.ci?.question == nil && state.lastError == nil)
        #expect(state.ci?.handledHead == nil && state.ci?.handled == [])
        #expect(f.store.state.queue.isEmpty)
        #expect(try await f.branch() == f.head)
        f.rounds.afterPoll(f.poll)
        #expect(f.rounds.queue.task(of: f.pr) != nil)
        await f.end()
    }
}
