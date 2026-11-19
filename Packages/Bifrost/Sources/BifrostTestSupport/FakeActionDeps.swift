import BifrostFoundation
import BifrostSessions
import Darwin
import Foundation
import Synchronization
import Testing

// The dependencies of the session commands (SessionActions) for a test. The registry service is
// real, on fake session lists and a manual clock. claude, git, the folder reads, the process reads
// and the signals are fakes that record each call in order. No test with these deps runs a
// program, reads a real folder other than its projects folder, or signals a process, unless it
// gives its own claude runner, process reads or signals to makeActions.
//
// The loops of the registry wait one day or more, so a move of the clock by the limits of the
// commands wakes none of them. poll() makes the registry read the lists at once.
@MainActor
package final class FakeActionDeps {
    // The path of the fake claude. No file is at this path.
    package static let claudePath = "/nonexistent-bifrost-test/bin/claude"

    package let clock = ManualClock()
    package let lists: FakeSessionLists
    package let registry: RegistryService
    package let calls = FakeActionCalls()
    // The process reads of the probe and of the signals. A PID with no identity is a process that
    // does not exist.
    package let inspector = FakeProcessInspector()
    package let log = Recorder<SessionsLogEvent>()
    // False: Bifrost finds no claude.
    package var claudeFound = true

    // store: the store of the registry at the start. active and all: the first lists.
    package init(
        store: RegistryStore = RegistryStore(), active: [AgentEntry] = [], all: [AgentEntry] = []
    ) {
        lists = FakeSessionLists(active: active, all: all)
        var timing = RegistryTiming()
        timing.active = .seconds(86_400)
        timing.all = .seconds(2 * 86_400)
        timing.branch = .seconds(3 * 86_400)
        timing.tick = .seconds(4 * 86_400)
        registry = RegistryService(
            registry: SessionRegistry(store: store, escalation: .seconds(600)), deps: lists,
            clock: clock, now: SteadyWallClock().next, timing: timing, log: log)
    }

    isolated deinit {
        registry.stop()
        calls.openAll()
        lists.releaseActive()
    }

    // The session commands on these deps. claude: a claude runner of the test, for example one
    // that runs a script in the sandbox; nil gives the fake claude, which runs no program.
    // projects: the projects folder of the transcript check, for example a temporary folder; nil
    // gives a path where no folder is. processes and signals: the process reads of the probe and
    // the signals in place of the fakes, for a test of a process that the test started; nil gives
    // the fakes.
    package func makeActions(
        claude real: ClaudeRunner? = nil, projects: URL? = nil,
        processes: (any ProcessInspector)? = nil, signals realSignals: SystemSignals? = nil
    ) -> SessionActions {
        let calls = self.calls
        let inspector = self.inspector
        let runner = FakeActionRunner(calls: calls)
        // The probe keeps the real clock on purpose: its folder reads end at once, so its time
        // limit never acts, and the limit sleeps no sleeper of the manual clock that a test counts.
        let probe = ProcessProbe(
            inspector: processes ?? inspector, runner: runner, environment: [:], skipRoots: [],
            fileKind: { calls.folderRead($0) }, realPath: { $0 })
        let signals =
            realSignals
            ?? SystemSignals(
                identity: { calls.identityAtSignal($0) ?? inspector.identities[$0] },
                send: { calls.send($0, $1) }, exit: { await calls.exit($0) })
        let worktrees = WorktreeChecker(
            runner: runner, environment: [:], skipRoots: [], clock: clock, realPath: { $0 })
        let claude =
            real ?? ClaudeRunner(path: Self.claudePath, baseEnvironment: [:], runner: runner)
        return SessionActions(
            claude: { [weak self] in self?.claudeFound == true ? claude : nil },
            registry: registry, probe: probe, signals: signals, worktrees: worktrees,
            projects: projects
                ?? URL(filePath: "/nonexistent-bifrost-test/projects", directoryHint: .isDirectory),
            clock: clock, log: log)
    }

    // The fake claude of these deps, which runs no program: each run is a call of calls.
    package func claudeRunner() -> ClaudeRunner {
        ClaudeRunner(
            path: Self.claudePath, baseEnvironment: [:], runner: FakeActionRunner(calls: calls))
    }

    // Start the registry. The first active list and the first --all list give the first rows.
    // Then one more active list shows that the rows of the --all list are not active, as the next
    // poll of the app does (ActiveListing). With confirmAll false, that list does not come, so
    // the new rows of the --all list stay unconfirmed. The start ends when each loop of the
    // registry waits on the clock.
    package func start(confirmAll: Bool = true) async {
        registry.start()
        await clock.waitForSleepers(4)
        if confirmAll { await poll() }
        await clock.waitForSleepers(exactly: 4)
    }

    // The row of the registry now.
    package func row(_ sessionId: String) -> SessionRow? {
        registry.rows.first { $0.sessionId == sessionId }
    }

    // Make the registry read the active list now, as a window that shows does. The wait ends
    // when the read started: a test waits for the rows that it expects.
    package func poll() async {
        let before = lists.activeCalls
        registry.setWindowVisible(false)
        registry.setWindowVisible(true)
        await waitUntil { lists.activeCalls > before }
    }

    // Give the registry this active list, and wait until the rows meet the condition. With no
    // condition, the wait ends when the read started: a job that waits for a row then gives the
    // end.
    package func show(
        _ active: [AgentEntry], until condition: ([SessionRow]) -> Bool = { _ in true }
    ) async {
        lists.active = active
        await poll()
        await waitUntil { condition(registry.rows) }
    }
}

