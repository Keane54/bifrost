// The worktree check before a Delete (docs/behaviour/actions.md, "The worktree check"). The tests
// give a fake git and a manual clock. One test runs the real git, only in a repository that it
// makes in a temporary folder.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostSessions

private let wt = "/r/.claude/worktrees/fix-a"
// The commit of the main checkout, and the HEAD commit of the worktree.
private let base = String(repeating: "a", count: 40)
private let head = "f7698d38614ba22b41f996fab73124361d2fe389"

private func ok(_ stdout: String) -> ExecResult { ExecResult(.exited(0), stdout: stdout) }
private let fail = ExecResult(.exited(128), stderr: "fatal")

// git status takes no optional lock, so it does not write the index.lock of the worktree.
private func statusArgs(_ worktree: String = wt) -> [String] {
    ["--no-optional-locks", "-C", worktree, "status", "--porcelain"]
}
private let branchArgs = ["-C", wt, "rev-parse", "--abbrev-ref", "HEAD"]
private let baseArgs = ["-C", "/r", "rev-parse", "HEAD"]
private let countArgs = ["-C", wt, "rev-list", "--count", "\(base)..HEAD"]
private let headArgs = ["-C", wt, "rev-parse", "HEAD"]

// The outputs of a good check: two changed files, the branch, the base and three commits.
private func good() -> [ExecResult] {
    [ok(" M a\n?? b\n"), ok("worktree-fix-a\n"), ok("\(base)\n"), ok("3\n")]
}
private let goodCheck = WorktreeCheck(
    branch: "worktree-fix-a", changedFiles: 2, unmergedCommits: 3, worktree: wt)

// The outputs of git, one for each command in order. After the last one, git gives no text.
private final class Outputs: Sendable {
    private let queue: Mutex<[ExecResult]>

    init(_ results: [ExecResult]) { queue = Mutex(results) }

    func next() -> ExecResult {
        queue.withLock { $0.isEmpty ? ok("") : $0.removeFirst() }
    }
}

private func git(_ results: [ExecResult]) -> FakeRunner {
    let outputs = Outputs(results)
    return FakeRunner { _ in outputs.next() }
}

// The default clock is the real clock, so a defect that makes an extra try waits 500 ms and
// fails, and does not wait for a manual clock that no test moves.
private func checker(
    _ runner: FakeRunner, clock: any Clock<Duration> = ContinuousClock(),
    skipRoots: [String] = [],
    environment: [String: String] = [:],
    realPath: @escaping @Sendable (String) -> String? = { _ in nil }
) -> WorktreeChecker {
    WorktreeChecker(
        runner: runner, environment: environment, skipRoots: skipRoots, clock: clock,
        realPath: realPath)
}

// The result of work whose first try fails: the test moves the clock past the wait for the
// second try.
private func afterTheRetry<T: Sendable>(
    _ clock: ManualClock, _ work: @escaping @Sendable () async -> T
) async -> T {
    let task = Task { await work() }
    await clock.waitForSleepers(1)
    clock.advance(by: WorktreeChecker.retry)
    return await task.value
}

@Suite("the worktree check")
struct WorktreeCheckerTests {
    @Test func gitHas5sAndAFailedCheckWaits500msBeforeItsSecondTry() {
        #expect(WorktreeChecker.gitTimeout == .seconds(5))
        #expect(WorktreeChecker.retry == .milliseconds(500))
    }

