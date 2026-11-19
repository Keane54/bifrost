// The process probe and the signals of the session actions (docs/behaviour/actions.md, "The
// process probe"). The tests read the fake inspector, run a fake git and give a fake stat, a fake
// identity read and a fake kill. Only the real-process tests use a child that the test started.
import BifrostFoundation
import BifrostTestSupport
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import BifrostSessions

private let ok = ExecResult(.exited(0), stdout: "/p\n")

// A stat that records each path and gives one kind.
private final class FakeStat: Sendable {
    private let kind: DirInfo.Kind
    private let recorded = Mutex<[String]>([])

    init(_ kind: DirInfo.Kind) { self.kind = kind }

    var paths: [String] { recorded.withLock { $0 } }

    func read(_ path: String) -> DirInfo.Kind {
        recorded.withLock { $0.append(path) }
        return kind
    }
}

private func probe(
    _ stat: FakeStat = FakeStat(.dir), runner: FakeRunner = FakeRunner(ok),
    inspector: FakeProcessInspector = FakeProcessInspector(), skipRoots: [String] = [],
    environment: [String: String] = ["PATH": "/login"]
) -> ProcessProbe {
    ProcessProbe(
        inspector: inspector, runner: runner, environment: environment, skipRoots: skipRoots,
        fileKind: stat.read)
}

private let startA = ProcessStart(seconds: 1_700_000_000, microseconds: 1)
private let startB = ProcessStart(seconds: 1_700_000_000, microseconds: 2)
private let claudePath = "/Users/x/.local/bin/claude"

// A fake inspector with one process of this command and start time at the PID.
private func inspector(
    _ pid: pid_t, _ command: String = claudePath, started: ProcessStart = startA
) -> FakeProcessInspector {
    let inspector = FakeProcessInspector()
    inspector.identities = [pid: ProcessIdentity(command: command, started: started)]
    return inspector
}

@Suite("the claude process of a PID")
struct ClaudeProcessTests {
    @Test func aClaudeCommandGivesTheProcessWithItsStartTime() async throws {
        let inspector = inspector(4242)
        let process = try #require(await probe(inspector: inspector).claudeProcess(4242))
        #expect(process.pid == 4242 && process.started == startA)
        #expect(inspector.calls == [.identity(4242)])
    }

    // The last path component of the trimmed command must be "claude".
    @Test(arguments: ["claude", " claude \n", "./claude", "/a b/claude"])
    func aCommandThatEndsInClaudeIsClaude(command: String) async {
        #expect(await probe(inspector: inspector(4242, command)).claudeProcess(4242) != nil)
    }

    @Test(arguments: ["/bin/zsh", "claudex", "/x/claude/", "claude-code", "Claude", "", "-zsh"])
    func anotherProgramIsNoClaudeProcess(command: String) async {
        #expect(await probe(inspector: inspector(4242, command)).claudeProcess(4242) == nil)
    }

    @Test func aProcessThatIsGoneIsNoClaudeProcess() async {
        #expect(await probe(inspector: inspector(4242)).claudeProcess(4243) == nil)
    }

    // PID 1 is launchd, PID 0 names the process group of Bifrost, PID -1 all processes of the
    // user, and getpid() is Bifrost itself. With no ClaudeProcess, no signal can go to them.
    @Test(arguments: [pid_t(1), 0, -1, .min, getpid()])
    func aPidThatTheCheckRefusesIsNeverRead(pid: pid_t) async {
        let inspector = inspector(pid)
        #expect(await probe(inspector: inspector).claudeProcess(pid) == nil)
        #expect(inspector.calls == [])
    }

