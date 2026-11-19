import Dispatch
import Foundation
import Synchronization

// MARK: - Commands

// The signal that stops a program at the timeout, at the output limit and at a cancel.
package enum KillSignal: Sendable, Equatable {
    // SIGKILL. A program cannot ignore it, so a hung program cannot stop a poll.
    case kill
    // SIGTERM. The program can stop its work cleanly. Use it only for a command that a SIGKILL
    // can leave half done. The runner waits until the program ends, for at most the grace of the
    // command (Command.terminateGrace). A program that still runs then gets SIGKILL.
    case terminate

    var number: Int32 { self == .kill ? SIGKILL : SIGTERM }
}

// How a command ended.
package enum ExecEnd: Sendable, Hashable {
    // The program ended by itself with this exit code.
    case exited(Int32)
    // The time limit stopped the program. A program that exits with code 0 after the time limit
    // is exited(0): its work is done.
    case timedOut
    // The output went over the limit, so the runner stopped the program.
    case overflow
    // The calling task was cancelled. The runner stopped the program, or did not start it.
    case cancelled
    // The program did not start.
    case notStarted
    // A signal that the runner did not send ended the program.
    case signal(Int32)
}

// One run of a program.
package struct Command: Sendable, Equatable {
    // The default time from a SIGTERM to the SIGKILL of a program that still runs.
    package static let defaultTerminateGrace = Duration.seconds(5)

    // A path, or a name that the runner finds through the PATH of the env.
    package var executable: String
    package var arguments: [String]
    // nil: the current folder of the app.
    package var directory: String?
    // nil: the env of the app.
    package var environment: [String: String]?
    package var timeout: Duration
    package var killSignal: KillSignal
    // With the kill signal terminate: the time from the SIGTERM to a SIGKILL of a program that
    // still runs, on the clock of the runner. nil: no SIGKILL, so the caller must set its own
    // limit of the wait for the end.
    package var terminateGrace: Duration?
    // The limit in bytes, for stdout and for stderr: 1 MiB by default.
    package var outputLimit: Int
    // nil: an empty, closed stdin. claude adds piped stdin to the prompt, so a claude run never
    // gets input.
    package var input: Data?
    // false: after a cancel the result comes at once. true: after a cancel the result comes when
    // the program ended, so the caller knows that the program no longer runs. Such a command
    // needs a kill signal that ends the program: SIGKILL, or SIGTERM with a grace.
    package var waitsForEnd: Bool
    // true: the result also keeps the bytes of stdout as they are (ExecResult.stdoutBytes), for
    // an output that can have bytes that are not UTF-8 text.
    package var keepsStdoutBytes: Bool

    package init(
        _ executable: String, _ arguments: [String] = [], directory: String? = nil,
        environment: [String: String]? = nil, timeout: Duration = .seconds(10),
        killSignal: KillSignal = .kill, terminateGrace: Duration? = Command.defaultTerminateGrace,
        outputLimit: Int = 1_048_576, input: Data? = nil, waitsForEnd: Bool = false,
        keepsStdoutBytes: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
        self.timeout = timeout
        self.killSignal = killSignal
        self.terminateGrace = terminateGrace
        self.outputLimit = outputLimit
        self.input = input
        self.waitsForEnd = waitsForEnd
        self.keepsStdoutBytes = keepsStdoutBytes
    }
}

// The result of a command. The output is UTF-8 text. A byte that is not UTF-8 becomes U+FFFD.
package struct ExecResult: Sendable, Equatable {
    package var end: ExecEnd
    package var stdout: String
    package var stderr: String
    // The bytes of stdout as they are, for a command that keeps them (Command.keepsStdoutBytes).
    // Else nil.
    package var stdoutBytes: Data?

    package init(
        _ end: ExecEnd, stdout: String = "", stderr: String = "", stdoutBytes: Data? = nil
    ) {
        self.end = end
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutBytes = stdoutBytes
    }

    // True when the program ended by itself with code 0.
    package var succeeded: Bool { end == .exited(0) }
}

// Runs a command. A test gives a fake.
package protocol CommandRunner: Sendable {
    func run(_ command: Command) async -> ExecResult
}

