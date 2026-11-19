// The session command Take control (docs/behaviour/actions.md, "Take control"). The registry
// service is real, on fake session lists and a manual clock. claude, the folder reads, the process
// reads and the signals are fakes (FakeActionDeps), so no test runs a program or signals a
// process. The transcripts are files in a temporary folder of the test sandbox.
import BifrostFoundation
import BifrostTestSupport
import Darwin
import Foundation
import Testing

@testable import BifrostSessions

// Session IDs whose first 8 characters are the short ID of their job, as for a job of claude.
private let s1 = "f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f"
private let s2 = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"

private let settings = #"{"statusLine":{"type":"command","command":"true"}}"#

// The terminal process of the external session, and the process of the resumed session.
private let terminalPid: pid_t = 4242
private let resumedPid: pid_t = 6161
private let claudeIdentity = ProcessIdentity(
    command: "/Users/x/.local/bin/claude", started: ProcessStart(seconds: 100, microseconds: 5))

// The claude run of Take control: a resume with the statusline override, in the folder of the
// session, with SIGTERM at its limit.
private func resumeRun(_ id: String) -> FakeActionCalls.Call {
    .claude(
        ["--bg", "--settings", settings, "--resume", id], directory: "/p", timeout: .seconds(60),
        killSignal: .terminate)
}

// A projects folder of Claude Code in the test sandbox. Each session ID gets a transcript with a
// user message, and each ID of noMessages gets a transcript with no user message.
private func transcripts(_ ids: String..., noMessages: [String] = []) throws -> TemporaryFolder {
    let temp = try TemporaryFolder()
    let project = temp.appending("-p")
    try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: false)
    for id in ids {
        try #"{"type":"user","message":{"role":"user","content":"hi"}}"#.appending("\n").write(
            toFile: "\(project)/\(id).jsonl", atomically: true, encoding: .utf8)
    }
    for id in noMessages {
        try #"{"type":"summary","summary":"x"}"#.appending("\n").write(
            toFile: "\(project)/\(id).jsonl", atomically: true, encoding: .utf8)
    }
    return temp
}

extension CommandHarness {
    // The harness of a Take control: the rows of the active list, the transcripts, and the
    // terminal process, which is claude. With no other answer, no process is alive.
    fileprivate static func takeControl(
        _ active: [AgentEntry], _ projects: TemporaryFolder
    ) async -> CommandHarness {
        let c = await CommandHarness(active: active, projects: projects.url)
        c.deps.inspector.identities = [terminalPid: claudeIdentity]
        return c
    }

    fileprivate func takeControl(_ id: String = s1) async -> Result<ActionDone, ActionRefusal> {
        await run(.takeControl(id, confirmed: true))
    }

    fileprivate func startTakeControl(_ id: String = s1) -> Task<
        Result<ActionDone, ActionRefusal>, Never
    > {
        start(.takeControl(id, confirmed: true))
    }

    // After the end of the terminal process: the resumed session shows as an owned row of the
    // row ID, and the settle passes.
    fileprivate func resumeAndSettle(_ entry: AgentEntry = Entry.running(s1, pid: resumedPid))
        async
    {
        await waitForSleepers(1)
        await deps.show([entry]) { rows in
            rows.contains { $0.sessionId == s1 && $0.kind == .owned }
        }
        await waitForSleepers(1)
        clock.advance(by: .seconds(3))
    }

    // The calls of a Take control that refused before any signal.
    fileprivate var noSignalAndNoStart: Bool {
        calls.signals.isEmpty && calls.claudeRuns.isEmpty
    }
}

@Suite("the session command Take control", .timeLimit(.minutes(1)))
@MainActor
struct SessionActionsTakeControlTests {
    // MARK: - A takeover