    @Test(arguments: [
        "/r", "r/.claude/worktrees/a", "/r/.claude/worktrees/", "/r/./.claude/worktrees/a",
        "/.claude/worktrees/a", "",
    ])
    func aFolderOutsideAWorktreeHasNoWorktreeAndRunsNoGit(cwd: String) async {
        let runner = git([])
        let check = await checker(runner).check(cwd)
        #expect(
            check == WorktreeCheck(branch: nil, changedFiles: 0, unmergedCommits: 0, worktree: nil))
        #expect(runner.calls.isEmpty)
    }

    @Test func theCheckCountsTheChangedFilesAndTheUnmergedCommits() async {
        let runner = git(good())
        #expect(await checker(runner).check("\(wt)/src") == goodCheck)
        let calls = [statusArgs(), branchArgs, baseArgs, countArgs].map {
            FakeRunner.Call(file: "git", args: $0, timeout: .seconds(5))
        }
        #expect(runner.calls == calls)
    }

    // git is the git of the login PATH, as for the other git runs of the app.
    @Test func gitGetsTheLoginEnvironment() async {
        let runner = git(good())
        let env = ["PATH": "/opt/homebrew/bin:/usr/bin"]
        _ = await checker(runner, environment: env).check(wt)
        #expect(runner.commands.count == 4)
        #expect(runner.commands.allSatisfy { $0.environment == env })
    }

    @Test(arguments: ["HEAD\n", "\n", ""])
    func aDetachedHeadOrAnEmptyBranchGivesNoBranch(output: String) async {
        var outputs = good()
        outputs[1] = ok(output)
        #expect(await checker(git(outputs)).check(wt)?.branch == nil)
    }

    // Each step that fails in both tries makes the check fail. One try runs the commands up to
    // the one that fails, and the second try gets the same outputs.
    @Test(arguments: [
        (0, fail), (0, ExecResult(.timedOut)), (1, ExecResult(.notStarted)),
        (1, ExecResult(.signal(9))), (2, ok("")), (2, ok("HEAD\n")), (2, fail),
        (3, ok("x\n")), (3, fail),
    ])
    func aStepThatFailsInBothTriesFailsTheCheck(step: Int, result: ExecResult) async {
        var once = Array(good().prefix(step + 1))
        once[step] = result
        let runner = git(once + once)
        let clock = ManualClock()
        let check = checker(runner, clock: clock)
        #expect(await afterTheRetry(clock) { await check.check(wt) } == nil)
        #expect(runner.calls.count == 2 * (step + 1))
    }

    // A count is ASCII digits only, so "-1" and "+3" are no counts.
    @Test(arguments: ["-1", "+3", "", " ", "3.0", "1e3", "\u{0663}", "99999999999999999999999"])
    func aCountThatIsNotAWholeNumberFailsTheCheck(count: String) async {
        var once = good()
        once[3] = ok("\(count)\n")
        let clock = ManualClock()
        let check = checker(git(once + once), clock: clock)
        #expect(await afterTheRetry(clock) { await check.check(wt) } == nil)
    }

    // The base goes into the argument of git rev-list, so it must be a commit ID.
    @Test(arguments: ["-x", "main", String(repeating: "A", count: 40), "abc"])
    func aBaseThatIsNotACommitIdFailsTheCheck(output: String) async {
        var once = good()
        once[2] = ok("\(output)\n")
        let runner = git(once + once)
        let clock = ManualClock()
        let check = checker(runner, clock: clock)
        #expect(await afterTheRetry(clock) { await check.check(wt) } == nil)
        #expect(!runner.calls.contains { $0.args.first == "-C" && $0.args.contains("rev-list") })
    }

    @Test func aBaseOfASHA256RepositoryIsACommitId() async {
        var outputs = good()
        let long = String(repeating: "b", count: 64)
        outputs[2] = ok("\(long)\n")
        let runner = git(outputs)
        #expect(await checker(runner).check(wt) == goodCheck)
        #expect(runner.calls.last?.args == ["-C", wt, "rev-list", "--count", "\(long)..HEAD"])
    }

    @Test func aFailedCheckTriesOnceMoreAfter500ms() async {
        let runner = git([fail] + good())
        let clock = ManualClock()
        let check = checker(runner, clock: clock)
        let result = Task { await check.check(wt) }
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(499))
        #expect(runner.calls.count == 1)
        clock.advance(by: .milliseconds(1))
        #expect(await result.value == goodCheck)
        #expect(
            runner.calls.map(\.args)
                == [statusArgs(), statusArgs(), branchArgs, baseArgs, countArgs])
    }

    @Test func aGoodCheckRunsOnce() async {
        let runner = git(good())
        #expect(await checker(runner).check(wt)?.worktree == wt)
        #expect(runner.calls.count == 4)
    }

    @Test func aSecondFailureGivesNoCheck() async {
        let runner = git([fail, fail] + good())
        let clock = ManualClock()
        let check = checker(runner, clock: clock)
        #expect(await afterTheRetry(clock) { await check.check(wt) } == nil)
        #expect(runner.calls.count == 2)
    }

    // A cancel during the wait ends the check with no second try.
    @Test func aCancelDuringTheWaitEndsTheCheck() async {
        let runner = git([fail] + good())
        let clock = ManualClock()
        let check = checker(runner, clock: clock)
        let result = Task { await check.check(wt) }
        await clock.waitForSleepers(1)
        result.cancel()
        #expect(await result.value == nil)
        #expect(runner.calls.count == 1)
    }
}