extension CommandRunner {
    // The short form for a command with no input, no env and no folder.
    package func run(_ file: String, _ args: [String], timeout: Duration) async -> ExecResult {
        await run(Command(file, args, timeout: timeout))
    }
}

// MARK: - The texts of stderr

// The stderr of a program that a cancel stopped.
let stoppedText = "Bifrost stopped the program."

// The stderr of a program that went over the output limit.
func overLimitText(_ limit: Int) -> String { "The output is over the limit of \(limit) bytes." }

// When a signal ends a program and its stderr is empty, the stderr becomes
// "<program> stopped with signal <n>.". A program that did not start gets the stderr
// "Cannot start <program>: <reason>.". ErrorText makes both texts. The error line of the session
// list shows them.

// MARK: - The real runner

// Runs a real process with Foundation Process. The function never throws: a start error, a
// timeout, the output limit, a cancel and a non-zero exit all give an ExecResult. An empty stderr
// gets the text above for the end.
//
// At the timeout, at the output limit and at a cancel of the calling task, the runner sends the
// kill signal of the command and stops the reads of stdout and stderr. After a cancel, the result
// comes at once, or when the program ended for a command that waits for its end
// (Command.waitsForEnd). In the other cases the result comes when the program ends. A task that
// is cancelled before the start starts no program. A SIGTERM starts the grace of the command on the
// clock: a program that still runs at its end gets SIGKILL, also after a cancel. A program that
// ends within the grace gets no SIGKILL.
//
// The spawn can wait a long time (the endpoint scanner of the Mac checks each exec), so the run
// uses the blocking executor, not a thread of the cooperative pool. The timeout runs on the
// clock of the runner: a test gives a manual clock.
package struct ProcessRunner: CommandRunner {
    private let clock: any Clock<Duration>

    package init() { clock = ContinuousClock() }

    package init(clock: any Clock<Duration>) { self.clock = clock }

    @concurrent package func run(_ command: Command) async -> ExecResult {
        let execution = Execution(command, clock: clock)
        return await withTaskExecutorPreference(BlockingExecutor.shared) {
            await withTaskCancellationHandler {
                await execution.run()
            } onCancel: {
                execution.stop(.cancelled)
            }
        }
    }
}

// How a program ended, from the termination handler.
private enum Termination: Sendable {
    case exit(Int32)
    case signal(Int32)
}

// Why the runner stopped the program. requested: the owner of the run asked for the stop, for
// example ProcessLines after the accepted line; the result comes when the program ended.
enum Stop: Sendable, Equatable {
    case timedOut, overflow, cancelled, requested
}

// The life of the child process.
private enum Child {
    case notStarted
    // The spawn runs. It runs outside the lock, so a cancel or a timeout never waits for it.
    case starting
    // The program runs, so a signal can go to its pid.
    case running(pid_t)
    // The termination handler ran, so no signal goes to the pid after this point. Foundation
    // reaps the child just before it calls that handler. In that very short gap a signal can
    // still go to the pid; the system gives a pid again only much later.
    case ended(Termination)
}

// The two output streams.
private enum Stream: Sendable {
    case stdout, stderr
}

// A reason that stops the start: the error number, and the folder of the run when the folder is
// the problem.
private struct StartProblem: Error {
    var code: Int32
    var folder: String?
}

// One run of a process: the one process core of the app. ProcessRunner and ProcessLines use it.
// The state is in a mutex, because the read handlers, the termination handler, the timer and the
// cancel handler run on other threads. With a stdout hook, each chunk of stdout goes to the hook
// in order, and the result keeps no stdout; the output limit still counts each byte.
final class Execution: Sendable {
    private struct State {
        // The first stop of the runner. A cancel always sets it (see stop).
        var stop: Stop?
        var child = Child.notStarted
        var stdout = Data()
        // The bytes of stdout so far, also the bytes that went to the hook.
        var stdoutCount = 0
        var stderr = Data()
        var openStreams = 2
        var readers: [DispatchIO] = []
        var writer: DispatchIO?
        var waiter: CheckedContinuation<Void, Never>?
        // The grace after the first SIGTERM. The end of the program cancels it.
        var grace: Task<Void, Never>?

        var termination: Termination? {
            if case .ended(let termination) = child { termination } else { nil }
        }
    }

