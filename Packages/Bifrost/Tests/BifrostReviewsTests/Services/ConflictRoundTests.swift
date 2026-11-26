// The conflict rounds (docs/behaviour/reviews.md, "Merge conflicts"), end to end: the real git on
// a local bare source that plays GitHub, where the branch feat (the head of PR 7, also at
// refs/pull/7/head) and its base branch main each change line 11 of src/a.swift, a Reviews store
// and a trusted clone in a temporary folder, the in-process FakeGitHub for the poll and the fresh
// head reads, and the real registry on scripted session lists with a fake claude
// (FakeActionDeps). The test plays the session: it shows its rows, edits the worktree and writes
// the result file. A later round types its prompt through a fake text input. No test reaches
// GitHub, runs claude or reads the real ~/.claude or ~/.claude.json, and each test removes its
// folder at its end.
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostReviews

// The runner of git of the conflict tests: it runs a one-time action after the first git status
// that follows its arm (the count of the changes at the end of the turn), or right before the
// first git add that follows its arm (the commit of the merge). The action plays a person.
private final class ConflictHookRunner: CommandRunner {
    private let real = ProcessRunner()
    private let afterStatus = Mutex<(@Sendable () -> Void)?>(nil)
    private let beforeAdd = Mutex<(@Sendable () -> Void)?>(nil)

    func afterFirstStatus(_ action: @escaping @Sendable () -> Void) {
        afterStatus.withLock { $0 = action }
    }

    func beforeFirstAdd(_ action: @escaping @Sendable () -> Void) {
        beforeAdd.withLock { $0 = action }
    }

    func run(_ command: Command) async -> ExecResult {
        if command.arguments.contains("add"), let action = beforeAdd.withLock({ $0.take() }) {
            action()
        }
        let result = await real.run(command)
        if command.arguments.contains("status"), let action = afterStatus.withLock({ $0.take() }) {
            action()
        }
        return result
    }
}

@MainActor
private final class ConflictFixture {
    static let id = "33333333-4444-5555-6666-777777777777"
    static let name = "bifrost-test-Repo-A-7-request"
    static let shortID = ShortID("abcdef12")

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
    let clock = GapClock()
    let prompts = RecordingPromptInput()
    let pr: PRKey
    // The head of feat and the tip of main at the start of the test.
    let head: CommitID
    let base: CommitID
    // The last good poll of the rounds.
    var poll: PollAnswer

