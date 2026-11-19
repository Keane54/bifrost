// The session command Delete and the check of the Delete dialog (docs/behaviour/actions.md,
// "Delete"). The registry service is real, on fake session lists and a manual clock. claude, git,
// the folder reads and the alive checks are fakes (FakeActionDeps), so no test runs a program,
// removes a folder or signals a process.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSessions

// Session IDs whose first 8 characters are the short ID of their job, as for a job of claude.
private let s1 = "f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f"
private let s2 = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"
private let s3 = "1c2d3e4f-5061-4b7c-9d8e-0f1a2b3c4d5e"
private let s4 = "2d3e4f50-6172-4c8d-ae9f-1a2b3c4d5e6f"
private let short1: ShortID = "f3a9c2d1"
private let short2: ShortID = "0b1c2d3e"
private let short3: ShortID = "1c2d3e4f"
private let short4: ShortID = "2d3e4f50"

private let ok = ExecResult(.exited(0))

// A worktree of Claude Code, its repository, and the commits of git.
private let repo = "/r"
private let wt = "/r/.claude/worktrees/w1"
private let baseCommit = String(repeating: "b", count: 40)
private let headCommit = "f7698d38614ba22b41f996fab73124361d2fe389"
private let discardValue = "\(headCommit)@598a160a880168020f78fdeda23f998a"

// The output of "claude rm" for a worktree with a commit on no remote, in the form of a real run
// of Claude Code: the kept line, the commits, and the discard value.
private func kept(_ shortId: ShortID, at worktree: String = wt, value: String = discardValue)
    -> ExecResult
{
    let id = shortId.text
    let stdout = [
        "kept \(id) \u{2014} its worktree is still at \u{201C}\(worktree)\u{201D}",
        "  1 unpushed commit on \u{201C}worktree-w1\u{201D}: f7698d3 \u{201C}test\u{201D}. It "
            + "exists on no remote, so deleting the worktree would lose it.",
        "  push it and run 'claude rm \(id)' again, or discard the worktree and its commits: "
            + "claude rm \(id) --discard-unpushed \(value)",
        "",
    ]
    return ExecResult(.exited(1), stdout: stdout.joined(separator: "\n"))
}

// The output of "claude rm" for a worktree with changes that are not committed. It has no
// discard value, unless the test adds one.
private func changes(_ shortId: ShortID, at worktree: String = wt, withValue: Bool = false)
    -> ExecResult
{
    let id = shortId.text
    var lines = [
        "kept \(id) \u{2014} its worktree is still at \u{201C}\(worktree)\u{201D}",
        "  The worktree has uncommitted changes. Deleting it would lose them.",
        "  commit or stash them and run 'claude rm \(id)' again, or delete the session from "
            + "'claude agents' (ctrl+x twice)",
    ]
    if withValue { lines.append("  claude rm \(id) --discard-unpushed \(discardValue)") }
    return ExecResult(.exited(1), stdout: (lines + [""]).joined(separator: "\n"))
}

// The git of the worktree wt: the lines of git status, the count of the commits that the main
// checkout does not have, the HEAD commit, and the commit of the main checkout. The count is only
// for the commits up to the HEAD commit. A git that fails ends with code 128.
private struct FakeGit: Sendable {
    var status: [String] = []
    var commits: UInt = 0
    var head = headCommit
    var base = baseCommit
    var fails = false

    func answer(_ args: [String]) -> ExecResult {
        if fails { return ExecResult(.exited(128), stderr: "fatal: not a git repository") }
        let stdout: String
        switch args {
        case ["--no-optional-locks", "-C", wt, "status", "--porcelain"]:
            stdout = status.map { "\($0)\n" }.joined()
        case ["-C", wt, "rev-parse", "--abbrev-ref", "HEAD"]: stdout = "worktree-w1\n"
        case ["-C", repo, "rev-parse", "HEAD"]: stdout = "\(base)\n"
        case ["-C", wt, "rev-list", "--count", "\(base)..\(head)"]: stdout = "\(commits)\n"
        case ["-C", wt, "rev-parse", "HEAD"]: stdout = "\(head)\n"
        default: return ExecResult(.exited(128))
        }
        return ExecResult(.exited(0), stdout: stdout)
    }
}

// The git runs of the check with the HEAD commit of the worktree wt: the HEAD commit first, then
// the counts up to that commit.
private let statusRun = FakeActionCalls.Call.git(
    ["--no-optional-locks", "-C", wt, "status", "--porcelain"])
private let headRun = FakeActionCalls.Call.git(["-C", wt, "rev-parse", "HEAD"])
private func headCheckRuns(_ head: String) -> [FakeActionCalls.Call] {
    [
        headRun, statusRun, .git(["-C", wt, "rev-parse", "--abbrev-ref", "HEAD"]),
        .git(["-C", repo, "rev-parse", "HEAD"]),
        .git(["-C", wt, "rev-list", "--count", "\(baseCommit)..\(head)"]),
    ]
}
private let checkWithHeadRuns = headCheckRuns(headCommit)

// claude stop gets SIGKILL at its 60 s limit. claude rm gets SIGTERM at its 600 s limit and no
// SIGKILL. Neither runs in a folder.
private func stopRun(_ shortId: ShortID) -> FakeActionCalls.Call {
    .claude(["stop", shortId.text], directory: nil, timeout: .seconds(60), killSignal: .kill)
}

private func rmRun(_ shortId: ShortID) -> FakeActionCalls.Call {
    .claude(
        ["rm", shortId.text], directory: nil, timeout: .seconds(600), killSignal: .terminate,
        terminateGrace: nil)
}

private func discardRun(_ shortId: ShortID) -> FakeActionCalls.Call {
    .claude(
        ["rm", shortId.text, "--discard-unpushed", discardValue], directory: nil,
        timeout: .seconds(600), killSignal: .terminate, terminateGrace: nil)
}

// The values of a check of the Delete dialog.
private func seen(
    commits: UInt = 0, files: UInt = 0, at worktree: String = wt, head: String = headCommit
) -> SeenCounts? {
    SeenCounts(
        WorktreeCheck(
            branch: "worktree-w1", changedFiles: files, unmergedCommits: commits,
            worktree: worktree, head: head))
}

// A stopped worktree session reports its start folder. The registry keeps the worktree.
private let storedWorktree = RegistryStore(worktrees: [s1: wt])

extension CommandHarness {
    fileprivate func delete(_ id: String = s1, seen: SeenCounts? = nil) async -> Result<
        ActionDone, ActionRefusal
    > {
        await run(.remove(id, confirmed: true, seen: seen))
    }

    fileprivate func startDelete(_ id: String = s1, seen: SeenCounts? = nil) -> Task<
        Result<ActionDone, ActionRefusal>, Never
    > {
        start(.remove(id, confirmed: true, seen: seen))
    }

    // The row IDs of the deferred deletes of wt, in the order of the defers.
    fileprivate var deferred: [String] { deps.registry.deferredIn(wt).map(\.sessionId) }

    fileprivate func answerGit(_ git: FakeGit) {
        calls.answerGit { git.answer($0) }
    }
}

private func deferredEntry(_ id: String, _ shortId: ShortID) -> DeferredDelete {
    DeferredDelete(sessionId: id, shortId: shortId, worktree: wt)
}

