import Darwin
import Foundation

// One line the host wrote on stdout, with the moment the check app saw it and its place among
// every line the host wrote. A line that isn't JSON keeps its text, so the report can show it.
struct HostLine {
    let json: JSON?
    let text: String
    let at: ContinuousClock.Instant
    let index: Int

    init(_ bytes: ArraySlice<UInt8>, at: ContinuousClock.Instant, index: Int) {
        let data = Data(bytes)
        json = try? JSONDecoder().decode(JSON.self, from: data)
        text = String(decoding: data, as: UTF8.self)
        self.at = at
        self.index = index
    }

    var type: String? { json?["type"]?.string }

    // The text of a log line, which is how the module's console calls reach the check app.
    var logText: String { json?["text"]?.string ?? "" }
}

// How a host ended.
enum HostExit: Equatable {
    case exited(Int32)
    case signalled(Int32)

    // The WIFEXITED and WEXITSTATUS macros don't reach Swift, so this is their arithmetic.
    init(waitStatus: Int32) {
        let signal = waitStatus & 0x7f
        self = signal == 0 ? .exited((waitStatus >> 8) & 0xff) : .signalled(signal)
    }

    var json: JSON {
        switch self {
        case .exited(let code): .number(Double(code))
        case .signalled(let signal): .string("signal \(signal)")
        }
    }
}

struct HostStartError: Error {
    let message: String
}

// One running host, started the way Heimdall will start it: posix_spawn with an empty
// environment, POSIX_SPAWN_CLOEXEC_DEFAULT so it gets the three pipes on 0 to 2 and nothing else,
// and the utility QoS class. All the waiting happens on this one thread through poll, which
// watches the host's stdout, its stderr, its exit and, while a send is stuck, its stdin, so a host
// that writes while the check app writes can't deadlock the two.
final class HostProcess {
    let pid: pid_t
    let startedAt: ContinuousClock.Instant
    private var input: Int32
    private let output: Int32
    private let errors: Int32
    // A kqueue that turns readable when the host exits, so poll can wait for the exit as well.
    private let exitWatch: Int32
    private var outputOpen = true
    private var errorsOpen = true
    private var outputBytes: [UInt8] = []
    private var linesRead = 0
    // The lines no check has taken yet. Log lines go to logs instead, because they can come at
    // any time, before or after the line a check is waiting for.
    private var pending: [HostLine] = []
    private(set) var logs: [HostLine] = []
    private(set) var errorBytes: [UInt8] = []
    private(set) var status: HostExit?
    private(set) var exitedAt: ContinuousClock.Instant?
    private var stopped = false

    private init(
        pid: pid_t, startedAt: ContinuousClock.Instant, input: Int32, output: Int32,
        errors: Int32, exitWatch: Int32
    ) {
        self.pid = pid
        self.startedAt = startedAt
        self.input = input
        self.output = output
        self.errors = errors
        self.exitWatch = exitWatch
    }