    // One SIGTERM, a wait for the exit event of the terminal process, the resume, the wait for
    // the row, and a check of the new process after 3 s.
    @Test func takeControlEndsTheTerminalProcessAndResumesTheSessionInBifrost() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        c.calls.answerAlive { $0 == terminalPid }
        let job = c.startTakeControl()
        // The wait sleeps to its limit and watches the exit of the process.
        await c.waitForSleepers(1)
        #expect(await waitUntil { c.calls.all.contains(.exitWatch(terminalPid)) })
        #expect(c.calls.claudeRuns.isEmpty)
        // The exit event ends the wait with no move of the clock.
        c.calls.answerAlive { $0 == resumedPid }
        #expect(await waitUntil { c.calls.claudeRuns.count == 1 })
        await c.waitForSleepers(1)
        #expect(await c.started() == [s1])
        await c.deps.show([Entry.running(s1, pid: resumedPid)]) { rows in
            rows.contains { $0.sessionId == s1 && $0.kind == .owned }
        }
        await c.waitForSleepers(1)
        c.clock.advance(by: .seconds(3) - .milliseconds(1))
        await c.waitForSleepers(1)
        #expect(!c.anyEnded)
        c.clock.advance(by: .milliseconds(1))
        #expect(await c.result(of: job) == .success(.tookControl(sessionId: s1)))
        #expect(
            c.calls.all == [
                .folderRead("/p"), .signal(terminalPid, SIGTERM), .aliveCheck(terminalPid),
                .exitWatch(terminalPid), resumeRun(s1), .aliveCheck(resumedPid),
            ])
        #expect(c.deps.inspector.calls == [.identity(terminalPid)])
        #expect(c.deps.log.values == [.sessionCommandDone(.takeControl, session: s1)])
    }

    @Test func theLimitsOfTakeControl() {
        #expect(SessionActions.endWait == .seconds(5))
        #expect(SessionActions.resumeSettle == .seconds(3))
    }

    // A session that finished its turn has a yellow box. Take control accepts it.
    @Test func takeControlAcceptsAYellowBox() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1, status: .busy)], temp)
        await c.deps.show([Entry.interactive(s1)]) { rows in
            rows.first?.state == .needsYou && rows.first?.alert.colour == .yellow
        }
        c.calls.answerAlive { $0 == resumedPid }
        let job = c.startTakeControl()
        await c.resumeAndSettle()
        #expect(await c.result(of: job) == .success(.tookControl(sessionId: s1)))
        #expect(c.calls.signals == [.signal(terminalPid, SIGTERM)])
    }

    // Claude Code cannot resume a session with no user message.
    @Test func aSessionWithNoMessagesGetsNoSignal() async throws {
        let temp = try transcripts(noMessages: [s1])
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        #expect(await c.takeControl() == .failure(.noMessages))
        #expect(c.calls.all == [.folderRead("/p")])
        #expect(c.deps.inspector.calls.isEmpty)
        let none = await CommandHarness(active: [Entry.interactive(s1)])
        #expect(await none.takeControl() == .failure(.noMessages))
        #expect(none.noSignalAndNoStart)
    }

    // The process ends at once, and claude --bg exits with code 0, but the resumed job parks
    // before it runs.
    @Test func takeControlFailsWhenTheResumedSessionParksBeforeItRuns() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        c.calls.answerAlive { $0 == resumedPid }
        let job = c.startTakeControl()
        await c.waitForSleepers(1)
        await c.deps.show([Entry.running(s1, pid: resumedPid)]) { rows in
            rows.contains { $0.sessionId == s1 && $0.kind == .owned }
        }
        await c.waitForSleepers(1)
        c.deps.registry.pushLive(.state(HookEvent(.sessionEnd, s1, at: 1_800_000_100_000)))
        #expect(c.deps.row(s1)?.state == .parked)
        c.clock.advance(by: .seconds(3))
        #expect(await c.result(of: job) == .failure(.resumeFailed(shortId: "f3a9c2d1")))
        #expect(await c.started() == [s1])
    }

    @Test func takeControlFailsWhenTheProcessOfTheResumedSessionEnds() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        let job = c.startTakeControl()
        await c.resumeAndSettle()
        #expect(await c.result(of: job) == .failure(.resumeFailed(shortId: "f3a9c2d1")))
        #expect(c.calls.all.last == .aliveCheck(resumedPid))
    }

    // Bifrost knows no short ID of the resumed row, so the text has no hint to claude logs.
    @Test func aFailedResumeOfARowWithNoShortIdGivesNoHint() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        let job = c.startTakeControl()
        await c.resumeAndSettle(Entry.running(s1, pid: resumedPid, noShortId: true))
        #expect(await c.result(of: job) == .failure(.resumeFailed(shortId: nil)))
    }

    // Bifrost starts no copy of a session whose terminal process still runs.
    @Test func takeControlStartsNoCopyWhenTheProcessDoesNotEndIn5s() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        c.calls.answerAlive { _ in true }
        let job = c.startTakeControl()
        await c.waitForSleepers(1)
        c.clock.advance(by: .seconds(5) - .milliseconds(1))
        await c.waitForSleepers(1)
        #expect(!c.anyEnded)
        c.clock.advance(by: .milliseconds(1))
        #expect(await c.result(of: job) == .failure(.notEnded))
        #expect(c.calls.signals == [.signal(terminalPid, SIGTERM)])
        #expect(c.calls.all.count { $0 == .aliveCheck(terminalPid) } == 1)
        #expect(c.calls.all.count { $0 == .exitWatch(terminalPid) } == 1)
        #expect(c.calls.claudeRuns.isEmpty)
        #expect(await c.started() == [])
    }

    // A started session parks when it ends, so a failed resume leaves a parked row.
    @Test func takeControlMarksTheSessionAsStartedWhenTheResumeFails() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        c.calls.answerClaude { _ in ExecResult(.exited(1), stderr: "resume failed") }
        #expect(await c.takeControl() == .failure(.claudeReported("resume failed")))
        #expect(c.calls.signals == [.signal(terminalPid, SIGTERM)])
        #expect(await c.started() == [s1])
    }

    @Test func theTrustErrorOfTheResumeGivesTheTrustText() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        c.calls.answerClaude { _ in
            ExecResult(.exited(1), stderr: "Workspace not trusted. Run `claude` in /p once.")
        }
        #expect(await c.takeControl() == .failure(.trust(dir: "/p")))
        #expect(c.calls.signals == [.signal(terminalPid, SIGTERM)])
    }

    @Test func takeControlNeedsTheConfirmation() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        #expect(
            await c.run(.takeControl(s1, confirmed: false))
                == .failure(.takeControlNotConfirmed))
        #expect(c.calls.all.isEmpty && c.deps.inspector.calls.isEmpty)
        #expect(!c.actions.isRunning(s1))
    }

    // The confirmation comes before the lock, so a refused command holds no lock and the next
    // Take control runs.
    @Test func aTakeControlWithNoConfirmationHoldsNoLock() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        #expect(
            await c.run(.takeControl(s1, confirmed: false))
                == .failure(.takeControlNotConfirmed))
        c.calls.answerAlive { $0 == resumedPid }
        let job = c.startTakeControl()
        await c.resumeAndSettle()
        #expect(await c.result(of: job) == .success(.tookControl(sessionId: s1)))
    }

    // MARK: - The rows that Take control refuses

    // Take control is only for an external session that runs and is idle or has a yellow box.
    @Test func theRulesOfTakeControlForEachRow() {
        func row(_ state: SessionState, _ alert: SessionAlert, kind: SessionKind = .external)
            -> SessionRow
        {
            var row = SessionRow.test(kind: kind, pid: terminalPid, state: state)
            row.alert = alert
            return row
        }
        func refusal(_ row: SessionRow) -> ActionRefusal? {
            do throws(ActionRefusal) {
                try SessionActions.checkTakeControl(row)
                return nil
            } catch {
                return error
            }
        }
        #expect(refusal(row(.idle, .none)) == nil)
        #expect(refusal(row(.needsYou, .yellow(since: 1))) == nil)
        #expect(refusal(row(.working, .none)) == .working)
        #expect(refusal(row(.needsYou, .red(.prompt, since: 1))) == .openPrompt)
        #expect(refusal(row(.needsYou, .red(.escalated, since: 1))) == .openPrompt)
        #expect(refusal(row(.error, .red(.error, since: 1))) == .openPrompt)
        #expect(refusal(row(.needsYou, .none)) == .notIdle)
        #expect(refusal(row(.error, .none)) == .notIdle)
        #expect(refusal(row(.idle, .yellow(since: 1))) == nil)
        #expect(refusal(row(.idle, .none, kind: .owned)) == .onlyExternal)
        #expect(refusal(row(.parked, .none)) == .onlyExternal)
    }

    @Test func takeControlRefusesARowThatDoesNotFitBeforeAnyProcessRead() async throws {
        let temp = try transcripts(s1, "abc")
        defer { temp.remove() }
        let cases: [([AgentEntry], ActionRefusal)] = [
            ([Entry.running(s1, pid: terminalPid)], .onlyExternal),
            ([Entry.interactive(s1, status: .busy)], .working),
            ([Entry.interactive(s1, status: .waiting, waitingFor: "permission")], .openPrompt),
            ([Entry.interactive(s1, pid: nil)], .noPid),
            ([Entry.interactive("abc")], .badSessionId),
            ([Entry.interactive(s1, cwd: "")], .noProjectFolder),
            ([Entry.interactive(s1, cwd: "p")], .folderMissing("p")),
        ]
        for (active, refusal) in cases {
            let c = await CommandHarness.takeControl(active, temp)
            let id = active[0].sessionId
            #expect(await c.takeControl(id) == .failure(refusal))
            #expect(c.deps.inspector.calls.isEmpty)
            #expect(c.noSignalAndNoStart)
            #expect(await c.started() == [])
        }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        c.calls.setKind(.missing, at: "/p")
        #expect(await c.takeControl() == .failure(.folderMissing("/p")))
        #expect(await c.takeControl(s2) == .failure(.unknownSession))
        // A session whose terminal ended is parked.
        c.deps.registry.pushLive(.state(HookEvent(.sessionEnd, s1, at: 1_800_000_100_000)))
        #expect(await c.takeControl() == .failure(.onlyExternal))
        #expect(c.deps.inspector.calls.isEmpty && c.noSignalAndNoStart)
    }

    // Live state is a hint, not an authority: a Stop line (also a forged one) gives a yellow box
    // to an external session that the session list shows as busy, or as waiting on a prompt.
    // Take control refuses it and sends no signal.
    @Test func takeControlRefusesABoxOfALiveLineWhenTheListSaysTheSessionWorks() async throws {
        let temp = try transcripts(s1, "abc")
        defer { temp.remove() }
        let cases: [(AgentEntry, ActionRefusal)] = [
            (Entry.interactive(s1, status: .busy), .working),
            (Entry.interactive(s1, status: .waiting, waitingFor: "permission"), .openPrompt),
        ]
        for (entry, refusal) in cases {
            let c = await CommandHarness.takeControl([entry], temp)
            c.deps.registry.pushLive(.state(HookEvent(.stop, s1, at: 1_800_000_100_000)))
            #expect(c.deps.row(s1)?.state == .needsYou)
            #expect(await c.takeControl() == .failure(refusal))
            #expect(c.deps.inspector.calls.isEmpty && c.noSignalAndNoStart)
        }
    }

    // An external entry has no pid and no status for about 2.5 s after its start. A line in that
    // time (also a forged one) makes no Take control: with the yellow box of a Stop line the row
    // has no pid, and a SessionEnd line parks it. Bifrost sends no signal and starts nothing.
    @Test func aLiveLineBeforeTheEntryHasAPidMakesNoTakeControl() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let cases: [(HookEventName, ActionRefusal)] = [
            (.stop, .noPid), (.sessionEnd, .onlyExternal),
        ]
        for (name, refusal) in cases {
            let entry = Entry.interactive(s1, pid: nil, status: .unknown)
            let c = await CommandHarness.takeControl([entry], temp)
            c.deps.registry.pushLive(.state(HookEvent(name, s1, at: 1_800_000_100_000)))
            #expect(c.deps.row(s1)?.pid == nil)
            #expect(await c.takeControl() == .failure(refusal))
            #expect(c.deps.inspector.calls.isEmpty && c.noSignalAndNoStart)
        }
    }

    // Without claude, Bifrost cannot resume the session, so it finds claude before the signal.
    @Test func noSignalWhenBifrostCannotFindClaude() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        c.deps.claudeFound = false
        #expect(await c.takeControl() == .failure(.claudeNotFound))
        #expect(c.deps.inspector.calls.isEmpty && c.noSignalAndNoStart)
    }

    // PID 0 and -1 signal a group of processes, and PID 1 is launchd.
    @Test func noSignalToPidOneOrLess() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        for pid: pid_t in [1, 0, -1] {
            let c = await CommandHarness.takeControl([Entry.interactive(s1, pid: pid)], temp)
            c.deps.inspector.identities = [pid: claudeIdentity]
            #expect(c.deps.row(s1)?.pid == pid)
            #expect(await c.takeControl() == .failure(.badPid))
            #expect(c.calls.all.isEmpty && c.deps.inspector.calls.isEmpty)
        }
    }

    @Test func noSignalToAProcessThatIsNotClaude() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        for command in ["/usr/bin/node", "claude-helper", "/x/claude/node", "", nil] {
            let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
            let identity = command.map {
                ProcessIdentity(command: $0, started: claudeIdentity.started)
            }
            c.deps.inspector.identities = identity.map { [terminalPid: $0] } ?? [:]
            #expect(await c.takeControl() == .failure(.notClaudeProcess(pid: terminalPid)))
            #expect(c.noSignalAndNoStart)
        }
        // Bifrost itself is never a session process, also when its name is claude.
        let own = getpid()
        let c = await CommandHarness.takeControl([Entry.interactive(s1, pid: own)], temp)
        c.deps.inspector.identities = [own: claudeIdentity]
        #expect(await c.takeControl() == .failure(.notClaudeProcess(pid: own)))
        #expect(c.deps.inspector.calls.isEmpty && c.noSignalAndNoStart)
    }

    // The rows can change during the reads. The process must still be the process of this row and
    // of no other row, and the rules must still apply.
    @Test func noSignalWhenThePidChangedDuringTheChecks() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        // The registry gives a new PID during the folder read.
        let changed = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        let first = await duringTheReads(changed) {
            await changed.deps.show([Entry.interactive(s1, pid: 5151)]) { $0.first?.pid == 5151 }
        }
        #expect(await changed.result(of: first) == .failure(.processChanged))
        // The session starts to work during the reads.
        let working = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        let second = await duringTheReads(working) {
            await working.deps.show([Entry.interactive(s1, status: .busy)]) {
                $0.first?.state == .working
            }
        }
        #expect(await working.result(of: second) == .failure(.working))
        // The row leaves the list during the reads.
        let gone = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        let third = await duringTheReads(gone) { gone.deps.registry.forget(s1) }
        #expect(await gone.result(of: third) == .failure(.processChanged))
        for c in [changed, working, gone] {
            #expect(c.deps.inspector.calls == [.identity(terminalPid)])
            #expect(c.noSignalAndNoStart)
        }
        // Another row has the PID.
        let shared = await CommandHarness.takeControl(
            [Entry.interactive(s1), Entry.running(s2, pid: terminalPid)], temp)
        #expect(await shared.takeControl() == .failure(.processChanged))
        #expect(shared.noSignalAndNoStart)
    }

    // MARK: - The signal

    @Test func aFailedSigtermGivesTheFriendlyText() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        c.calls.answerSignals(EPERM)
        #expect(await c.takeControl() == .failure(.signalFailed))
        #expect(c.calls.signals == [.signal(terminalPid, SIGTERM)])
        #expect(c.calls.claudeRuns.isEmpty)
        #expect(await c.started() == [])
    }

    // A process that ended just before the signal needs none, so Take control goes on and
    // resumes the session.
    @Test func aProcessThatEndedJustBeforeTheSignalIsResumed() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        // The kill gives ESRCH.
        let late = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        late.calls.answerSignals(ESRCH)
        late.calls.answerAlive { $0 == resumedPid }
        let first = late.startTakeControl()
        await late.resumeAndSettle()
        #expect(await late.result(of: first) == .success(.tookControl(sessionId: s1)))
        #expect(late.calls.signals == [.signal(terminalPid, SIGTERM)])
        // The read just before the kill finds no process, and no process has the PID.
        let gone = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        gone.calls.answerIdentitiesAtSignal([:])
        gone.calls.answerAlive { $0 == resumedPid }
        let second = gone.startTakeControl()
        await gone.resumeAndSettle()
        #expect(await gone.result(of: second) == .success(.tookControl(sessionId: s1)))
        #expect(gone.calls.signals.isEmpty)
    }

    // The system gave the PID to a new process after the check, or the read just before the kill
    // failed while a process has the PID. Bifrost leaves that process alone.
    @Test func noSignalToAProcessThatChangedAfterTheCheck() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let newer = ProcessIdentity(
            command: claudeIdentity.command, started: ProcessStart(seconds: 200, microseconds: 0))
        for identities in [[terminalPid: newer], [:]] {
            let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
            c.calls.answerIdentitiesAtSignal(identities)
            c.calls.answerAlive { $0 == terminalPid }
            #expect(await c.takeControl() == .failure(.notClaudeProcess(pid: terminalPid)))
            #expect(c.noSignalAndNoStart)
            #expect(await c.started() == [])
        }
    }

    // MARK: - The IDs after a /clear

    // A /clear in the terminal made s2 the current ID of the row s1. Take control checks and
    // resumes s2, and the resumed job of s2 keeps the row ID s1.
    @Test func afterAClearTakeControlResumesTheCurrentId() async throws {
        let temp = try transcripts(s2)
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        await c.deps.show([Entry.interactive(s2)]) { $0.first?.currentId == s2 }
        c.calls.answerAlive { $0 == resumedPid }
        let job = c.startTakeControl()
        await c.resumeAndSettle(Entry.running(s2, pid: resumedPid))
        #expect(await c.result(of: job) == .success(.tookControl(sessionId: s1)))
        #expect(c.calls.claudeRuns == [["--bg", "--settings", settings, "--resume", s2]])
        #expect(await c.started() == [s1])
    }

    // The transcript of the row ID does not count: the resume takes the current ID.
    @Test func afterAClearTheTranscriptOfTheCurrentIdCounts() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        await c.deps.show([Entry.interactive(s2)]) { $0.first?.currentId == s2 }
        #expect(await c.takeControl() == .failure(.noMessages))
        #expect(c.noSignalAndNoStart)
    }

    // Else the resume would take the old conversation.
    @Test func aClearDuringTheChecksGivesNoSignal() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        let job = await duringTheReads(c) {
            await c.deps.show([Entry.interactive(s2)]) { $0.first?.currentId == s2 }
        }
        #expect(await c.result(of: job) == .failure(.processChanged))
        #expect(c.noSignalAndNoStart)
    }

    @Test func aCurrentIdThatIsNotASessionIdIsRefused() async throws {
        let temp = try transcripts(s1)
        defer { temp.remove() }
        let c = await CommandHarness.takeControl([Entry.interactive(s1)], temp)
        await c.deps.show([Entry.interactive("abc")]) { $0.first?.currentId == "abc" }
        #expect(await c.takeControl() == .failure(.badSessionId))
        #expect(c.calls.all.isEmpty && c.deps.inspector.calls.isEmpty)
    }

    // MARK: - Helpers

    // Start a Take control, hold its folder read, run the change, then let the read go. The
    // result is the job.
    private func duringTheReads(
        _ c: CommandHarness, _ change: () async -> Void
    ) async -> Task<Result<ActionDone, ActionRefusal>, Never> {
        let gate = TestGate()
        c.calls.holdFolderReads(gate)
        let job = c.startTakeControl()
        await gate.waitUntilHolding(1)
        await change()
        gate.openAll()
        return job
    }
}