// A PR session can write the git config of its folder, and git reads that config, so no git
// runs at or below a skip root.
@Suite("the worktree check under a skip root")
struct WorktreeCheckerSkipRootTests {
    private static let roots = ["/r/x", "/r/reviews"]

    @Test(arguments: [
        "/r/reviews/acme/.claude/worktrees/pr", "/r/reviews/acme/.claude/worktrees/pr/src",
        "/r/reviews/.claude/worktrees/pr",
    ])
    func noGitForAWorktreeUnderASkipRoot(path: String) async {
        let runner = git(good())
        let check = checker(runner, skipRoots: Self.roots)
        #expect(await check.check(path) == nil)
        #expect(await check.checkWithHead(path) == nil)
        #expect(await check.trackedChanges(path) == nil)
        #expect(runner.calls.isEmpty)
    }

    // A worktree whose real path is under a skip root runs no git either.
    @Test func noGitForAWorktreeThatALinkPutsUnderASkipRoot() async {
        let runner = git(good())
        let links = [
            "/w": "/r/reviews/acme",
            "/w/.claude/worktrees/pr": "/r/reviews/acme/.claude/worktrees/pr",
            "/r/reviews": "/r/reviews",
        ]
        let check = checker(runner, skipRoots: Self.roots) { links[$0] }
        #expect(await check.check("/w/.claude/worktrees/pr") == nil)
        #expect(await check.trackedChanges("/w/.claude/worktrees/pr") == nil)
        #expect(runner.calls.isEmpty)
    }

    // The repository counts too: here only the real path of the repository is under a skip root.
    @Test func noGitForAWorktreeWhoseRepositoryALinkPutsUnderASkipRoot() async {
        let runner = git(good())
        let links = [
            "/w": "/r/reviews/acme",
            "/w/.claude/worktrees/pr": "/elsewhere/pr",
            "/r/reviews": "/r/reviews",
        ]
        let check = checker(runner, skipRoots: Self.roots) { links[$0] }
        #expect(await check.check("/w/.claude/worktrees/pr") == nil)
        #expect(await check.trackedChanges("/w/.claude/worktrees/pr") == nil)
        #expect(runner.calls.isEmpty)
    }

