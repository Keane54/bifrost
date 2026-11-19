// The process reads, the folder check and the signals of the session actions
// (docs/behaviour/actions.md, "The process probe"). The probe never sends a signal. The signals
// go only to a ClaudeProcess, and only the probe makes one.
import BifrostFoundation
import Darwin
import Dispatch
import Synchronization

// A process that the probe found to be claude: a PID above 1 that is not Bifrost itself, with a
// command whose last path component is "claude", and the start time of that process. It is the
// only value that SystemSignals.terminate takes, so no signal goes to a PID with no check.
package struct ClaudeProcess: Sendable, Equatable {
    package let pid: pid_t
    package let started: ProcessStart

    fileprivate init(pid: pid_t, started: ProcessStart) {
        self.pid = pid
        self.started = started
    }

    // A PID that a check can accept. PID 1 is launchd, PID 0 signals the process group of
    // Bifrost, PID -1 signals each process of the user, and getpid() is Bifrost itself.
    fileprivate static func isSignallable(_ pid: pid_t) -> Bool {
        pid > 1 && pid != getpid()
    }

    // The same process, when the identity has the start time of the check and is still claude.
    fileprivate func matches(_ identity: ProcessIdentity?) -> Bool {
        guard let identity else { return false }
        return identity.started == started && identity.isClaude
    }
}

// The claude process of a PID and the check of a folder.
package struct ProcessProbe: Sendable {
    // The time limit of the reads and of the git run of a folder check.
    package static let timeout = Duration.seconds(2)

    private let inspector: any ProcessInspector
    private let runner: any CommandRunner
    private let environment: [String: String]
    private let skipRoots: SkipRoots
    private let clock: any Clock<Duration>
    private let fileKind: @Sendable (String) -> DirInfo.Kind
    private let realPath: @Sendable (String) -> String?

    // environment is the env of git: the env of the claude runs, so git is the git of the login
    // PATH. skipRoots are the folders in which the check runs no git (SkipRoots). A test gives a
    // manual clock, a fake stat (fileKind) and a fake real path.
    package init(
        inspector: any ProcessInspector, runner: any CommandRunner,
        environment: [String: String], skipRoots: [String],
        clock: any Clock<Duration> = ContinuousClock(),
        fileKind: @escaping @Sendable (String) -> DirInfo.Kind = ProcessProbe.fileKind,
        realPath: @escaping @Sendable (String) -> String? = RealPath.of
    ) {
        self.inspector = inspector
        self.runner = runner
        self.environment = environment
        self.skipRoots = SkipRoots(skipRoots)
        self.clock = clock
        self.fileKind = fileKind
        self.realPath = realPath
    }

    // The process of the PID when it is a claude process, with its start time. nil for a PID of
    // 1 or less, for Bifrost itself, for a process that does not exist and for another program.
    // A PID that the check refuses gets no read.
    package func claudeProcess(_ pid: pid_t) async -> ClaudeProcess? {
        guard ClaudeProcess.isSignallable(pid), let identity = await inspector.identity(of: pid),
            identity.isClaude
        else { return nil }
        return ClaudeProcess(pid: pid, started: identity.started)
    }

    // What is at the path, and for a folder, whether it is in a git repository. A relative path
    // and a path with a NUL are missing, with no read. The reads of the path (the stat and the
    // real paths of the skip roots) must end in timeout, else the path is missing, for example
    // on a network volume that is offline. A folder under a skip root gives git false with no
    // git run.
    package func dirInfo(_ path: String) async -> DirInfo {
        guard Self.isReadable(path) else { return DirInfo(kind: .missing, git: false) }
        let read = await readWithinTheLimit(path, skipRootCheck: true)
        guard read.kind == .dir else { return DirInfo(kind: read.kind, git: false) }
        if read.underSkipRoot { return DirInfo(kind: .dir, git: false) }
        let result = await runner.run(
            Command(
                "git", ["-C", path, "rev-parse", "--show-toplevel"], environment: environment,
                timeout: Self.timeout))
        return DirInfo(kind: .dir, git: result.succeeded)
    }

    // What is at the path, with the reads and the time limit of dirInfo, but with no git run and
    // no read of the skip roots. A relative path and a path with a NUL are missing, with no read.
    package func kind(_ path: String) async -> DirInfo.Kind {
        guard Self.isReadable(path) else { return .missing }
        return await readWithinTheLimit(path, skipRootCheck: false).kind
    }

    // An absolute path with no NUL. Only such a path gets a read.
    private static func isReadable(_ path: String) -> Bool {
        path.unicodeScalars.first == "/" && !path.unicodeScalars.contains("\0")
    }

    // The kind of the path from stat, which follows a link. Each error gives missing.
    package static func fileKind(_ path: String) -> DirInfo.Kind {
        var info = stat()
        guard stat(path, &info) == 0 else { return .missing }
        return info.st_mode & S_IFMT == S_IFDIR ? .dir : .other
    }

    // The result of the reads of a path.
    private struct FolderRead: Sendable {
        var kind: DirInfo.Kind
        var underSkipRoot = false
    }

    // The reads run in one task on the blocking executor and race the limit
    // (BlockingExecutor.run(within:)). A read that does not end in the limit, and a cancel of
    // the caller, give missing.
    // skipRootCheck false: no read of the real paths of the skip roots.
    private func readWithinTheLimit(_ path: String, skipRootCheck: Bool) async -> FolderRead {
        let missing = FolderRead(kind: .missing)
        return await BlockingExecutor.run(within: Self.timeout, on: clock, else: missing) {
            [fileKind, realPath, skipRoots] in
            let kind = fileKind(path)
            guard kind == .dir, skipRootCheck else { return FolderRead(kind: kind) }
            let under = await skipRoots.contains(path) { realPath($0) }
            return FolderRead(kind: .dir, underSkipRoot: under)
        }
    }
}

