// The session commands with real processes (docs/behaviour/actions.md, "The session commands",
// "Delete" and "Take control"): each claude command runs the fake claude of scripts/fake-claude in
// a test home in the test sandbox. The registry service is real, on fake session lists and a
// manual clock: a test gives it the list of the fake. git, the folder reads and, unless a test
// says otherwise, the process reads and the signals are fakes (FakeActionDeps). No test runs the
// real claude, and the only process that a test signals is a stand-in process that it started.
import BifrostFoundation
import BifrostTestSupport
import Darwin
import Foundation
import Testing

@testable import BifrostSessions

// Session IDs whose first 8 characters are the short ID of their job, as for a job of claude.
private let s1 = "f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f"
private let s2 = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"
// The ID of the first new session of the fake claude.
private let newId = "5b0e0001-0000-4000-8000-000000000001"

private let settings = #"{"statusLine":{"type":"command","command":"true"}}"#

private func newSession(cwd: String) throws -> NewSessionSpec {
    try NewSessionSpec.check(
        cwd: cwd, name: "bifrost-test-n", model: .haiku, permissionMode: nil, prompt: "Reply",
        worktree: false
    ).get()
}

// An entry of the list of the fake: a background session that runs, with a PID that no test
// signals, or an interactive session in another terminal.
private func background(_ id: String, cwd: String) -> FakeClaude.Agent {
    FakeClaude.Agent(
        sessionId: id, cwd: cwd, kind: "background", name: "bifrost-test-s", status: "idle",
        id: String(id.prefix(8)), pid: 4242, startedAt: 1)
}

private func interactive(_ id: String, cwd: String, pid: pid_t) -> FakeClaude.Agent {
    FakeClaude.Agent(
        sessionId: id, cwd: cwd, kind: "interactive", name: "bifrost-test-x", status: "idle",
        id: nil, pid: Int(pid), startedAt: 1)
}

// A test home in a short temporary folder, for the fake claude of scripts/fake-claude. The fake
// writes only in the test home, and its session processes end when the test removes the home.
private struct FakeClaudeHome {
    let folder: TemporaryFolder
    let fake: String

    init() throws {
        folder = try TemporaryFolder(short: true)
        fake = try Repo.fakeClaude()
    }

    var path: String { folder.path }

    func remove() { folder.remove() }