    // A read of a real path that does not end in 2 s counts as under a skip root, so the check
    // fails and runs no git. The read runs on a thread of the blocking executor.
    @MainActor
    @Test func aReadThatHangsCountsAsUnderASkipRoot() async {
        #expect(WorktreeChecker.skipRootLimit == .seconds(2))
        let gate = TestGate()
        defer { gate.openAll() }
        let runner = git(good())
        let clock = ManualClock()
        let check = checker(runner, clock: clock, skipRoots: Self.roots) { _ in
            gate.passBlocking()
            return nil
        }
        let wt = "/w/.claude/worktrees/pr"
        let result = Task { await check.check(wt) }
        await gate.waitUntilHolding(1)
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(2))
        #expect(await result.value == nil)
        let tracked = Task { await check.trackedChanges(wt) }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(2))
        #expect(await tracked.value == nil)
        #expect(runner.calls.isEmpty)
        #expect(!gate.ranOnTheMainThread)
    }

    @Test func aWorktreeBesideASkipRootRunsGit() async {
        let runner = git(good())
        let check = checker(runner, skipRoots: Self.roots)
        #expect(await check.check("/r/reviews-old/.claude/worktrees/a")?.changedFiles == 2)
        #expect(runner.calls.count == 4)
    }
}

@Suite("the worktree check with the HEAD commit")
struct WorktreeHeadCheckTests {
    // The check reads the HEAD commit first, and counts the commits up to that commit, not up to
    // HEAD. So a HEAD that moves during the check cannot give the counts of another commit.
    @Test func theCheckReadsTheHeadFirstAndCountsUpToThatCommit() async {
        let runner = git([ok("\(head)\n")] + good())
        let result = await checker(runner).checkWithHead("\(wt)/src")
        var expected = goodCheck
        expected.head = head
        #expect(result == expected)
        let countToHead = ["-C", wt, "rev-list", "--count", "\(base)..\(head)"]
        let calls = [headArgs, statusArgs(), branchArgs, baseArgs, countToHead].map {
            FakeRunner.Call(file: "git", args: $0, timeout: .seconds(5))
        }
        #expect(runner.calls == calls)
    }

    @Test(arguments: [
        fail, ExecResult(.timedOut), ExecResult(.notStarted), ok(""), ok("abc\n"),
        ok(head.uppercased()), ok("\(head)x\n"),
    ])
    func aHeadReadThatFailsOrGivesNoCommitInBothTriesGivesNoCheck(bad: ExecResult) async {
        let runner = git([bad, bad] + good())
        let clock = ManualClock()
        let check = checker(runner, clock: clock)
        #expect(await afterTheRetry(clock) { await check.checkWithHead(wt) } == nil)
        #expect(runner.calls.map(\.args) == [headArgs, headArgs])
    }

    // The second try reads the HEAD commit again, and counts up to the commit of that read.
    @Test func aFailedTryReadsTheHeadAgain() async {
        let runner = git([ok("\(base)\n"), fail, ok("\(head)\n")] + good())
        let clock = ManualClock()
        let check = checker(runner, clock: clock)
        let result = await afterTheRetry(clock) { await check.checkWithHead(wt) }
        #expect(result?.head == head)
        #expect(runner.calls.map(\.args).prefix(3) == [headArgs, statusArgs(), headArgs])
        #expect(runner.calls.last?.args == ["-C", wt, "rev-list", "--count", "\(base)..\(head)"])
    }

    @Test func aSHA256HeadIsAHeadCommit() async {
        let long = String(repeating: "c", count: 64)
        let runner = git([ok("\(long)\n")] + good())
        let result = await checker(runner).checkWithHead(wt)
        #expect(result?.head == long)
        #expect(runner.calls.last?.args == ["-C", wt, "rev-list", "--count", "\(base)..\(long)"])
    }

    @Test func aFolderOutsideAWorktreeGivesNoHeadCheck() async {
        let runner = git([])
        #expect(await checker(runner).checkWithHead("/r") == nil)
        #expect(runner.calls.isEmpty)
    }
}

// The Delete of a running worktree session counts the changed files that git tracks before the
// stop.
@Suite("the tracked changes of a worktree")
struct TrackedChangesTests {
    @Test func theCountIsThePorcelainLinesThatDoNotStartWithTwoQuestionMarks() async {
        let runner = git([ok(" M a\n?? b\nM  c\nD  d\nR  e -> f\n?? g/\nA  h\n")])
        #expect(await checker(runner).trackedChanges(wt) == 5)
        let call = FakeRunner.Call(file: "git", args: statusArgs(), timeout: .seconds(5))
        #expect(runner.calls == [call])
    }