    private let command: Command
    private let clock: any Clock<Duration>
    private let onStdout: (@Sendable (Data) -> Void)?
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "bifrost.process")

    init(
        _ command: Command, clock: any Clock<Duration>,
        onStdout: (@Sendable (Data) -> Void)? = nil
    ) {
        self.command = command
        self.clock = clock
        self.onStdout = onStdout
    }

    // True when the runner stopped the program: a timeout, the output limit, a cancel or a
    // requested stop. False when the program ended by itself.
    var wasStopped: Bool { state.withLock { $0.stop != nil } }

    // MARK: Start and result

    func run() async -> ExecResult {
        if Task.isCancelled { return state.withLock { s in cancelBeforeStart(&s) } }
        let path: String
        switch startPath() {
        case .success(let found): path = found
        case .failure(let problem):
            let text = ErrorText.notStarted(
                command.executable, in: problem.folder, code: problem.code)
            return ExecResult(.notStarted, stderr: text)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = command.arguments
        if let environment = command.environment { process.environment = environment }
        if let directory = command.directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        let output = Pipe()
        let errors = Pipe()
        let input = Pipe()
        let handles = [output, errors, input].flatMap(\.handles)
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        process.terminationHandler = { [self] done in
            ended(
                done.terminationReason == .uncaughtSignal
                    ? .signal(done.terminationStatus) : .exit(done.terminationStatus))
        }
        let cancelled: ExecResult? = state.withLock { s in
            // A cancel before the start starts no program.
            if s.stop == .cancelled || Task.isCancelled { return cancelBeforeStart(&s) }
            s.child = .starting
            return nil
        }
        if let cancelled {
            for handle in handles { try? handle.close() }
            return cancelled
        }
        do {
            try process.run()
        } catch {
            state.withLock { $0.child = .notStarted }
            for handle in handles { try? handle.close() }
            return ExecResult(
                .notStarted, stderr: ErrorText.notStarted(command.executable, error: error))
        }
        let readers = [
            read(output.fileHandleForReading, .stdout), read(errors.fileHandleForReading, .stderr),
        ]
        let writer = write(input.fileHandleForWriting)
        let (stopped, unused) = state.withLock { s in
            // The termination handler can run before this point.
            if case .starting = s.child { s.child = .running(process.processIdentifier) }
            let unused: DispatchIO?
            if case .ended = s.child { unused = writer } else { (s.writer, unused) = (writer, nil) }
            // A stop during the spawn: the signal goes now, and the reads stop.
            guard s.stop != nil else {
                s.readers = readers
                return ([DispatchIO](), unused)
            }
            signal(&s)
            return (readers, unused)
        }
        for reader in stopped { reader.close(flags: .stop) }
        unused?.close(flags: .stop)
        await withDiscardingTaskGroup { group in
            group.addTask { [self, timeout = command.timeout] in
                do {
                    try await clock.sleep(for: timeout)
                } catch {
                    return
                }
                stop(.timedOut)
            }
            await finished()
            group.cancelAll()
        }
        return state.withLock { s in result(s) }
    }

    private func cancelBeforeStart(_ s: inout State) -> ExecResult {
        s.stop = .cancelled
        return result(s)
    }

    // Wait until the program ended and both streams closed, or until a cancel.
    private func finished() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { s in
                if isDone(s) { return true }
                s.waiter = waiter
                return false
            }
            if ready { waiter.resume() }
        }
    }

    // The run is done when the program ended and both streams closed, or at a cancel of a
    // command that does not wait for its end. A stop closes the reads, so the streams close soon
    // after it.
    private func isDone(_ s: State) -> Bool {
        (s.stop == .cancelled && !command.waitsForEnd)
            || (s.termination != nil && s.openStreams == 0)
    }

    // The waiter, when the run is done. The caller resumes it after the lock.
    private func takeWaiterIfDone(_ s: inout State) -> CheckedContinuation<Void, Never>? {
        guard isDone(s), let waiter = s.waiter else { return nil }
        s.waiter = nil
        return waiter
    }

    private func result(_ s: State) -> ExecResult {
        let stdout = String(decoding: s.stdout, as: UTF8.self)
        let stderr = String(decoding: s.stderr, as: UTF8.self)
        let bytes = command.keepsStdoutBytes ? s.stdout : nil
        func make(_ end: ExecEnd, emptyStderr: String = "") -> ExecResult {
            ExecResult(
                end, stdout: stdout, stderr: stderr.isEmpty ? emptyStderr : stderr,
                stdoutBytes: bytes)
        }
        switch (s.stop, s.termination) {
        case (.cancelled, _), (.requested, _):
            return make(.cancelled, emptyStderr: stoppedText)
        case (.overflow, _):
            return make(.overflow, emptyStderr: overLimitText(command.outputLimit))
        case (.timedOut, .exit(let code)):
            // A program that exits with code 0 did its work before the kill signal stopped it.
            return make(code == 0 ? .exited(0) : .timedOut)
        case (.timedOut, _):
            // The signal of the time limit ended the program: the text names the limit.
            return make(
                .timedOut,
                emptyStderr: ErrorText.timedOut(command.executable, limit: command.timeout))
        case (nil, .exit(let code)):
            return make(.exited(code))
        case (nil, .signal(let number)):
            return make(
                .signal(number), emptyStderr: ErrorText.stopped(command.executable, signal: number))
        case (nil, nil):
            // Not reachable: the run waits for the end of the program.
            return make(.notStarted)
        }
    }

    // MARK: Events

    // Send the kill signal to the program, if it runs, and stop the reads. The first stop sets
    // the end, but a cancel always sets it and ends the run at once (when the program ended, for
    // a command that waits for its end). Each later stop sends the signal again. A stop after the
    // end of the run changes nothing. A stop during the spawn sends its signal when the spawn
    // ends (run).
    func stop(_ reason: Stop) {
        let (readers, waiter) = state.withLock { s in
            if isDone(s) { return ([DispatchIO](), CheckedContinuation<Void, Never>?.none) }
            if s.stop == nil || reason == .cancelled { s.stop = reason }
            signal(&s)
            let readers = s.readers
            s.readers = []
            return (readers, takeWaiterIfDone(&s))
        }
        for reader in readers { reader.close(flags: .stop) }
        waiter?.resume()
    }

    // Send the kill signal while the program runs. The caller holds the lock, and the
    // termination handler takes the same lock, so no signal goes after that handler (see
    // Child.ended for the short gap between the reap and the handler). The first SIGTERM starts
    // the grace, which outlives a cancel of the run.
    private func signal(_ s: inout State) {
        guard case .running(let pid) = s.child else { return }
        kill(pid, command.killSignal.number)
        guard command.killSignal == .terminate, s.grace == nil, let grace = command.terminateGrace
        else { return }
        s.grace = Task { [self, clock] in
            do {
                try await clock.sleep(for: grace)
            } catch {
                return
            }
            killAfterGrace()
        }
    }

    // SIGKILL to a program that still runs at the end of the grace of its SIGTERM.
    private func killAfterGrace() {
        state.withLock { s in
            if case .running(let pid) = s.child { kill(pid, SIGKILL) }
        }
    }

    private func ended(_ termination: Termination) {
        let (writer, waiter, grace) = state.withLock { s in
            s.child = .ended(termination)
            let writer = s.writer
            s.writer = nil
            let grace = s.grace
            s.grace = nil
            return (writer, takeWaiterIfDone(&s), grace)
        }
        grace?.cancel()
        writer?.close(flags: .stop)
        waiter?.resume()
    }

    // Keep the bytes up to the output limit, or give the stdout bytes to the hook. The bytes
    // under the limit go to the hook before the stop of an overflow.
    private func received(_ data: DispatchData, from stream: Stream) {
        var bytes = Data(capacity: data.count)
        data.enumerateBytes { buffer, _, _ in bytes.append(buffer) }
        let (overflow, hooked) = state.withLock { s -> (Bool, Data?) in
            // After a stop, the runner keeps no more output.
            guard s.stop == nil else { return (false, nil) }
            let used = stream == .stdout ? s.stdoutCount : s.stderr.count
            let room = command.outputLimit - used
            let kept = bytes.prefix(max(room, 0))
            var hooked: Data?
            switch stream {
            case .stdout:
                s.stdoutCount += kept.count
                if onStdout == nil { s.stdout.append(kept) } else { hooked = Data(kept) }
            case .stderr:
                s.stderr.append(kept)
            }
            return (bytes.count > room, hooked)
        }
        // The read handlers run on one serial queue, so the chunks reach the hook in order.
        if let hooked, !hooked.isEmpty { onStdout?(hooked) }
        if overflow { stop(.overflow) }
    }

    private func streamClosed() {
        let waiter = state.withLock { s in
            s.openStreams -= 1
            return takeWaiterIfDone(&s)
        }
        waiter?.resume()
    }

    // MARK: Pipes

    // Read a stream in chunks until its end or a stop. The channel closes the handle at the end.
    private func read(_ handle: FileHandle, _ stream: Stream) -> DispatchIO {
        let channel = DispatchIO(
            type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue,
            cleanupHandler: { _ in try? handle.close() })
        channel.setLimit(lowWater: 1)
        channel.read(offset: 0, length: Int.max, queue: queue) { [self] done, data, _ in
            if let data, !data.isEmpty { received(data, from: stream) }
            if done {
                channel.close()
                streamClosed()
            }
        }
        return channel
    }

    // Write the input to stdin, then close it. With no input, close stdin at once. A program that
    // ends before it reads its input makes the write fail with EPIPE. F_SETNOSIGPIPE makes that
    // an error of the write, not a SIGPIPE that stops the app. The result of the program is the
    // result, so this error has no other effect.
    private func write(_ handle: FileHandle) -> DispatchIO? {
        guard let input = command.input, !input.isEmpty else {
            try? handle.close()
            return nil
        }
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        let channel = DispatchIO(
            type: .stream, fileDescriptor: handle.fileDescriptor, queue: queue,
            cleanupHandler: { _ in try? handle.close() })
        let data = input.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: data, queue: queue) { done, _, _ in
            if done { channel.close() }
        }
        return channel
    }

    // MARK: The start checks

    // The path of the program, or the error number that the start of the child process gives.
    // A name with no slash is found through the PATH of the env (ProgramLookup). With no PATH,
    // the search uses /usr/bin:/bin, as execvp does.
    private func startPath() -> Result<String, StartProblem> {
        if let directory = command.directory {
            var info = stat()
            if stat(directory, &info) != 0 {
                return .failure(StartProblem(code: errno, folder: directory))
            }
            if info.st_mode & S_IFMT != S_IFDIR {
                return .failure(StartProblem(code: ENOTDIR, folder: directory))
            }
        }
        var path = command.executable
        if !path.contains("/") {
            let environment = command.environment ?? ProcessInfo.processInfo.environment
            let search = environment["PATH"] ?? "/usr/bin:/bin"
            guard let found = ProgramLookup.find(path, path: search)
            else { return .failure(StartProblem(code: ENOENT)) }
            path = found
        }
        var info = stat()
        if stat(path, &info) != 0 { return .failure(StartProblem(code: errno)) }
        if info.st_mode & S_IFMT != S_IFREG { return .failure(StartProblem(code: EACCES)) }
        if access(path, X_OK) != 0 { return .failure(StartProblem(code: errno)) }
        return .success(path)
    }
}

extension Pipe {
    fileprivate var handles: [FileHandle] { [fileHandleForReading, fileHandleForWriting] }
}

// MARK: - The program lookup

// The one lookup of a program name in a PATH text (docs/behaviour/process.md). The process runner
// and the claude locator use it.
package enum ProgramLookup {
    // The first folder of the PATH text that holds a runnable file with this name. Only an
    // absolute folder counts: an empty or a relative folder is skipped, so the result never
    // depends on the current folder of the app. isRunnable checks each candidate; a test can
    // give its own check. nil when no folder holds one.
    package static func find(
        _ name: String, path: String, isRunnable: (String) -> Bool = isRunnable
    ) -> String? {
        for folder in path.split(separator: ":") where folder.hasPrefix("/") {
            let candidate = folder.hasSuffix("/") ? "\(folder)\(name)" : "\(folder)/\(name)"
            if isRunnable(candidate) { return candidate }
        }
        return nil
    }

    // True when the path is a regular file (after links) that the user can run. A folder is not
    // runnable.
    package static func isRunnable(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            && access(path, X_OK) == 0
    }
}