@Suite("the session command Delete", .testTimeLimit)
@MainActor
struct SessionActionsDeleteTests {
    // MARK: - A plain remove

    @Test func deleteStopsARunningSessionRunsClaudeRmAndForgetsIt() async {
        let c = await CommandHarness(active: [Entry.running(s1)])
        #expect(await c.delete() == .success(.done))
        #expect(c.calls.all == [stopRun(short1), .aliveCheck(4242), rmRun(short1)])
        #expect(c.deps.row(s1) == nil)
        #expect(c.deps.log.values == [.sessionCommandDone(.delete, session: s1)])
    }

    @Test func deleteOfAParkedRowRunsOnlyClaudeRm() async {
        let c = await CommandHarness(all: [Entry.stopped(s1)])
        #expect(await c.delete() == .success(.done))
        #expect(c.calls.all == [rmRun(short1)])
        #expect(c.deps.row(s1) == nil)
    }

    // Live state is a hint, not an authority: a SessionEnd line (also a forged one) parks a row
    // that the session list still shows with a process. Delete stops it first, as a running row.
    @Test func deleteStopsARowThatOnlyALiveLineParked() async {
        let c = await CommandHarness(active: [Entry.running(s1)])
        c.deps.registry.pushLive(.state(HookEvent(.sessionEnd, s1, at: 1_800_000_100_000)))
        #expect(c.deps.row(s1)?.state == .parked)
        #expect(await c.delete() == .success(.done))
        #expect(c.calls.all == [stopRun(short1), .aliveCheck(4242), rmRun(short1)])
    }

    // The same for an entry with no pid and no status yet, about 2.5 s after a start: the active
    // list still has it, so Delete stops it first. It has no pid, so no wait for its end follows
    // the stop.
    @Test func deleteStopsARowThatOnlyALiveLineParkedBeforeItHasAPid() async {
        let c = await CommandHarness(active: [Entry.running(s1, pid: nil, status: .unknown)])
        c.deps.registry.pushLive(.state(HookEvent(.sessionEnd, s1, at: 1_800_000_100_000)))
        #expect(c.deps.row(s1)?.state == .parked)
        #expect(c.deps.row(s1)?.pid == nil && c.deps.row(s1)?.status == .unknown)
        #expect(await c.delete() == .success(.done))
        #expect(c.calls.all == [stopRun(short1), rmRun(short1)])
    }

    // A new row of the --all list with no pid can be a session that starts, so Delete reads the
    // active list one more time first. That list lacks the row, so the session stopped: Delete
    // runs only claude rm.
    @Test func deleteChecksAnUnconfirmedRowAndThenRunsOnlyClaudeRm() async {
        let c = await CommandHarness(all: [Entry.stopped(s1)], confirmAll: false)
        #expect(c.deps.row(s1)?.listing == .unconfirmed)
        let reads = c.deps.lists.activeCalls
        #expect(await c.delete() == .success(.done))
        #expect(c.deps.lists.activeCalls == reads + 1)
        #expect(c.calls.all == [rmRun(short1)])
        #expect(c.deps.row(s1) == nil)
    }

    // The check shows that the session starts: the active list has its entry with no pid and no
    // status. Delete stops it first, as a running row.
    @Test func deleteStopsAnUnconfirmedRowThatTheCheckLists() async {
        let c = await CommandHarness(all: [Entry.stopped(s1)], confirmAll: false)
        c.deps.lists.active = [Entry.running(s1, pid: nil, status: .unknown)]
        let reads = c.deps.lists.activeCalls
        #expect(await c.delete() == .success(.done))
        #expect(c.deps.lists.activeCalls == reads + 1)
        #expect(c.calls.all == [stopRun(short1), rmRun(short1)])
    }

    // A check that gives no list keeps the row unconfirmed: Delete refuses it with the reason,
    // runs no claude and keeps the row.
    @Test func deleteOfAnUnconfirmedRowAfterAFailedCheckGivesTheReason() async {
        let c = await CommandHarness(all: [Entry.stopped(s1)], confirmAll: false)
        c.deps.lists.activeFailure = .emptyOutput
        #expect(await c.delete() == .failure(.unconfirmed(.emptyOutput)))
        #expect(c.calls.all.isEmpty)
        #expect(c.deps.row(s1)?.listing == .unconfirmed)
        #expect(!c.actions.isRunning(s1))
    }

    // A parked row with no short ID gets no claude rm, so it needs no claude.
    @Test func aParkedRowWithNoShortIdOnlyLeavesTheList() async {
        let c = await CommandHarness(all: [Entry.stopped(s1, noShortId: true)])
        c.deps.claudeFound = false
        #expect(await c.delete() == .success(.done))
        #expect(c.calls.all.isEmpty)
        #expect(c.deps.row(s1) == nil)
    }

    // Live state is a hint, not an authority: an external session that only a SessionEnd line
    // parked still runs in its terminal by the session list (the active list has it, with a pid,
    // or with no pid and no status yet), so Delete refuses it as an external session, and a
    // running row with no short ID as one with no short ID.
    @Test func aRowThatOnlyALiveLineParkedIsStillRefusedAsARunningRow() async {
        let cases: [(AgentEntry, ActionRefusal)] = [
            (Entry.interactive(s1), .deleteExternal),
            (Entry.interactive(s1, pid: nil, status: .unknown), .deleteExternal),
            (Entry.running(s1, noShortId: true), .noShortId),
            (Entry.running(s1, pid: nil, status: .unknown, noShortId: true), .noShortId),
        ]
        for (entry, refusal) in cases {
            let c = await CommandHarness(active: [entry])
            c.deps.registry.pushLive(.state(HookEvent(.sessionEnd, s1, at: 1_800_000_100_000)))
            #expect(c.deps.row(s1)?.state == .parked)
            #expect(await c.delete() == .failure(refusal))
            #expect(c.calls.all.isEmpty)
            #expect(c.deps.row(s1) != nil)
        }
    }

    // Bifrost cannot stop a running session with no short ID, and the next sample would show it
    // again.
    @Test func aRunningRowWithNoShortIdIsRefused() async {
        let c = await CommandHarness(active: [Entry.running(s1, noShortId: true)])
        #expect(await c.delete() == .failure(.noShortId))
        #expect(c.calls.all.isEmpty)
        #expect(c.deps.row(s1) != nil)
    }

