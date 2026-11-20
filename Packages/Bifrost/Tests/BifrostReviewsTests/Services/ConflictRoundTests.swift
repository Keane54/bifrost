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
import Testing

@testable import BifrostReviews

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
        consent: Bool = true, fork: Bool = false, saved: (inout ReviewsState) -> Void = { _ in }
    ) async throws {
        self.config = config
        repos = try RepoFixture()
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

    func show(_ status: AgentStatus) async {
        let entry = AgentEntry(
            sessionId: Self.id, cwd: worktree, isBackground: true, startedAt: 1, name: Self.name,
            status: status, pid: 4242, id: Self.shortID)
        await deps.show([entry]) { rows in
            rows.contains { $0.sessionId == Self.id && ($0.state == .working) == (status == .busy) }
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
        let limit = deps.clock.now.offset + ReviewRounds.requestLimit
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
        let fields: JSONValue = [
            "version": 1, "pr": "Owner-A/Repo-A#7", "headSha": .string(head.hex),
            "commit": ["message": "refactor: rename the helper", "paths": ["src/a.swift"]],
        ]
        try ReviewData.json(fields).write(to: URL(filePath: input + "/" + OwnRequestFile.name))
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

    // Claude also adds a file that has no conflict: Bifrost pushes nothing.
    @Test func aChangeOutsideTheConflictsPushesNothing() async throws {
        let f = try await ConflictFixture()
        let round = try f.pollNow()
        await f.sessionWorks()
        try f.resolve()
        try "notes\n".write(toFile: f.worktree + "/notes.txt", atomically: false, encoding: .utf8)
        try await f.endTurn(result: f.result())
        await round.value
        #expect(f.mark?.outcome == .failed(ConflictFailure.otherFiles.message))
        #expect(try await f.branch() == f.head)
        #expect(!FileManager.default.fileExists(atPath: f.worktree + "/notes.txt"))
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
        let store = f.repos.store
        try await store.ensureClone(f.pr.repo)
        _ = try await store.fetchPR(f.pr, base: try #require(BranchName("main")))
        let start = try await ConflictMerge.start(
            pr: f.pr, head: f.head, base: f.base, git: store.git)
        _ = try await store.placeWorktree(f.pr, head: start.auto)
        try f.resolve()
        let merge = try await ConflictMerge.commit(
            pr: f.pr, start: start, head: f.head, base: f.base, message: "Merge main into feat",
            git: store.git)
        if alreadyPushed {
            try await f.repos.setup(
                ["push", "-q", f.bare, "\(merge.hex):refs/heads/feat"],
                in: f.repos.clone(f.pr.repo))
        }
        await f.store.update { state in
            var prState = PRState()
            prState.round = ActiveRound(
                phase: .posting, startedAt: Rows.now, at: Rows.now, headSHA: f.head,
                baseSHA: f.base, kind: .conflict, fixSHA: merge, token: "t1",
                startSHA: start.auto)
            prState.conflict = ConflictMark(
                head: f.head, base: f.base, at: Rows.now, outcome: .working)
            state.prs[f.pr] = prState
        }
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
}