    // Make a folder in the test home. The result is its path; the fake gives its real path.
    func makeFolder(_ name: String) throws -> String {
        let path = folder.appending(name)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func realPath(_ name: String) -> String { "\(folder.realPath)/\(name)" }

    // The claude runner of the fake: the fake first on the PATH, and the test home as HOME and
    // as BIFROST_TEST_HOME. clock: the clock of the time limits, or nil for the real clock.
    func runner(clock: (any Clock<Duration>)? = nil) -> ClaudeRunner {
        let bin = URL(fileURLWithPath: fake).deletingLastPathComponent().path
        return ClaudeRunner(
            path: fake,
            baseEnvironment: [
                "PATH": "\(bin):/usr/bin:/bin", "HOME": path, "BIFROST_TEST_HOME": path,
                "LANG": "en_US.UTF-8",
            ],
            runner: clock.map { ProcessRunner(clock: $0) } ?? ProcessRunner())
    }

    // The text of a file in the test home, or nil.
    func text(_ name: String) -> String? {
        FileManager.default.contents(atPath: folder.appending(name))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    func write(_ name: String, _ text: String = "") throws {
        try text.write(toFile: folder.appending(name), atomically: true, encoding: .utf8)
    }

    // Each call of the fake: its arguments, with one space between them.
    var calls: [String] {
        (text("claude-calls.log") ?? "").split(separator: "\n").map(String.init)
    }

    // The list of the fake, as "claude agents --json" gives it.
    var agents: [AgentEntry] { AgentList(output: text("fake-agents.json") ?? "[]").entries }

    func setAgents(_ agents: [FakeClaude.Agent]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(agents).write(
            to: URL(fileURLWithPath: folder.appending("fake-agents.json")), options: .atomic)
    }
}

// A signal of the real signals of a test: the PID and the signal number.
private struct Sent: Sendable, Equatable {
    var pid: pid_t
    var signal: Int32
}

@Suite("the session commands with the fake claude", .testTimeLimit, .tags(.realProcess))
@MainActor
struct SessionActionsTests {
    init() throws { try TestSandbox.require() }

    // The fake prints the short ID of the new session and adds the session to its list. The job
    // waits for the row of that short ID, which comes with the next list.
    @Test func aNewSessionRunsClaudeBgInItsFolderAndWaitsForItsRow() async throws {
        let home = try FakeClaudeHome()
        defer { home.remove() }
        let folder = try home.makeFolder("alpha")
        let c = await CommandHarness(claude: { _ in home.runner() })
        let job = c.start(.create(try newSession(cwd: folder)))
        await c.waitForSleepers(1)
        #expect(!c.anyEnded)
        let entry = try #require(home.agents.first)
        #expect(entry.sessionId == newId && entry.id == "5b0e0001")
        #expect(entry.cwd == home.realPath("alpha"))
        await c.deps.show(home.agents)
        #expect(await c.result(of: job) == .success(.created(sessionId: newId)))
        #expect(
            home.calls == [
                "--bg --settings \(settings) --model haiku --name bifrost-test-n Reply"
            ])
        #expect(c.deps.row(newId)?.kind == .owned)
        #expect(await c.started() == [newId])
    }

    // A session that the fake started stops with its short ID, and its process ends.
    @Test func stopRunsClaudeStopWithTheShortId() async throws {
        let home = try FakeClaudeHome()
        defer { home.remove() }
        let folder = try home.makeFolder("alpha")
        let c = await CommandHarness(claude: { _ in home.runner() })
        let create = c.start(.create(try newSession(cwd: folder)))
        await c.waitForSleepers(1)
        await c.deps.show(home.agents)
        #expect(await c.result(of: create) == .success(.created(sessionId: newId)))
        let pid = try #require(home.agents.first?.pid)
        #expect(SystemSignals().isAlive(pid))
        let stop = c.start(.stop(newId))
        await c.waitForSleepers(1)
        // The list of the fake no longer has the session, so the row parks at the next sample,
        // and then Stop ends.
        await c.deps.show(home.agents)
        #expect(await c.result(of: stop) == .success(.done))
        #expect(c.deps.row(newId)?.state == .parked)
        #expect(home.calls.last == "stop 5b0e0001")
        #expect(home.agents.isEmpty)
        #expect(await c.store()?.lastActive.contains(newId) == false)
        #expect(await waitUntil { !SystemSignals().isAlive(pid) })
    }

    // The resume runs in the folder of the row, and the resumed job keeps the row ID.
    @Test func resumeRunsClaudeBgResumeWithTheResumeId() async throws {
        let home = try FakeClaudeHome()
        defer { home.remove() }
        let folder = try home.makeFolder("alpha")
        let c = await CommandHarness(
            all: [Entry.stopped(s1, cwd: folder)], claude: { _ in home.runner() })
        #expect(c.deps.row(s1)?.state == .parked)
        let job = c.start(.resume(s1))
        await c.waitForSleepers(1)
        let entry = try #require(home.agents.first)
        #expect(entry.sessionId == s1 && entry.id == "f3a9c2d1" && entry.isBackground)
        #expect(entry.cwd == home.realPath("alpha"))
        await c.deps.show(home.agents, until: CommandHarness.runs(s1))
        #expect(await c.result(of: job) == .success(.done))
        #expect(home.calls == ["--bg --resume \(s1)"])
        #expect(await c.started() == [s1])
    }

    // Delete of a running session: claude stop, the wait for the end of the session process,
    // claude rm, and then the row leaves the list.
    @Test func deleteRunsStopThenRmAndForgetsTheRow() async throws {
        let home = try FakeClaudeHome()
        defer { home.remove() }
        let folder = try home.makeFolder("alpha")
        try home.setAgents([background(s1, cwd: folder)])
        let c = await CommandHarness(active: home.agents, claude: { _ in home.runner() })
        #expect(c.deps.row(s1)?.state == .idle)
        #expect(await c.run(.remove(s1, confirmed: true, seen: nil)) == .success(.done))
        #expect(home.calls == ["stop f3a9c2d1", "rm f3a9c2d1"])
        #expect(c.calls.all == [.aliveCheck(4242)])
        #expect(c.deps.row(s1) == nil)
        #expect(c.deps.registry.forgotten.contains(s1))
        #expect(home.agents.isEmpty)
    }

    // claude rm keeps a worktree with a commit on no remote, or with changes that are not
    // committed. The Delete of a row with no check of the dialog gives the friendly text, and the
    // row stays.
    @Test(arguments: [
        (
            "fake-rm-kept", ActionRefusal.kept,
            "Claude Code kept this session, because its worktree has commits that exist on no "
                + "remote. Open the worktree to check them, then delete again."
        ),
        (
            "fake-rm-changes", ActionRefusal.uncommitted,
            "This worktree has changes that aren't committed, so Claude Code won't delete it. "
                + "Open the worktree, commit or discard them, then delete again."
        ),
    ])
    func aKeptWorktreeIsRefusedWithItsText(
        output: String, refusal: ActionRefusal, text: String
    ) async throws {
        let home = try FakeClaudeHome()
        defer { home.remove() }
        let worktree = "\(home.path)/repo/.claude/worktrees/w1"
        try home.write(output, worktree + "\n")
        let c = await CommandHarness(
            all: [Entry.stopped(s1, cwd: worktree)], claude: { _ in home.runner() })
        #expect(await c.run(.remove(s1, confirmed: true, seen: nil)) == .failure(refusal))
        #expect(refusal.message == text)
        #expect(home.calls == ["rm f3a9c2d1"])
        #expect(c.deps.row(s1) != nil)
        #expect(!c.actions.isRunning(s1))
    }

    // The terminal process of the row is a stand-in: /bin/sleep with the first argument "claude",
    // so the real process read finds a claude process. Another stand-in is the terminal process
    // of another row. The signals are real, but a signal other than the alive check goes only to
    // the two stand-ins. Take control sends one SIGTERM to the process of its row, waits for its
    // end, and resumes the session with the fake claude, whose session process then runs.
    @Test func takeControlTerminatesOnlyTheFakeSessionProcess() async throws {
        let home = try FakeClaudeHome()
        defer { home.remove() }
        let folder = try home.makeFolder("alpha")
        let project = try home.makeFolder("projects/-alpha")
        try #"{"type":"user","message":{"role":"user","content":"hi"}}"#.appending("\n").write(
            toFile: "\(project)/\(s1).jsonl", atomically: true, encoding: .utf8)
        let terminal = try StandInProcess(name: "claude")
        let other = try StandInProcess(name: "claude")
        try home.setAgents([
            interactive(s1, cwd: folder, pid: terminal.pid),
            interactive(s2, cwd: folder, pid: other.pid),
        ])
        let sent = Recorder<Sent>()
        let standIns = [terminal.pid, other.pid]
        let signals = SystemSignals(
            identity: SystemProcessInspector.identity(of:),
            send: { pid, signal in
                if signal != 0 { sent.record(Sent(pid: pid, signal: signal)) }
                guard signal == 0 || standIns.contains(pid) else { return EPERM }
                return kill(pid, signal) == 0 ? 0 : errno
            }, exit: ProcessExit.wait(for:))
        let c = await CommandHarness(
            active: home.agents, projects: URL(fileURLWithPath: "\(home.path)/projects"),
            claude: { _ in home.runner() }, processes: SystemProcessInspector(), signals: signals)
        let job = c.start(.takeControl(s1, confirmed: true))
        // After the SIGTERM the command waits for the exit event of the stand-in, with no move
        // of the clock. Then the fake resumes the session, and the command waits for its row.
        #expect(await waitUntil { !terminal.alive })
        #expect(await waitUntil { !home.calls.isEmpty })
        await c.waitForSleepers(1)
        await c.deps.show(home.agents) { rows in
            rows.contains { $0.sessionId == s1 && $0.kind == .owned }
        }
        // The resumed session must still run after 3 s.
        await c.waitForSleepers(1)
        c.clock.advance(by: .seconds(3))
        #expect(await c.result(of: job) == .success(.tookControl(sessionId: s1)))
        #expect(sent.values == [Sent(pid: terminal.pid, signal: SIGTERM)])
        #expect(other.alive)
        #expect(home.calls == ["--bg --settings \(settings) --resume \(s1)"])
        let resumed = try #require(home.agents.first { $0.sessionId == s1 })
        #expect(resumed.isBackground && resumed.cwd == home.realPath("alpha"))
        #expect(await c.started() == [s1])
    }