    @Test func deleteRefusesARunningExternalRowAnUnknownRowAndNoConfirmation() async {
        let c = await CommandHarness(active: [Entry.interactive(s1), Entry.running(s2)])
        #expect(await c.delete(s1) == .failure(.deleteExternal))
        #expect(await c.delete(s3) == .failure(.unknownSession))
        #expect(
            await c.run(.remove(s2, confirmed: false, seen: nil)) == .failure(.deleteNotConfirmed))
        #expect(c.calls.all.isEmpty)
        #expect(
            c.deps.log.values == [
                .sessionCommandFailed(.delete, session: s1, .deleteExternal),
                .sessionCommandFailed(.delete, session: s3, .unknownSession),
                .sessionCommandFailed(.delete, session: s2, .deleteNotConfirmed),
            ])
    }

    // The confirmation comes before the lock, so a Delete with no confirmation takes no lock.
    @Test func aDeleteWithNoConfirmationTakesNoLock() async {
        let c = await CommandHarness(active: [Entry.running(s1)])
        let gate = TestGate()
        c.calls.hold(gate)
        let stop = c.start(.stop(s1))
        await gate.waitUntilHolding(1)
        #expect(
            await c.run(.remove(s1, confirmed: false, seen: nil)) == .failure(.deleteNotConfirmed))
        #expect(await c.delete() == .failure(.locked))
        gate.openAll()
        await c.waitForSleepers(1)
        c.clock.advance(by: SessionActions.parkWait)
        #expect(await c.result(of: stop) == .success(.done))
    }

    @Test func aFailedClaudeRmKeepsTheRow() async {
        let c = await CommandHarness(all: [Entry.stopped(s1)])
        c.calls.answerClaude { _ in ExecResult(.exited(1), stderr: "rm failed") }
        #expect(await c.delete() == .failure(.claudeReported("rm failed")))
        #expect(c.deps.row(s1) != nil)
        #expect(
            c.deps.log.values == [
                .sessionCommandFailed(.delete, session: s1, .claudeReported("rm failed"))
            ])
    }

    @Test func noClaudeRmAfterAFailedClaudeStop() async {
        let c = await CommandHarness(active: [Entry.running(s1)])
        c.calls.answerClaude { $0.first == "stop" ? ExecResult(.exited(1)) : ok }
        #expect(await c.delete() == .failure(.claudeExited(code: 1)))
        #expect(c.calls.all == [stopRun(short1)])
        #expect(c.deps.row(s1) != nil)
    }

    // MARK: - The limit of claude rm

    @Test func theLimitsOfDelete() {
        #expect(SessionActions.rmTimeout == .seconds(600))
        #expect(SessionActions.rmGrace == .seconds(30))
        #expect(SessionActions.deleteEndWait == .seconds(15))
        #expect(SessionActions.runTimeout == .seconds(60))
    }

    // The output of a claude rm that the limit ended is not complete. A claude rm that did not
    // end by itself never gives a kept line, so no discard can come from it.
    @Test func aClaudeRmThatDidNotEndByItselfGivesNoKeptLine() async {
        let c = await CommandHarness(store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
        let cut = kept(short1).stdout
        c.calls.answerClaude { _ in ExecResult(.timedOut, stdout: cut) }
        #expect(await c.delete(seen: seen()) == .failure(.rmTooSlow))
        c.calls.answerClaude { _ in ExecResult(.overflow, stdout: cut) }
        #expect(await c.delete(seen: seen()) == .failure(.claudeFailed))
        c.calls.answerClaude { _ in ExecResult(.signal(SIGTERM), stdout: cut) }
        #expect(await c.delete(seen: seen()) == .failure(.claudeFailed))
        #expect(c.calls.all == [rmRun(short1), rmRun(short1), rmRun(short1)])
        #expect(c.deps.row(s1) != nil)
    }

    // The runner sends SIGTERM at 600 s. The Delete waits 30 s more, then fails, and sends
    // nothing to claude rm. The run holds the lock of the session until the program ends. Its
    // late end gives a notice in the log and changes no row.
    @Test func theLockHoldsAfterTheLimitUntilClaudeRmEnds() async {
        let c = await CommandHarness(all: [Entry.stopped(s1)])
        let gate = TestGate()
        c.calls.hold(gate)
        let job = c.startDelete()
        await gate.waitUntilHolding(1)
        await c.waitForSleepers(1)
        #expect(c.clock.nextDeadline == ManualClock.Instant(offset: .seconds(630)))
        c.clock.advance(by: .seconds(630) - .milliseconds(1))
        await c.waitForSleepers(1)
        #expect(!c.anyEnded)
        c.clock.advance(by: .milliseconds(1))
        #expect(await c.result(of: job) == .failure(.rmTooSlow))
        #expect(c.actions.isRunning(s1))
        #expect(await c.delete() == .failure(.locked))
        gate.openAll()
        #expect(await waitUntil { !c.actions.isRunning(s1) })
        #expect(c.calls.all == [rmRun(short1)])
        #expect(c.deps.log.values.last == .claudeRmEndedAfterItsJob(session: s1, .exited(0)))
        #expect(c.deps.row(s1) != nil)
        // The lock is free: the next Delete runs claude rm again.
        #expect(await c.delete() == .success(.done))
        #expect(c.calls.all == [rmRun(short1), rmRun(short1)])
    }

    // Resume all skips a session whose claude rm still runs, as for any other held lock.
    @Test func resumeAllSkipsASessionWhoseClaudeRmRuns() async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s1]), all: [Entry.stopped(s1)])
        #expect(c.deps.row(s1)?.resumable == true)
        let gate = TestGate()
        c.calls.hold(gate)
        let job = c.startDelete()
        await gate.waitUntilHolding(1)
        await c.waitForSleepers(1)
        c.clock.advance(by: .seconds(630))
        #expect(await c.result(of: job) == .failure(.rmTooSlow))
        let failed = [ResumeFailure(sessionId: s1, name: "bifrost-test-s", error: .locked)]
        #expect(await c.run(.resumeAll) == .success(.resumedAll(ResumeAllResult(failed: failed))))
        gate.openAll()
        #expect(await waitUntil { !c.actions.isRunning(s1) })
        #expect(c.calls.claudeRuns == [["rm", "f3a9c2d1"]])
    }

    @Test func theLogNamesTheEndOfALateClaudeRmInFixedWords() {
        #expect(SystemSessionsLog.word(.exited(0)) == "exit code 0")
        #expect(SystemSessionsLog.word(.exited(1)) == "exit code 1")
        #expect(SystemSessionsLog.word(.timedOut) == "timeout")
        #expect(SystemSessionsLog.word(.signal(SIGTERM)) == "signal 15")
        #expect(SystemSessionsLog.word(.overflow) == "too much output")
        #expect(SystemSessionsLog.word(.cancelled) == "cancelled")
        #expect(SystemSessionsLog.word(.notStarted) == "not started")
    }

    @Test func aDiscardThatDoesNotEndFailsAfterTheLimitAndTheGrace() async {
        let c = await CommandHarness(store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
        c.calls.answerClaude { $0.count == 2 ? kept(short1) : ok }
        c.answerGit(FakeGit())
        let gate = TestGate()
        c.calls.hold(gate)
        let job = c.startDelete(seen: seen())
        await gate.waitUntilHolding(1)
        gate.open()
        await gate.waitUntilHolding(1)
        #expect(c.calls.all == [rmRun(short1)] + checkWithHeadRuns + [discardRun(short1)])
        await c.waitForSleepers(1)
        c.clock.advance(by: .seconds(630))
        #expect(await c.result(of: job) == .failure(.rmTooSlow))
        #expect(c.calls.claudeRuns.last == ["rm", "f3a9c2d1", "--discard-unpushed", discardValue])
        #expect(c.deps.row(s1) != nil)
        gate.openAll()
        #expect(await waitUntil { !c.actions.isRunning(s1) })
    }

    // MARK: - A worktree that claude rm keeps

    @Test func aKeptWorktreeIsDiscardedWhenTheNewCheckFindsNoMoreWork() async {
        let c = await CommandHarness(store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
        c.calls.answerClaude { $0.count == 2 ? kept(short1) : ok }
        c.answerGit(FakeGit())
        #expect(await c.delete(seen: seen()) == .success(.done))
        #expect(c.calls.all == [rmRun(short1)] + checkWithHeadRuns + [discardRun(short1)])
        #expect(c.deps.row(s1) == nil)
    }

    // The dialog counted two commits and one untracked file. git tracks no changed file, so the
    // count before the stop does not block, and the new check after the stop equals the dialog.
    @Test func aRunningWorktreeSessionIsDiscardedWhenTheNewCheckEqualsTheDialog() async {
        let c = await CommandHarness(active: [Entry.running(s1, cwd: "\(wt)/src")])
        c.calls.answerClaude { $0.count == 2 && $0[0] == "rm" ? kept(short1) : ok }
        c.answerGit(FakeGit(status: ["?? notes.txt"], commits: 2))
        #expect(await c.delete(seen: seen(commits: 2, files: 1)) == .success(.done))
        #expect(
            c.calls.all
                == [statusRun, stopRun(short1), .aliveCheck(4242), rmRun(short1)]
                + checkWithHeadRuns + [discardRun(short1)])
    }

    @Test func lessWorkThanTheDialogShowedAlsoDiscards() async {
        let c = await CommandHarness(store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
        c.calls.answerClaude { $0.count == 2 ? kept(short1) : ok }
        c.answerGit(FakeGit(commits: 1))
        #expect(await c.delete(seen: seen(commits: 2, files: 1)) == .success(.done))
        #expect(c.calls.all == [rmRun(short1)] + checkWithHeadRuns + [discardRun(short1)])
    }

    @Test func noDiscardWhenTheNewCheckHasMoreCommitsOrMoreChangedFiles() async {
        for git in [
            FakeGit(status: ["?? a"], commits: 3), FakeGit(status: ["?? a", "?? b"], commits: 2),
        ] {
            let c = await CommandHarness(
                store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
            c.calls.answerClaude { $0.count == 2 ? kept(short1) : ok }
            c.answerGit(git)
            #expect(await c.delete(seen: seen(commits: 2, files: 1)) == .failure(.worktreeChanged))
            #expect(c.calls.all == [rmRun(short1)] + checkWithHeadRuns)
            #expect(c.deps.row(s1) != nil)
        }
    }

    // The check tries one more time after 500 ms. A second failure gives no discard.
    @Test func noDiscardWhenTheNewCheckFails() async {
        let c = await CommandHarness(store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
        c.calls.answerClaude { $0.count == 2 ? kept(short1) : ok }
        c.answerGit(FakeGit(fails: true))
        let job = c.startDelete(seen: seen())
        // The limit of claude rm sleeps on the clock until the run ends, so the test waits for
        // the first git run, which comes after that end.
        await waitUntil { c.calls.all.contains(headRun) }
        await c.waitForSleepers(1)
        #expect(c.clock.nextDeadline == c.clock.now.advanced(by: .milliseconds(500)))
        c.clock.advance(by: .milliseconds(500))
        #expect(await c.result(of: job) == .failure(.worktreeChanged))
        #expect(c.calls.all == [rmRun(short1), headRun, headRun])
    }

    @Test func noDiscardWithoutTheCheckOfTheDialog() async {
        let c = await CommandHarness(store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
        c.calls.answerClaude { $0.count == 2 ? kept(short1) : ok }
        c.answerGit(FakeGit())
        #expect(await c.delete(seen: nil) == .failure(.kept))
        #expect(c.calls.all == [rmRun(short1)])
        #expect(c.deps.row(s1) != nil)
    }

    @Test func noDiscardWhenTheHeadMovedAfterTheCheck() async {
        let c = await CommandHarness(store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
        c.calls.answerClaude { $0.count == 2 ? kept(short1) : ok }
        let moved = String(repeating: "0", count: 40)
        c.answerGit(FakeGit(head: moved))
        #expect(await c.delete(seen: seen()) == .failure(.worktreeChanged))
        #expect(c.calls.all == [rmRun(short1)] + headCheckRuns(moved))
    }

    // The check of the dialog, then a change of the git of the worktree while the dialog is open,
    // then the Delete with the values of that check. claude rm keeps the worktree and gives the
    // discard value of the HEAD of now.
    private func deleteAfterTheDialog(changedTo git: FakeGit) async -> (
        CommandHarness, Result<ActionDone, ActionRefusal>
    ) {
        let c = await CommandHarness(store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
        c.answerGit(FakeGit(commits: 1))
        let check = await c.actions.deleteCheck(s1)
        #expect(check?.head == headCommit && check?.unmergedCommits == 1)
        c.answerGit(git)
        let value = "\(git.head)@598a160a880168020f78fdeda23f998a"
        c.calls.answerClaude { $0.count == 2 ? kept(short1, value: value) : ok }
        return (c, await c.delete(seen: check.flatMap(SeenCounts.init)))
    }

    private func discards(_ c: CommandHarness) -> Bool {
        c.calls.claudeRuns.contains { $0.contains("--discard-unpushed") }
    }

    @Test func theDiscardFollowsTheCheckOfTheDialog() async {
        let (c, result) = await deleteAfterTheDialog(changedTo: FakeGit(commits: 1))
        #expect(result == .success(.done))
        #expect(discards(c))
    }

    // git commit --amend: one commit, as the dialog showed, with another HEAD.
    @Test func noDiscardAfterAnAmendWhileTheDialogIsOpen() async {
        let amended = String(repeating: "a1", count: 20)
        let (c, result) = await deleteAfterTheDialog(changedTo: FakeGit(commits: 1, head: amended))
        #expect(result == .failure(.worktreeChanged))
        #expect(!discards(c))
    }

    // git reset to the main checkout, then a new commit: one commit again, with another HEAD.
    @Test func noDiscardAfterAResetAndANewCommitWhileTheDialogIsOpen() async {
        let other = String(repeating: "c3", count: 20)
        let (c, result) = await deleteAfterTheDialog(changedTo: FakeGit(commits: 1, head: other))
        #expect(result == .failure(.worktreeChanged))
        #expect(!discards(c))
    }

    // The commit of the dialog went into the main checkout, then the session made a new commit:
    // one commit that the main checkout does not have, with another HEAD.
    @Test func noDiscardAfterAMergeAndANewCommitWhileTheDialogIsOpen() async {
        let newer = String(repeating: "d4", count: 20)
        let git = FakeGit(commits: 1, head: newer, base: headCommit)
        let (c, result) = await deleteAfterTheDialog(changedTo: git)
        #expect(result == .failure(.worktreeChanged))
        #expect(!discards(c))
    }

    // The next Delete can then check the worktree of the kept line and offer Open worktree. The
    // dialog check of a row with no worktree finds no worktree, so it gives no counts.
    @Test func theWorktreeOfAKeptLineIsRememberedForARowWithNoKnownWorktree() async {
        for path in [wt, "\(wt)/"] {
            let c = await CommandHarness(all: [Entry.stopped(s1, cwd: "/r")])
            c.calls.answerClaude { _ in kept(short1, at: path) }
            #expect(await c.delete() == .failure(.kept))
            #expect(c.calls.all == [rmRun(short1)])
            #expect(c.deps.row(s1)?.worktree == wt)
        }
    }

    @Test func noRememberForAKeptLineOfAnotherSessionOrAPathThatIsNotARoot() async {
        let cases: [ExecResult] = [
            kept(short2), kept(short1, at: "\(wt)/src"), kept(short1, at: "/r/src"),
            kept(short1, at: "r/.claude/worktrees/a"), kept(short1, at: "\(wt)//"),
        ]
        for result in cases {
            let c = await CommandHarness(all: [Entry.stopped(s1, cwd: "/r")])
            c.calls.answerClaude { _ in result }
            #expect(await c.delete() == .failure(.kept))
            #expect(c.calls.all == [rmRun(short1)])
            #expect(c.deps.row(s1)?.worktree == nil)
        }
    }

    @Test func noDiscardWhenTheKeptLineNamesAnotherSessionOrAnotherWorktree() async {
        let cases: [ExecResult] = [
            kept(short2), kept(short1, at: "/r/.claude/worktrees/other"),
            kept(short1, at: "\(wt)//"), kept(short1, at: "\(wt)-2"),
        ]
        for result in cases {
            let c = await CommandHarness(
                store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
            c.calls.answerClaude { $0.count == 2 ? result : ok }
            c.answerGit(FakeGit())
            #expect(await c.delete(seen: seen()) == .failure(.worktreeChanged))
            #expect(c.calls.all == [rmRun(short1)])
            #expect(c.deps.row(s1) != nil)
        }
        // A folder in a worktree inside a worktree gives the outer root. claude rm keeps the
        // inner one.
        let inner = "\(wt)/.claude/worktrees/inner"
        let c = await CommandHarness(active: [Entry.running(s1, cwd: inner)])
        c.calls.answerClaude { $0.count == 2 && $0[0] == "rm" ? kept(short1, at: inner) : ok }
        c.answerGit(FakeGit())
        #expect(await c.delete(seen: seen()) == .failure(.worktreeChanged))
        #expect(c.calls.claudeRuns == [["stop", "f3a9c2d1"], ["rm", "f3a9c2d1"]])
    }

    @Test func theKeptWorktreeIsComparedWithoutOneSlashAtTheEnd() async {
        let c = await CommandHarness(store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
        c.calls.answerClaude { $0.count == 2 ? kept(short1, at: "\(wt)/") : ok }
        c.answerGit(FakeGit())
        #expect(await c.delete(seen: seen()) == .success(.done))
        #expect(c.calls.claudeRuns.last == ["rm", "f3a9c2d1", "--discard-unpushed", discardValue])
    }

    // Only the parse of the kept output gives the discard value.
    @Test func noDiscardWithAValueThatTheParseDidNotGive() async {
        let text = kept(short1).stdout
        let cases: [(ExecResult, ActionRefusal?)] = [
            (ExecResult(.exited(1), stderr: "rm failed"), .claudeReported("rm failed")),
            (ExecResult(.exited(1), stderr: text), nil),
            (ExecResult(.exited(1), stdout: text.replacing("kept ", with: "held ")), nil),
            (kept(short1, value: "\(discardValue);id"), nil),
            (kept(short1, value: discardValue.uppercased()), nil),
            (kept(short1, value: "--all"), nil),
            (ExecResult(.exited(2)), .claudeExited(code: 2)),
        ]
        for (result, refusal) in cases {
            let c = await CommandHarness(
                store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
            c.calls.answerClaude { _ in result }
            c.answerGit(FakeGit())
            let outcome = await c.delete(seen: seen())
            let reported = if case .failure(.claudeReported) = outcome { true } else { false }
            #expect(refusal.map { outcome == .failure($0) } ?? reported)
            #expect(c.calls.all == [rmRun(short1)])
        }
    }

    // Bifrost tries the discard one time only. A second refusal means that the worktree changed
    // after the first claude rm.
    @Test func aRefusalOfTheDiscardEndsTheDelete() async {
        let cases: [(ExecResult, ActionRefusal)] = [
            (kept(short1), .worktreeChanged), (changes(short1), .uncommitted),
            (ExecResult(.timedOut), .rmTooSlow),
            (ExecResult(.exited(1), stderr: "boom"), .claudeReported("boom")),
        ]
        for (second, refusal) in cases {
            let c = await CommandHarness(
                store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
            c.calls.answerClaude { $0.count == 2 ? kept(short1) : second }
            c.answerGit(FakeGit())
            #expect(await c.delete(seen: seen()) == .failure(refusal))
            #expect(c.calls.all == [rmRun(short1)] + checkWithHeadRuns + [discardRun(short1)])
            #expect(c.deps.row(s1) != nil)
        }
    }

    // Claude Code has no command that deletes a worktree with changes that are not committed, so
    // Bifrost never tries a discard for it, also when the output has a discard value.
    @Test func noDiscardForAWorktreeWithUncommittedChanges() async {
        for (result, counts) in [
            (changes(short1), seen(files: 75)), (changes(short1), nil),
            (changes(short1, withValue: true), seen()),
        ] {
            let c = await CommandHarness(
                store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
            c.calls.answerClaude { _ in result }
            c.answerGit(FakeGit())
            #expect(await c.delete(seen: counts) == .failure(.uncommitted))
            #expect(c.calls.all == [rmRun(short1)])
        }
        // Bifrost knows no worktree of the row: it remembers the worktree of the kept line, but
        // not a kept line of another session.
        let unknown = await CommandHarness(all: [Entry.stopped(s1, cwd: "/r")])
        unknown.calls.answerClaude { _ in changes(short1) }
        #expect(await unknown.delete() == .failure(.uncommitted))
        #expect(unknown.deps.row(s1)?.worktree == wt)
        let other = await CommandHarness(all: [Entry.stopped(s1, cwd: "/r")])
        other.calls.answerClaude { _ in changes(short2) }
        #expect(await other.delete() == .failure(.uncommitted))
        #expect(other.deps.row(s1)?.worktree == nil)
    }

    // The row moved to another worktree after the check of the dialog. Without this rule the kept
    // line and the new check name the worktree of the row, and the discard runs.
    @Test func aCheckOfAnotherWorktreeIsRefusedBeforeAnyCommand() async {
        let other = "/r/.claude/worktrees/other"
        let parked = await CommandHarness(
            store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
        let running = await CommandHarness(active: [Entry.running(s1, cwd: "\(wt)/src")])
        let plain = await CommandHarness(all: [Entry.stopped(s1, cwd: "/r")])
        #expect(await parked.delete(seen: seen(at: other)) == .failure(.worktreeChanged))
        #expect(await parked.delete(seen: seen(at: "\(wt)/")) == .failure(.worktreeChanged))
        #expect(await running.delete(seen: seen(at: other)) == .failure(.worktreeChanged))
        #expect(await plain.delete(seen: seen()) == .failure(.worktreeChanged))
        #expect(parked.calls.all.isEmpty && running.calls.all.isEmpty && plain.calls.all.isEmpty)
        // The worktree of the row discards as before.
        parked.calls.answerClaude { $0.count == 2 ? kept(short1) : ok }
        parked.answerGit(FakeGit())
        #expect(await parked.delete(seen: seen()) == .success(.done))
    }

    // MARK: - A running worktree session with changes

    // claude rm refuses such a worktree. A stop first would end the turn of the session for no
    // result.
    @Test func aRunningWorktreeSessionWithTrackedChangesIsRefusedBeforeTheStop() async {
        for counts in [seen(files: 2), nil] {
            let c = await CommandHarness(active: [Entry.running(s1, cwd: "\(wt)/src")])
            c.answerGit(FakeGit(status: [" M Sources/a.swift", "?? notes.txt"]))
            #expect(await c.delete(seen: counts) == .failure(.uncommitted))
            #expect(c.calls.all == [statusRun])
            #expect(c.deps.row(s1)?.state != .parked)
        }
    }

    @Test func untrackedFilesAloneDoNotBlockTheStop() async {
        let c = await CommandHarness(active: [Entry.running(s1, cwd: "\(wt)/src")])
        c.answerGit(FakeGit(status: ["?? a", "?? b", "?? c"]))
        #expect(await c.delete(seen: seen(files: 3)) == .success(.done))
        #expect(c.calls.all == [statusRun, stopRun(short1), .aliveCheck(4242), rmRun(short1)])
    }

    // A failed count tries one more time after 500 ms. Then claude rm decides.
    @Test func aFailedCountDoesNotBlockTheStop() async {
        let c = await CommandHarness(active: [Entry.running(s1, cwd: "\(wt)/src")])
        c.answerGit(FakeGit(fails: true))
        let job = c.startDelete(seen: seen())
        await c.waitForSleepers(1)
        c.clock.advance(by: .milliseconds(500))
        #expect(await c.result(of: job) == .success(.done))
        #expect(
            c.calls.all == [
                statusRun, statusRun, stopRun(short1), .aliveCheck(4242), rmRun(short1),
            ])
    }

    @Test func aParkedRowAndARowOutsideAWorktreeGetNoCount() async {
        let parked = await CommandHarness(
            store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
        parked.answerGit(FakeGit(status: [" M a"]))
        #expect(await parked.delete(seen: seen(files: 1)) == .success(.done))
        #expect(parked.calls.all == [rmRun(short1)])
        let plain = await CommandHarness(active: [Entry.running(s1)])
        plain.answerGit(FakeGit(status: [" M a"]))
        #expect(await plain.delete() == .success(.done))
        #expect(plain.calls.all == [stopRun(short1), .aliveCheck(4242), rmRun(short1)])
    }

    // MARK: - The wait for the end of the session process

    // claude rm refuses a worktree while the session process runs.
    @Test func claudeRmRunsOnlyAfterTheSessionProcessEnded() async {
        let c = await CommandHarness(active: [Entry.running(s1)])
        c.calls.answerAlive { _ in true }
        let job = c.startDelete()
        await c.waitForSleepers(1)
        c.clock.advance(by: .seconds(2))
        await c.waitForSleepers(1)
        #expect(await waitUntil { c.calls.all.contains(.exitWatch(4242)) })
        #expect(c.calls.claudeRuns == [["stop", "f3a9c2d1"]])
        #expect(c.calls.all.count { $0 == .aliveCheck(4242) } == 1)
        // The exit event ends the wait with no move of the clock.
        c.calls.answerAlive { _ in false }
        #expect(await c.result(of: job) == .success(.done))
        #expect(c.calls.claudeRuns == [["stop", "f3a9c2d1"], ["rm", "f3a9c2d1"]])
    }

    @Test func aProcessThatStaysPast15sGivesNoClaudeRmAndFreesTheLock() async {
        let c = await CommandHarness(active: [Entry.running(s1)])
        c.calls.answerAlive { _ in true }
        let job = c.startDelete()
        await c.waitForSleepers(1)
        c.clock.advance(by: .seconds(15) - .milliseconds(1))
        await c.waitForSleepers(1)
        #expect(!c.anyEnded)
        c.clock.advance(by: .milliseconds(1))
        #expect(await c.result(of: job) == .failure(.notStopped))
        #expect(c.calls.all.count { $0 == .aliveCheck(4242) } == 1)
        #expect(c.calls.all.count { $0 == .exitWatch(4242) } == 1)
        #expect(c.calls.claudeRuns == [["stop", "f3a9c2d1"]])
        #expect(c.deps.row(s1) != nil)
        // The lock is free. A second Delete runs claude stop again.
        c.calls.answerAlive { _ in false }
        #expect(await c.delete() == .success(.done))
        #expect(c.calls.claudeRuns.count == 3)
    }

    @Test func aSessionWithNoPidChecksNoProcess() async {
        let c = await CommandHarness(active: [Entry.running(s1, pid: nil)])
        #expect(c.deps.row(s1)?.state != .parked)
        #expect(await c.delete() == .success(.done))
        #expect(c.calls.all == [stopRun(short1), rmRun(short1)])
    }

    // MARK: - A folder that another session uses

    @Test func aSharedFolderDefersTheDeleteAndRunsNoClaudeRm() async {
        // The other row can run or be parked, and the counts of the dialog are not used.
        for other in [
            [Entry.running(s2, cwd: "\(wt)/src", pid: 5151)], [Entry.stopped(s2, cwd: wt)],
        ] {
            let running = other[0].pid != nil
            let c = await CommandHarness(
                store: storedWorktree, active: running ? other : [],
                all: [Entry.stopped(s1, cwd: "/r")] + (running ? [] : other))
            #expect(await c.delete(seen: seen(at: "/x")) == .success(.done))
            #expect(c.calls.all.isEmpty)
            #expect(c.deferred == [s1])
            #expect(c.deps.registry.deferredIn(wt).first?.shortId == short1)
            #expect(c.rowIds == [s2])
        }
    }

    // No claude rm runs now, so no count of the changes runs before the stop.
    @Test func aRunningRowInASharedFolderStopsThenDefers() async {
        let c = await CommandHarness(
            active: [Entry.running(s1, cwd: "\(wt)/src")], all: [Entry.stopped(s2, cwd: wt)])
        c.answerGit(FakeGit(status: [" M a"]))
        #expect(await c.delete() == .success(.done))
        #expect(c.calls.all == [stopRun(short1), .aliveCheck(4242)])
        #expect(c.deferred == [s1])
    }

    @Test func aRunningRowInASharedFolderThatDoesNotStopIsNotDeferred() async {
        let c = await CommandHarness(
            active: [Entry.running(s1, cwd: "\(wt)/src")], all: [Entry.stopped(s2, cwd: wt)])
        c.calls.answerAlive { _ in true }
        let job = c.startDelete()
        await c.waitForSleepers(1)
        c.clock.advance(by: SessionActions.deleteEndWait)
        #expect(await c.result(of: job) == .failure(.notStopped))
        #expect(c.calls.claudeRuns == [["stop", "f3a9c2d1"]])
        #expect(c.deferred.isEmpty)
        #expect(c.deps.row(s1) != nil)
    }

    // Three sessions in one folder: the last Delete runs its own claude rm, then the claude rm of
    // each deferred session in the order of the defers.
    @Test func theLastDeleteRemovesEachDeferredSessionInTheOrderOfTheDefers() async {
        let c = await CommandHarness(
            store: storedWorktree, active: [Entry.running(s3, cwd: wt, pid: 6262)],
            all: [Entry.stopped(s1, cwd: "/r"), Entry.stopped(s2, cwd: wt)])
        c.answerGit(FakeGit())
        #expect(await c.delete(s1) == .success(.done))
        #expect(await c.delete(s2) == .success(.done))
        #expect(c.deferred == [s1, s2])
        #expect(c.rowIds == [s3])
        #expect(c.calls.all.isEmpty)
        #expect(await c.delete(s3, seen: seen()) == .success(.done))
        #expect(
            c.calls.all == [
                statusRun, stopRun(short3), .aliveCheck(6262), rmRun(short3), rmRun(short1),
                rmRun(short2),
            ])
        #expect(c.deferred.isEmpty)
        #expect(c.rowIds.isEmpty)
    }

    // A failed deferred claude rm shows that session and each later one again. The last session
    // leaves the list, because its claude rm worked.
    @Test func aFailedDeferredRmUndefersThatEntryAndEachLaterOne() async {
        let store = RegistryStore(
            deferred: [
                deferredEntry(s1, short1), deferredEntry(s2, short2), deferredEntry(s4, short4),
            ],
            worktrees: [s3: wt])
        let c = await CommandHarness(store: store, all: [Entry.stopped(s3, cwd: "/r")])
        c.calls.answerClaude { $0 == ["rm", "0b1c2d3e"] ? changes(short2) : ok }
        #expect(await c.delete(s3) == .failure(.uncommitted))
        #expect(c.calls.all == [rmRun(short3), rmRun(short1), rmRun(short2)])
        #expect(c.deferred.isEmpty)
        #expect(c.rowIds.isEmpty)
        #expect(
            c.deps.log.values == [.sessionCommandFailed(.delete, session: s3, .uncommitted)])
    }

    @Test func aDeferredRmGetsTheCheckOfTheLastDialog() async {
        let store = RegistryStore(deferred: [deferredEntry(s1, short1)], worktrees: [s2: wt])
        let c = await CommandHarness(store: store, all: [Entry.stopped(s2, cwd: "/r")])
        c.calls.answerClaude { $0 == ["rm", "f3a9c2d1"] ? kept(short1) : ok }
        c.answerGit(FakeGit(commits: 1))
        #expect(await c.delete(s2, seen: seen(commits: 1)) == .success(.done))
        #expect(
            c.calls.all
                == [rmRun(short2), rmRun(short1)] + checkWithHeadRuns + [discardRun(short1)])
        #expect(c.deferred.isEmpty)
        // The dialog showed no check: Bifrost discards nothing, and the session shows again.
        let unchecked = await CommandHarness(store: store, all: [Entry.stopped(s2, cwd: "/r")])
        unchecked.calls.answerClaude { $0 == ["rm", "f3a9c2d1"] ? kept(short1) : ok }
        #expect(await unchecked.delete(s2) == .failure(.kept))
        #expect(unchecked.calls.all == [rmRun(short2), rmRun(short1)])
        #expect(unchecked.deferred.isEmpty)
        #expect(unchecked.rowIds.isEmpty)
    }

    // A claude rm can take minutes. An entry that the registry no longer has, for example after
    // the orphan rule, gets no claude rm.
    @Test func aDeferredEntryThatWentDuringTheLastDeleteGetsNoClaudeRm() async {
        let store = RegistryStore(
            deferred: [deferredEntry(s1, short1), deferredEntry(s2, short2)], worktrees: [s3: wt])
        let c = await CommandHarness(store: store, all: [Entry.stopped(s3, cwd: "/r")])
        let gate = TestGate()
        c.calls.hold(gate)
        let job = c.startDelete(s3)
        await gate.waitUntilHolding(1)
        gate.open()
        await gate.waitUntilHolding(1)
        #expect(c.calls.claudeRuns.last == ["rm", "f3a9c2d1"])
        c.deps.registry.undefer(s2)
        gate.openAll()
        #expect(await c.result(of: job) == .success(.done))
        #expect(c.calls.all == [rmRun(short3), rmRun(short1)])
    }

    // A session that starts in the worktree during a claude rm keeps the next deferred entry for
    // its own Delete.
    @Test func aNewRowInTheWorktreeStopsTheDeferredClaudeRm() async {
        let store = RegistryStore(
            deferred: [deferredEntry(s1, short1), deferredEntry(s2, short2)], worktrees: [s3: wt])
        let c = await CommandHarness(store: store, all: [Entry.stopped(s3, cwd: "/r")])
        let gate = TestGate()
        c.calls.hold(gate)
        let job = c.startDelete(s3)
        await gate.waitUntilHolding(1)
        gate.open()
        await gate.waitUntilHolding(1)
        await c.deps.show([Entry.running(s4, cwd: wt)], until: CommandHarness.runs(s4))
        gate.openAll()
        #expect(await c.result(of: job) == .success(.done))
        #expect(c.calls.all == [rmRun(short3), rmRun(short1)])
        #expect(c.deferred == [s2])
    }

    // A session that starts in the worktree during the wait for the end of the process keeps the
    // folder: the claude rm of the Delete waits as a deferred delete.
    @Test func aSessionThatStartsInTheWorktreeDuringTheStopKeepsTheFolder() async {
        let c = await CommandHarness(active: [Entry.running(s1, cwd: "\(wt)/src")])
        c.answerGit(FakeGit())
        c.calls.answerAlive { _ in true }
        let job = c.startDelete(seen: seen())
        await c.waitForSleepers(1)
        await c.deps.show(
            [Entry.running(s1, cwd: "\(wt)/src"), Entry.running(s2, cwd: wt, pid: 5151)],
            until: CommandHarness.runs(s2))
        c.calls.answerAlive { _ in false }
        #expect(await c.result(of: job) == .success(.done))
        #expect(c.calls.claudeRuns == [["stop", "f3a9c2d1"]])
        #expect(c.deferred == [s1])
        #expect(c.rowIds == [s2])
    }

    // The claude rm of a deferred entry still runs after an earlier Delete ended, so the run
    // holds the lock of the entry. The next Delete of the last session skips that entry, which
    // stays deferred.
    @Test func aDeferredEntryWhoseClaudeRmStillRunsIsSkipped() async {
        let store = RegistryStore(deferred: [deferredEntry(s1, short1)], worktrees: [s3: wt])
        let c = await CommandHarness(store: store, all: [Entry.stopped(s3, cwd: "/r")])
        let held = TestGate()
        c.calls.hold(held)
        let first = c.startDelete(s3)
        await held.waitUntilHolding(1)
        held.open()
        await held.waitUntilHolding(1)
        #expect(c.calls.claudeRuns.last == ["rm", "f3a9c2d1"])
        first.cancel()
        #expect(await c.result(of: first) == .failure(.cancelled))
        #expect(c.deferred == [s1])
        #expect(c.actions.isRunning(s1))
        let open = TestGate()
        open.openAll()
        c.calls.hold(open)
        #expect(await c.delete(s3) == .success(.done))
        #expect(
            c.calls.claudeRuns == [["rm", "1c2d3e4f"], ["rm", "f3a9c2d1"], ["rm", "1c2d3e4f"]])
        #expect(c.deferred == [s1])
        #expect(c.rowIds.isEmpty)
        held.openAll()
        #expect(await waitUntil { !c.actions.isRunning(s1) })
        #expect(c.deps.log.values.last == .claudeRmEndedAfterItsJob(session: s1, .exited(0)))
    }

    @Test func aFailedClaudeRmOfTheLastSessionRunsNoDeferredRm() async {
        let store = RegistryStore(deferred: [deferredEntry(s1, short1)], worktrees: [s3: wt])
        let c = await CommandHarness(store: store, all: [Entry.stopped(s3, cwd: "/r")])
        c.calls.answerClaude { _ in ExecResult(.exited(1), stderr: "boom") }
        #expect(await c.delete(s3) == .failure(.claudeReported("boom")))
        #expect(c.calls.all == [rmRun(short3)])
        #expect(c.deferred == [s1])
        #expect(c.rowIds == [s3])
    }

    // Delete runs no claude rm for a row with no short ID, so the folder is safe.
    @Test func aRowWithNoShortIdInASharedFolderOnlyLeavesTheList() async {
        let c = await CommandHarness(
            store: storedWorktree, active: [Entry.running(s2, cwd: "\(wt)/src")],
            all: [Entry.stopped(s1, cwd: "/r", noShortId: true)])
        c.deps.claudeFound = false
        #expect(await c.delete() == .success(.done))
        #expect(c.calls.all.isEmpty)
        #expect(c.deferred.isEmpty)
        #expect(c.rowIds == [s2])
    }

    // MARK: - The IDs after a /clear

    // The row ID is s3. A /clear made s2 the current ID. The short ID of the job does not change.
    @Test func afterAClearDeleteUsesTheShortId() async {
        let store = RegistryStore(current: [s3: s2], jobs: [s3: short1])
        let c = await CommandHarness(store: store, all: [Entry.stopped(s1)])
        let row = c.deps.row(s3)
        #expect(row?.currentId == s2 && row?.shortId == short1 && row?.state == .parked)
        #expect(await c.delete(s3) == .success(.done))
        #expect(c.calls.all == [rmRun(short1)])
        #expect(c.deps.row(s3) == nil)
    }

    // MARK: - The end of a job

    // A cancel during claude rm ends the job at once with cancelled, and sends nothing to
    // claude rm. The run holds the lock until the program ends, and the row stays.
    @Test func aCancelDuringClaudeRmSendsNothingAndTheRunKeepsTheLock() async {
        let c = await CommandHarness(all: [Entry.stopped(s1)])
        let gate = TestGate()
        c.calls.hold(gate)
        let job = c.startDelete()
        await gate.waitUntilHolding(1)
        job.cancel()
        #expect(await c.result(of: job) == .failure(.cancelled))
        #expect(c.calls.all == [rmRun(short1)])
        #expect(c.actions.isRunning(s1))
        #expect(await c.delete() == .failure(.locked))
        gate.openAll()
        #expect(await waitUntil { !c.actions.isRunning(s1) })
        #expect(c.calls.all == [rmRun(short1)])
        #expect(c.deps.log.values.last == .claudeRmEndedAfterItsJob(session: s1, .exited(0)))
        #expect(c.deps.row(s1) != nil)
    }

    // The quit of the app ends the Delete with cancelled and sends nothing to claude rm, which
    // runs on until it ends.
    @Test func aQuitDuringClaudeRmSendsNothingToIt() async {
        let c = await CommandHarness(all: [Entry.stopped(s1)])
        let gate = TestGate()
        c.calls.hold(gate)
        let job = c.startDelete()
        await gate.waitUntilHolding(1)
        c.actions.stop()
        #expect(await c.result(of: job) == .failure(.cancelled))
        #expect(c.actions.isRunning(s1))
        gate.openAll()
        #expect(await waitUntil { !c.actions.isRunning(s1) })
        #expect(c.calls.all == [rmRun(short1)])
        #expect(c.deps.log.values.last == .claudeRmEndedAfterItsJob(session: s1, .exited(0)))
    }

    @Test func aStopDuringTheWaitForTheEndOfTheProcessRunsNoClaudeRm() async {
        let c = await CommandHarness(active: [Entry.running(s1)])
        c.calls.answerAlive { _ in true }
        let job = c.startDelete()
        await c.waitForSleepers(1)
        c.actions.stop()
        #expect(await c.result(of: job) == .failure(.cancelled))
        #expect(c.calls.claudeRuns == [["stop", "f3a9c2d1"]])
        #expect(c.deps.row(s1) != nil)
    }

    // MARK: - The check of the Delete dialog

    // A stopped session reports its start folder, so the check uses the stored worktree.
    // The check of a worktree also reads its HEAD commit, which binds a discard to the commits
    // that the dialog shows.
    @Test func theDialogCheckUsesTheStoredWorktreeOfAStoppedSession() async {
        let c = await CommandHarness(store: storedWorktree, all: [Entry.stopped(s1, cwd: "/r")])
        c.answerGit(FakeGit(status: ["?? a"], commits: 2))
        #expect(
            await c.actions.deleteCheck(s1)
                == WorktreeCheck(
                    branch: "worktree-w1", changedFiles: 1, unmergedCommits: 2, worktree: wt,
                    head: headCommit))
        #expect(c.calls.all == checkWithHeadRuns)
    }

    @Test func theDialogCheckOfAFolderOutsideAWorktreeRunsNoGit() async {
        let c = await CommandHarness(active: [Entry.running(s1)])
        #expect(
            await c.actions.deleteCheck(s1)
                == WorktreeCheck(branch: nil, changedFiles: 0, unmergedCommits: 0, worktree: nil))
        #expect(c.calls.all.isEmpty)
    }

    @Test func theDialogCheckGivesNoCheckForAnUnknownOrExternalRowOrNoFolder() async {
        let c = await CommandHarness(
            active: [Entry.interactive(s1, cwd: wt), Entry.running(s2, cwd: "")])
        #expect(c.deps.row(s2)?.cwd == "")
        #expect(await c.actions.deleteCheck(s1) == nil)
        #expect(await c.actions.deleteCheck(s2) == nil)
        #expect(await c.actions.deleteCheck(s3) == nil)
        #expect(c.calls.all.isEmpty)
    }

    @Test func aFailedDialogCheckGivesNoCheck() async {
        let c = await CommandHarness(active: [Entry.running(s1, cwd: wt)])
        c.answerGit(FakeGit(fails: true))
        let check = Task { await c.actions.deleteCheck(s1) }
        await c.waitForSleepers(1)
        c.clock.advance(by: .milliseconds(500))
        #expect(await check.value == nil)
    }

    // Only a check that found a worktree gives the counts of the dialog.
    @Test func theCountsOfTheDialogComeOnlyFromACheckOfAWorktree() {
        let none = WorktreeCheck(branch: nil, changedFiles: 0, unmergedCommits: 0, worktree: nil)
        #expect(SeenCounts(none) == nil)
        let noHead = WorktreeCheck(branch: nil, changedFiles: 0, unmergedCommits: 0, worktree: wt)
        #expect(SeenCounts(noHead) == nil)
        let counts = seen(commits: 2, files: 3)
        #expect(counts?.unmergedCommits == 2 && counts?.changedFiles == 3 && counts?.worktree == wt)
        #expect(counts?.head == headCommit)
    }
}