    // The command is argv[0], as `ps -o comm=` gives it, and the start time stays.
    @MainActor
    @Test(.tags(.realProcess))
    func theRealIdentityOfAChildOfTheTestIsItsFirstArgumentAndItsStart() async throws {
        let child = try StandInProcess()
        let inspector = SystemProcessInspector()
        let identity = try #require(await inspector.identity(of: child.pid))
        #expect(identity.command == "/bin/sleep")
        #expect(identity.started.seconds > 0)
        #expect(await inspector.identity(of: child.pid) == identity)
        let real = ProcessProbe(
            inspector: inspector, runner: FakeRunner(ok), environment: [:], skipRoots: [])
        #expect(await real.claudeProcess(child.pid) == nil)
    }
}

@Suite("the folder check")
struct DirInfoTests {
    @Test func aFolderInARepositoryGivesGitFromOneGitRun() async {
        let runner = FakeRunner(ok)
        #expect(await probe(runner: runner).dirInfo("/p") == DirInfo(kind: .dir, git: true))
        let call = FakeRunner.Call(
            file: "git", args: ["-C", "/p", "rev-parse", "--show-toplevel"], timeout: .seconds(2))
        #expect(runner.calls == [call])
        #expect(runner.commands.first?.environment == ["PATH": "/login"])
        #expect(ProcessProbe.timeout == .seconds(2))
    }

    @Test(arguments: [ExecEnd.exited(128), .timedOut, .notStarted])
    func aGitRunThatFailsGivesNoGit(end: ExecEnd) async {
        let runner = FakeRunner(ExecResult(end, stderr: "fatal: not a git repository"))
        #expect(await probe(runner: runner).dirInfo("/p") == DirInfo(kind: .dir, git: false))
    }

    @Test(arguments: [DirInfo.Kind.other, .missing])
    func aFileOrAMissingPathRunsNoGit(kind: DirInfo.Kind) async {
        let stat = FakeStat(kind)
        let runner = FakeRunner(ok)
        #expect(await probe(stat, runner: runner).dirInfo("/f") == DirInfo(kind: kind, git: false))
        #expect(stat.paths == ["/f"])
        #expect(runner.calls == [])
    }

    // The stat of a relative path would read from the folder of the app, and the C string of a
    // path ends at a NUL.
    @Test(arguments: ["p", "", "./p", "~/p", "/p\u{0}x"])
    func aRelativePathOrAPathWithANulIsMissingWithNoRead(path: String) async {
        let stat = FakeStat(.dir)
        let runner = FakeRunner(ok)
        let info = await probe(stat, runner: runner).dirInfo(path)
        #expect(info == DirInfo(kind: .missing, git: false))
        #expect(stat.paths == [])
        #expect(runner.calls == [])
    }

    // A PR session can write the git config of its folder, and git reads that config.
    @Test(arguments: ["/r/reviews", "/r/reviews/pr-1", "/r/reviews/pr-1/src", "/r/reviews/"])
    func noGitRunsUnderASkipRoot(path: String) async {
        let runner = FakeRunner(ok)
        let info = await probe(runner: runner, skipRoots: ["/r/x", "/r/reviews"]).dirInfo(path)
        #expect(info == DirInfo(kind: .dir, git: false))
        #expect(runner.calls == [])
    }

    @Test(arguments: ["/r/reviews-old", "/r", "/r/x2"])
    func aFolderBesideASkipRootRunsGit(path: String) async {
        let runner = FakeRunner(ok)
        let info = await probe(runner: runner, skipRoots: ["/r/x", "/r/reviews"]).dirInfo(path)
        #expect(info == DirInfo(kind: .dir, git: true))
        #expect(runner.calls.count == 1)
    }

