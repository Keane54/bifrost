// The review rounds (docs/behaviour/reviews.md, "Review rounds"), end to end: the real git on a
// local bare source with a PR head at refs/pull/7/head, a Reviews store and a trusted clone in a
// temporary folder, the in-process FakeGitHub, and the real registry on scripted session lists
// with a fake claude (FakeActionDeps). The test plays the session: it shows its rows and writes
// its result file. No test reaches GitHub, runs claude or reads the real ~/.claude.json.
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostReviews

@MainActor
private final class RoundFixture {
    static let id = "11111111-2222-3333-4444-555555555555"
    static let name = "bifrost-test-Repo-A-7-review"
    static let shortID = ShortID("abcdef12")
    static let comment = DraftComment(
        path: "src/a.swift", line: 11, side: .right, body: "Use `<` here.")

    let repos: RepoFixture
    let deps = FakeActionDeps()
    let store: ReviewsStore
    let github: FakeGitHub
    let setup: RepoSetup
    private(set) var rounds: ReviewRounds
    let skills: URL
    let config: ReviewsConfig
    // The last good poll of the rounds: PR 7 and PR 8 of the repository.
    let answer: PollAnswer
    let notices = Recorder<ReviewsNotice>()
    let polls = Recorder<Bool>()
    let pr: PRKey
    let head: CommitID

