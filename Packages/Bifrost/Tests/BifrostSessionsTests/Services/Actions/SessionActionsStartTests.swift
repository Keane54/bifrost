// The session commands New session, Stop, Resume and Resume all (docs/behaviour/actions.md, "The
// session commands"). The registry service is real, on fake session lists and a manual clock.
// claude, git and the folder reads are fakes (FakeActionDeps), so no test of the first suite runs
// a program or signals a process. A test moves the clock and awaits the result of each job within
// the limit of CommandHarness.result(of:), so a job that does not end stops only its test.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Observation
import Testing

@testable import BifrostSessions

// Session IDs whose first 8 characters are the short ID of their job, as for a job of claude.
private let s1 = "f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f"
private let s2 = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"
private let s3 = "1c2d3e4f-5061-4b7c-9d8e-0f1a2b3c4d5e"
private let s4 = "2d3e4f50-6172-4c8d-ae9f-1a2b3c4d5e6f"
private let newId = "4cb23c30-7283-4d9e-bfa0-2b3c4d5e6f70"
private let newShort: ShortID = "4cb23c30"

private let ok = ExecResult(.exited(0))
private let startedOutput = ExecResult(
    .exited(0), stdout: "backgrounded \u{B7} 4cb23c30 \u{B7} bifrost-test-n\n  hint line",
    stderr: "Starting background service\u{2026}")
private let trustText =
    "Workspace not trusted. Run `claude` in /p once and accept the trust prompt, then retry."
private let settings = #"{"statusLine":{"type":"command","command":"true"}}"#

private func short(_ id: String) -> ShortID? { ShortID(id.prefix(8)) }

// A background session of the active list: an owned row that runs. Its short ID comes from the
// ID of its job, which is its session ID unless the test names another job.
private func running(
    _ id: String, cwd: String = "/p", name: String = "bifrost-test-s", pid: pid_t? = 4242,
    status: AgentStatus = .idle, job: String? = nil, noShortId: Bool = false
) -> AgentEntry {
    AgentEntry(
        sessionId: id, cwd: cwd, isBackground: true, startedAt: 1, name: name, status: status,
        pid: pid, id: noShortId ? nil : short(job ?? id))
}

// A stopped background session of the --all list: a parked row.
private func stopped(_ id: String, cwd: String = "/p", name: String = "bifrost-test-s")
    -> AgentEntry
{
    AgentEntry(sessionId: id, cwd: cwd, isBackground: true, startedAt: 1, name: name, id: short(id))
}

// An interactive session in another terminal: an external row.
private func interactive(_ id: String, id shortId: ShortID? = nil) -> AgentEntry {
    AgentEntry(
        sessionId: id, cwd: "/p", startedAt: 1, name: "bifrost-test-x", status: .idle, pid: 5151,
        id: shortId)
}

// The condition of a row that runs: the row ID is there and is not parked.
private func runs(_ id: String) -> ([SessionRow]) -> Bool {
    { rows in rows.contains { $0.sessionId == id && $0.state != .parked } }
}

// A claude run. A start gets SIGTERM at its limit and at a cancel.
private func claude(
    _ args: [String], in folder: String? = "/p", signal: KillSignal = .terminate
) -> FakeActionCalls.Call {
    .claude(args, directory: folder, timeout: .seconds(60), killSignal: signal)
}

private func gitCheck(_ folder: String) -> FakeActionCalls.Call {
    .git(["-C", folder, "rev-parse", "--show-toplevel"])
}

private func spec(
    cwd: String = "/p", mode: PermissionMode? = nil, prompt: String = "", worktree: Bool = false
) -> NewSessionSpec {
    try! NewSessionSpec.check(
        cwd: cwd, name: "bifrost-test-n", model: .haiku, permissionMode: mode, prompt: prompt,
        worktree: worktree
    ).get()
}

@Suite("the session commands: New session, Stop, Resume and Resume all", .testTimeLimit)
@MainActor
struct SessionActionsStartTests {
    // MARK: - New session