// A wall clock for the registry that goes 1 ms forward at each read. So two samples never have
// the same time.
private final class SteadyWallClock: Sendable {
    private let reads = Mutex(0)

    func next() -> Date {
        let count = reads.withLock { value in
            value += 1
            return value
        }
        return Date(timeIntervalSince1970: 1_800_000_000 + Double(count) / 1000)
    }
}

// The session lists of the registry. The test sets the entries. The --all list counts only when
// it has entries. A save does nothing and is kept. A test can make the active list fail, or hold
// each read of it until the release.
package final class FakeSessionLists: RegistryServiceDeps {
    private struct State {
        var active: [AgentEntry]
        var all: [AgentEntry]
        var activeFailure: AgentListError?
        var holdActive = false
        var heldReads: [CheckedContinuation<Void, Never>] = []
        var activeCalls = 0
        var saves: [RegistryStore] = []
    }

    private let state: Mutex<State>

    package init(active: [AgentEntry], all: [AgentEntry]) {
        state = Mutex(State(active: active, all: all))
    }

    package var active: [AgentEntry] {
        get { state.withLock { $0.active } }
        set { state.withLock { $0.active = newValue } }
    }

    package var all: [AgentEntry] {
        get { state.withLock { $0.all } }
        set { state.withLock { $0.all = newValue } }
    }

    // The reason of each later failed read of the active list, or nil for a list.
    package var activeFailure: AgentListError? {
        get { state.withLock { $0.activeFailure } }
        set { state.withLock { $0.activeFailure = newValue } }
    }

    // The number of the reads of the active list. A held read counts from its start.
    package var activeCalls: Int { state.withLock { $0.activeCalls } }

    // The reads of the active list that wait for the release.
    package var heldReads: Int { state.withLock { $0.heldReads.count } }

    // Hold each later read of the active list until releaseActive().
    package func holdActive() {
        state.withLock { $0.holdActive = true }
    }

    // End the hold. The reads that wait continue.
    package func releaseActive() {
        let waiting = state.withLock { s in
            s.holdActive = false
            defer { s.heldReads = [] }
            return s.heldReads
        }
        for read in waiting { read.resume() }
    }

    // Each store that the registry saved, in order.
    package var saves: [RegistryStore] { state.withLock { $0.saves } }

    package func listActive() async throws -> AgentList {
        let held = state.withLock { s in
            s.activeCalls += 1
            return s.holdActive
        }
        if held {
            await withCheckedContinuation { read in
                let wait = state.withLock { s in
                    if s.holdActive { s.heldReads.append(read) }
                    return s.holdActive
                }
                if !wait { read.resume() }
            }
        }
        return state.withLock { s in
            s.activeFailure.map(AgentList.failed) ?? AgentList(entries: s.active)
        }
    }

    package func listAll() async throws -> AgentList { AgentList(entries: all) }
    package func readBranch(_ cwd: String) async throws -> String? { nil }
    package func readTerminalApps(_ pids: [pid_t]) async -> TerminalApps { TerminalApps() }
    package func readAttachClients() async -> [AttachClient] { [] }

    package func saveStore(_ store: RegistryStore) async throws {
        state.withLock { $0.saves.append(store) }
    }
}