    // pending: the pending reviews of the PR on GitHub. pendingNow: the answer of the fresh read
    // of the pending review of the user. saved: the state that the store holds before the start
    // of the rounds, as an earlier run left it.
    // trusted: the .claude.json of the home trusts the clone.
    init(
        pending: JSONValue = [], pendingNow: JSONValue? = nil, config: ReviewsConfig = .init(),
        trusted: Bool = true, runner: any CommandRunner = ProcessRunner(),
        saved: (inout ReviewsState, CommitID) -> Void = { _, _ in }
    ) async throws {
        self.config = config
        answer = Rows.answer(toReview: [
            try Rows.pull("Owner-A/Repo-A#7"), try Rows.pull("Owner-A/Repo-A#8"),
        ])
        repos = try RepoFixture(runner: runner)
        let repo = try #require(RepoName("Owner-A/Repo-A"))
        pr = try #require(PRKey(repo: repo, number: 7))
        let lines = (1...20).map { "line \($0)" }
        try await repos.source(repo, files: ["src/a.swift": lines.joined(separator: "\n") + "\n"])
        // The head of the PR: a second commit, at refs/pull/7/head of the source.
        let work = repos.root + "/work/" + repo.key
        var changed = lines
        changed[10] = "line eleven"
        changed.insert("line 11b", at: 11)
        try (changed.joined(separator: "\n") + "\n").write(
            toFile: work + "/src/a.swift", atomically: false, encoding: .utf8)
        try await repos.setup(["commit", "-q", "-am", "two"], in: work)
        try await repos.setup(
            ["push", "-q", repos.root + "/sources/" + repo.key + ".git", "HEAD:refs/pull/7/head"],
            in: work)
        let parsed = await ProcessRunner().run(
            Command(
                "/usr/bin/git", ["-C", work, "rev-parse", "HEAD"], environment: repos.env,
                timeout: .seconds(30)))
        head = try #require(CommitID(parsed.stdout.trimmed()))
        store = try await ReviewsStore.open(layout: repos.layout, log: Recorder<StoreEvent>())
        // Claude Code trusts the clone (the .claude.json of the temporary home).
        let clone = String(repos.clone(repo).dropLast())
        try "{\"projects\": {\"\(clone)\": {\"hasTrustDialogAccepted\": \(trusted)}}}".write(
            toFile: repos.root + "/.claude.json", atomically: false, encoding: .utf8)
        let skillsPath = repos.root + "/skills"
        skills = URL(filePath: skillsPath, directoryHint: .isDirectory)
        for (path, text) in [
            "skills/bifrost-review/bifrost-mode.md": "The mode.\n",
            "skills/bifrost-humanise/rules.md": "The rules.\n",
        ] {
            let file = skillsPath + "/" + path
            try FileManager.default.createDirectory(
                atPath: (file as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try text.write(toFile: file, atomically: false, encoding: .utf8)
        }
        var answers: [String: Result<Data, GitHubError>] = [
            ReviewQueries.contextName: .success(Self.context(head: head, pending: pending)),
            FakeGitHub.pendingReviewKey: .success(
                ReviewData.json(["state": "PENDING", "node_id": "PRR_new", "id": 1])),
        ]
        if let pendingNow {
            answers[ReviewQueries.reviewName] = .success(
                ReviewData.json(["data": ["node": pendingNow]]))
        }
        github = FakeGitHub(answers: answers)
        let notices = notices
        setup = RepoSetup(
            repos: repos.store, store: store, ptys: nil,
            home: URL(filePath: repos.root, directoryHint: .isDirectory),
            notify: { notices.record($0) }, now: { Rows.now })
        rounds = Self.rounds(
            store: store, deps: deps, github: github, repos: repos, setup: setup, skills: skills,
            config: config, answer: answer, notices: notices, polls: polls)
        deps.calls.answerClaude { args in
            args.first == "--bg"
                ? ExecResult(.exited(0), stdout: "backgrounded \u{B7} abcdef12 \u{B7} name\n")
                : ExecResult(.exited(0))
        }
        let head = head
        await store.update { saved(&$0, head) }
        await deps.start()
        rounds.start()
    }

    // The rounds on the parts of the fixture.
    private static func rounds(
        store: ReviewsStore, deps: FakeActionDeps, github: FakeGitHub, repos: RepoFixture,
        setup: RepoSetup, skills: URL, config: ReviewsConfig, answer: PollAnswer,
        notices: Recorder<ReviewsNotice>, polls: Recorder<Bool>
    ) -> ReviewRounds {
        let sessions = PRSessions(
            store: store, registry: deps.registry, actions: deps.makeActions(),
            claude: deps.claudeRunner(), clock: deps.clock, now: { Rows.now }, testPrefix: true)
        let rounds = ReviewRounds(
            store: store, github: GitHubClient(access: github), repos: repos.store, setup: setup,
            sessions: sessions, skills: skills,
            userHome: URL(filePath: repos.root, directoryHint: .isDirectory), config: config,
            now: { Rows.now })
        rounds.answer = { answer }
        rounds.notify = { notices.record($0) }
        rounds.ended = { polls.record(true) }
        return rounds
    }

    // A quit and a new start of Bifrost on the same state: the rounds stop, and new rounds take
    // the state over.
    func restart() async throws {
        rounds.stop()
        await rounds.waitForEnd()
        rounds = Self.rounds(
            store: store, deps: deps, github: github, repos: repos, setup: setup, skills: skills,
            config: config, answer: answer, notices: notices, polls: polls)
        rounds.start()
    }

    func end() async {
        rounds.stop()
        await rounds.waitForEnd()
        await store.close().value
        repos.folder.remove()
    }

    // The answer of the context read: the PR at the head, with its pending reviews.
    static func context(head: CommitID, pending: JSONValue) -> Data {
        ReviewData.json([
            "data": [
                "repository": [
                    "pullRequest": [
                        "title": "Fix the parser", "body": "The body.",
                        "url": "https://github.com/Owner-A/Repo-A/pull/7", "state": "OPEN",
                        "author": ["login": "user-a"], "baseRefName": "main",
                        "headRefName": "feat", "headRefOid": .string(head.hex),
                        "pending": ["nodes": pending],
                        "reviews": [
                            "nodes": [], "pageInfo": ["hasNextPage": false, "endCursor": .null],
                        ],
                    ]
                ]
            ]
        ])
    }

    var input: String { repos.layout.inputFolder(pr.repo, number: 7).plainPath }
    var worktree: String { GitPlace.worktree(pr, repos.layout) }

    // A good result file of the review of the head.
    // The token of the round comes from its input.json, as the session reads it.
    func result(_ change: (inout [String: JSONValue]) -> Void = { _ in }) -> Data {
        let file = try? Data(contentsOf: URL(filePath: input + "/input.json"))
        let token = file.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?
            .object?["round"]?.string
        return ReviewData.result {
            $0["headSha"] = .string(head.hex)
            if let token { $0["round"] = .string(token) }
            change(&$0)
        }
    }

    // The click on Review, and the task of its round.
    func review() async throws -> Task<Void, Never> {
        await rounds.review(pr)
        return try #require(rounds.queue.task(of: pr))
    }

    // The session starts: claude --bg ran, and its row works. The call ends when the wait for
    // the turn end has seen the working row, so a later idle row is an end after work. The wait
    // then holds the timer of the time limit, the earliest sleeper of the clock (the registry
    // sleeps for days).
    func sessionWorks() async {
        await waitUntil {
            self.deps.calls.claudeRuns.contains { $0.first == "--bg" }
        }
        await show(.busy)
        await waitUntil {
            self.store.state.prs[self.pr]?.round?.phase == .running
        }
        await waitUntil {
            guard let next = self.deps.clock.nextDeadline?.offset else { return false }
            return next <= self.deps.clock.now.offset + ReviewRounds.limit
        }
    }

    // The end of the task of a round. A cancel of the test (its time limit) cancels the round, so
    // a test that fails never holds the process.
    func ended(_ round: Task<Void, Never>) async {
        await withTaskCancellationHandler {
            await round.value
        } onCancel: {
            round.cancel()
        }
    }

    func show(_ status: AgentStatus) async {
        let entry = AgentEntry(
            sessionId: Self.id, cwd: worktree, isBackground: true, startedAt: 1, name: Self.name,
            status: status, pid: 4242, id: Self.shortID)
        await deps.show([entry]) { rows in
            rows.contains { $0.sessionId == Self.id && ($0.state == .working) == (status == .busy) }
        }
    }

    // The turn ends: the result file lands and the row is idle, which ends the turn at once when
    // the result passes the check. With no result (or a bad one), the clock moves to the end of
    // the settle time after work, and a later session list still shows the row idle. Until that
    // list, the wait holds only the timer of its time limit.
    func endTurn(result: Data?, passes: Bool = true) async throws {
        if let result {
            try result.write(to: URL(filePath: input + "/result.json"))
        }
        let limit = deps.clock.nextDeadline?.offset
        await show(.idle)
        guard result == nil || !passes else { return }
        let due = deps.clock.now.offset + RoundEnd.settle
        await waitUntil { self.deps.clock.nextDeadline?.offset == due }
        deps.clock.advance(by: RoundEnd.settle)
        await waitUntil { self.deps.clock.nextDeadline?.offset == limit }
        await deps.poll()
    }

    var writes: [GitHubWrite] {
        github.calls.compactMap { if case .write(let write) = $0 { write } else { nil } }
    }
}

@MainActor
@Suite("the review rounds", .serialized, .timeLimit(.minutes(3)), .tags(.realProcess))
struct ReviewRoundTests {
    // A round writes the input folder (input.json, the full diff, the mode file and the rules),
    // starts the read-only session in the worktree, and creates the pending review on the
    // reviewed commit with the summary and the comments. The draft texts are kept.
    @Test func aRoundWritesTheInputAndCreatesThePendingReview() async throws {
        let f = try await RoundFixture()
        let round = try await f.review()
        await f.sessionWorks()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: f.input)) ?? []
        #expect(Set(names) == ["input.json", "full.diff", "mode.md", "humanise-rules.md"])
        let input = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: URL(filePath: f.input + "/input.json")))
        #expect(input.object?["pr"]?.object?["key"] == "Owner-A/Repo-A#7")
        #expect(input.object?["pr"]?.object?["headSha"] == .string(f.head.hex))
        #expect(input.object?["review"]?.object?["kind"] == "first")
        let token = try #require(input.object?["round"]?.string)
        #expect(f.store.state.prs[f.pr]?.round?.token == token)
        #expect(input.object?["changedFiles"] == ["src/a.swift"])
        let mode = try String(contentsOfFile: f.input + "/mode.md", encoding: .utf8)
        #expect(mode == "The mode.\n")
        let start = try #require(f.deps.calls.claudeRuns.first { $0.first == "--bg" })
        #expect(start.contains("--restricted") && !start.contains("Bash"))
        #expect(start.suffix(2).first == RoundFixture.name)
        #expect(start.last == "/bifrost-review bifrost-input=\(f.input)/input.json")
        try await f.endTurn(result: f.result())
        await f.ended(round)
        #expect(
            f.writes == [
                .createPendingReview(
                    f.pr, commit: f.head, body: "One bug blocks this.",
                    comments: [RoundFixture.comment])
            ])
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.round == nil && state.lastError == nil)
        #expect(state.recommendation?.reviewID == (try ReviewData.node("PRR_new")))
        #expect(state.recommendation?.value == .requestChanges)
        #expect(state.lastReviewedCommit == f.head)
        #expect(state.reviewSession?.name == RoundFixture.name)
        #expect(f.store.state.drafts.map(\.path) == ["src/a.swift", ""])
        #expect(f.polls.values.count == 1)
        await f.end()
    }

    // The user submitted the pending review on GitHub after the read: the fresh read just before
    // the write sees it, and Bifrost writes nothing to it.
    @Test func aReviewSubmittedMeanwhileIsNotEdited() async throws {
        let f = try await RoundFixture(pendingNow: ["state": "COMMENTED", "viewerDidAuthor": true])
        // The pending review of the user is on the head commit.
        f.github.answers[ReviewQueries.contextName] = .success(
            RoundFixture.context(
                head: f.head,
                pending: [
                    [
                        "id": "PRR_mine", "body": "My notes.", "viewerDidAuthor": true,
                        "commit": ["oid": .string(f.head.hex)],
                    ]
                ]))
        let round = try await f.review()
        await f.sessionWorks()
        try await f.endTurn(result: f.result())
        await f.ended(round)
        #expect(f.writes.isEmpty)
        #expect(f.github.calls.contains(.read(ReviewQueries.reviewName)))
        #expect(f.store.state.prs[f.pr]?.lastError == RoundFailure.notPending.message)
        #expect(f.notices.values.isEmpty)
        await f.end()
    }

    // The round follows the row and the result file, with no poll: a good result written while
    // the session works does not end the round, and the only timer is the time limit. The idle
    // row then ends the turn at once, with no settle time.
    @Test func theRoundWaitsForTheTurnEndWithNoPoll() async throws {
        let f = try await RoundFixture()
        let round = try await f.review()
        await f.sessionWorks()
        try f.result().write(to: URL(filePath: f.input + "/result.json"))
        let limit = f.deps.clock.now.offset + ReviewRounds.limit
        await waitUntil { f.deps.clock.nextDeadline?.offset == limit }
        let reads = f.github.calls.count
        f.deps.clock.advance(by: .seconds(60))
        #expect(f.store.state.prs[f.pr]?.round?.phase == .running)
        #expect(f.github.calls.count == reads)
        let time = f.deps.clock.now
        await f.show(.idle)
        await f.ended(round)
        #expect(f.deps.clock.now == time)
        #expect(f.writes.count == 1)
        await f.end()
    }

    // A result of another session (here one with no token of this round, as an earlier session
    // or a session that a stop left would write) is no end and never counts.
    @Test func aResultWithoutTheTokenOfTheRoundIsRefused() async throws {
        let f = try await RoundFixture()
        let round = try await f.review()
        await f.sessionWorks()
        try await f.endTurn(result: f.result { $0["round"] = nil }, passes: false)
        await f.ended(round)
        #expect(
            f.store.state.prs[f.pr]?.lastError
                == RoundFailure.badResult(ResultRefusal("the round field is missing")).message)
        #expect(f.writes.isEmpty)
        await f.end()
    }

    // A drop that comes before the task of a round ran (the first poll after a click, with the
    // request gone) stops it: its entry goes, and no round stays in the state.
    @Test func aDropBeforeTheRoundRanStopsIt() async throws {
        let f = try await RoundFixture()
        let round = try await f.review()
        f.rounds.afterPoll(Rows.answer(toReview: [try Rows.pull("Owner-A/Repo-A#8")]))
        await f.ended(round)
        await waitUntil { f.store.state.queue.isEmpty }
        #expect(f.store.state.prs[f.pr]?.round == nil)
        #expect(f.store.state.prs[f.pr]?.actedAt == nil)
        #expect(!f.deps.calls.claudeRuns.contains { $0.first == "--bg" })
        await f.end()
    }

    // A result file that does not pass the check is no end: the round ends at the end of the
    // settle time after work, and fails with the reason of the check.
    @Test func aBadResultIsNoEnd() async throws {
        let f = try await RoundFixture()
        let round = try await f.review()
        await f.sessionWorks()
        try await f.endTurn(result: f.result { $0["why"] = "" }, passes: false)
        await f.ended(round)
        #expect(
            f.store.state.prs[f.pr]?.lastError
                == RoundFailure.badResult(ResultRefusal("the why field is empty")).message)
        #expect(f.writes.isEmpty)
        await f.end()
    }

    // Stop session during the turn: the round ends with nothing posted, and the session stops
    // and stays.
    @Test func aStoppedSessionFailsTheRoundAndPostsNothing() async throws {
        let f = try await RoundFixture()
        let round = try await f.review()
        await f.sessionWorks()
        let stop = Task { await f.rounds.stopSession(f.pr) }
        await f.ended(round)
        await waitUntil { f.deps.calls.claudeRuns.contains { $0 == ["stop", "abcdef12"] } }
        // The stop waits for the row to park; its time limit ends the wait.
        f.deps.clock.advance(by: SessionActions.parkWait)
        await stop.value
        #expect(f.writes.isEmpty)
        #expect(f.store.state.prs[f.pr]?.lastError == RoundFailure.stopped.message)
        #expect(f.store.state.prs[f.pr]?.round == nil)
        #expect(!f.deps.calls.claudeRuns.contains { $0.first == "rm" })
        #expect(f.notices.values.isEmpty)
        await f.end()
    }

    // A session that ends with no result fails the round: the row shows "Review failed" with
    // the reason and offers Try again, and no notification goes out.
    @Test func aFailedRoundShowsTryAgainAndSendsNoNotification() async throws {
        let f = try await RoundFixture()
        let round = try await f.review()
        await f.sessionWorks()
        try await f.endTurn(result: nil)
        await f.ended(round)
        let reason = RoundFailure.noResult.message
        #expect(f.store.state.prs[f.pr]?.lastError == reason)
        #expect(f.writes.isEmpty)
        #expect(f.notices.values.isEmpty)
        let rows = Rows.toReview(
            Rows.answer(toReview: [try Rows.pull("Owner-A/Repo-A#7")]), f.store.state)
        #expect(rows.first?.toReviewState == .failed(reason))
        #expect(rows.first?.status.text == "Review failed")
        #expect(rows.first?.status.tip == reason)
        #expect(rows.first?.reviewable == true)
        await f.end()
    }

    // A review round still starts a new session at each round, with the fixed names of its
    // input folder: Try again deletes the session of the last round first, then starts another.
    @Test func aReviewRoundStillStartsAFreshSession() async throws {
        let f = try await RoundFixture()
        let first = try await f.review()
        await f.sessionWorks()
        try await f.endTurn(result: nil)
        await f.ended(first)
        #expect(!f.deps.calls.claudeRuns.contains { $0.first == "rm" })
        let second = try await f.review()
        await waitUntil { f.deps.calls.claudeRuns.filter { $0.first == "--bg" }.count == 2 }
        let runs = f.deps.calls.claudeRuns
        let removed = try #require(runs.firstIndex(of: ["rm", "abcdef12"]))
        let started = try #require(runs.lastIndex { $0.first == "--bg" })
        #expect(removed < started)
        let input = URL(filePath: f.input + "/input.json", directoryHint: .notDirectory)
        #expect(runs[started].last == PRSessionArgs.reviewPrompt(input))
        await f.sessionWorks()
        try await f.endTurn(result: f.result())
        await f.ended(second)
        #expect(f.store.state.prs[f.pr]?.lastError == nil)
        await f.end()
    }

    // A comment that GitHub confirmed in Bifrost stays as You commented, and a poll never shows a
    // comment. A new review round of the PR ends it: the row shows the round, then the draft of
    // the round, not You commented.
    @Test func aNewRoundEndsAKeptReviewResult() async throws {
        let f = try await RoundFixture()
        let writes = ReviewWrites(clock: ManualClock())
        f.rounds.reviewStarted = { writes.forget($0) }
        let head = f.head.hex
        try await writes.send(f.pr, .comment) { () async throws(DraftRefusal) -> String in head }
        var request = try Rows.pull(f.pr.text)
        request.headSHA = head
        func row(_ request: PullRequest) -> ReviewRow? {
            let answer = Rows.answer(toReview: [request])
            return ReviewRows.toReview(
                answer, f.store.state, ReviewsConfig(), reviewedHere: writes.reviewedHere(answer),
                now: Rows.now
            ).first
        }
        #expect(row(request)?.toReviewState == .youCommented)
        let round = try await f.review()
        await f.sessionWorks()
        #expect(row(request)?.toReviewState == .reviewing)
        try await f.endTurn(result: f.result())
        await f.ended(round)
        var drafted = request
        drafted.viewerPendingReviewID = try ReviewData.node("PRR_new")
        let shown = try #require(row(drafted))
        #expect(shown.toReviewState == .draftReady && shown.draft == .requestChanges)
        #expect(row(request)?.toReviewState != .youCommented)
        await f.end()
    }

    // A round that left a draft notifies once; later changes of the state notify nothing more.
    @Test func draftReadyNotifiesOnce() async throws {
        let f = try await RoundFixture()
        let round = try await f.review()
        await f.sessionWorks()
        try await f.endTurn(result: f.result())
        await f.ended(round)
        f.rounds.afterPoll(Rows.answer(toReview: [try Rows.pull("Owner-A/Repo-A#7")]))
        await f.rounds.cancel(f.pr)
        #expect(f.notices.values == [.draftReady(f.pr)])
        await f.end()
    }

    // Remove all clones: the review session of the PR goes (claude rm), and the review that waits
    // in the queue (here an entry of an earlier run that waits for the trust step of the user,
    // which claude refused) goes with its entry.
    @Test func removeAllClonesStopsTheSessionsAndDropsTheQueuedReviews() async throws {
        let f = try await RoundFixture()
        let round = try await f.review()
        await f.sessionWorks()
        try await f.endTurn(result: f.result())
        await f.ended(round)
        #expect(f.store.state.prs[f.pr]?.reviewSession != nil)
        f.setup.waitsForTrust(f.pr.repo, refusedByClaude: true)
        await f.store.update { $0.queue.append(QueueEntry(pr: f.pr, kind: .review, at: Rows.now)) }
        f.rounds.queue.add(QueuedJob(pr: f.pr, kind: .review, since: Rows.now))
        #expect(f.rounds.queue.waiting == [f.pr])
        #expect(f.store.state.queue.map(\.pr) == [f.pr])
        #expect(await f.rounds.removeAll(then: { nil }) == nil)
        #expect(f.deps.calls.claudeRuns.contains(["rm", "abcdef12"]))
        #expect(f.store.state.prs[f.pr]?.reviewSession == nil)
        #expect(f.rounds.queue.waiting.isEmpty && f.store.state.queue.isEmpty)
        await f.end()
    }

    // Remove all clones with one slot, one running round and one waiting round: the waiting round
    // never starts, also when the running one ends, and a click, a poll and a trust end during
    // the removal start nothing. The running round goes with its session.
    @Test func removeAllClonesStartsNoWaitingRound() async throws {
        var config = ReviewsConfig()
        config.maxSessions = 1
        let f = try await RoundFixture(config: config)
        let other = try ReviewData.pr("Owner-A/Repo-A#8")
        _ = try await f.review()
        await f.sessionWorks()
        await f.rounds.review(other)
        #expect(f.rounds.queue.waiting == [other])
        let failure = await f.rounds.removeAll {
            await f.rounds.review(other)
            f.rounds.afterPoll(f.answer)
            f.rounds.trusted(other.repo)
            #expect(f.rounds.queue.waiting.isEmpty && f.rounds.queue.running.isEmpty)
            #expect(f.store.state.queue.isEmpty)
            return "The folder is busy."
        }
        #expect(failure == "The folder is busy.")
        #expect(f.deps.calls.claudeRuns.filter { $0.first == "--bg" }.count == 1)
        #expect(f.store.state.prs[f.pr]?.round == nil)
        #expect(f.store.state.prs[f.pr]?.reviewSession == nil)
        #expect(f.rounds.queue.running.isEmpty && f.rounds.queue.waiting.isEmpty)
        #expect(f.writes.isEmpty)
        // After the removal, a click starts a round again.
        await f.rounds.review(other)
        #expect(f.store.state.queue.map(\.pr) == [other])
        await f.end()
    }

    // A second Remove all clones during a removal waits for the first and gives its result. The
    // folders go once, and nothing runs again after the first call.
    @Test func aSecondRemoveAllWaitsForTheFirst() async throws {
        let f = try await RoundFixture()
        let started = Recorder<Void>()
        let second = Mutex<Task<String?, Never>?>(nil)
        let first = await f.rounds.removeAll {
            let task = Task {
                // The call reaches the wait for the first removal in the same turn.
                started.record(())
                return await f.rounds.removeAll { "The second removal ran." }
            }
            second.withLock { $0 = task }
            await waitUntil { !started.values.isEmpty }
            #expect(f.rounds.removing)
            return "The folder is busy."
        }
        #expect(first == "The folder is busy.")
        #expect(await second.withLock({ $0 })?.value == "The folder is busy.")
        #expect(!f.rounds.removing)
        await f.end()
    }

    // The round uses the result that ended the turn. A session that writes another text into
    // result.json after the end (here at the reset of the worktree) changes nothing.
    @Test func aResultWrittenAfterTheTurnEndChangesNothing() async throws {
        let runner = RewritingRunner()
        let f = try await RoundFixture(runner: runner)
        let round = try await f.review()
        await f.sessionWorks()
        runner.arm(file: f.input + "/result.json", text: "{ not json")
        try await f.endTurn(result: f.result())
        await f.ended(round)
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.round == nil && state.lastError == nil)
        #expect(!f.writes.isEmpty)
        await f.end()
    }

    // A round whose state another change cleared never posts: the save of the posting phase
    // finds no round, and the round fails with notSaved.
    @Test func aClearedRoundNeverPosts() async throws {
        let f = try await RoundFixture()
        let round = try await f.review()
        await f.sessionWorks()
        await f.store.update { $0.prs[f.pr]?.round = nil }
        try await f.endTurn(result: f.result())
        await f.ended(round)
        #expect(f.writes.isEmpty)
        #expect(f.store.state.prs[f.pr]?.lastError == RoundFailure.notSaved.message)
        await f.end()
    }

    // The trust read says no, but Claude Code trusts the clone. The round waits at Trust needed;
    // a click then gives one start that claude judges, the session starts, and from then on the
    // clone counts as trusted.
    @Test func aClickGivesOneStartToACloneThatTheReadCallsUntrusted() async throws {
        let f = try await RoundFixture(trusted: false)
        let first = try await f.review()
        await first.value
        #expect(f.setup.clones.needsTrust == [f.pr.repo])
        #expect(f.rounds.queue.waiting == [f.pr])
        #expect(!f.deps.calls.claudeRuns.contains { $0.first == "--bg" })
        await f.rounds.cancel(f.pr)
        let round = try await f.review()
        await f.sessionWorks()
        #expect(f.setup.clones.needsTrust.isEmpty)
        #expect(await f.setup.trustsForStart(f.pr.repo))
        try await f.endTurn(result: f.result())
        await f.ended(round)
        #expect(f.writes.count == 1)
        await f.end()
    }

    // claude refuses the one start for trust: the round goes back to the queue, and no start
    // follows until a trust step ends, which gives one more start.
    @Test func aRefusedStartWaitsForTheTrustStep() async throws {
        let f = try await RoundFixture(trusted: false)
        await (try f.review()).value
        await f.rounds.cancel(f.pr)
        f.deps.calls.answerClaude { args in
            args.first == "--bg"
                ? ExecResult(.exited(1), stderr: "Workspace not trusted. Run claude first.")
                : ExecResult(.exited(0))
        }
        let refused = try await f.review()
        await refused.value
        let starts = { f.deps.calls.claudeRuns.filter { $0.first == "--bg" }.count }
        #expect(starts() == 1)
        #expect(f.rounds.queue.waiting == [f.pr])
        #expect(f.setup.clones.needsTrust == [f.pr.repo])
        #expect(!(await f.setup.trustsForStart(f.pr.repo)))
        f.rounds.afterPoll(f.answer)
        #expect(starts() == 1)
        f.deps.calls.answerClaude { args in
            args.first == "--bg"
                ? ExecResult(.exited(0), stdout: "backgrounded \u{B7} abcdef12 \u{B7} name\n")
                : ExecResult(.exited(0))
        }
        f.rounds.trustStepEnded(f.pr.repo)
        let round = try #require(f.rounds.queue.task(of: f.pr))
        await f.sessionWorks()
        #expect(starts() == 2)
        try await f.endTurn(result: f.result())
        await f.ended(round)
        #expect(f.writes.count == 1)
        await f.end()
    }

    // At the start, a round of an earlier run that was posting fails and posts nothing again, a
    // preparing round that the user stopped fails, and a preparing round goes back to the queue
    // and starts.
    @Test func theRoundsOfAnEarlierRunAreTakenOver() async throws {
        let other = try ReviewData.pr("Owner-A/Repo-A#8")
        let stopped = try ReviewData.pr("Owner-A/Repo-A#9")
        let stoppedRunning = try ReviewData.pr("Owner-A/Repo-A#10")
        let f = try await RoundFixture { state, head in
            let time = Rows.at(-5)
            for pr in [other, stopped] {
                state.prs[pr] = PRState()
            }
            state.prs[other]?.round = ActiveRound(
                phase: .posting, startedAt: time, at: time, headSHA: head, kind: .review)
            state.prs[stopped]?.round = ActiveRound(
                phase: .preparing, startedAt: time, at: time, stoppedByUser: true, kind: .review)
            state.prs[stoppedRunning] = PRState()
            state.prs[stoppedRunning]?.round = ActiveRound(
                phase: .running, startedAt: time, at: time, headSHA: head,
                stoppedByUser: true, kind: .review)
            let pr = try? ReviewData.pr()
            if let pr {
                state.prs[pr] = PRState()
                state.prs[pr]?.round = ActiveRound(
                    phase: .preparing, startedAt: time, at: time, kind: .review)
            }
        }
        #expect(f.store.state.prs[other]?.round == nil)
        #expect(f.store.state.prs[other]?.lastError == RoundFailure.closedWhilePosting.message)
        #expect(f.store.state.prs[stopped]?.lastError == RoundFailure.stopped.message)
        // A running round that the user stopped before the quit never waits again.
        #expect(f.store.state.prs[stoppedRunning]?.round == nil)
        #expect(f.store.state.prs[stoppedRunning]?.lastError == RoundFailure.stopped.message)
        await f.sessionWorks()
        #expect(f.writes.isEmpty)
        await f.end()
    }

    // A round whose session ran when Bifrost quit waits for the end of that session after the
    // next start, and then posts its draft with the diff of the clone.
    @Test func aRunningRoundGoesOnAfterARestart() async throws {
        let f = try await RoundFixture()
        _ = try await f.review()
        await f.sessionWorks()
        try await f.restart()
        #expect(f.store.state.prs[f.pr]?.round?.phase == .running)
        let round = try #require(f.rounds.queue.task(of: f.pr))
        try await f.endTurn(result: f.result())
        await f.ended(round)
        #expect(f.writes.count == 1)
        #expect(f.store.state.prs[f.pr]?.recommendation?.reviewID != nil)
        #expect(f.deps.calls.claudeRuns.filter { $0.first == "--bg" }.count == 1)
        await f.end()
    }

    // The session can write any file of its worktree: after the round, the worktree is back at
    // the head, and the log counts the change.
    @Test func theWorktreeIsResetAfterTheRound() async throws {
        let f = try await RoundFixture()
        let round = try await f.review()
        await f.sessionWorks()
        try "stray\n".write(toFile: f.worktree + "/stray.txt", atomically: false, encoding: .utf8)
        try "changed\n".write(
            toFile: f.worktree + "/src/a.swift", atomically: false, encoding: .utf8)
        try await f.endTurn(result: f.result())
        await f.ended(round)
        #expect(!FileManager.default.fileExists(atPath: f.worktree + "/stray.txt"))
        let file = try String(contentsOfFile: f.worktree + "/src/a.swift", encoding: .utf8)
        #expect(file.contains("line eleven"))
        #expect(f.repos.log.values.contains(.worktreeReset(f.pr, changes: 2)))
        await f.end()
    }
}