    // Only an owned row with the short ID of the start, not parked, with a PID is the new
    // session. The row that the wait gives is in the rows at once.
    @Test func aNewSessionRunsClaudeBgInItsFolderAndWaitsForItsRow() async {
        let c = await CommandHarness()
        c.calls.answerClaude { _ in startedOutput }
        let job = c.start(.create(spec(cwd: "/p/", mode: .plan, prompt: "Reply")))
        await c.waitForSleepers(1)
        await c.deps.show([running(newId, pid: nil), interactive(s2, id: newShort)]) {
            $0.count == 2
        }
        await c.waitForSleepers(1)
        #expect(!c.anyEnded)
        c.deps.lists.active = [running(newId, pid: 5151)]
        await c.deps.poll()
        #expect(await c.result(of: job) == .success(.created(sessionId: newId)))
        #expect(c.deps.row(newId)?.pid == 5151)
        #expect(
            c.calls.all == [
                .folderRead("/p"), gitCheck("/p"),
                claude([
                    "--bg", "--settings", settings, "--model", "haiku", "--permission-mode",
                    "plan", "--name", "bifrost-test-n", "Reply",
                ]),
            ])
        #expect(await c.started() == [newId])
        #expect(c.deps.log.values == [.sessionCommandDone(.newSession, session: newId)])
    }

    // Claude Code lists the new job when claude --bg ends, first with no PID. The job reads the
    // active list at once, so the row shows with no poll of the registry (its loop waits a day).
    // The start still waits for the PID, which a later poll gives.
    @Test func aNewSessionReadsTheListAtOnceAfterClaudeBg() async {
        let c = await CommandHarness()
        c.calls.answerClaude { _ in startedOutput }
        c.deps.lists.active = [running(newId, pid: nil)]
        let reads = c.deps.lists.activeCalls
        let job = c.start(.create(spec()))
        await c.waitForSleepers(1)
        #expect(c.deps.lists.activeCalls == reads + 1)
        #expect(c.rowIds == [newId])
        #expect(c.deps.row(newId)?.pid == nil)
        #expect(!c.anyEnded)
        c.deps.lists.active = [running(newId, pid: 5151)]
        await c.deps.poll()
        #expect(await c.result(of: job) == .success(.created(sessionId: newId)))
        // A list that has the PID at the first read ends the start with no wait.
        c.deps.lists.active = [running(newId, pid: 5151), running(s1, pid: 6161)]
        c.calls.answerClaude { _ in
            ExecResult(.exited(0), stdout: "backgrounded \u{B7} f3a9c2d1 \u{B7} bifrost-test-n")
        }
        #expect(await c.run(.create(spec())) == .success(.created(sessionId: s1)))
        #expect(c.deps.lists.activeCalls == reads + 3)
    }

    // A failed read keeps the rows, and the start waits for the next poll. The registry logs the
    // failed list, and the job logs nothing yet.
    @Test func aFailedReadAfterClaudeBgWaitsForThePoll() async {
        let c = await CommandHarness()
        c.calls.answerClaude { _ in startedOutput }
        c.deps.lists.activeFailure = .emptyOutput
        let job = c.start(.create(spec()))
        await c.waitForSleepers(1)
        #expect(c.rowIds.isEmpty)
        #expect(c.deps.log.values == [.agentListFailed(.emptyOutput)])
        c.deps.lists.activeFailure = nil
        await c.deps.show([running(newId, pid: 5151)])
        #expect(await c.result(of: job) == .success(.created(sessionId: newId)))
    }

    // The steps of a start: accepted before claude --bg, then launched with its short ID. A
    // refusal before claude --bg gives no step.
    @Test func aNewSessionGivesItsStepsInOrder() async {
        let c = await CommandHarness()
        let gate = TestGate()
        defer { gate.openAll() }
        c.calls.hold(gate)
        c.calls.answerClaude { _ in startedOutput }
        c.deps.lists.active = [running(newId, pid: 5151)]
        let steps = Recorder<StartStep>()
        let actions = c.actions
        let job = Task { () -> Result<String, ActionRefusal> in
            do throws(ActionRefusal) {
                return .success(try await actions.newSession(spec()) { steps.record($0) })
            } catch {
                return .failure(error)
            }
        }
        await gate.waitUntilHolding(1)
        #expect(steps.values == [.accepted])
        gate.openAll()
        #expect(await job.value == .success(newId))
        #expect(steps.values == [.accepted, .launched(newShort)])
        c.calls.setKind(.missing, at: "/p")
        await #expect(throws: ActionRefusal.dirMissing) {
            try await actions.newSession(spec()) { steps.record($0) }
        }
        #expect(steps.values.count == 2)
    }

    // claude --bg can exit with code 0 and start no session. The start waits 30 s for its row.
    @Test func exitCodeZeroIsNotProofOfAStart() async {
        let c = await CommandHarness()
        c.calls.answerClaude { _ in startedOutput }
        let job = c.start(.create(spec()))
        await c.waitForSleepers(1)
        c.deps.clock.advance(by: .seconds(30) - .milliseconds(1))
        await c.waitForSleepers(1)
        #expect(!c.anyEnded)
        c.deps.clock.advance(by: .milliseconds(1))
        #expect(await c.result(of: job) == .failure(.notStarted(shortId: newShort)))
        #expect(await c.started() == [])
    }

    @Test func theTrustErrorGivesTheTrustText() async {
        let c = await CommandHarness()
        c.calls.answerClaude { _ in ExecResult(.exited(1), stderr: trustText) }
        #expect(await c.run(.create(spec())) == .failure(.trust(dir: "/p")))
        c.calls.answerClaude { _ in ExecResult(.exited(0), stdout: trustText) }
        #expect(await c.run(.create(spec())) == .failure(.trust(dir: "/p")))
        #expect(c.deps.clock.sleeperCount == 4)
        #expect(await c.started() == [])
    }

    @Test func aMissingFolderOrAWorktreeOutsideGitIsRefusedBeforeClaude() async {
        let c = await CommandHarness()
        c.calls.setKind(.missing, at: "/p")
        #expect(await c.run(.create(spec())) == .failure(.dirMissing))
        c.calls.setKind(.other, at: "/p")
        #expect(await c.run(.create(spec())) == .failure(.dirMissing))
        c.calls.setKind(.dir, at: "/p")
        c.calls.setNoGit("/p")
        #expect(await c.run(.create(spec(worktree: true))) == .failure(.noGit))
        #expect(c.calls.claudeRuns.isEmpty)
        // Without a worktree, a folder outside git is correct.
        c.calls.answerClaude { _ in startedOutput }
        await c.deps.show([running(newId)]) { $0.count == 1 }
        #expect(await c.run(.create(spec())) == .success(.created(sessionId: newId)))
    }

    // A double click starts one session. A failed start also frees the slot.
    @Test func aSecondCreateDuringACreateIsRefused() async {
        let c = await CommandHarness()
        let gate = TestGate()
        c.calls.hold(gate)
        c.calls.answerClaude { _ in startedOutput }
        let first = c.start(.create(spec()))
        await gate.waitUntilHolding(1)
        #expect(await c.run(.create(spec())) == .failure(.creating))
        gate.openAll()
        await c.deps.show([running(newId)]) { $0.count == 1 }
        #expect(await c.result(of: first) == .success(.created(sessionId: newId)))
        c.calls.answerClaude { _ in ExecResult(.exited(1), stderr: "boom") }
        #expect(await c.run(.create(spec())) == .failure(.claudeReported("boom")))
        c.calls.answerClaude { _ in startedOutput }
        #expect(await c.run(.create(spec())) == .success(.created(sessionId: newId)))
        #expect(c.calls.claudeRuns.count == 3)
    }

    @Test func aFailedStartGivesTheFailureOfClaude() async {
        let c = await CommandHarness()
        c.calls.answerClaude { _ in ExecResult(.exited(2), stderr: " unknown option \n") }
        #expect(await c.run(.create(spec())) == .failure(.claudeReported("unknown option")))
        c.calls.answerClaude { _ in ExecResult(.exited(3)) }
        #expect(await c.run(.create(spec())) == .failure(.claudeExited(code: 3)))
        c.calls.answerClaude { _ in ExecResult(.timedOut) }
        #expect(await c.run(.create(spec())) == .failure(.claudeFailed))
        // No short ID: no wait for a row.
        c.calls.answerClaude { _ in ExecResult(.exited(0), stdout: "done") }
        #expect(await c.run(.create(spec())) == .failure(.startGaveNoId))
        #expect(c.deps.clock.sleeperCount == 4)
        c.deps.claudeFound = false
        #expect(await c.run(.create(spec())) == .failure(.claudeNotFound))
        #expect(c.calls.claudeRuns.count == 4)
    }

    // MARK: - Stop

    @Test func stopRunsClaudeStopWithTheShortIdAndMarksTheSessionAsStopped() async {
        let c = await CommandHarness(active: [running(s1, status: .busy)])
        #expect(await c.store()?.lastActive.contains(s1) == true)
        #expect(await c.runStop(s1) == .success(.done))
        #expect(c.calls.all == [claude(["stop", "f3a9c2d1"], in: nil, signal: .kill)])
        #expect(await c.store()?.lastActive.contains(s1) == false)
        #expect(c.deps.log.values == [.sessionCommandDone(.stop, session: s1)])
    }

    // After claude stop, the row still looks as if it runs until the next sample of the list.
    // Stop keeps the lock until a sample without the session parks the row, and only then ends.
    @Test func stopEndsOnlyAfterASampleWithoutTheSession() async {
        let c = await CommandHarness(
            active: [running(s1), running(s2)], all: [stopped(s1), stopped(s2)])
        let stop = c.start(.stop(s1))
        await c.waitForSleepers(1)
        #expect(c.calls.claudeRuns == [["stop", "f3a9c2d1"]])
        #expect(c.actions.isRunning(s1))
        #expect(!c.anyEnded)
        // A sample that still has the session does not end the wait.
        await c.deps.show([running(s1), running(s2)])
        await c.waitForSleepers(1)
        #expect(!c.anyEnded)
        await c.deps.show([running(s2)]) { rows in
            rows.contains { $0.sessionId == s1 && $0.state == .parked }
        }
        #expect(await c.result(of: stop) == .success(.done))
        #expect(!c.actions.isRunning(s1))
        #expect(c.deps.log.values == [.sessionCommandDone(.stop, session: s1)])
    }

    // While Stop waits for the park, the session stays locked: Delete, a second Stop, Resume and
    // Take control are refused, and none runs a claude command.
    @Test func aDeleteDuringTheParkWaitIsRefusedAsLocked() async {
        let c = await CommandHarness(
            active: [running(s1), running(s2)], all: [stopped(s1), stopped(s2)])
        let stop = c.start(.stop(s1))
        await c.waitForSleepers(1)
        #expect(await c.run(.remove(s1, confirmed: true, seen: nil)) == .failure(.locked))
        #expect(await c.run(.stop(s1)) == .failure(.locked))
        #expect(await c.run(.resume(s1)) == .failure(.locked))
        #expect(await c.run(.takeControl(s1, confirmed: true)) == .failure(.locked))
        #expect(c.calls.claudeRuns == [["stop", "f3a9c2d1"]])
        await c.deps.show([running(s2)]) { rows in
            rows.contains { $0.sessionId == s1 && $0.state == .parked }
        }
        #expect(await c.result(of: stop) == .success(.done))
    }

    // The stop worked, so the limit of the park wait ends Stop as done, and so does a stop of the
    // registry.
    @Test func theLimitOfTheParkWaitEndsStopAsDone() async {
        let c = await CommandHarness(active: [running(s1)])
        let stop = c.start(.stop(s1))
        await c.waitForSleepers(1)
        c.clock.advance(by: SessionActions.parkWait - .milliseconds(1))
        await c.waitForSleepers(1)
        #expect(!c.anyEnded)
        c.clock.advance(by: .milliseconds(1))
        #expect(await c.result(of: stop) == .success(.done))
        #expect(!c.actions.isRunning(s1))
        let second = await CommandHarness(active: [running(s1)])
        let job = second.start(.stop(s1))
        await second.waitForSleepers(1)
        second.deps.registry.stop()
        #expect(await second.result(of: job) == .success(.done))
    }

    // The stop of the commands is a cancel of the job. With no stop of the registry, the cancel
    // ends the park wait: Stop ends as cancelled and frees its lock.
    @Test func theStopOfTheCommandsCancelsTheParkWait() async {
        let c = await CommandHarness(active: [running(s1)])
        let stop = c.start(.stop(s1))
        await c.waitForSleepers(1)
        c.actions.stop()
        #expect(await c.result(of: stop) == .failure(.cancelled))
        #expect(!c.actions.isRunning(s1))
    }

    // The quit of the app stops the commands and then the registry, in one step
    // (AppServices.stop). The stop of the registry ends the park wait before the cancel reaches
    // it, so Stop ends as done and frees its lock at once.
    @Test func theQuitOfTheAppEndsTheParkWaitAsDone() async {
        let c = await CommandHarness(active: [running(s1)])
        let stop = c.start(.stop(s1))
        await c.waitForSleepers(1)
        c.actions.stop()
        c.deps.registry.stop()
        #expect(await c.result(of: stop) == .success(.done))
        #expect(!c.actions.isRunning(s1))
    }

    // The wait reads all the rows, so a sample that leaves no row at all also ends it. The clock
    // does not move.
    @Test func stopEndsWhenTheLastRowLeaves() async {
        let c = await CommandHarness(active: [running(s1)])
        let stop = c.start(.stop(s1))
        await c.waitForSleepers(1)
        #expect(!c.anyEnded)
        await c.deps.show([]) { $0.isEmpty }
        #expect(await c.result(of: stop) == .success(.done))
        #expect(!c.actions.isRunning(s1))
    }

    @Test func stopRefusesAnExternalAndAParkedRow() async {
        let c = await CommandHarness(active: [interactive(s1)], all: [stopped(s2)])
        #expect(await c.run(.stop(s1)) == .failure(.onlyRunning))
        #expect(await c.run(.stop(s2)) == .failure(.onlyRunning))
        #expect(c.calls.all.isEmpty)
    }

    @Test func stopRefusesAnUnknownSessionAndARowWithNoShortId() async {
        let c = await CommandHarness(active: [running(s1, noShortId: true)])
        #expect(await c.run(.stop(s2)) == .failure(.unknownSession))
        #expect(await c.run(.stop(s1)) == .failure(.badSessionId))
        #expect(c.calls.all.isEmpty)
    }

    @Test func aFailedStopDoesNotMarkTheSession() async {
        let c = await CommandHarness(active: [running(s1)])
        c.calls.answerClaude { _ in ExecResult(.exited(1), stderr: "no such job\n") }
        #expect(await c.run(.stop(s1)) == .failure(.claudeReported("no such job")))
        #expect(await c.store()?.lastActive.contains(s1) == true)
        #expect(
            c.deps.log.values == [
                .sessionCommandFailed(.stop, session: s1, .claudeReported("no such job"))
            ])
    }

    // MARK: - Resume

    // Only the row ID that runs again as an owned row with a PID ends the wait.
    @Test func resumeRunsClaudeBgResumeWithTheResumeIdAndWaitsForTheRow() async {
        let c = await CommandHarness(all: [stopped(s1)])
        let job = c.start(.resume(s1))
        await c.waitForSleepers(1)
        await c.deps.show([running(s1, pid: nil), running(s2)]) { $0.count == 2 }
        #expect(c.deps.row(s1)?.state == .parked)
        await c.waitForSleepers(1)
        #expect(!c.anyEnded)
        c.deps.lists.active = [running(s1, pid: 5151), running(s2)]
        await c.deps.poll()
        #expect(await c.result(of: job) == .success(.done))
        #expect(c.deps.row(s1)?.pid == 5151)
        #expect(c.calls.all == [.folderRead("/p"), claude(["--bg", "--resume", s1])])
        #expect(await c.started() == [s1])
    }

    @Test func resumeRefusesARowThatIsNotParked() async {
        let c = await CommandHarness(active: [running(s1), interactive(s2)])
        #expect(await c.run(.resume(s1)) == .failure(.notParked))
        #expect(await c.run(.resume(s2)) == .failure(.notParked))
        #expect(c.calls.all.isEmpty)
    }

    // Live state is a hint, not an authority: a SessionEnd line (also a forged one) parks a row
    // that the active list still has, with a process, or with no pid and no status in the 2.5 s
    // or so after a start. Resume and Resume all never start a copy of it.
    // The session was active at the last close, so with no pid its row stays one that Resume all
    // resumes. Resume all then gives it as not parked, not as a quiet skip.
    @Test(arguments: [(4242, .idle), (nil, .unknown)] as [(pid_t?, AgentStatus)])
    func resumeRefusesARowThatOnlyALiveLineParked(pid: pid_t?, status: AgentStatus) async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s1]), active: [running(s1, pid: pid, status: status)])
        c.deps.registry.pushLive(.state(HookEvent(.sessionEnd, s1, at: 1_800_000_100_000)))
        #expect(c.deps.row(s1)?.state == .parked)
        #expect(c.deps.row(s1)?.pid == pid)
        #expect(c.deps.row(s1)?.status == status)
        #expect(c.deps.row(s1)?.resumable == (pid == nil))
        #expect(await c.run(.resume(s1)) == .failure(.notParked))
        let notParked = ResumeFailure(sessionId: s1, name: "bifrost-test-s", error: .notParked)
        let skipped = pid == nil ? [notParked] : []
        #expect(await c.run(.resumeAll) == .success(.resumedAll(ResumeAllResult(failed: skipped))))
        #expect(c.calls.all.isEmpty)
    }

    @Test func resumeRefusesAReviewSession() async {
        let c = await CommandHarness(store: RegistryStore(prSessions: [s1]), all: [stopped(s1)])
        #expect(c.deps.row(s1)?.prSession == true)
        #expect(await c.run(.resume(s1)) == .failure(.prResume))
        #expect(c.calls.all.isEmpty)
    }

    @Test func resumeRefusesAMissingFolderAndAnIdThatIsNotASessionId() async {
        let c = await CommandHarness(all: [stopped(s1, cwd: ""), stopped(s2, cwd: "/gone")])
        #expect(await c.run(.resume(s1)) == .failure(.noProjectFolder))
        c.calls.setKind(.missing, at: "/gone")
        #expect(await c.run(.resume(s2)) == .failure(.folderMissing("/gone")))
        let bad = await CommandHarness(
            all: [AgentEntry(sessionId: "abc", cwd: "/p", isBackground: true)])
        #expect(bad.deps.row("abc")?.resumeId == "abc")
        #expect(await bad.run(.resume("abc")) == .failure(.badSessionId))
        #expect(c.calls.claudeRuns.isEmpty && bad.calls.all.isEmpty)
    }

    // The session can run again during the folder check. The resume then starts no copy.
    @Test func aSessionThatRunsAgainDuringTheFolderCheckIsNotResumed() async {
        let c = await CommandHarness(all: [stopped(s1)])
        let gate = TestGate()
        c.calls.holdFolderReads(gate)
        let job = c.start(.resume(s1))
        await gate.waitUntilHolding(1)
        await c.deps.show([running(s1)], until: runs(s1))
        gate.openAll()
        #expect(await c.result(of: job) == .failure(.notParked))
        #expect(c.calls.all == [.folderRead("/p")])
    }

    @Test func resumeGivesTheTrustTextAndTheTimeoutAndMarksNothing() async {
        let c = await CommandHarness(all: [stopped(s1)])
        c.calls.answerClaude { _ in ExecResult(.exited(1), stderr: trustText) }
        #expect(await c.run(.resume(s1)) == .failure(.trust(dir: "/p")))
        c.calls.answerClaude { _ in ok }
        let job = c.start(.resume(s1))
        await c.waitForSleepers(1)
        c.deps.clock.advance(by: .seconds(30))
        #expect(await c.result(of: job) == .failure(.notResumed))
        #expect(await c.started() == [])
    }

    // MARK: - The IDs after a /clear

    // The row ID is s3. A /clear made s2 the current ID. s1 is the original ID of the job, which
    // starts with its short ID.
    private func clearedStore(lastActive: Set<String> = []) -> RegistryStore {
        RegistryStore(current: [s3: s2], jobs: [s3: "f3a9c2d1"], lastActive: lastActive)
    }

    @Test func afterAClearResumePassesTheJobIdAndWaitsForTheRowId() async {
        let c = await CommandHarness(store: clearedStore(), all: [stopped(s1)])
        let row = c.deps.row(s3)
        #expect(row?.currentId == s2 && row?.resumeId == s1 && row?.state == .parked)
        let job = c.start(.resume(s3))
        await c.waitForSleepers(1)
        await c.deps.show([running(s2, job: s1)], until: runs(s3))
        #expect(await c.result(of: job) == .success(.done))
        #expect(c.calls.claudeRuns == [["--bg", "--resume", s1]])
        #expect(await c.started() == [s3])
    }

    @Test func afterAClearResumeAllPassesTheJobId() async {
        let c = await CommandHarness(store: clearedStore(lastActive: [s3]), all: [stopped(s1)])
        #expect(c.deps.row(s3)?.resumable == true)
        c.deps.lists.active = [running(s2, job: s1)]
        let job = c.start(.resumeAll)
        await c.waitForSleepers(1)
        await c.deps.poll()
        #expect(await c.result(of: job) == .success(.resumedAll(ResumeAllResult(resumed: 1))))
        #expect(c.calls.claudeRuns == [["--bg", "--resume", s1]])
    }

    @Test func afterAClearStopUsesTheShortId() async {
        let c = await CommandHarness(store: clearedStore(), active: [running(s2, job: s1)])
        #expect(c.deps.row(s3)?.currentId == s2)
        #expect(await c.runStop(s3) == .success(.done))
        #expect(c.calls.claudeRuns == [["stop", "f3a9c2d1"]])
    }

    // The waits match the rows by these rules, also after a /clear.
    @Test func theWaitsMatchTheRowOfTheStartAndTheRowIdThatRunsAgain() {
        func row(
            _ id: String, kind: SessionKind = .owned, state: SessionState = .idle,
            pid: pid_t? = 5151, shortId: ShortID? = newShort, currentId: String? = nil
        ) -> SessionRow {
            var row = SessionRow.test(
                sessionId: id, shortId: shortId, kind: kind, pid: pid, state: state)
            row.currentId = currentId
            return row
        }
        #expect(SessionActions.isStart(of: newShort, row(newId)))
        #expect(!SessionActions.isStart(of: newShort, row(newId, kind: .external)))
        #expect(!SessionActions.isStart(of: newShort, row(newId, state: .parked)))
        #expect(!SessionActions.isStart(of: newShort, row(newId, pid: nil)))
        #expect(!SessionActions.isStart(of: newShort, row(newId, shortId: "abcd1234")))
        #expect(SessionActions.runsAgain(s3, row(s3, currentId: s2)))
        #expect(!SessionActions.runsAgain(s3, row(s2)))
        #expect(!SessionActions.runsAgain(s3, row(s3, kind: .external)))
        #expect(!SessionActions.runsAgain(s3, row(s3, state: .parked)))
        #expect(!SessionActions.runsAgain(s3, row(s3, pid: nil)))
    }

    // MARK: - Resume all

    // The resumable parked rows resume one after the other, in the order of the rows (the start
    // time, then the row ID), and then the waits run together.
    @Test func resumeAllResumesTheResumableParkedRowsOneAfterTheOther() async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s1, s4]), active: [running(s3, name: "c")],
            all: [
                stopped(s1, name: "a1"), stopped(s2, name: "b"),
                stopped(s4, cwd: "/q", name: "a2"),
            ])
        let gate = TestGate()
        c.calls.hold(gate)
        let job = c.start(.resumeAll)
        await gate.waitUntilHolding(1)
        #expect(c.calls.claudeRuns == [["--bg", "--resume", s4]])
        gate.open()
        await gate.waitUntilHolding(1)
        #expect(c.calls.claudeRuns.count == 2)
        gate.open()
        await c.waitForSleepers(2)
        await c.deps.show(
            [running(s3, name: "c"), running(s1), running(s4, cwd: "/q")], until: runs(s1))
        #expect(await c.result(of: job) == .success(.resumedAll(ResumeAllResult(resumed: 2))))
        #expect(
            c.calls.all == [
                .folderRead("/q"), claude(["--bg", "--resume", s4], in: "/q"),
                .folderRead("/p"), claude(["--bg", "--resume", s1]),
            ])
        #expect(await c.started() == [s1, s4])
    }

    // Each session is marked as started when its row shows, not after the last wait.
    @Test func resumeAllMarksEachSessionWhenItsRowShows() async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s3, s4]),
            all: [stopped(s3, name: "a3"), stopped(s4, name: "a4")])
        let job = c.start(.resumeAll)
        await c.waitForSleepers(2)
        await c.deps.show([running(s4)], until: runs(s4))
        await c.waitForSleepers(1)
        #expect(await c.started() == [s4])
        #expect(!c.anyEnded)
        await c.deps.show([running(s3), running(s4)], until: runs(s3))
        #expect(await c.result(of: job) == .success(.resumedAll(ResumeAllResult(resumed: 2))))
        #expect(await c.started() == [s3, s4])
    }

    // The failures name each session, in the order of the rows, and the failed waits come
    // last. The log has a line for each failure.
    @Test func resumeAllGivesEachFailureWithTheRowNameInTheOrderOfTheRows() async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s1, s2, s3, s4]),
            all: [
                stopped(s1, cwd: "/gone", name: "a1"), stopped(s2, name: "a2"),
                stopped(s3, name: "a3"), stopped(s4, name: "a4"),
            ])
        c.calls.setKind(.missing, at: "/gone")
        c.calls.answerClaude { args in
            args.last == s2 ? ExecResult(.exited(1), stderr: trustText) : ok
        }
        let job = c.start(.resumeAll)
        await c.waitForSleepers(2)
        await c.deps.show([running(s4)], until: runs(s4))
        await c.waitForSleepers(1)
        c.deps.clock.advance(by: .seconds(30))
        // The resumes run in the row order s2, s3, s4, s1.
        let failed = [
            ResumeFailure(sessionId: s2, name: "a2", error: .trust(dir: "/p")),
            ResumeFailure(sessionId: s1, name: "a1", error: .folderMissing("/gone")),
            ResumeFailure(sessionId: s3, name: "a3", error: .notResumed),
        ]
        #expect(
            await c.result(of: job)
                == .success(.resumedAll(ResumeAllResult(resumed: 1, failed: failed))))
        #expect(
            c.deps.log.values
                == failed.map { .sessionCommandFailed(.resumeAll, session: $0.sessionId, $0.error) }
                + [.sessionCommandDone(.resumeAll, session: nil)])
    }

    // An earlier resume can take some seconds, so each resume checks the row of now. The rows
    // resume in the order s2, s1.
    @Test func resumeAllDoesNotResumeACandidateThatRunsAgainDuringAnEarlierResume() async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s1, s2]),
            all: [stopped(s1, name: "a1"), stopped(s2, name: "a2")])
        let gate = TestGate()
        c.calls.hold(gate)
        let job = c.start(.resumeAll)
        await gate.waitUntilHolding(1)
        await c.deps.show([running(s1)], until: runs(s1))
        c.deps.lists.active = [running(s1), running(s2)]
        gate.openAll()
        await c.waitForSleepers(1)
        await c.deps.poll()
        let failed = [ResumeFailure(sessionId: s1, name: "a1", error: .notParked)]
        #expect(
            await c.result(of: job)
                == .success(.resumedAll(ResumeAllResult(resumed: 1, failed: failed))))
        #expect(c.calls.claudeRuns.count == 1)
    }

    @Test func resumeAllWithNoCandidateDoesNothing() async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s2]), active: [running(s2)], all: [stopped(s1)])
        #expect(c.deps.row(s1)?.resumable == false)
        #expect(await c.run(.resumeAll) == .success(.resumedAll(ResumeAllResult())))
        #expect(c.calls.all.isEmpty)
        #expect(!c.actions.resumeAllRunning)
    }

    // One Resume all runs at a time, and it holds the lock of each session that it resumes until
    // its end.
    @Test func aSecondResumeAllIsRefused() async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s1, s2]),
            all: [stopped(s1, name: "a1"), stopped(s2, name: "a2")])
        let gate = TestGate()
        c.calls.hold(gate)
        let job = c.start(.resumeAll)
        await gate.waitUntilHolding(1)
        #expect(c.actions.resumeAllRunning)
        #expect(c.actions.isRunning(s1) && c.actions.isRunning(s2))
        #expect(await c.run(.resumeAll) == .failure(.resumeAllRuns))
        #expect(await c.run(.resume(s1)) == .failure(.locked))
        #expect(await c.run(.stop(s2)) == .failure(.locked))
        gate.openAll()
        await c.waitForSleepers(2)
        await c.deps.show([running(s1), running(s2)]) { runs(s1)($0) && runs(s2)($0) }
        #expect(await c.result(of: job) == .success(.resumedAll(ResumeAllResult(resumed: 2))))
        #expect(!c.actions.resumeAllRunning)
        #expect(!c.actions.isRunning(s1) && !c.actions.isRunning(s2))
        #expect(await c.runStop(s1) == .success(.done))
    }

    @Test func resumeAllSkipsASessionThatHasARunningAction() async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s1, s2]),
            all: [stopped(s1, name: "a1"), stopped(s2, name: "a2")])
        let gate = TestGate()
        c.calls.hold(gate)
        let resume = c.start(.resume(s1))
        await gate.waitUntilHolding(1)
        let all = c.start(.resumeAll)
        await gate.waitUntilHolding(2)
        gate.openAll()
        await c.waitForSleepers(2)
        await c.deps.show([running(s1), running(s2)]) { runs(s1)($0) && runs(s2)($0) }
        #expect(await c.result(of: resume) == .success(.done))
        let failed = [ResumeFailure(sessionId: s1, name: "a1", error: .locked)]
        #expect(
            await c.result(of: all)
                == .success(.resumedAll(ResumeAllResult(resumed: 1, failed: failed))))
        #expect(c.calls.claudeRuns == [["--bg", "--resume", s1], ["--bg", "--resume", s2]])
    }

    // MARK: - The locks

    @Test func oneActionAtATimeRunsForEachSession() async {
        let c = await CommandHarness(active: [running(s1), running(s2)])
        let gate = TestGate()
        c.calls.hold(gate)
        let first = c.start(.stop(s1))
        await gate.waitUntilHolding(1)
        #expect(c.actions.isRunning(s1) && !c.actions.isRunning(s2))
        #expect(await c.run(.stop(s1)) == .failure(.locked))
        #expect(await c.run(.resume(s1)) == .failure(.locked))
        // Another session is free.
        let other = c.start(.stop(s2))
        await gate.waitUntilHolding(2)
        gate.openAll()
        // Each Stop waits for the park of its row until the limit.
        await c.waitForSleepers(2)
        c.clock.advance(by: SessionActions.parkWait)
        #expect(await c.result(of: first) == .success(.done))
        #expect(await c.result(of: other) == .success(.done))
        // After the end, the lock is free again.
        #expect(!c.actions.isRunning(s1))
        #expect(await c.runStop(s1) == .success(.done))
        #expect(
            c.calls.claudeRuns == [
                ["stop", "f3a9c2d1"], ["stop", "0b1c2d3e"], ["stop", "f3a9c2d1"],
            ])
    }

    // The UI follows the locks, so a job that takes a lock tells its observers.
    @Test func theLocksAreObservable() async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s2]), active: [running(s1)], all: [stopped(s2)])
        let gate = TestGate()
        c.calls.hold(gate)
        let session = TestSignal()
        let all = TestSignal()
        withObservationTracking {
            _ = c.actions.isRunning(s1)
        } onChange: {
            session.send()
        }
        withObservationTracking {
            _ = c.actions.resumeAllRunning
        } onChange: {
            all.send()
        }
        let creating = TestSignal()
        withObservationTracking {
            _ = c.actions.isCreating
        } onChange: {
            creating.send()
        }
        c.calls.answerClaude { _ in startedOutput }
        let stop = c.start(.stop(s1))
        let resume = c.start(.resumeAll)
        let create = c.start(.create(spec()))
        await gate.waitUntilHolding(3)
        #expect(session.sent && all.sent && creating.sent)
        #expect(c.actions.isCreating)
        gate.openAll()
        // The waits of the three jobs: the park of the Stop and the rows of the two starts. The
        // limit of the park wait comes before the limit of a start.
        await c.waitForSleepers(3)
        c.clock.advance(by: SessionActions.parkWait)
        #expect(await c.result(of: stop) == .success(.done))
        c.deps.lists.active = [running(s1), running(s2), running(newId)]
        await c.deps.poll()
        #expect(await c.result(of: resume) == .success(.resumedAll(ResumeAllResult(resumed: 1))))
        #expect(await c.result(of: create) == .success(.created(sessionId: newId)))
        #expect(!c.actions.isCreating)
    }

    // A SIGKILL at the limit or at a cancel can leave a start half done, so each start gets
    // SIGTERM. claude stop keeps SIGKILL.
    @Test func theStartsGetSigtermAndStopKeepsSigkill() async {
        let c = await CommandHarness(active: [running(s1)], all: [stopped(s2)])
        c.calls.answerClaude { _ in startedOutput }
        await c.deps.show([running(s1), running(newId)]) { $0.count == 3 }
        #expect(await c.run(.create(spec())) == .success(.created(sessionId: newId)))
        c.calls.answerClaude { _ in ok }
        c.deps.lists.active = [running(s1), running(newId), running(s2)]
        let resume = c.start(.resume(s2))
        await c.waitForSleepers(1)
        await c.deps.poll()
        #expect(await c.result(of: resume) == .success(.done))
        #expect(await c.runStop(s1) == .success(.done))
        let signals = c.calls.all.compactMap { call in
            if case .claude(_, _, _, let signal, _) = call { signal } else { nil }
        }
        #expect(signals == [.terminate, .terminate, .kill])
    }

    @Test func aFailedActionFreesTheLock() async {
        let c = await CommandHarness(active: [running(s1)])
        c.calls.answerClaude { _ in ExecResult(.exited(1), stderr: "busy") }
        #expect(await c.run(.stop(s1)) == .failure(.claudeReported("busy")))
        #expect(!c.actions.isRunning(s1))
        c.calls.answerClaude { _ in ok }
        #expect(await c.runStop(s1) == .success(.done))
    }

    @Test func theFolderCheckReadsOnlyAnAbsolutePath() async {
        let c = await CommandHarness()
        #expect(await c.actions.dirInfo("p") == DirInfo(kind: .missing, git: false))
        #expect(c.calls.all.isEmpty)
        #expect(await c.actions.dirInfo("/p") == DirInfo(kind: .dir, git: true))
        #expect(c.calls.all == [.folderRead("/p"), gitCheck("/p")])
    }

    // MARK: - The end of a job

    // A cancelled job ends its wait at once and frees its lock. A row that shows later gets no
    // step of the job.
    @Test func noStepRunsAfterItsJobEnds() async {
        let c = await CommandHarness(all: [stopped(s1)])
        let job = c.start(.resume(s1))
        await c.waitForSleepers(1)
        job.cancel()
        #expect(await c.result(of: job) == .failure(.cancelled))
        #expect(!c.actions.isRunning(s1))
        await c.waitForSleepers(0)
        await c.deps.show([running(s1)], until: runs(s1))
        #expect(await c.started() == [])
        #expect(c.calls.claudeRuns.count == 1)
        #expect(c.deps.log.values == [.sessionCommandFailed(.resume, session: s1, .cancelled)])
    }

    // A start that timed out is over: its row can show later, and nothing marks it.
    @Test func aRowAfterTheTimeoutGetsNoStep() async {
        let c = await CommandHarness()
        c.calls.answerClaude { _ in startedOutput }
        let job = c.start(.create(spec()))
        await c.waitForSleepers(1)
        c.deps.clock.advance(by: .seconds(30))
        #expect(await c.result(of: job) == .failure(.notStarted(shortId: newShort)))
        await c.deps.show([running(newId)]) { $0.count == 1 }
        #expect(await c.started() == [])
    }

    // A cancel during the claude run ends the job after the run, with no wait for a row.
    @Test func aCancelDuringTheClaudeRunEndsTheJob() async {
        let c = await CommandHarness()
        let gate = TestGate()
        c.calls.hold(gate)
        c.calls.answerClaude { _ in startedOutput }
        let job = c.start(.create(spec()))
        await gate.waitUntilHolding(1)
        job.cancel()
        gate.openAll()
        #expect(await c.result(of: job) == .failure(.cancelled))
        #expect(c.deps.clock.sleeperCount == 4)
        // The slot is free again.
        await c.deps.show([running(newId)]) { $0.count == 1 }
        #expect(await c.run(.create(spec())) == .success(.created(sessionId: newId)))
    }

    // stop() at the quit ends Resume all at its next step: no more claude run, and each lock is
    // free.
    @Test func aStopEndsResumeAllWithNoMoreClaudeRun() async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s1, s2]),
            all: [stopped(s1, name: "a1"), stopped(s2, name: "a2")])
        let gate = TestGate()
        c.calls.hold(gate)
        let job = c.start(.resumeAll)
        await gate.waitUntilHolding(1)
        c.actions.stop()
        gate.openAll()
        #expect(await c.result(of: job) == .failure(.cancelled))
        #expect(c.calls.claudeRuns.count == 1)
        #expect(!c.actions.isRunning(s1) && !c.actions.isRunning(s2))
        #expect(!c.actions.resumeAllRunning)
    }

    // A stop during the folder check of a start runs no claude, and each later command is
    // refused.
    @Test func aStopDuringTheFolderCheckRunsNoClaudeAndRefusesLaterCommands() async {
        let c = await CommandHarness(active: [running(s1)], all: [stopped(s2)])
        let gate = TestGate()
        c.calls.holdFolderReads(gate)
        let create = c.start(.create(spec()))
        let resume = c.start(.resume(s2))
        await gate.waitUntilHolding(2)
        c.actions.stop()
        gate.openAll()
        #expect(await c.result(of: create) == .failure(.cancelled))
        #expect(await c.result(of: resume) == .failure(.cancelled))
        #expect(await c.run(.stop(s1)) == .failure(.cancelled))
        #expect(c.calls.claudeRuns.isEmpty)
        #expect(!c.actions.isRunning(s1) && !c.actions.isRunning(s2))
    }

    // A cancel of Resume all during its waits ends it, frees each lock and marks nothing.
    @Test func aCancelOfResumeAllEndsItAndFreesEachLock() async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s1, s2]),
            all: [stopped(s1, name: "a1"), stopped(s2, name: "a2")])
        let job = c.start(.resumeAll)
        await c.waitForSleepers(2)
        job.cancel()
        #expect(await c.result(of: job) == .failure(.cancelled))
        #expect(!c.actions.isRunning(s1) && !c.actions.isRunning(s2))
        #expect(!c.actions.resumeAllRunning)
        await c.waitForSleepers(0)
        await c.deps.show([running(s1), running(s2)]) { rows in
            rows.allSatisfy { $0.state != .parked }
        }
        #expect(await c.started() == [])
    }

    // With no claude, Resume all frees each lock that it took.
    @Test func resumeAllWithNoClaudeFreesEachLock() async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s1, s2]),
            all: [stopped(s1, name: "a1"), stopped(s2, name: "a2")])
        c.deps.claudeFound = false
        #expect(await c.run(.resumeAll) == .failure(.claudeNotFound))
        #expect(!c.actions.isRunning(s1) && !c.actions.isRunning(s2))
        #expect(!c.actions.resumeAllRunning)
        #expect(c.calls.all.isEmpty)
    }

    // The stop of the registry ends the waits of Resume all, and the job ends with cancelled.
    @Test func aStopOfTheRegistryEndsResumeAll() async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s1, s2]),
            all: [stopped(s1, name: "a1"), stopped(s2, name: "a2")])
        let job = c.start(.resumeAll)
        await c.waitForSleepers(2)
        c.deps.registry.stop()
        #expect(await c.result(of: job) == .failure(.cancelled))
        #expect(!c.actions.resumeAllRunning)
    }

    // The stop of the registry (the app quits) ends each wait, and the job ends with no step.
    @Test func aStopOfTheRegistryEndsTheJob() async {
        let c = await CommandHarness(all: [stopped(s1)])
        let job = c.start(.resume(s1))
        await c.waitForSleepers(1)
        c.deps.registry.stop()
        #expect(await c.result(of: job) == .failure(.cancelled))
        #expect(!c.actions.isRunning(s1))
    }

    // MARK: - Rows that only an --all read lists

    // The start reads the active list one time and runs no check: the new row of the first --all
    // list stays unconfirmed until a command needs it or the next poll comes.
    @Test func aStartRunsNoCheck() async {
        let c = await CommandHarness(all: [stopped(s1)], confirmAll: false)
        #expect(c.deps.lists.activeCalls == 1)
        #expect(c.deps.row(s1)?.listing == .unconfirmed)
        #expect(!c.actions.isCheckingSessions)
        #expect(c.calls.all.isEmpty)
    }

    // A new row of the --all list with no pid can be a session that starts, so Resume reads the
    // active list one more time first. That list lacks the row, so the session stopped, and the
    // resume runs.
    @Test func resumeChecksAnUnconfirmedRowAndThenResumesIt() async {
        let c = await CommandHarness(all: [stopped(s1)], confirmAll: false)
        let reads = c.deps.lists.activeCalls
        let job = c.start(.resume(s1))
        await c.waitForSleepers(1)
        #expect(c.deps.lists.activeCalls == reads + 1)
        #expect(c.deps.row(s1)?.listing == .notListed)
        #expect(c.calls.all == [.folderRead("/p"), claude(["--bg", "--resume", s1])])
        await c.deps.show([running(s1, pid: 5151)], until: runs(s1))
        #expect(await c.result(of: job) == .success(.done))
        #expect(!c.actions.isCheckingSessions)
    }

    // The check gives the real state: the active list has the entry with no pid and no status,
    // as in the 2.5 s after a start. The session runs, so Resume refuses it and starts no copy.
    @Test func resumeRefusesAnUnconfirmedRowThatTheCheckLists() async {
        let c = await CommandHarness(all: [stopped(s1)], confirmAll: false)
        c.deps.lists.active = [running(s1, pid: nil, status: .unknown)]
        let reads = c.deps.lists.activeCalls
        #expect(await c.run(.resume(s1)) == .failure(.notParked))
        #expect(c.deps.lists.activeCalls == reads + 1)
        #expect(c.deps.row(s1)?.listing == .listed)
        #expect(c.calls.all.isEmpty)
    }

    // Resume all checks the active list one time for its unconfirmed rows, and then resumes the
    // rows that the check shows as stopped.
    @Test func resumeAllChecksAnUnconfirmedRowAndThenResumesIt() async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s1]), all: [stopped(s1)], confirmAll: false)
        #expect(c.deps.row(s1)?.resumable == true)
        let reads = c.deps.lists.activeCalls
        let job = c.start(.resumeAll)
        await c.waitForSleepers(1)
        #expect(c.deps.lists.activeCalls == reads + 1)
        #expect(c.calls.all == [.folderRead("/p"), claude(["--bg", "--resume", s1])])
        await c.deps.show([running(s1, pid: 5151)], until: runs(s1))
        #expect(await c.result(of: job) == .success(.resumedAll(ResumeAllResult(resumed: 1))))
    }

    // The check lists the row: the session starts, with no pid and no status yet, so its row stays
    // parked and resumable. Resume all gives it as not parked, takes no lock and runs no claude,
    // so the runner never says "Resumed 0 sessions." for it.
    @Test func resumeAllGivesAnUnconfirmedRowThatTheCheckListsAsNotParked() async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s1]), all: [stopped(s1)], confirmAll: false)
        c.deps.lists.active = [running(s1, pid: nil, status: .unknown)]
        let reads = c.deps.lists.activeCalls
        let failure = ResumeFailure(sessionId: s1, name: "bifrost-test-s", error: .notParked)
        #expect(
            await c.run(.resumeAll) == .success(.resumedAll(ResumeAllResult(failed: [failure]))))
        #expect(c.deps.lists.activeCalls == reads + 1)
        #expect(c.deps.row(s1)?.listing == .listed)
        #expect(c.deps.row(s1)?.resumable == true)
        #expect(c.calls.all.isEmpty)
        #expect(!c.actions.isRunning(s1) && !c.actions.resumeAllRunning)
    }

    // A check that gives no list keeps the row unconfirmed. Resume refuses it with the reason,
    // and Resume all gives it as a failure with the reason, not as a quiet skip. No claude runs.
    @Test func aFailedCheckGivesTheReasonAndResumesNothing() async {
        let c = await CommandHarness(
            store: RegistryStore(lastActive: [s1]), all: [stopped(s1)], confirmAll: false)
        let reason = AgentListError.commandFailed(detail: "boom")
        c.deps.lists.activeFailure = reason
        let reads = c.deps.lists.activeCalls
        #expect(await c.run(.resume(s1)) == .failure(.unconfirmed(reason)))
        let failure = ResumeFailure(
            sessionId: s1, name: "bifrost-test-s", error: .unconfirmed(reason))
        #expect(
            await c.run(.resumeAll) == .success(.resumedAll(ResumeAllResult(failed: [failure]))))
        #expect(c.deps.lists.activeCalls == reads + 2)
        #expect(c.deps.row(s1)?.listing == .unconfirmed)
        #expect(c.calls.all.isEmpty)
        #expect(!c.actions.isRunning(s1) && !c.actions.resumeAllRunning)
    }
}