    // A link outside a skip root can point into it. The check also compares the real paths.
    @Test func noGitRunsInALinkIntoASkipRoot() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let files = FileManager.default
        let reviews = folder.appending("reviews")
        try files.createDirectory(atPath: "\(reviews)/pr", withIntermediateDirectories: true)
        let outside = folder.appending("outside")
        try files.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let link = folder.appending("outside/link")
        try files.createSymbolicLink(atPath: link, withDestinationPath: "\(reviews)/pr")
        let runner = FakeRunner(ok)
        let real = ProcessProbe(
            inspector: FakeProcessInspector(), runner: runner, environment: [:],
            skipRoots: [reviews])
        #expect(await real.dirInfo(link) == DirInfo(kind: .dir, git: false))
        #expect(runner.calls == [])
        #expect(await real.dirInfo(outside) == DirInfo(kind: .dir, git: true))
        #expect(await real.dirInfo(folder.appending("none")) == DirInfo(kind: .missing, git: false))
        #expect(runner.calls.count == 1)
    }

    // A stat can wait with no end, for example on a network volume that is offline. It holds
    // only its own thread of the blocking executor.
    @Test func theStatRunsOnTheBlockingExecutor() async {
        let labels = Recorder<String>()
        let probe = ProcessProbe(
            inspector: FakeProcessInspector(), runner: FakeRunner(ok), environment: [:],
            skipRoots: []
        ) { _ in
            labels.record(String(cString: __dispatch_queue_get_label(nil)))
            return .dir
        }
        _ = await probe.dirInfo("/p")
        #expect(labels.values == ["bifrost.blocking"])
    }

    @Test func aStatThatHangsGivesMissing() async {
        let clock = ManualClock()
        let gate = TestGate()
        defer { gate.openAll() }
        let runner = FakeRunner(ok)
        let probe = ProcessProbe(
            inspector: FakeProcessInspector(), runner: runner, environment: [:], skipRoots: [],
            clock: clock
        ) { _ in
            gate.passBlocking()
            return .dir
        }
        let info = Task { await probe.dirInfo("/Volumes/offline") }
        await gate.waitUntilHolding()
        await clock.waitForSleepers(1)
        clock.advance(by: ProcessProbe.timeout - .milliseconds(1))
        // The limit sleeps on and the stat waits at the gate, so the check has no result yet.
        #expect(clock.sleeperCount == 1 && gate.holding == 1)
        clock.advance(by: .milliseconds(1))
        #expect(await info.value == DirInfo(kind: .missing, git: false))
        #expect(runner.calls == [])
    }

    // The kind read of a resume runs no git and reads no real path of a skip root.
    @Test(arguments: [DirInfo.Kind.dir, .other, .missing])
    func theKindReadRunsNoGit(kind: DirInfo.Kind) async {
        let stat = FakeStat(kind)
        let runner = FakeRunner(ok)
        let probe = ProcessProbe(
            inspector: FakeProcessInspector(), runner: runner, environment: [:],
            skipRoots: ["/r/reviews"], fileKind: stat.read
        ) { path in
            Issue.record("The kind read read the real path of \(path).")
            return path
        }
        #expect(await probe.kind("/r/reviews/pr-1") == kind)
        #expect(stat.paths == ["/r/reviews/pr-1"])
        #expect(runner.calls == [])
    }

    @Test(arguments: ["p", "", "./p", "/p\u{0}x"])
    func theKindOfARelativePathOrAPathWithANulIsMissingWithNoRead(path: String) async {
        let stat = FakeStat(.dir)
        #expect(await probe(stat).kind(path) == .missing)
        #expect(stat.paths == [])
    }

    // The real paths of the skip-root check run under the same limit as the stat.
    @Test func aRealPathReadThatHangsGivesMissing() async {
        let clock = ManualClock()
        let gate = TestGate()
        defer { gate.openAll() }
        let runner = FakeRunner(ok)
        let probe = ProcessProbe(
            inspector: FakeProcessInspector(), runner: runner, environment: [:],
            skipRoots: ["/r/reviews"], clock: clock, fileKind: { _ in .dir }
        ) { path in
            gate.passBlocking()
            return path
        }
        let info = Task { await probe.dirInfo("/Volumes/offline/p") }
        await gate.waitUntilHolding()
        await clock.waitForSleepers(1)
        clock.advance(by: ProcessProbe.timeout)
        #expect(await info.value == DirInfo(kind: .missing, git: false))
        #expect(runner.calls == [])
    }
}