    // conflict: main and feat change the same line, else other lines. consent: the user confirmed
    // the automatic conflict rounds. saved: the state before the start of the rounds.
    init(
        config: ReviewsConfig = ReviewsConfig(resolveConflicts: true), conflict: Bool = true,
        consent: Bool = true, fork: Bool = false, runner: any CommandRunner = ProcessRunner(),
        saved: (inout ReviewsState) -> Void = { _ in }
    ) async throws {
        self.config = config
        repos = try RepoFixture(runner: runner)
        let repo = try #require(RepoName("Owner-A/Repo-A"))
        pr = try #require(PRKey(repo: repo, number: 7))
        try await repos.source(repo, files: ["src/a.swift": Self.lines()])
        let work = repos.root + "/work/" + repo.key
        try await repos.setup(["checkout", "-q", "-b", "feat"], in: work)
        head = try await Self.commit(
            repos, work, [11: "line eleven feat"], refs: ["refs/pull/7/head", "refs/heads/feat"])
        try await repos.setup(["checkout", "-q", "main"], in: work)
        base = try await Self.commit(
            repos, work, [conflict ? 11 : 18: "line main"], refs: ["refs/heads/main"])
        store = try await ReviewsStore.open(layout: repos.layout, log: Recorder<StoreEvent>())
        // Claude Code trusts the clone (the .claude.json of the temporary home).
        let clone = String(repos.clone(repo).dropLast())
        try "{\"projects\": {\"\(clone)\": {\"hasTrustDialogAccepted\": true}}}".write(
            toFile: repos.root + "/.claude.json", atomically: false, encoding: .utf8)
        let skillsPath = repos.root + "/skills"
        skills = URL(filePath: skillsPath, directoryHint: .isDirectory)
        let file = skillsPath + "/" + ConflictRound.modeFile
        try FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "The conflict mode.\n".write(toFile: file, atomically: false, encoding: .utf8)
        home = URL(filePath: repos.root, directoryHint: .isDirectory)
        github = FakeGitHub(answers: [
            HeadQueries.name: .success(Self.headRead(head: head, base: base, fork: fork))
        ])
        poll = try Self.answer(head: head, base: base, fork: fork)
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
            if consent { state.consentToConflictFix() }
            saved(&state)
        }
        await deps.start()
        rounds.start()
    }

    private func wire() {
        rounds.answer = { [weak self] in self?.poll }
        rounds.ended = { [polls] in polls.record(true) }
        rounds.eventLine = { [events] in events.record($0) }
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

    // The fresh read of the head of PR 7 as GitHub gives it.
    static func headRead(
        head: CommitID, base: CommitID, state: String = "OPEN", mergeable: String = "CONFLICTING",
        fork: Bool = false
    ) -> Data {
        ReviewData.json([
            "data": [
                "repository": [
                    "pullRequest": [
                        "state": .string(state), "author": ["login": .string(Rows.viewer)],
                        "repository": ["defaultBranchRef": ["name": "main"]],
                        "mergeable": .string(mergeable), "baseRefOid": .string(base.hex),
                        "headRefName": "feat", "headRefOid": .string(head.hex),
                        "baseRefName": "main", "isCrossRepository": .bool(fork),
                        "commits": ["nodes": []],
                    ]
                ]
            ]
        ])
    }

    // The poll with PR 7 of the user at the head and the base.
    static func answer(head: CommitID, base: CommitID, fork: Bool = false) throws -> PollAnswer {
        var pull = try Rows.pull(
            "Owner-A/Repo-A#7", author: Rows.viewer, fork: fork, mergeable: .conflicting,
            base: base.hex)
        pull.headSHA = head.hex
        pull.headRef = "feat"
        return Rows.answer(mine: [pull])
    }

    // GitHub shows the PR at the head and the base: the poll and the fresh read.
    func github(head: CommitID, base: CommitID) throws {
        poll = try Self.answer(head: head, base: base)
        github.answers[HeadQueries.name] = .success(Self.headRead(head: head, base: base))
    }

    // MARK: - The git of the source

    var bare: String { repos.root + "/sources/" + pr.repo.key + ".git" }
    var work: String { repos.root + "/work/" + pr.repo.key }
    var input: String { repos.layout.inputFolder(pr.repo, number: 7).plainPath }
    var worktree: String { GitPlace.worktree(pr, repos.layout) }

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

    // A new commit on main that sets line 11 to the text. The result is the new tip.
    func pushMain(lineEleven text: String) async throws -> CommitID {
        try await repos.setup(["checkout", "-q", "main"], in: work)
        return try await Self.commit(repos, work, [11: text], refs: ["refs/heads/main"])
    }

    // Another person pushes a commit to feat that changes line 2. The result is the new head.
    func otherPush() async throws -> CommitID {
        try await repos.setup(["checkout", "-q", "feat"], in: work)
        let pushed = try await Self.commit(
            repos, work, [2: "line two", 11: "line eleven feat"], refs: ["refs/heads/feat"])
        try await repos.setup(["checkout", "-q", "main"], in: work)
        return pushed
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

    // The session resolves the conflict in the worktree, as Claude does.
    func resolve(_ text: String = "line eleven both") throws {
        try Self.lines([11: text]).write(
            toFile: worktree + "/src/a.swift", atomically: false, encoding: .utf8)
    }

    // A result file of the round: resolved with src/a.swift, or needs-you with the reason. The
    // token, the head and the base come from the input file, as the session reads them.
    func result(needsYou reason: String? = nil) throws -> Data {
        let input = try inputFile()
        let pr = input["pr"]?.object
        var fields: [String: JSONValue] = [
            "version": 1, "pr": "Owner-A/Repo-A#7", "headSha": pr?["headSha"] ?? .null,
            "baseSha": pr?["baseSha"] ?? .null, "round": input["round"] ?? .null,
        ]
        if let reason {
            fields["outcome"] = "needs-you"
            fields["reason"] = .string(reason)
        } else {
            fields["outcome"] = "resolved"
            fields["files"] = ["src/a.swift"]
        }
        return ReviewData.json(.object(fields))
    }

    // The turn ends: the result file lands and the row is idle.
    func endTurn(result: Data) async throws {
        try result.write(to: try files().result)
        await show(.idle)
    }

    // A round of a new conflict that resolves the conflict and pushes the merge. The result is the
    // merge on feat.
    func resolvedRound(typed sends: Int? = nil) async throws -> CommitID {
        let round = try pollNow()
        if let sends { await typedTurnWorks(sends: sends) } else { await sessionWorks() }
        try resolve()
        try await endTurn(result: result())
        await round.value
        return try await branch()
    }

    // The state of a round that was posting when Bifrost quit: the merge of the resolved file is
    // committed in the worktree, and the round keeps it as its fix. pushed: the merge is on
    // GitHub already. The result is the merge.
    func postingRound(pushed: Bool) async throws -> CommitID {
        let store = repos.store
        try await store.ensureClone(pr.repo)
        _ = try await store.fetchPR(pr, base: try #require(BranchName("main")))
        let start = try await ConflictMerge.start(pr: pr, head: head, base: base, git: store.git)
        _ = try await store.placeWorktree(pr, head: start.auto)
        try resolve()
        let merge = try await ConflictMerge.commit(
            pr: pr, start: start, head: head, base: base, message: "Merge main into feat",
            git: store.git)
        await store.markLeftovers(pr)
        if pushed {
            try await repos.setup(
                ["push", "-q", bare, "\(merge.hex):refs/heads/feat"], in: repos.clone(pr.repo))
        }
        let (pr, head, base) = (pr, head, base)
        await self.store.update { state in
            var prState = PRState()
            prState.round = ActiveRound(
                phase: .posting, startedAt: Rows.now, at: Rows.now, headSHA: head,
                baseSHA: base, kind: .conflict, fixSHA: merge, token: "t1", startSHA: start.auto)
            prState.conflict = ConflictMark(
                head: head, base: base, at: Rows.now, outcome: .working)
            state.prs[pr] = prState
        }
        return merge
    }

    var bgRuns: [[String]] { deps.calls.claudeRuns.filter { $0.first == "--bg" } }

    // The stop of the session ran, and its wait for the park sleeps on the clock, so a move of the
    // clock by the park wait ends it.
    func parkWaitStarted() async {
        await waitUntil { self.deps.calls.claudeRuns.contains(["stop", "abcdef12"]) }
        await waitUntil {
            self.deps.clock.nextDeadline?.offset
                == self.deps.clock.now.offset + SessionActions.parkWait
        }
    }

    var mark: ConflictMark? { store.state.prs[pr]?.conflict }

    // The text of src/a.swift in the worktree.
    var fileA: String? { try? String(contentsOfFile: worktree + "/src/a.swift", encoding: .utf8) }

    // The commit that the worktree is at.
    func worktreeHead() async -> CommitID? { await repos.store.worktreeHead(pr) }

    // The own request file of the PR, with the commit of the worktree as its head.
    func writeOwnRequest(head: CommitID) throws {
        try Self.ownRequest(head: head).write(to: URL(filePath: input + "/" + OwnRequestFile.name))
    }

    // The bytes of an own request file for the head.
    static func context(head: CommitID) -> Data {
        ReviewData.json([
            "data": [
                "repository": [
                    "pullRequest": [
                        "id": "PR_kwDOrepo7", "url": "https://github.com/Owner-A/Repo-A/pull/7",
                        "title": "Add the cache", "body": "The body.", "state": "OPEN",
                        "author": ["login": .string(Rows.viewer)], "isCrossRepository": false,
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

    // The read of the threads and of the comments of the PR: none.
    static func noThreads() -> Data {
        ReviewData.json([
            "data": [
                "repository": [
                    "pullRequest": [
                        "reviewThreads": [
                            "nodes": [], "pageInfo": ["hasNextPage": false, "endCursor": .null],
                        ],
                        "comments": [
                            "nodes": [], "pageInfo": ["hasNextPage": false, "endCursor": .null],
                        ],
                    ]
                ]
            ]
        ])
    }

    static func ownRequest(head: CommitID) -> Data {
        ReviewData.json([
            "version": 1, "pr": "Owner-A/Repo-A#7", "headSha": .string(head.hex),
            "commit": ["message": "refactor: rename the helper", "paths": ["src/a.swift"]],
        ])
    }

    // The source refuses each push, as GitHub does for a protected branch.
    func protectBranch() throws {
        let hook = bare + "/hooks/pre-receive"
        try "#!/bin/sh\necho 'protected branch' >&2\nexit 1\n".write(
            toFile: hook, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
    }
}

@MainActor
@Suite("the conflict rounds", .serialized, .timeLimit(.minutes(3)), .tags(.realProcess))
struct ConflictRoundTests {
    // A poll that shows the conflict starts one round. Bifrost merges main into feat in its clone,
    // the session starts in the worktree at the merge with the markers, with the conflict prompt,
    // and Claude resolves the file. Bifrost commits the merge (parents head and main tip, "Merge
    // main into feat", unsigned) and pushes it to feat. The mark keeps the merge, nothing goes to
    // lastError, the worktree goes to the merge, and a poll runs at once.
    @Test func aConflictingPRGetsOneRoundThatPushesAnUnsignedMerge() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        #expect(f.store.state.queue.isEmpty)
        let files = try f.files()
        let start = try #require(f.bgRuns.first)
        #expect(start.last == PRSessionArgs.conflictPrompt(files.input))
        #expect(start.contains("--restricted"))
        #expect(f.store.state.prs[f.pr]?.round?.kind == .conflict)
        #expect(f.mark?.outcome == .working)
        #expect(f.mark?.head == f.head && f.mark?.base == f.base)
        let auto = try #require(f.store.state.prs[f.pr]?.round?.startSHA)
        #expect(await f.worktreeHead() == auto)
        #expect(f.fileA?.contains("<<<<<<<") == true)
        #expect(try f.inputFile()["conflicts"] == ["src/a.swift"])
        let id = files.id
        let names = (try? FileManager.default.contentsOfDirectory(atPath: f.input)) ?? []
        #expect(
            Set(names) == [
                "input-\(id).json", "mode-\(id).md", "ours-\(id).diff", "theirs-\(id).diff",
            ])
        try f.resolve()
        try await f.endTurn(result: f.result())
        await round.value
        let merge = try await f.branch()
        let object = try await f.object(merge)
        #expect(object.parents == [f.head, f.base] && !object.signed)
        #expect(object.message.trimmed() == "Merge main into feat")
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.conflict?.outcome == .pushed(merge) && state.round == nil)
        #expect(state.lastError == nil && state.waiting == nil && !state.resolveNow)
        #expect(await f.worktreeHead() == merge)
        #expect(f.polls.values.count == 1 && f.events.values.isEmpty)
        await f.end()
    }

    // A PR whose request session runs from an earlier round gets the prompt typed into that
    // session: no second claude --bg.
    @Test func aRoundSendsItsPromptIntoThePRSession() async throws {
        let f = try await ConflictFixture()
        let first = try await f.resolvedRound()
        try await f.followBranch()
        let base = try await f.pushMain(lineEleven: "line main again")
        try f.github(head: first, base: base)
        let second = try await f.resolvedRound(typed: 1)
        #expect(f.bgRuns.count == 1)
        let input = try #require(f.prompts.sends.first?.text)
        #expect(input.hasPrefix("/bifrost-resolve-conflicts bifrost-input="))
        #expect(f.prompts.sends.first?.session == ConflictFixture.id)
        #expect(try await f.object(second).parents == [first, base])
        #expect(f.mark?.outcome == .pushed(second))
        await f.end()
    }

    // A failed attempt keeps its pair, so a later poll with the same head and base starts nothing.
    @Test func theSamePairNeverStartsASecondRound() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try await f.endTurn(result: f.result(needsYou: "Only you can pick the line."))
        await round.value
        let reason = ConflictFailure.claude("Only you can pick the line.").message
        #expect(f.mark?.outcome == .failed(reason))
        #expect(try await f.branch() == f.head)
        #expect(f.store.state.prs[f.pr]?.lastError == nil)
        f.rounds.afterPoll(f.poll)
        #expect(f.store.state.queue.isEmpty && f.rounds.queue.task(of: f.pr) == nil)
        let rows = Rows.mine(f.poll, f.store.state)
        #expect(rows.first?.mineState?.claude == .conflicts(reason))
        await f.end()
    }

    // A new commit on the base branch makes a new pair, which gets a new round.
    @Test func aNewBaseCommitStartsANewRound() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try await f.endTurn(result: f.result(needsYou: "Only you can pick the line."))
        await round.value
        let base = try await f.pushMain(lineEleven: "line main again")
        try f.github(head: f.head, base: base)
        let merge = try await f.resolvedRound(typed: 1)
        #expect(try await f.object(merge).parents == [f.head, base])
        #expect(f.mark?.base == base && f.mark?.outcome == .pushed(merge))
        await f.end()
    }

    // Resolve now starts one more round on a pair that failed, and it works with the setting off
    // too. Its click goes in the state and the round spends it.
    @Test func resolveNowStartsOneMoreRoundAfterAFailure() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try await f.endTurn(result: f.result(needsYou: "Only you can pick the line."))
        await round.value
        await f.rounds.resolveNow(f.pr)
        let again = try #require(f.rounds.queue.task(of: f.pr))
        await f.typedTurnWorks(sends: 1)
        #expect(f.store.state.prs[f.pr]?.resolveNow == true)
        try f.resolve()
        try await f.endTurn(result: f.result())
        await again.value
        let merge = try await f.branch()
        #expect(f.mark?.outcome == .pushed(merge) && f.store.state.prs[f.pr]?.resolveNow == false)
        await f.end()

        let g = try await ConflictFixture(config: ReviewsConfig(resolveConflicts: false))
        g.rounds.afterPoll(g.poll)
        #expect(g.store.state.queue.isEmpty && g.rounds.queue.task(of: g.pr) == nil)
        await g.rounds.resolveNow(g.pr)
        let clicked = try #require(g.rounds.queue.task(of: g.pr))
        await g.sessionWorks()
        try g.resolve()
        try await g.endTurn(result: g.result())
        await clicked.value
        #expect(g.mark?.outcome == .pushed(try await g.branch()))
        await g.end()
    }

    // Claude says it resolved the file but leaves the markers: Bifrost pushes nothing, the mark
    // shows the reason, and the worktree goes back to the head.
    @Test func markersLeftPushNothingAndShowTheReason() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try await f.endTurn(result: f.result())
        await round.value
        #expect(f.mark?.outcome == .failed(ConflictFailure.markersLeft.message))
        #expect(try await f.branch() == f.head)
        #expect(await f.worktreeHead() == f.head)
        #expect(f.store.state.prs[f.pr]?.round == nil)
        #expect(f.store.state.prs[f.pr]?.lastError == nil)
        await f.end()
    }

    // Claude also adds a file that has no conflict: Bifrost pushes nothing and keeps the file.
    @Test func aChangeOutsideTheConflictsPushesNothing() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.resolve()
        try "notes\n".write(toFile: f.worktree + "/notes.txt", atomically: false, encoding: .utf8)
        try await f.endTurn(result: f.result())
        await round.value
        // The file is no change of the round, so it stays and the row shows Needs you.
        #expect(f.mark == nil)
        #expect(f.store.state.prs[f.pr]?.waiting?.files == ["notes.txt"])
        #expect(try await f.branch() == f.head)
        #expect(FileManager.default.fileExists(atPath: f.worktree + "/notes.txt"))
        await f.end()
    }

    // GitHub says the PR conflicts, but git merges it with no conflict: no session starts and
    // nothing is pushed.
    @Test func aCleanLocalMergePushesNothing() async throws {
        let f = try await ConflictFixture(conflict: false)
        await (try f.pollNow()).value
        #expect(f.bgRuns.isEmpty && f.prompts.sends.isEmpty)
        #expect(f.mark?.outcome == .failed(ConflictFailure.noConflict.message))
        #expect(try await f.branch() == f.head)
        #expect(f.store.state.prs[f.pr]?.round == nil)
        await f.end()
    }

    // Another person pushes to feat during the turn: the push finds new commits and pushes
    // nothing (BranchMoved.stop), with no text, and the new head is a new pair.
    @Test func aBranchThatMovedDuringTheRoundGetsNoPush() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        let moved = try await f.otherPush()
        try f.resolve()
        try await f.endTurn(result: f.result())
        await round.value
        #expect(try await f.branch() == moved)
        #expect(f.mark == nil && f.store.state.prs[f.pr]?.round == nil)
        #expect(f.store.state.prs[f.pr]?.lastError == nil)
        #expect(await f.worktreeHead() == f.head)
        await f.end()
    }

    // The user turns the setting off during the turn of an automatic round: the round checks the
    // gate again before the push, so nothing is pushed, with no text.
    @Test func turningTheSettingOffBeforeThePushPushesNothing() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        f.rounds.apply(ReviewsConfig(resolveConflicts: false))
        try f.resolve()
        try await f.endTurn(result: f.result())
        await round.value
        #expect(try await f.branch() == f.head)
        #expect(f.mark == nil && f.store.state.prs[f.pr]?.round == nil)
        #expect(await f.worktreeHead() == f.head)
        await f.end()
    }

    // A PR from a fork gets no round, also with Resolve now.
    @Test func aForkGetsNoRound() async throws {
        let f = try await ConflictFixture(fork: true)
        f.rounds.afterPoll(f.poll)
        await f.rounds.resolveNow(f.pr)
        #expect(f.store.state.queue.isEmpty && f.rounds.queue.task(of: f.pr) == nil)
        #expect(f.github.calls.isEmpty)
        await f.end()
    }

    // Writes of an earlier round that wait (an outbox) stop the conflict rounds: the fix of the
    // outbox can be in the worktree.
    @Test func aPRWithAnUnsentOutboxGetsNoRound() async throws {
        let outbox = Outbox(
            headSHA: try Rows.commit("c"), mergeBase: try Rows.commit("c"), startedAt: Rows.now,
            seen: [:],
            posts: [
                OutboxPost(
                    id: OutboxRules.pushID, state: .todo, write: .push(commit: nil, signed: false))
            ])
        let key = try #require(PRKey(text: "Owner-A/Repo-A#7"))
        let f = try await ConflictFixture { state in
            var prState = PRState()
            prState.outbox = outbox
            state.prs[key] = prState
        }
        f.rounds.afterPoll(f.poll)
        await f.rounds.resolveNow(f.pr)
        #expect(f.store.state.queue.isEmpty && f.rounds.queue.task(of: f.pr) == nil)
        await f.end()
    }

    // A round that was posting when Bifrost quit pushes its merge after the next start. A merge
    // that reached GitHub before the quit goes no second time: the push checks the branch first.
    @Test(arguments: [false, true])
    func aPostingRoundPushesAfterARestart(_ alreadyPushed: Bool) async throws {
        let f = try await ConflictFixture()
        let merge = try await f.postingRound(pushed: alreadyPushed)
        await f.restart()
        let round = try #require(f.rounds.queue.task(of: f.pr))
        await round.value
        #expect(try await f.branch() == merge)
        #expect(f.mark?.outcome == .pushed(merge) && f.store.state.prs[f.pr]?.round == nil)
        #expect(f.bgRuns.isEmpty)
        await f.end()
    }

    // A round whose session ran when Bifrost quit waits for the end of that session after the
    // next start, and goes on with the saved merge to resolve.
    @Test func aRunningRoundGoesOnAfterARestart() async throws {
        let f = try await ConflictFixture()
        _ = try f.pollNow()
        await f.sessionWorks()
        try f.resolve()
        await f.restart()
        #expect(f.store.state.prs[f.pr]?.round?.phase == .running)
        let round = try #require(f.rounds.queue.task(of: f.pr))
        try await f.endTurn(result: f.result())
        await round.value
        let merge = try await f.branch()
        #expect(try await f.object(merge).parents == [f.head, f.base])
        #expect(f.mark?.outcome == .pushed(merge) && f.bgRuns.count == 1)
        await f.end()
    }

    // The PR merges or closes while its round runs: the round stops, and its session, worktree,
    // mark and click go. Nothing is pushed.
    @Test func aClosedPRDropsTheConflictWork() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        f.github.answers[RequestQueries.stateName] = .success(WritesData.lifecycle("MERGED"))
        f.rounds.afterPoll(Rows.answer(mine: []))
        await round.value
        await waitUntil { f.rounds.drops[f.pr] == nil }
        #expect(f.deps.calls.claudeRuns.contains(["rm", "abcdef12"]))
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.round == nil && state.conflict == nil && state.requestSession == nil)
        #expect(!state.resolveNow && state.lastError == nil)
        #expect(!FileManager.default.fileExists(atPath: f.worktree))
        #expect(try await f.branch() == f.head)
        await f.end()
    }

    // Stop session in a turn: the round pushes nothing, and the mark gets the text of the stop,
    // so no automatic round tries the pair again.
    @Test func stopSessionGivesTheMarkTheStopText() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        let stop = Task { await f.rounds.stopSession(f.pr) }
        await round.value
        await f.parkWaitStarted()
        f.deps.clock.advance(by: SessionActions.parkWait)
        await stop.value
        #expect(f.mark?.outcome == .failed(ConflictFailure.session(.stopped).message))
        #expect(f.store.state.prs[f.pr]?.round == nil)
        #expect(f.store.state.prs[f.pr]?.lastError == nil)
        #expect(await f.worktreeHead() == f.head)
        f.rounds.afterPoll(f.poll)
        #expect(f.store.state.queue.isEmpty)
        await f.end()
    }

    // An own request file at the end of the turn shows that Claude changed files for a request in
    // the turn: Bifrost refuses the file, commits and pushes nothing, keeps the worktree, and the
    // row shows Needs you. The working mark goes, so the pair counts as not tried.
    @Test func anOwnRequestFileOfTheTurnIsRefusedAndNothingIsPushed() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.resolve()
        let auto = try #require(await f.worktreeHead())
        try f.writeOwnRequest(head: auto)
        try await f.endTurn(result: f.result())
        await round.value
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.waiting?.reason == OwnRequestStop.conflictMerge.message)
        #expect(state.waiting?.kind == .askAgain)
        #expect(state.waiting?.files == ["src/a.swift"])
        #expect(state.conflict == nil && state.round == nil && state.lastError == nil)
        #expect(!FileManager.default.fileExists(atPath: f.input + "/" + OwnRequestFile.name))
        #expect(try await f.branch() == f.head)
        #expect(await f.worktreeHead() == auto && f.fileA?.contains("both") == true)
        await f.end()
    }

    // An own request never commits on the merge with the markers of a conflict round (only the
    // clone of Bifrost has it): it is refused with Needs you, and nothing is pushed. Discard these
    // changes then puts the worktree back at the head of the PR.
    @Test func anOwnRequestOnTheMergeOfARoundIsRefused() async throws {
        let f = try await ConflictFixture()
        let store = f.repos.store
        try await store.ensureClone(f.pr.repo)
        _ = try await store.fetchPR(f.pr, base: try #require(BranchName("main")))
        let start = try await ConflictMerge.start(
            pr: f.pr, head: f.head, base: f.base, git: store.git)
        _ = try await store.roundFolder(f.pr)
        _ = try await store.placeWorktree(f.pr, head: start.auto)
        try f.resolve()
        try f.writeOwnRequest(head: start.auto)
        f.rounds.checkOwnRequest(f.pr)
        await waitUntil { f.rounds.ownRuns[f.pr] == nil && f.store.state.prs[f.pr] != nil }
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.waiting?.reason == OwnRequestStop.conflictMerge.message)
        #expect(state.outbox == nil)
        #expect(try await f.branch() == f.head)
        #expect(await f.rounds.changesToDiscard(f.pr) == .files(["src/a.swift"]))
        #expect(await f.rounds.discardChanges(f.pr, click: UserClick()) == .discarded)
        #expect(await f.worktreeHead() == f.head)
        #expect(f.fileA == ConflictFixture.lines([11: "line eleven feat"]))
        await f.end()
    }

    // The safety net: changes in the worktree that no round made stop the round before it moves
    // the worktree. They stay, the session gets no prompt, and the row shows Needs you with the
    // files, so Discard these changes is offered.
    @Test func theSafetyNetKeepsTheWorkOfThePersonAndStartsNoRound() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try await f.endTurn(result: f.result(needsYou: "Only you can pick the line."))
        await round.value
        #expect(await f.worktreeHead() == f.head)
        try "person\n".write(
            toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        await f.rounds.resolveNow(f.pr)
        let again = try #require(f.rounds.queue.task(of: f.pr))
        await again.value
        #expect(f.prompts.sends.isEmpty && f.bgRuns.count == 1)
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.waiting?.reason == RoundFailure.changesNotOnGitHub.message(for: .conflict))
        #expect(state.waiting?.kind == .unpushed)
        #expect(state.waiting?.files == ["src/a.swift"] && state.conflict == nil)
        #expect(f.fileA == "person\n")
        #expect(await f.worktreeHead() == f.head)
        await f.end()
    }

    // A record of the PR that did not read in full can lack the mark of a pair that a round tried:
    // the next poll counts its pair as tried, so no automatic round starts on it, and the row
    // offers Resolve now. A new pair gets its round.
    @Test func aRecordInDoubtStartsNoRoundOnItsPair() async throws {
        let f = try await ConflictFixture()
        await f.store.update { state in
            var prState = PRState()
            prState.markInDoubt = true
            state.prs[f.pr] = prState
        }
        f.rounds.afterPoll(f.poll)
        #expect(f.store.state.queue.isEmpty && f.rounds.queue.task(of: f.pr) == nil)
        let tried = ConflictMark(head: f.head, base: f.base, at: Rows.now, outcome: .failed(""))
        #expect(f.mark == tried)
        #expect(f.store.state.prs[f.pr]?.markInDoubt == false)
        let rows = Rows.mine(f.poll, f.store.state)
        #expect(rows.first?.mineState?.claude == .conflicts(nil))
        let base = try await f.pushMain(lineEleven: "line main again")
        try f.github(head: f.head, base: base)
        let merge = try await f.resolvedRound()
        #expect(f.mark?.outcome == .pushed(merge))
        await f.end()
    }

    // MARK: - The checks before the push

    // A person adds a file to the worktree after the end of the turn and before the commit: the
    // round pushes nothing, the file stays, and the row shows Needs you with it.
    @Test func aChangeAfterTheTurnBeforeTheCommitNeedsYouAndPushesNothing() async throws {
        let runner = ConflictHookRunner()
        let f = try await ConflictFixture(runner: runner)
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.resolve()
        let file = f.worktree + "/person.txt"
        runner.afterFirstStatus {
            try? "mine\n".write(toFile: file, atomically: false, encoding: .utf8)
        }
        try await f.endTurn(result: f.result())
        await round.value
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.waiting?.kind == .unpushed && state.waiting?.files == ["person.txt"])
        #expect(state.conflict == nil && state.round == nil && state.lastError == nil)
        #expect(try await f.branch() == f.head)
        #expect(FileManager.default.fileExists(atPath: file))
        await f.end()
    }

    // An own request file lands while git adds the files of the merge: the round pushes nothing,
    // and the file goes with its reason on the row.
    @Test func anOwnRequestWhileGitAddsTheMergePushesNothing() async throws {
        let runner = ConflictHookRunner()
        let f = try await ConflictFixture(runner: runner)
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.resolve()
        let auto = try #require(await f.worktreeHead())
        let (data, file) = (
            ConflictFixture.ownRequest(head: auto), f.input + "/" + OwnRequestFile.name
        )
        runner.beforeFirstAdd { try? data.write(to: URL(filePath: file)) }
        try await f.endTurn(result: f.result())
        await round.value
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.waiting?.reason == OwnRequestStop.conflictMerge.message)
        #expect(state.conflict == nil && state.round == nil)
        #expect(try await f.branch() == f.head)
        await f.end()
    }

    // MARK: - The copy at the end of a failed round

    // A person uses the session when the round fails after it committed the merge: the copy stays
    // where it is, so the work in the session is not moved under the person.
    @Test func aSessionInUseKeepsTheCopyAtAFailure() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.resolve()
        _ = try await f.otherPush()
        f.github.onRead = { name in
            guard name == HeadQueries.name else { return }
            await f.show(.busy)
        }
        try await f.endTurn(result: f.result())
        await round.value
        f.github.onRead = nil
        #expect(try await f.branch() != f.head)
        let at = try #require(await f.worktreeHead())
        #expect(at != f.head)
        await f.end()
    }

    // GitHub refuses the push (a protected branch): the mark shows the failure, and the copy goes
    // back to the head of the PR.
    @Test func aRefusedPushPutsTheCopyBackAtTheHead() async throws {
        let f = try await ConflictFixture()
        try f.protectBranch()
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.resolve()
        try await f.endTurn(result: f.result())
        await round.value
        guard case .failed(let text)? = f.mark?.outcome else {
            Issue.record("The mark is not a failure.")
            return await f.end()
        }
        #expect(!text.isEmpty)
        #expect(try await f.branch() == f.head)
        #expect(await f.worktreeHead() == f.head)
        #expect(f.store.state.prs[f.pr]?.round == nil)
        await f.end()
    }

    // A turn that passes the time limit gets a stop: the round pushes nothing, and the copy goes
    // back to the head also while the row still runs.
    @Test func aTurnThatTimesOutStopsTheSessionAndResetsTheCopy() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        f.deps.clock.advance(by: ReviewRounds.limit)
        await f.parkWaitStarted()
        f.deps.clock.advance(by: SessionActions.parkWait)
        await round.value
        #expect(f.mark?.outcome == .failed(ConflictFailure.session(.timeout).message))
        #expect(try await f.branch() == f.head)
        #expect(await f.worktreeHead() == f.head)
        #expect(f.fileA == ConflictFixture.lines([11: "line eleven feat"]))
        await f.end()
    }

    // A session that shows a prompt box must never ask: the round stops the session and pushes
    // nothing, and the copy goes back to the head also while the row shows the box.
    @Test func aPromptBoxStopsTheSessionAndResetsTheCopy() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        await f.show(.waiting, waitingFor: "permission")
        await f.parkWaitStarted()
        f.deps.clock.advance(by: SessionActions.parkWait)
        await round.value
        #expect(f.mark?.outcome == .failed(ConflictFailure.session(.blocked).message))
        #expect(try await f.branch() == f.head)
        #expect(await f.worktreeHead() == f.head)
        #expect(f.fileA == ConflictFixture.lines([11: "line eleven feat"]))
        await f.end()
    }

    // MARK: - The start and the end of the rounds

    // A start of Bifrost takes over the conflict rounds of the state: a stopped round that did
    // not run gets the text of the stop and loses its click, a stopped CI round goes (its stop
    // goes to its CI question, CIRoundTests), and a round that did not run goes back to the
    // queue.
    @Test func aStartTakesOverTheConflictRoundsOfTheState() async throws {
        let f = try await ConflictFixture()
        let (pr, head, base) = (f.pr, f.head, f.base)
        func round(stopped: Bool, kind: PRSessionKind) -> ActiveRound {
            ActiveRound(
                phase: .preparing, startedAt: Rows.now, at: Rows.now, headSHA: head, baseSHA: base,
                stoppedByUser: stopped, kind: kind)
        }
        let working = ConflictMark(head: head, base: base, at: Rows.now, outcome: .working)
        await f.store.update { state in
            var prState = PRState()
            prState.round = round(stopped: true, kind: .conflict)
            prState.conflict = working
            prState.resolveNow = true
            state.prs[pr] = prState
        }
        await f.restart()
        var state = try #require(f.store.state.prs[pr])
        #expect(state.round == nil && !state.resolveNow && f.store.state.queue.isEmpty)
        #expect(state.conflict?.outcome == .failed(ConflictFailure.session(.stopped).message))
        await f.store.update { state in
            var prState = PRState()
            prState.round = round(stopped: true, kind: .ci)
            state.prs[pr] = prState
        }
        await f.restart()
        #expect(f.store.state.prs[pr]?.round == nil && f.store.state.queue.isEmpty)
        await f.store.update { state in
            var prState = PRState()
            prState.round = round(stopped: false, kind: .conflict)
            state.prs[pr] = prState
        }
        await f.restart()
        state = try #require(f.store.state.prs[pr])
        #expect(state.round == nil && f.store.state.queue.map(\.pr) == [pr])
        await f.end()
    }

    // Remove all clones while a conflict round runs: the round, its working mark and its click
    // go, and nothing is pushed.
    @Test func removeAllClonesEndsAConflictRound() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        let pr = f.pr
        await f.store.update { $0.prs[pr]?.resolveNow = true }
        #expect(f.mark?.outcome == .working)
        #expect(await f.rounds.removeAll(then: { nil }) == nil)
        await round.value
        let state = try #require(f.store.state.prs[pr])
        #expect(state.round == nil && state.conflict == nil && !state.resolveNow)
        #expect(f.store.state.queue.isEmpty)
        #expect(try await f.branch() == f.head)
        await f.end()
    }

    // An own request of the user waits when a conflict round starts: it goes first and pushes
    // alone on the head of the PR. A round that already yielded twice fails as busy and keeps
    // the file.
    @Test func anOwnRequestBeforeAConflictRoundGoesFirst() async throws {
        let f = try await ConflictFixture()
        let store = f.repos.store
        try await store.ensureClone(f.pr.repo)
        _ = try await store.fetchPR(f.pr, base: try #require(BranchName("main")))
        _ = try await store.roundFolder(f.pr)
        _ = try await store.placeWorktree(f.pr, head: f.head)
        try ConflictFixture.lines([11: "line eleven renamed"]).write(
            toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        try f.writeOwnRequest(head: f.head)
        f.github.answers[RequestQueries.contextName] = .success(
            ConflictFixture.context(head: f.head))
        f.github.answers[RequestQueries.threadsName] = .success(ConflictFixture.noThreads())
        f.github.answers[RequestQueries.commentsName] = .success(ConflictFixture.noThreads())
        f.github.answers[RequestQueries.stateName] = .success(WritesData.lifecycle())
        f.rounds.afterPoll(f.poll)
        for _ in 0..<200 where try await f.branch() == f.head {
            try await Task.sleep(for: .milliseconds(50))
        }
        let pushed = try await f.branch()
        #expect(
            await f.sourceGit(["log", "-1", "--format=%P %s", pushed.hex])
                == "\(f.head.hex) refactor: rename the helper")
        await f.end()
    }

    // The third time that an own request waits, the round fails as busy and pushes nothing.
    @Test func aThirdYieldToAnOwnRequestFailsAsBusy() async throws {
        let f = try await ConflictFixture()
        let store = f.repos.store
        try await store.ensureClone(f.pr.repo)
        _ = try await store.fetchPR(f.pr, base: try #require(BranchName("main")))
        _ = try await store.roundFolder(f.pr)
        _ = try await store.placeWorktree(f.pr, head: f.head)
        try ConflictFixture.lines([11: "line eleven renamed"]).write(
            toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        try f.writeOwnRequest(head: f.head)
        f.rounds.afterPoll(f.poll)
        f.store.change { $0.queue.removeAll() }
        f.rounds.queue.cancel(f.pr)
        await f.rounds.runConflict(
            QueuedJob(pr: f.pr, kind: .conflict, since: Rows.now), saved: nil,
            yields: ReviewRounds.maxYields)
        #expect(f.mark?.outcome == .failed(ConflictFailure.session(.sessionBusy).message))
        #expect(try await f.branch() == f.head)
        #expect(FileManager.default.fileExists(atPath: f.input + "/" + OwnRequestFile.name))
        await f.end()
    }

    // A pushed merge goes on the CI chain of its head, so it counts in the budget of that head.
    @Test func aPushedMergeJoinsTheCIChainOfItsHead() async throws {
        let f = try await ConflictFixture()
        let (pr, head) = (f.pr, f.head)
        await f.store.update { state in
            var prState = PRState()
            prState.ci = CIMark(chain: [head])
            state.prs[pr] = prState
        }
        let merge = try await f.resolvedRound()
        #expect(f.store.state.prs[pr]?.ci?.chain == [head, merge])
        await f.end()
    }

    // A round that was posting when Bifrost quit, with the gate closed now (the setting is off
    // and no click waits): it ends with no text, pushes nothing, and the copy goes back to the
    // head.
    @Test func aPostingRoundWithTheGateClosedPushesNothing() async throws {
        let f = try await ConflictFixture(config: ReviewsConfig(resolveConflicts: false))
        _ = try await f.postingRound(pushed: false)
        await f.restart()
        let round = try #require(f.rounds.queue.task(of: f.pr))
        await round.value
        #expect(try await f.branch() == f.head)
        #expect(f.mark == nil && f.store.state.prs[f.pr]?.round == nil)
        #expect(await f.worktreeHead() == f.head)
        await f.end()
    }

    // MARK: - The ends of a round

    // A merge that went, while the copy cannot be reset (a person uses the session, or a change
    // that no round made is in the copy): HEAD and the index go to the merge, and the files stay.
    // The copy is not left on the commit with the markers, which GitHub does not have.
    @Test(arguments: ["session in use", "change of a person"])
    func aMergeThatWentMovesTheCopyToTheMerge(_ why: String) async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.resolve()
        let file = f.worktree + "/person.txt"
        f.github.onRead = { name in
            guard name == HeadQueries.name else { return }
            if why == "session in use" {
                await f.show(.busy)
            } else {
                try? "mine\n".write(toFile: file, atomically: false, encoding: .utf8)
            }
        }
        try await f.endTurn(result: f.result())
        await round.value
        f.github.onRead = nil
        let merge = try await f.branch()
        #expect(merge != f.head)
        #expect(f.mark?.outcome == .pushed(merge))
        #expect(await f.worktreeHead() == merge)
        #expect(f.fileA == ConflictFixture.lines([11: "line eleven both"]))
        #expect(FileManager.default.fileExists(atPath: file) == (why != "session in use"))
        await f.end()
    }

    // A turn that times out after Claude edited a conflicted file: the edit is a change of the
    // round, so the copy goes back to the head.
    @Test func aTurnThatTimesOutAfterEditsResetsTheCopy() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.resolve()
        f.deps.clock.advance(by: ReviewRounds.limit)
        await f.parkWaitStarted()
        f.deps.clock.advance(by: SessionActions.parkWait)
        await round.value
        #expect(f.mark?.outcome == .failed(ConflictFailure.session(.timeout).message))
        #expect(try await f.branch() == f.head)
        #expect(await f.worktreeHead() == f.head)
        #expect(f.fileA == ConflictFixture.lines([11: "line eleven feat"]))
        await f.end()
    }

    // A turn that times out when a person added a file too: the copy stays as it is, with the
    // file, so no work of the person is lost.
    @Test func aTurnThatTimesOutWithAFileOfAPersonKeepsTheCopy() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.resolve()
        let file = f.worktree + "/person.txt"
        try "mine\n".write(toFile: file, atomically: false, encoding: .utf8)
        f.deps.clock.advance(by: ReviewRounds.limit)
        await f.parkWaitStarted()
        f.deps.clock.advance(by: SessionActions.parkWait)
        await round.value
        #expect(f.mark?.outcome == .failed(ConflictFailure.session(.timeout).message))
        #expect(try await f.branch() == f.head)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "mine\n")
        #expect(await f.worktreeHead() != f.head)
        await f.end()
    }

    // A person uses the session when an automatic round reaches its turn: the pair is not tried.
    // The round ends with no text and no mark, and the next free poll starts it.
    @Test func aBusySessionLeavesThePairUntriedForTheNextFreePoll() async throws {
        let f = try await ConflictFixture()
        let first = try f.pollNow()
        await f.sessionWorks()
        try await f.endTurn(result: f.result(needsYou: "Only you can pick the line."))
        await first.value
        await f.show(.busy)
        let base = try await f.pushMain(lineEleven: "line main again")
        try f.github(head: f.head, base: base)
        let ended = Recorder<Bool>()
        let job = QueuedJob(pr: f.pr, kind: .conflict, since: Rows.now)
        let run = Task {
            await f.rounds.runConflict(job, saved: nil)
            ended.record(true)
        }
        var turns = 0
        while ended.values.isEmpty, turns < 2000 {
            f.deps.clock.advance(by: .seconds(30))
            try await Task.sleep(for: .milliseconds(2))
            turns += 1
        }
        await run.value
        #expect(f.mark == nil && f.store.state.prs[f.pr]?.round == nil)
        #expect(f.store.state.prs[f.pr]?.waiting == nil)
        await f.show(.idle)
        f.rounds.afterPoll(f.poll)
        #expect(f.rounds.queue.task(of: f.pr) != nil)
        await f.end()
    }

    // A posting round with the merge already on GitHub, and the gate closed now: the merge is
    // recorded as pushed, so it counts for the CI chain and for the mark.
    @Test func aPostingRoundWhoseMergeIsOnTheBranchRecordsItWithTheGateClosed() async throws {
        let f = try await ConflictFixture(config: ReviewsConfig(resolveConflicts: false))
        let merge = try await f.postingRound(pushed: true)
        await f.restart()
        let round = try #require(f.rounds.queue.task(of: f.pr))
        await round.value
        #expect(try await f.branch() == merge)
        #expect(f.mark?.outcome == .pushed(merge) && f.store.state.prs[f.pr]?.round == nil)
        await f.end()
    }

    // A poll says conflicting and the fresh read does not: the round ends with no text. The next
    // polls on the same pair queue nothing until WorkRule.readRetry has passed.
    @Test func aQuietPairWaitsForTheRetryTime() async throws {
        let f = try await ConflictFixture()
        f.github.answers[HeadQueries.name] = .success(
            ConflictFixture.headRead(head: f.head, base: f.base, mergeable: "MERGEABLE"))
        await (try f.pollNow()).value
        #expect(f.mark == nil && f.store.state.queue.isEmpty)
        f.rounds.afterPoll(f.poll)
        #expect(f.rounds.queue.task(of: f.pr) == nil)
        try await f.clock.sleep(for: WorkRule.readRetry - .seconds(1))
        f.rounds.afterPoll(f.poll)
        #expect(f.rounds.queue.task(of: f.pr) == nil)
        try await f.clock.sleep(for: .seconds(2))
        f.rounds.afterPoll(f.poll)
        let again = try #require(f.rounds.queue.task(of: f.pr))
        await again.value
        await f.end()
    }

    // A failure with no pair (the poll has no base commit and the head read fails) has no mark to
    // show it, so the Event log gets one line.
    @Test func aFailureWithNoPairWritesALineInTheEventLog() async throws {
        let f = try await ConflictFixture()
        f.poll.mine[0].baseSHA = ""
        f.github.answers[HeadQueries.name] = .failure(.unknownOutcome("Bad gateway"))
        f.rounds.afterPoll(f.poll)
        await f.rounds.resolveNow(f.pr)
        let round = try #require(f.rounds.queue.task(of: f.pr))
        await round.value
        #expect(f.mark == nil && f.store.state.prs[f.pr]?.round == nil)
        let line = try #require(f.events.values.first)
        #expect(line.contains("Owner-A/Repo-A#7") && line.contains("couldn't load"))
        await f.end()
    }

    // A pushed merge clears an old reason of the row: the round proved the copy clean first.
    @Test func aPushedMergeClearsAnOldReason() async throws {
        let f = try await ConflictFixture()
        await f.store.update { state in
            var prState = PRState()
            prState.waiting = WaitsForYou(reason: "An old reason.")
            state.prs[f.pr] = prState
        }
        f.rounds.afterPoll(f.poll)
        await f.rounds.resolveNow(f.pr)
        let round = try #require(f.rounds.queue.task(of: f.pr))
        await f.sessionWorks()
        try f.resolve()
        try await f.endTurn(result: f.result())
        await round.value
        let merge = try await f.branch()
        #expect(f.mark?.outcome == .pushed(merge))
        #expect(f.store.state.prs[f.pr]?.waiting == nil)
        await f.end()
    }

    // A person adds a file outside the conflicted files during the turn. At the normal end the
    // file is no change of the round: the merge is refused, the file stays, and the row shows
    // Needs you.
    @Test func aFileOfAPersonDuringTheTurnSurvivesTheNormalEnd() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.resolve()
        let file = f.worktree + "/person.txt"
        try "mine\n".write(toFile: file, atomically: false, encoding: .utf8)
        try await f.endTurn(result: f.result())
        await round.value
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "mine\n")
        #expect(f.store.state.prs[f.pr]?.waiting?.files == ["person.txt"])
        #expect(try await f.branch() == f.head)
        await f.end()
    }

    // The same file, and the user stops the session: the copy stays, and nothing is pushed.
    @Test func aFileOfAPersonDuringTheTurnSurvivesAStop() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        let file = f.worktree + "/person.txt"
        try "mine\n".write(toFile: file, atomically: false, encoding: .utf8)
        let stop = Task { await f.rounds.stopSession(f.pr) }
        await round.value
        await f.parkWaitStarted()
        f.deps.clock.advance(by: SessionActions.parkWait)
        await stop.value
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "mine\n")
        #expect(try await f.branch() == f.head)
        await f.end()
    }

    // A quiet end with the setting off keeps no wait, so turning the setting on works at the
    // next poll.
    @Test func aQuietEndWithTheSettingOffKeepsNoWait() async throws {
        let f = try await ConflictFixture(config: ReviewsConfig(resolveConflicts: false))
        f.github.answers[HeadQueries.name] = .success(
            ConflictFixture.headRead(head: f.head, base: f.base, mergeable: "MERGEABLE"))
        f.rounds.afterPoll(f.poll)
        await f.rounds.resolveNow(f.pr)
        await (try #require(f.rounds.queue.task(of: f.pr))).value
        #expect(f.rounds.quietPairs.isEmpty)
        await f.end()
    }

    // MARK: - The marks in doubt

    // Records that the file lost: a poll that is cut keeps the doubt, so the next complete poll
    // counts the pair as tried and then clears it.
    @Test func lostRecordsAreInDoubtUntilACompletePoll() async throws {
        let f = try await ConflictFixture()
        await f.store.update { $0.marksInDoubt = true }
        var cut = f.poll
        cut.mineCut = true
        f.rounds.afterPoll(cut)
        #expect(f.store.state.marksInDoubt)
        #expect(f.store.state.queue.isEmpty && f.rounds.queue.task(of: f.pr) == nil)
        f.rounds.afterPoll(f.poll)
        #expect(!f.store.state.marksInDoubt)
        #expect(f.store.state.queue.isEmpty && f.rounds.queue.task(of: f.pr) == nil)
        #expect(f.mark?.outcome == .failed(""))
        await f.end()
    }

    // MARK: - The other work of the PR

    // A poll starts no round while an own request or a discard of the PR runs, nor while a person
    // uses its session. When the work ends, the next poll starts the round.
    @Test(arguments: ["own request", "discard", "session"])
    func aPollStartsNoRoundWhileOtherWorkOfThePRRuns(_ work: String) async throws {
        let f = try await ConflictFixture()
        let gate = Recorder<Bool>()
        if work == "own request" {
            f.rounds.ownRuns[f.pr] = Task { await waitUntil { !gate.values.isEmpty } }
        } else if work == "discard" {
            f.rounds.discards[f.pr] = Task {
                await waitUntil { !gate.values.isEmpty }
                return .discarded
            }
        } else {
            let first = try f.pollNow()
            await f.sessionWorks()
            try await f.endTurn(result: f.result(needsYou: "Only you can pick the line."))
            await first.value
            await f.show(.busy)
            let base = try await f.pushMain(lineEleven: "line main again")
            try f.github(head: f.head, base: base)
        }
        f.rounds.afterPoll(f.poll)
        #expect(f.store.state.queue.isEmpty && f.rounds.queue.task(of: f.pr) == nil)
        gate.record(true)
        if work == "own request" {
            await f.rounds.ownRuns[f.pr]?.value
            f.rounds.ownRuns[f.pr] = nil
        } else if work == "discard" {
            _ = await f.rounds.discards[f.pr]?.value
            f.rounds.discards[f.pr] = nil
        } else {
            await f.show(.idle)
        }
        f.rounds.afterPoll(f.poll)
        #expect(f.rounds.queue.task(of: f.pr) != nil)
        await f.end()
    }

    // Resolve now does nothing while an own request or a discard of the PR runs.
    @Test(arguments: ["own request", "discard"])
    func resolveNowDoesNothingWhileOtherWorkOfThePRRuns(_ work: String) async throws {
        let f = try await ConflictFixture(config: ReviewsConfig(resolveConflicts: false))
        let gate = Recorder<Bool>()
        if work == "own request" {
            f.rounds.ownRuns[f.pr] = Task { await waitUntil { !gate.values.isEmpty } }
        } else {
            f.rounds.discards[f.pr] = Task {
                await waitUntil { !gate.values.isEmpty }
                return .discarded
            }
        }
        f.rounds.afterPoll(f.poll)
        await f.rounds.resolveNow(f.pr)
        #expect(f.store.state.queue.isEmpty && f.rounds.queue.task(of: f.pr) == nil)
        #expect(f.store.state.prs[f.pr]?.resolveNow != true)
        gate.record(true)
        await f.end()
    }
}