// The calls of the fakes of the session commands, and their answers.
package final class FakeActionCalls: Sendable {
    // One call, in order.
    package enum Call: Sendable, Equatable {
        // A read of what is at a path: the folder check.
        case folderRead(String)
        // A run of claude, with the time from a SIGTERM to its SIGKILL. nil: no SIGKILL.
        case claude(
            [String], directory: String?, timeout: Duration, killSignal: KillSignal,
            terminateGrace: Duration? = Command.defaultTerminateGrace)
        // A cancel of a claude run, with its arguments. The real runner then sends the kill signal
        // of the command to the program.
        case claudeCancelled([String])
        // A run of git.
        case git([String])
        // A signal to a PID. No signal goes to a process.
        case signal(pid_t, Int32)
        // The check whether a process has the PID (signal 0). No call goes to the system.
        case aliveCheck(pid_t)
        // The start of a wait for the exit event of the PID. No call goes to the system.
        case exitWatch(pid_t)
    }

    // A wait for the exit event of a PID.
    private struct ExitWaiter {
        let id: Int
        let pid: pid_t
        let resume: CheckedContinuation<Bool, Never>
    }

    private struct State {
        var calls: [Call] = []
        var claude: @Sendable ([String]) -> ExecResult = { _ in ExecResult(.exited(0)) }
        // The answer of git, or nil for the default answer.
        var git: (@Sendable ([String]) -> ExecResult)?
        // True for a PID that a process has now. With no answer, no process has a PID.
        var alive: @Sendable (pid_t) -> Bool = { _ in false }
        // The waits for an exit event, and the IDs of the waits that a cancel ended first.
        var exitWaiters: [ExitWaiter] = []
        var cancelledExits: Set<Int> = []
        var lastExit = 0
        // The error number of each signal other than 0.
        var signalResult: Int32 = 0
        // The identities that the read just before a kill gives, or nil for the identities of
        // the inspector.
        var identitiesAtSignal: [pid_t: ProcessIdentity]?
        // The kind of each path. Another path is a folder.
        var kinds: [String: DirInfo.Kind] = [:]
        // The folders that are not in a git repository.
        var noGit: Set<String> = []
        // The gate of the claude runs, or nil.
        var gate: TestGate?
        // The gate of the folder reads, or nil.
        var folderGate: TestGate?
        // The gate of the git runs, or nil.
        var gitGate: TestGate?
    }

    private let state = Mutex(State())

    package init() {}

    // Each call, in order.
    package var all: [Call] { state.withLock { $0.calls } }

    // The arguments of each claude run, in order.
    package var claudeRuns: [[String]] {
        all.compactMap { call in
            if case .claude(let args, _, _, _, _) = call { args } else { nil }
        }
    }

    // Each signal other than 0, in order.
    package var signals: [Call] {
        all.filter { if case .signal = $0 { true } else { false } }
    }

    // The answer of each later claude run, from its arguments.
    package func answerClaude(_ answer: @escaping @Sendable ([String]) -> ExecResult) {
        state.withLock { $0.claude = answer }
    }

    // The answer of each later git run, from its arguments. With no answer, git ends with exit
    // code 0 and no output, or with code 128 in a folder of setNoGit.
    package func answerGit(_ answer: @escaping @Sendable ([String]) -> ExecResult) {
        state.withLock { $0.git = answer }
    }

    // Which PIDs a process has now, for each later alive check. A wait for the exit event of a
    // PID that the answer has no process for ends at once, as the exit event of the kernel does.
    package func answerAlive(_ answer: @escaping @Sendable (pid_t) -> Bool) {
        let ended = state.withLock { s in
            s.alive = answer
            let ended = s.exitWaiters.filter { !answer($0.pid) }
            s.exitWaiters.removeAll { !answer($0.pid) }
            return ended
        }
        for waiter in ended { waiter.resume.resume(returning: true) }
    }

    // The exit event of SystemSignals: true when the alive answer has no process for the PID,
    // now or after a later answerAlive, and false at a cancel.
    func exit(_ pid: pid_t) async -> Bool {
        let id = state.withLock { s in
            s.calls.append(.exitWatch(pid))
            s.lastExit += 1
            return s.lastExit
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { resume in
                let now: Bool? = state.withLock { s in
                    if s.cancelledExits.remove(id) != nil { return false }
                    if !s.alive(pid) { return true }
                    s.exitWaiters.append(ExitWaiter(id: id, pid: pid, resume: resume))
                    return nil
                }
                if let now { resume.resume(returning: now) }
            }
        } onCancel: {
            let waiter = state.withLock { s -> ExitWaiter? in
                guard let index = s.exitWaiters.firstIndex(where: { $0.id == id }) else {
                    s.cancelledExits.insert(id)
                    return nil
                }
                return s.exitWaiters.remove(at: index)
            }
            waiter?.resume.resume(returning: false)
        }
    }

    // The error number of each later signal other than 0: 0 for a sent signal, or for example
    // ESRCH or EPERM.
    package func answerSignals(_ code: Int32) {
        state.withLock { $0.signalResult = code }
    }

    // The identities that the read just before each later kill gives, in the place of the
    // identities of the inspector: a process that ended or changed after the check. A PID that
    // the map does not have is a process that does not exist.
    package func answerIdentitiesAtSignal(_ identities: [pid_t: ProcessIdentity]) {
        state.withLock { $0.identitiesAtSignal = identities }
    }

    // The answer of the read just before a kill, when the test set one: nil means the identity
    // of the inspector.
    func identityAtSignal(_ pid: pid_t) -> ProcessIdentity?? {
        state.withLock { s in s.identitiesAtSignal.map { $0[pid] } }
    }

    // What is at the path. nil: a folder.
    package func setKind(_ kind: DirInfo.Kind, at path: String) {
        state.withLock { $0.kinds[path] = kind }
    }

    // The folder is not in a git repository.
    package func setNoGit(_ path: String) {
        state.withLock { _ = $0.noGit.insert(path) }
    }

    // Each later claude run waits at the gate.
    package func hold(_ gate: TestGate) {
        state.withLock { $0.gate = gate }
    }

    // Each later folder read waits at the gate, as a slow volume does. The read runs on the
    // blocking executor, so it waits with passBlocking.
    package func holdFolderReads(_ gate: TestGate) {
        state.withLock { $0.folderGate = gate }
    }

    // Each later git run waits at the gate, as a slow repository does.
    package func holdGit(_ gate: TestGate) {
        state.withLock { $0.gitGate = gate }
    }

    // Let each held claude run, each held folder read and each held git run go.
    package func openAll() {
        let gates = state.withLock { [$0.gate, $0.folderGate, $0.gitGate] }
        for gate in gates { gate?.openAll() }
    }

    package func record(_ call: Call) {
        state.withLock { $0.calls.append(call) }
    }

    // A signal of SystemSignals. Signal 0 is the alive check: 0 for a PID that a process has, else
    // ESRCH.
    func send(_ pid: pid_t, _ signal: Int32) -> Int32 {
        let (alive, result) = state.withLock { s in
            s.calls.append(signal == 0 ? .aliveCheck(pid) : .signal(pid, signal))
            return (s.alive, s.signalResult)
        }
        if signal == 0 { return alive(pid) ? 0 : ESRCH }
        return result
    }

    func folderRead(_ path: String) -> DirInfo.Kind {
        let (gate, kind) = state.withLock { s in
            s.calls.append(.folderRead(path))
            return (s.folderGate, s.kinds[path] ?? .dir)
        }
        gate?.passBlocking()
        return kind
    }

    // Record the command, and give its gate and its answer. The answer of claude runs after the
    // lock, so it can read the calls.
    func run(_ command: Command) -> (TestGate?, ExecResult) {
        typealias Answer = @Sendable ([String]) -> ExecResult
        let (gate, answer) = state.withLock { s -> (TestGate?, Answer) in
            if command.executable == "git" {
                s.calls.append(.git(command.arguments))
                if let git = s.git { return (s.gitGate, git) }
                let path = command.arguments.count > 1 ? command.arguments[1] : ""
                let end = s.noGit.contains(path) ? ExecEnd.exited(128) : .exited(0)
                return (s.gitGate, { _ in ExecResult(end) })
            }
            s.calls.append(
                .claude(
                    command.arguments, directory: command.directory, timeout: command.timeout,
                    killSignal: command.killSignal, terminateGrace: command.terminateGrace))
            return (s.gate, s.claude)
        }
        return (gate, answer(command.arguments))
    }
}

// The runner of claude and git for the session commands. It runs no program.
private struct FakeActionRunner: CommandRunner {
    let calls: FakeActionCalls

    func run(_ command: Command) async -> ExecResult {
        let (gate, result) = calls.run(command)
        await withTaskCancellationHandler {
            await gate?.pass()
        } onCancel: { [calls] in
            if command.executable != "git" { calls.record(.claudeCancelled(command.arguments)) }
        }
        if Task.isCancelled { return ExecResult(.cancelled) }
        return result
    }
}