// A kill that records each call and sends no signal. It gives the error number of its answer.
private final class FakeKill: Sendable {
    struct Sent: Equatable {
        var pid: pid_t
        var signal: Int32
    }

    private let answer: Int32
    private let recorded = Mutex<[Sent]>([])

    init(answer: Int32 = 0) { self.answer = answer }

    var sent: [Sent] { recorded.withLock { $0 } }

    func send(_ pid: pid_t, _ signal: Int32) -> Int32 {
        recorded.withLock { $0.append(Sent(pid: pid, signal: signal)) }
        return answer
    }
}

// An identity read that records each PID and gives one answer.
private final class FakeIdentity: Sendable {
    private let answer: ProcessIdentity?
    private let recorded = Mutex<[pid_t]>([])

    init(_ answer: ProcessIdentity?) { self.answer = answer }

    var reads: [pid_t] { recorded.withLock { $0 } }

    func read(_ pid: pid_t) -> ProcessIdentity? {
        recorded.withLock { $0.append(pid) }
        return answer
    }
}

// The claude process 4242 with the start time A, as the probe gives it.
private func checkedProcess() async throws -> ClaudeProcess {
    try #require(await probe(inspector: inspector(4242)).claudeProcess(4242))
}

private func signals(
    identity: FakeIdentity = FakeIdentity(ProcessIdentity(command: claudePath, started: startA)),
    kill: FakeKill
) -> SystemSignals {
    SystemSignals(identity: identity.read, send: kill.send, exit: { _ in false })
}

@Suite("the signals of the session actions")
struct SystemSignalsTests {
    @Test func terminateReadsTheProcessAgainThenSendsOneSIGTERM() async throws {
        let identity = FakeIdentity(ProcessIdentity(command: claudePath, started: startA))
        let kill = FakeKill()
        try signals(identity: identity, kill: kill).terminate(try await checkedProcess())
        #expect(identity.reads == [4242])
        #expect(kill.sent == [FakeKill.Sent(pid: 4242, signal: SIGTERM)])
    }