// A start with a real program in the place of claude, in the test sandbox: a script that
// ignores SIGTERM. It is no Claude Code program. The process runner runs it on the manual clock.
@Suite(
    "the session commands with a program that ignores SIGTERM", .testTimeLimit,
    .tags(.realProcess))
@MainActor
struct SessionActionsGraceTests {
    init() throws { try TestSandbox.require() }

    // The start gets SIGTERM at its limit, then SIGKILL at the end of the grace. Then the job
    // ends and frees its slot.
    @Test func aStartThatIgnoresSIGTERMIsKilledAfterTheGraceAndFreesItsSlot() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let script = temp.appending("claude")
        let pidFile = temp.appending("pid")
        try "#!/bin/sh\ntrap \"\" TERM\necho $$ > '\(pidFile)'\nexec /bin/sleep 600\n".write(
            toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: script)
        let c = await CommandHarness(claude: { clock in
            ClaudeRunner(
                path: script, baseEnvironment: ["PATH": "/usr/bin:/bin"],
                runner: ProcessRunner(clock: clock))
        })
        // The program runs in the folder of the session, so the folder must exist.
        let job = c.start(.create(spec(cwd: temp.path)))
        try #require(await waitUntil { fileExists(pidFile) })
        // The four loops of the registry and the time limit of the run sleep on the clock.
        try #require(await c.deps.clock.waitForSleepers(exactly: 5))
        c.deps.clock.advance(by: .seconds(60))
        // Now the grace of the SIGTERM sleeps in the place of the time limit.
        try #require(await c.deps.clock.waitForSleepers(exactly: 5))
        #expect(c.deps.clock.nextDeadline == ManualClock.Instant(offset: .seconds(65)))
        #expect(c.actions.isCreating)
        #expect(!c.anyEnded)
        c.deps.clock.advance(by: .seconds(5))
        #expect(await c.result(of: job) == .failure(.claudeFailed))
        #expect(!c.actions.isCreating)
        #expect(c.deps.clock.sleeperCount == 4)
    }
}