    // A folder in a worktree counts the whole worktree.
    @Test func aFolderInAWorktreeCountsTheWorktree() async {
        let runner = git([ok(" M a\n")])
        #expect(await checker(runner).trackedChanges("\(wt)/src") == 1)
        #expect(runner.calls.map(\.args) == [statusArgs()])
    }

    @Test(arguments: ["", "r/.claude/worktrees/a", "/r", "/r/.claude/worktrees/", "/r/./x"])
    func aFolderOutsideAWorktreeHasNoCountAndRunsNoGit(folder: String) async {
        let runner = git([ok(" M a\n")])
        #expect(await checker(runner).trackedChanges(folder) == nil)
        #expect(runner.calls.isEmpty)
    }

    @Test(arguments: ["?? a\n?? b/\n", "", "\n\n"])
    func untrackedFilesOnlyOrACleanWorktreeGiveZero(output: String) async {
        #expect(await checker(git([ok(output)])).trackedChanges(wt) == 0)
    }

    @Test func aFailedReadTriesOnceMore() async {
        let runner = git([fail, ok(" M a\n")])
        let clock = ManualClock()
        let check = checker(runner, clock: clock)
        #expect(await afterTheRetry(clock) { await check.trackedChanges(wt) } == 1)
        #expect(runner.calls.count == 2)
    }

    @Test(arguments: [fail, ExecResult(.timedOut), ExecResult(.notStarted)])
    func twoFailedReadsGiveNoCount(bad: ExecResult) async {
        let clock = ManualClock()
        let check = checker(git([bad, bad]), clock: clock)
        #expect(await afterTheRetry(clock) { await check.trackedChanges(wt) } == nil)
    }
}

// The real git, in a repository that the test makes in a temporary folder. The env of git has
// no config of the user and no config of the system.
@Suite("the worktree check of a real repository")
struct RealWorktreeCheckTests {
    @Test func theCheckReadsARealWorktree() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let repo = folder.realPath + "/repo"
        let worktree = repo + "/.claude/worktrees/fix-a"
        let env = [
            "PATH": "/usr/bin:/bin", "HOME": folder.realPath, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@example.invalid", "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@example.invalid",
        ]
        let runner = ProcessRunner()
        func run(_ args: [String], in dir: String) async throws {
            let result = await runner.run(
                Command(
                    testGit, ["-C", dir] + args, environment: env, timeout: .seconds(30)))
            try #require(result.succeeded, "git \(args.joined(separator: " ")): \(result.stderr)")
        }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try await run(["-c", "init.defaultBranch=main", "init", "-q"], in: repo)
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try await run(["add", "a.txt"], in: repo)
        try await run(["commit", "-q", "-m", "one"], in: repo)
        try await run(["worktree", "add", "-q", "-b", "worktree-fix-a", worktree], in: repo)
        for name in ["b", "c"] {
            try name.write(toFile: "\(worktree)/\(name).txt", atomically: true, encoding: .utf8)
            try await run(["add", "\(name).txt"], in: worktree)
            try await run(["commit", "-q", "-m", name], in: worktree)
        }
        try "changed\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: worktree + "/d.txt", atomically: true, encoding: .utf8)

        let check = WorktreeChecker(
            runner: runner, environment: env, skipRoots: [], clock: ContinuousClock())
        #expect(
            await check.check(worktree + "/src")
                == WorktreeCheck(
                    branch: "worktree-fix-a", changedFiles: 2, unmergedCommits: 2,
                    worktree: worktree))
        #expect(await check.trackedChanges(worktree) == 1)
        let withHead = await check.checkWithHead(worktree)
        let real = await runner.run(
            Command(testGit, ["-C", worktree, "rev-parse", "HEAD"], environment: env))
        #expect(withHead?.head == real.stdout.trimmed())
    }
}