    // The session process of the fake removes its pid file before it ends at its limit, so a
    // later stop or rm of that short ID signals no process that got the pid after it.
    @Test func aFakeSessionThatEndsAtItsLimitLeavesNoPidFile() async throws {
        let home = try FakeClaudeHome()
        defer { home.remove() }
        let folder = try home.makeFolder("alpha")
        try home.write("fake-session-seconds", "1\n")
        let result = await home.runner().run(
            ["--bg", "--settings", settings, "--name", "bifrost-test-n"], directory: folder)
        #expect(result.succeeded)
        let pid = try #require(home.agents.first?.pid)
        #expect(await waitUntil { home.text("fake-session-5b0e0001.pid") == nil })
        #expect(await waitUntil { !SystemSignals().isAlive(pid) })
    }

    // claude rm gets SIGTERM at its limit of 600 s on the clock of the runner. The fake records
    // the signal and ends, and the Delete gives the slow text. The row stays.
    @Test func aTimeoutOfRmGivesTheSlowText() async throws {
        let home = try FakeClaudeHome()
        defer { home.remove() }
        try home.write("fake-rm-hang")
        let c = await CommandHarness(
            all: [Entry.stopped(s1)], claude: { clock in home.runner(clock: clock) })
        let job = c.start(.remove(s1, confirmed: true, seen: nil))
        #expect(await waitUntil { home.text("fake-rm-waiting") != nil })
        // The time limit of the run and the limit of the Delete sleep on the clock.
        await c.waitForSleepers(2)
        #expect(c.clock.nextDeadline == ManualClock.Instant(offset: .seconds(600)))
        c.clock.advance(by: .seconds(600))
        #expect(await c.result(of: job) == .failure(.rmTooSlow))
        #expect(
            ActionRefusal.rmTooSlow.message
                == "Claude Code took too long to delete this session. Check the worktree, then "
                + "delete again.")
        // The fake ended in the trap of its SIGTERM.
        #expect(home.text("fake-rm-signals") == "TERM\n")
        #expect(await waitUntil { !c.actions.isRunning(s1) })
        #expect(home.calls == ["rm f3a9c2d1"])
        #expect(c.deps.row(s1) != nil)
    }
}