    // The system can give the PID to a new process between the check and the signal, and the
    // process can end or start another program.
    @Test(
        arguments: [
            ProcessIdentity(command: claudePath, started: startB),
            ProcessIdentity(command: "/bin/zsh", started: startA), nil,
        ])
    func aProcessThatChangedAfterTheCheckGetsNoSignal(now: ProcessIdentity?) async throws {
        let kill = FakeKill()
        let process = try await checkedProcess()
        #expect(throws: ActionRefusal.notClaudeProcess(pid: 4242)) {
            try signals(identity: FakeIdentity(now), kill: kill).terminate(process)
        }
        #expect(kill.sent == [])
    }

    // ESRCH: the process ended just before the signal, so Take control can go on.
    @Test func aKillThatFindsNoProcessIsNoError() async throws {
        try signals(kill: FakeKill(answer: ESRCH)).terminate(try await checkedProcess())
    }

    @Test(arguments: [EPERM, EINVAL])
    func anotherKillErrorFails(code: Int32) async throws {
        let process = try await checkedProcess()
        #expect(throws: ActionRefusal.signalFailed) {
            try signals(kill: FakeKill(answer: code)).terminate(process)
        }
        let text = "Bifrost couldn't stop the terminal session. Try again."
        #expect(ActionRefusal.signalFailed.message == text)
    }

    // Signal 0 sends no signal: it only checks the process. EPERM: the process exists and is of
    // another user.
    @Test(arguments: [(Int32(0), true), (ESRCH, false), (EPERM, true), (EINVAL, true)])
    func isAliveChecksWithSignalZero(code: Int32, alive: Bool) {
        let kill = FakeKill(answer: code)
        #expect(signals(kill: kill).isAlive(4242) == alive)
        #expect(kill.sent == [FakeKill.Sent(pid: 4242, signal: 0)])
    }

    // Alive is the safe answer: Take control then starts no copy of the session.
    @Test(arguments: [pid_t(1), 0, -1, .min])
    func aPidOfOneOrLessIsAliveWithNoCall(pid: pid_t) {
        let kill = FakeKill(answer: ESRCH)
        #expect(signals(kill: kill).isAlive(pid))
        #expect(kill.sent == [])
        #expect(ActionRefusal.badPid.message == "The process ID of this session isn't valid.")
    }

    // The child runs /bin/sleep with the first argument "claude", so it reads as a claude
    // process. It is the only process that the test signals.
    @MainActor
    @Test(.tags(.realProcess))
    func theRealSignalsTerminateOnlyAChildOfTheTest() async throws {
        let child = try StandInProcess(name: "claude")
        let real = ProcessProbe(
            inspector: SystemProcessInspector(), runner: FakeRunner(ok), environment: [:],
            skipRoots: [])
        let process = try #require(await real.claudeProcess(child.pid))
        let signals = SystemSignals()
        #expect(signals.isAlive(child.pid))
        try signals.terminate(process)
        #expect(await waitUntil { !child.alive })
    }

    // The exit event of the kernel ends the wait when the child ends, with no move of the clock.
    // The test ends its own child only.
    @MainActor
    @Test(.tags(.realProcess))
    func theExitEventEndsTheWaitForTheEndOfARealChild() async throws {
        let child = try StandInProcess()
        let clock = ManualClock()
        let signals = SystemSignals()
        let pid = child.pid
        let wait = Task { await signals.waitForEnd(of: pid, within: .seconds(60), on: clock) }
        await clock.waitForSleepers(1)
        child.stop()
        #expect(await wait.value)
    }

    // A PID with no process ends the wait at once. The watch of the kernel also ends at once for
    // such a PID, with no check of signal 0 first.
    @MainActor
    @Test(.tags(.realProcess))
    func aPidWithNoProcessEndsTheWaitAtOnce() async throws {
        let child = try StandInProcess()
        let pid = child.pid
        child.stop()
        #expect(await SystemSignals().waitForEnd(of: pid, within: .seconds(60), on: ManualClock()))
        #expect(await ProcessExit.wait(for: pid))
    }

    // A process that does not end gives false at the limit on the clock. A PID of 1 or less gives
    // false with no call, the safe answer.
    @Test func aProcessThatDoesNotEndGivesFalseAtTheLimit() async {
        let kill = FakeKill(answer: 0)
        let clock = ManualClock()
        let signals = SystemSignals(
            identity: { _ in nil }, send: kill.send,
            exit: { _ in
                try? await Task.sleep(for: .seconds(3600))
                return false
            })
        let wait = Task { await signals.waitForEnd(of: 4242, within: .seconds(5), on: clock) }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(5))
        #expect(await wait.value == false)
        #expect(kill.sent == [FakeKill.Sent(pid: 4242, signal: 0)])
        for pid in [pid_t(1), 0, -1] {
            #expect(await signals.waitForEnd(of: pid, within: .seconds(5), on: clock) == false)
        }
        #expect(kill.sent.count == 1)
    }

    // A cancel of the caller ends the wait with false.
    @Test func aCancelEndsTheWaitWithFalse() async {
        let clock = ManualClock()
        let signals = SystemSignals(
            identity: { _ in nil }, send: FakeKill(answer: 0).send,
            exit: { _ in
                try? await Task.sleep(for: .seconds(3600))
                return false
            })
        let wait = Task { await signals.waitForEnd(of: 4242, within: .seconds(5), on: clock) }
        await clock.waitForSleepers(1)
        wait.cancel()
        #expect(await wait.value == false)
    }
}