    static func start(_ path: String) throws(HostStartError) -> HostProcess {
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        var errors: [Int32] = [-1, -1]
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&errors) == 0 else {
            let reason = String(cString: strerror(errno))
            for descriptor in input + output + errors where descriptor >= 0 { close(descriptor) }
            throw HostStartError(message: "pipe failed: \(reason)")
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        let setUp = [
            posix_spawn_file_actions_adddup2(&actions, input[0], 0),
            posix_spawn_file_actions_adddup2(&actions, output[1], 1),
            posix_spawn_file_actions_adddup2(&actions, errors[1], 2),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)),
            posix_spawnattr_set_qos_class_np(&attributes, QOS_CLASS_UTILITY),
        ]
        var pid: pid_t = 0
        let startedAt = ContinuousClock.now
        var result = setUp.first { $0 != 0 } ?? 0
        if result == 0 {
            result = path.withCString { program in
                let arguments = [UnsafeMutablePointer(mutating: program), nil]
                let environment: [UnsafeMutablePointer<CChar>?] = [nil]
                return posix_spawn(&pid, program, &actions, &attributes, arguments, environment)
            }
        }
        // The host has its own copies of its ends now, and the check app keeps only its own.
        for descriptor in [input[0], output[1], errors[1]] { close(descriptor) }
        guard result == 0 else {
            for descriptor in [input[1], output[0], errors[0]] { close(descriptor) }
            let reason = String(cString: strerror(result))
            throw HostStartError(message: "posix_spawn failed: \(reason)")
        }
        for descriptor in [input[1], output[0], errors[0]] {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        let exitWatch = kqueue()
        var change = kevent64_s(
            ident: UInt64(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: NOTE_EXIT, data: 0, udata: 0, ext: (0, 0))
        var noWait = timespec()
        let watched = exitWatch >= 0 && kevent64(exitWatch, &change, 1, nil, 0, 0, &noWait) == 0
        let failure = errno
        let host = HostProcess(
            pid: pid, startedAt: startedAt, input: input[1], output: output[0], errors: errors[0],
            exitWatch: exitWatch)
        if !watched {
            // A host that has gone already is a zombie, which the kqueue refuses with ESRCH, so
            // it's reaped here. Any other failure means its exit can't be watched, so it's stopped
            // rather than left running.
            guard failure == ESRCH else {
                host.stop()
                let reason = String(cString: strerror(failure))
                throw HostStartError(message: "kqueue failed: \(reason)")
            }
            host.reap()
        }
        return host
    }

    // What the host is doing, for the report when a check fails.
    var state: JSON { status?.json ?? "running" }

    // The host's physical footprint, the memory figure Activity Monitor shows for it.
    var footprint: UInt64? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    // Writes the bytes to the host's stdin and gives how many went in by the deadline. It comes
    // back short when the host stops reading or has gone, which shows up as a broken pipe, so the
    // check app ignores SIGPIPE.
    func send(_ bytes: [UInt8], by deadline: ContinuousClock.Instant) -> Int {
        var sent = 0
        while sent < bytes.count && input >= 0 {
            let count = bytes.withUnsafeBytes { buffer in
                write(input, buffer.baseAddress?.advanced(by: sent), buffer.count - sent)
            }
            if count > 0 {
                sent += count
            } else if count < 0 && errno == EAGAIN {
                guard pump(by: deadline, writing: true) else { break }
            } else if !(count < 0 && errno == EINTR) {
                break
            }
        }
        return sent
    }

    // The next line that isn't a log line, or nil when none comes by the deadline.
    func next(by deadline: ContinuousClock.Instant) -> HostLine? {
        while pending.isEmpty {
            guard pump(by: deadline) else { return nil }
        }
        return pending.removeFirst()
    }

    // The first log line whose text matches, whether it has been read already or comes by the
    // deadline.
    func log(by deadline: ContinuousClock.Instant, where matches: (String) -> Bool) -> HostLine? {
        var checked = 0
        while true {
            if let line = logs[checked...].first(where: { matches($0.logText) }) { return line }
            checked = logs.count
            guard pump(by: deadline) else { return nil }
        }
    }

    func closeInput() {
        guard input >= 0 else { return }
        close(input)
        input = -1
    }

    func waitForExit(by deadline: ContinuousClock.Instant) -> HostExit? {
        while status == nil {
            guard pump(by: deadline) else { break }
        }
        return status
    }

    // Ends the host for good: closes its stdin, kills it if it's still running, reaps it and reads
    // what's left in its pipes, so no check leaves a host behind, whatever went wrong.
    func stop() {
        guard !stopped else { return }
        stopped = true
        closeInput()
        if status == nil {
            kill(pid, SIGKILL)
            reap()
        }
        // The host held the only other ends, so these reads run to EOF.
        while outputOpen && readOutput(at: .now) {}
        while errorsOpen && readErrors() {}
        for descriptor in [output, errors, exitWatch] { close(descriptor) }
    }

    // Waits until the host has written something, has exited or, when writing, can take more
    // input, and reads whatever came. It gives false at the deadline, or at once when there's
    // nothing left to wait for.
    private func pump(by deadline: ContinuousClock.Instant, writing: Bool = false) -> Bool {
        var watched: [pollfd] = []
        if outputOpen { watched.append(pollfd(fd: output, events: Int16(POLLIN), revents: 0)) }
        if errorsOpen { watched.append(pollfd(fd: errors, events: Int16(POLLIN), revents: 0)) }
        if status == nil {
            watched.append(pollfd(fd: exitWatch, events: Int16(POLLIN), revents: 0))
        }
        if writing && input >= 0 {
            watched.append(pollfd(fd: input, events: Int16(POLLOUT), revents: 0))
        }
        let left = deadline - .now
        guard !watched.isEmpty, left > .zero else { return false }
        let count = poll(&watched, nfds_t(watched.count), Self.pollTimeout(left))
        let at = ContinuousClock.now
        guard count > 0 else { return count < 0 && errno == EINTR }
        for entry in watched where entry.revents != 0 {
            switch entry.fd {
            case output: readOutput(at: at)
            case errors: readErrors()
            case exitWatch: reap()
            // The host can take more input, which the next write finds out.
            default: break
            }
        }
        return true
    }

    // Reads what's in stdout now and splits it into lines. It gives false when nothing came.
    @discardableResult
    private func readOutput(at: ContinuousClock.Instant) -> Bool {
        guard let chunk = Self.readChunk(output) else {
            outputOpen = false
            // A last line with no newline still counts as a line the host wrote.
            if !outputBytes.isEmpty { take(outputBytes[...], at: at) }
            outputBytes.removeAll()
            return false
        }
        outputBytes.append(contentsOf: chunk)
        while let newline = outputBytes.firstIndex(of: UInt8(ascii: "\n")) {
            take(outputBytes[..<newline], at: at)
            outputBytes.removeSubrange(...newline)
        }
        return !chunk.isEmpty
    }

    @discardableResult
    private func readErrors() -> Bool {
        guard let chunk = Self.readChunk(errors) else {
            errorsOpen = false
            return false
        }
        errorBytes.append(contentsOf: chunk)
        return !chunk.isEmpty
    }

    private func take(_ bytes: ArraySlice<UInt8>, at: ContinuousClock.Instant) {
        let line = HostLine(bytes, at: at, index: linesRead)
        linesRead += 1
        if line.type == "log" { logs.append(line) } else { pending.append(line) }
    }

    private func reap() {
        var waitStatus: Int32 = 0
        // The host is this process's own child and nothing else reaps it, so only an interrupt
        // can stop the wait.
        while waitpid(pid, &waitStatus, 0) < 0 && errno == EINTR {}
        status = HostExit(waitStatus: waitStatus)
        exitedAt = .now
    }

    // What's in a pipe right now: some bytes, nothing yet, or nil once the host's end has closed.
    private static func readChunk(_ descriptor: Int32) -> [UInt8]? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(descriptor, &chunk, chunk.count)
        if count > 0 { return Array(chunk[..<count]) }
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return [] }
        return nil
    }

    // poll takes whole milliseconds, so the wait rounds up rather than end before the deadline.
    private static func pollTimeout(_ duration: Duration) -> Int32 {
        let (seconds, attoseconds) = duration.components
        let perMillisecond: Int64 = 1_000_000_000_000_000
        let milliseconds = seconds * 1000 + (attoseconds + perMillisecond - 1) / perMillisecond
        return Int32(clamping: milliseconds)
    }
}

// A descriptor the check app holds open without FD_CLOEXEC while it starts every host, so a spawn
// that let descriptors through would show up in the self-test as fds "open". Its file is removed
// straight away, so nothing is left on disk, but the descriptor stays good.
struct Canary {
    let descriptor: Int32
    // True when the descriptor would really reach a child that inherited everything.
    let inheritable: Bool

    static func open() -> Canary? {
        var template = Array((NSTemporaryDirectory() + "module-host-check.XXXXXX").utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { return nil }
        unlink(template)
        let flags = fcntl(descriptor, F_GETFD)
        return Canary(descriptor: descriptor, inheritable: flags >= 0 && flags & FD_CLOEXEC == 0)
    }

    func close() {
        Darwin.close(descriptor)
    }
}