// The signals of the session actions: SIGTERM to a ClaudeProcess, the check whether a PID is
// alive, and the wait for the end of a process. A test gives a fake identity read, a fake send,
// which records each call and sends no signal, and a fake exit event.
package struct SystemSignals: Sendable {
    // The identity of the PID now. It is synchronous, so the kill comes straight after it.
    private let identity: @Sendable (pid_t) -> ProcessIdentity?
    // Send the signal to the PID. The result is 0, or the error number of the call.
    private let send: @Sendable (pid_t, Int32) -> Int32
    // Return true when the kernel reports the end of the process with the PID, or false at a
    // cancel.
    private let exit: @Sendable (pid_t) async -> Bool

    package init() {
        identity = SystemProcessInspector.identity(of:)
        send = { pid, signal in kill(pid, signal) == 0 ? 0 : errno }
        exit = ProcessExit.wait(for:)
    }

    package init(
        identity: @escaping @Sendable (pid_t) -> ProcessIdentity?,
        send: @escaping @Sendable (pid_t, Int32) -> Int32,
        exit: @escaping @Sendable (pid_t) async -> Bool
    ) {
        self.identity = identity
        self.send = send
        self.exit = exit
    }

    // Read the identity of the PID again, then send SIGTERM at once. A process that is gone, that
    // has another start time (the system gave the PID to a new process) or that is no longer
    // claude gets no signal. ESRCH from the kill means that the process ended just before it,
    // which is no error. Another error of the kill throws signalFailed.
    package func terminate(_ process: ClaudeProcess) throws(ActionRefusal) {
        let pid = process.pid
        guard ClaudeProcess.isSignallable(pid) else { throw .badPid }
        guard process.matches(identity(pid)) else { throw .notClaudeProcess(pid: pid) }
        switch send(pid, SIGTERM) {
        case 0, ESRCH: return
        default: throw .signalFailed
        }
    }

    // True while a process has the PID. Signal 0 sends no signal: it only checks the process.
    // Only ESRCH (no such process) gives false. EPERM means that the process exists and is of
    // another user, and another error also gives true. A PID of 1 or less gives true with no
    // call: true is the safe answer, because Take control then starts no copy of the session.
    package func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return true }
        return send(pid, 0) != ESRCH
    }

    // True when the process with the PID ends within the limit on the clock. A process that is
    // already gone gives true at once. Else the wait follows the exit event of the kernel, so
    // no poll runs. A PID of 1 or less gives false with no call, the safe answer of isAlive. A
    // cancel of the caller gives false.
    package func waitForEnd(
        of pid: pid_t, within limit: Duration, on clock: any Clock<Duration>
    ) async -> Bool {
        guard pid > 1 else { return false }
        if !isAlive(pid) { return true }
        let exit = self.exit
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await exit(pid) }
            group.addTask {
                _ = try? await clock.sleep(for: limit)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

// The exit event of the kernel for one process: a process source of Dispatch (EVFILT_PROC with
// NOTE_EXIT). The source works for each process of the user, not only for a child of the app.
// The event comes when the process ends, also before its parent reaps it, and for a process that
// ended before the source started.
package enum ProcessExit {
    // Return true when the process with the PID ends, or false at a cancel. Dispatch gives the
    // event also for a PID with no process, but its documentation does not promise it. So a check
    // with signal 0 after the registration of the source gives true for a PID with no process.
    @concurrent package static func wait(for pid: pid_t) async -> Bool {
        let watch = ExitWatch(pid)
        return await withTaskCancellationHandler {
            await watch.result()
        } onCancel: {
            watch.finish(false)
        }
    }
}

// One process source and the one caller that waits for its result.
private final class ExitWatch: Sendable {
    private enum State {
        case waiting(CheckedContinuation<Bool, Never>?)
        case done(Bool)
    }

    private let source: any DispatchSourceProcess
    private let state = Mutex(State.waiting(nil))

    init(_ pid: pid_t) {
        source = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        // The handlers keep the watch until the source is cancelled (finish).
        source.setEventHandler { [self] in finish(true) }
        source.setRegistrationHandler { [self] in
            if kill(pid, 0) != 0 && errno == ESRCH { finish(true) }
        }
        source.activate()
    }

    // The result of the watch. It waits until finish gives it.
    func result() async -> Bool {
        await withCheckedContinuation { waiter in
            let now: Bool? = state.withLock { s in
                switch s {
                case .done(let ended): return ended
                case .waiting:
                    s = .waiting(waiter)
                    return nil
                }
            }
            if let now { waiter.resume(returning: now) }
        }
    }

    // The first result counts. The source stops, and the caller that waits gets the result.
    func finish(_ ended: Bool) {
        let waiter: CheckedContinuation<Bool, Never>?? = state.withLock { s in
            guard case .waiting(let waiter) = s else { return nil }
            s = .done(ended)
            return .some(waiter)
        }
        guard let waiter else { return }
        source.cancel()
        waiter?.resume(returning: ended)
    }
}
