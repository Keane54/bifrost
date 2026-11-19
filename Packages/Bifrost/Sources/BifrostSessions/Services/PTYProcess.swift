import BifrostFoundation
import Darwin
import Dispatch
import Synchronization

// The PTY of one child process, made with forkpty and posix_spawn. This file uses the calls of the
// system, so the services need no UI framework.
//
// The child is the session leader of a new session, and the terminal of the PTY is its controlling
// terminal. So a resize sends SIGWINCH to it, also when the program does not take a terminal
// itself. It gets only the descriptors 0, 1 and 2, all on the terminal. The app sends a signal only
// to this child, by its pid, and never after the reap of the child: the system can give a reaped
// pid to a new process.

// MARK: - The system spawner

// Makes a PTYProcess for each spawn.
package struct SystemPTYSpawner: PTYSpawner {
    package init() {}

    package func spawn(
        program: String, arguments: [String], environment: [String: String],
        directory: String, size: TerminalSize
    ) throws(PTYError) -> any PTYChild {
        try PTYProcess(
            program: program, arguments: arguments, environment: environment,
            directory: directory, size: size)
    }
}

// MARK: - The process

// Flow control: the read of the master stops while more than highWater bytes wait for a drain,
// and it starts again when a drain leaves fewer than lowWater bytes. While the read stops, the
// kernel buffer of the PTY fills and the write of the child waits, as with each terminal. So a
// slow reader, or a reader that stopped, never makes the memory of the app grow with no limit.
package final class PTYProcess: PTYChild {
    // The size of one read of the master.
    static let readSize = 65_536
    // The limits of the flow control: four drains, and one drain.
    static let highWater = 4 * PTYAttach.drainLimit
    static let lowWater = PTYAttach.drainLimit

    private struct State {
        // The output that waits for a drain, in order.
        var waiting = ByteQueue()
        // True from the bytesWaiting event until a drain takes the last waiting byte. So it is
        // true exactly when bytes wait, and one drain is in flight at a time.
        var notified = false
        // True while the read of the master stops (flow control).
        var paused = false
        // True after the end of the output (end of file, an error, or the limit after the exit).
        var ended = false
        // The exit code, after the reap.
        var code: Int32?
        // True after the exited event.
        var finished = false
        // True after the close of the master.
        var closed = false
    }

    package let pid: pid_t
    private let master: Int32
    private let state = Mutex(State())
    private let readQueue = DispatchQueue(label: "bifrost.pty.read")
    private let writeQueue = DispatchQueue(label: "bifrost.pty.write")
    private let reader: any DispatchSourceRead
    private let watcher: any DispatchSourceProcess
    package let events: AsyncStream<PTYEvent>
    private let sendEvent: AsyncStream<PTYEvent>.Continuation
    // Sends a signal to a pid. A test records the calls, then calls defaultSend.
    private let send: @Sendable (pid_t, Int32) -> Void

    // The signal goes only to the one pid, never to a process group.
    package static let defaultSend: @Sendable (pid_t, Int32) -> Void = { _ = Darwin.kill($0, $1) }

    // The events: bytesWaiting when bytes wait and no drain is in flight (from a queue of the
    // process, or from a drain that leaves bytes), then exited one time, after the last output.
    package init(
        program: String, arguments: [String], environment: [String: String],
        directory: String, size: TerminalSize,
        send: @escaping @Sendable (pid_t, Int32) -> Void = PTYProcess.defaultSend
    ) throws(PTYError) {
        let started = try Self.start(
            program: program, arguments: arguments, environment: environment,
            directory: directory, size: size)
        pid = started.pid
        master = started.master
        (events, sendEvent) = AsyncStream.makeStream()
        self.send = send
        reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: readQueue)
        watcher = DispatchSource.makeProcessSource(
            identifier: pid, eventMask: .exit, queue: readQueue)
        // The handlers keep this object alive until the sources end. So a closed chat cannot
        // leave a child that nobody reaps.
        reader.setEventHandler { [self] in readAvailable() }
        reader.setCancelHandler { [self] in closeMaster() }
        watcher.setEventHandler { [self] in childExited() }
        reader.resume()
        watcher.resume()
    }

    // MARK: The calls of the owner

    // Write the bytes on the write queue, in the order of the calls. A large paste does not stop
    // the caller.
    package func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        writeQueue.async { [self] in writeAll(bytes) }
    }

    package func resize(_ size: TerminalSize) {
        guard size.cols > 0, size.rows > 0 else { return }
        var window = Self.window(size)
        state.withLock { s in
            if !s.closed { _ = ioctl(master, TIOCSWINSZ, &window) }
        }
    }

    // The lock makes the reap and the signal one step after the other. So the signal never goes
    // to a pid after the reap.
    package func signal(_ signal: CloseSignal) {
        state.withLock { s in
            if s.code == nil { send(pid, signal.number) }
        }
    }

    // The waiting bytes, in order, at most limit. When bytes stay, the next bytesWaiting event
    // comes at once. A drain below lowWater starts the read of the master again. A drain that
    // takes the last byte after the end can give the exited event.
    package func drain(limit: Int) -> [UInt8] {
        let (bytes, more) = state.withLock { s in
            let bytes = s.waiting.take(limit)
            s.notified = !s.waiting.isEmpty
            if s.paused && s.waiting.count < Self.lowWater && !s.ended {
                s.paused = false
                reader.resume()
            }
            return (bytes, s.notified)
        }
        if more { sendEvent.yield(.bytesWaiting) } else { finishIfReady() }
        return bytes
    }

    // True after the reap of the child. A test waits for it.
    var reaped: Bool { state.withLock { $0.code != nil } }

    // The bytes that wait for a drain, and true while the read stops. A test reads them.
    var waitingCount: Int { state.withLock { $0.waiting.count } }
    var isPaused: Bool { state.withLock { $0.paused } }

    // MARK: The events

    private enum ReadResult {
        case bytes([UInt8])
        case again
        case end
    }

    // Runs on the read queue.
    private func readAvailable() {
        let result = withUnsafeTemporaryAllocation(byteCount: Self.readSize, alignment: 1) {
            buffer -> ReadResult in
            let count = Darwin.read(master, buffer.baseAddress, buffer.count)
            if count > 0 {
                return .bytes(Array(UnsafeRawBufferPointer(rebasing: buffer[..<count])))
            }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { return .again }
            // The end of the output (0 or EIO). No process has the terminal open now.
            return .end
        }
        switch result {
        case .bytes(let bytes):
            let notify = state.withLock { s in
                s.waiting.append(bytes)
                // The suspend runs in the lock, so a drain cannot resume the source first.
                if !s.paused && s.waiting.count > Self.highWater {
                    s.paused = true
                    reader.suspend()
                }
                guard !s.notified else { return false }
                s.notified = true
                return true
            }
            if notify { sendEvent.yield(.bytesWaiting) }
        case .again:
            break
        case .end:
            endOutput()
        }
    }

    // Runs on the read queue.
    private func childExited() {
        guard reap() else { return }
        watcher.cancel()
        // A child of the child can keep the terminal open. Do not wait long for that.
        readQueue.asyncAfter(deadline: .now() + 1) { [self] in endOutput() }
        finishIfReady()
    }

    // Runs on the read queue. A paused read first takes the bytes that the kernel still holds,
    // and then the source starts again: GCD does not run the cancel handler (closeMaster) of a
    // suspended source.
    private func endOutput() {
        let first = state.withLock { s in
            defer { s.ended = true }
            guard !s.ended else { return false }
            if s.paused {
                readRemaining(into: &s)
                s.paused = false
                reader.resume()
            }
            return true
        }
        if first { reader.cancel() }
        // A child that ends very soon can end before the exit source starts. Then look again.
        guard reap() else {
            readQueue.asyncAfter(deadline: .now() + 0.5) { [self] in endOutput() }
            return
        }
        finishIfReady()
    }

    // Reap the child, so it does not stay as a zombie. True when the child ended. A child that
    // another part of the process reaped (ECHILD) counts as ended, so no signal goes to its pid.
    private func reap() -> Bool {
        state.withLock { s in
            if s.code != nil { return true }
            var status: Int32 = 0
            while true {
                let found = waitpid(pid, &status, WNOHANG)
                if found == pid {
                    s.code = Self.exitCode(status)
                    return true
                }
                if found < 0 && errno == EINTR { continue }
                if found < 0 && errno == ECHILD {
                    s.code = 0
                    return true
                }
                return false
            }
        }
    }

    // Give the exited event one time, after the end, the reap and the drain of the last byte.
    private func finishIfReady() {
        let code: Int32? = state.withLock { s in
            guard s.ended, let code = s.code, s.waiting.isEmpty, !s.finished else { return nil }
            s.finished = true
            return code
        }
        guard let code else { return }
        watcher.cancel()
        sendEvent.yield(.exited(code))
        sendEvent.finish()
    }

    // Read the bytes that the kernel holds for a paused source, until the master has no more,
    // and at most highWater bytes: a child of the child can keep the terminal open and write
    // with no end, and the lock must not stay held. The rest of the output goes, as after the
    // 1 s wait of childExited. The master does not block. Runs in the lock, on the read queue.
    private func readRemaining(into s: inout State) {
        withUnsafeTemporaryAllocation(byteCount: Self.readSize, alignment: 1) { buffer in
            var total = 0
            while total < Self.highWater {
                let size = min(buffer.count, Self.highWater - total)
                let count = Darwin.read(master, buffer.baseAddress, size)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                total += count
                s.waiting.append(Array(UnsafeRawBufferPointer(rebasing: buffer[..<count])))
            }
        }
        if !s.waiting.isEmpty && !s.notified {
            s.notified = true
            sendEvent.yield(.bytesWaiting)
        }
    }

    // Runs on the read queue, after the cancel of the reader.
    private func closeMaster() {
        state.withLock { s in
            s.closed = true
            Darwin.close(master)
        }
    }

    // Runs on the write queue. The descriptor does not block, so the lock is never held while
    // the write waits. A full PTY waits until the child reads (poll), at most 100 ms for each
    // look, so a close of the master during the wait stops the loop.
    private func writeAll(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let result: (count: Int, error: Int32)? = state.withLock { s in
                if s.closed || s.ended { return nil }
                let count = bytes.withUnsafeBytes { raw in
                    Darwin.write(master, raw.baseAddress.map { $0 + offset }, raw.count - offset)
                }
                return (count, errno)
            }
            guard let result else { return }
            if result.count > 0 {
                offset += result.count
                continue
            }
            guard result.count < 0, result.error == EAGAIN || result.error == EINTR else { return }
            var wait = pollfd(fd: master, events: Int16(POLLOUT), revents: 0)
            _ = poll(&wait, 1, 100)
        }
    }

    // MARK: The start

    // The exit code of the event: the code of an exit, or 0 when a signal ended the child.
    static func exitCode(_ status: Int32) -> Int32 {
        status & 0x7f == 0 ? (status >> 8) & 0xff : 0
    }

    private static func window(_ size: TerminalSize) -> winsize {
        winsize(
            ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.cols),
            ws_xpixel: 0, ws_ypixel: 0)
    }

    // Open the PTY and start the child. forkpty opens the PTY with the modes and the start size,
    // and starts a copy of this process. In the copy, login_tty makes a new session, makes the
    // terminal its controlling terminal, and puts the terminal on descriptors 0, 1 and 2. Then
    // posix_spawn with POSIX_SPAWN_SETEXEC runs the program in place of the copy. The kernel sends
    // SIGWINCH for a resize only to the foreground process group of a controlling terminal, so the
    // child must have one.
    //
    // posix_spawn alone cannot give a controlling terminal on macOS. Its file actions run before
    // POSIX_SPAWN_SETSID, so an open of the terminal in them comes before the new session. Then
    // only a program that takes a terminal itself (bash, sh) gets one. The other way is a helper
    // program that opens the terminal again, and the app has no helper program.
    //
    // The fork is safe in an app with many threads, because the copy does very little before the
    // exec. After a fork, the copy has only the thread of the fork, and a lock that another thread
    // held stays locked (for example the lock of malloc or of the Swift runtime). The copy makes
    // only these calls:
    // - In forkpty: close of the master, then login_tty (setsid, ioctl TIOCSCTTY, dup2 to 0, 1 and
    //   2, close). When login_tty fails, forkpty calls syslog (not safe after a fork) and then does
    //   the dup2 itself. login_tty does not fail here: the terminal is new, and openpty opened it
    //   with O_NOCTTY, so no session has it.
    // - In forkAndExec: tcgetpgrp and getpid (a check that the terminal is the controlling
    //   terminal), posix_spawn, write and _exit.
    // POSIX lists each of them as safe after a fork, except syslog and posix_spawn. posix_spawn of
    // the system gives the prepared attributes and file actions to one system call, with no
    // allocation and no lock. forkAndExec gets only C values (pointers and numbers) that this
    // function made before the fork, so the copy has no Swift value to release. The step fork-child
    // of scripts/check.sh reads the compiled forkAndExec of the Debug and the Release build, and
    // fails when it calls a function of the Swift or the Objective-C runtime or other Swift code.
    // This thread blocks all signals during the fork, so no signal handler of the app runs in the
    // copy before the exec.
    private static func start(
        program: String, arguments: [String], environment: [String: String],
        directory: String, size: TerminalSize
    ) throws(PTYError) -> (pid: pid_t, master: Int32) {
        if let code = folderProblem(directory) {
            throw PTYError(message: ErrorText.notStarted(program, in: directory, code: code))
        }
        let fail = { (code: Int32) in PTYError(message: ErrorText.notStarted(program, code: code)) }
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions), fail)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes), fail)
        defer { posix_spawnattr_destroy(&attributes) }
        try prepareExec(&actions, &attributes, directory: directory, fail)

        let argv = [program] + arguments
        let entries = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let cArguments = cArray(argv)
        let cEnvironment = cArray(entries)
        defer {
            free(cArguments, count: argv.count)
            free(cEnvironment, count: entries.count)
        }

        // The copy writes the error number of a failed exec to this pipe. A good exec closes the
        // pipe (POSIX_SPAWN_CLOEXEC_DEFAULT), so the read gets the end of the file.
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw fail(errno) }
        let readEnd = ends[0]
        let writeEnd = ends[1]
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        defer { Darwin.close(readEnd) }

        var master: Int32 = -1
        var modes = modes()
        var window = window(size)
        var all = sigset_t()
        sigfillset(&all)
        var old = sigset_t()
        _ = pthread_sigmask(SIG_SETMASK, &all, &old)
        let pid = forkAndExec(
            master: &master, modes: &modes, window: &window, actions: &actions,
            attributes: &attributes, arguments: cArguments, environment: cEnvironment,
            report: writeEnd)
        let forkError = errno
        _ = pthread_sigmask(SIG_SETMASK, &old, nil)
        Darwin.close(writeEnd)
        guard pid > 0 else { throw fail(forkError) }
        // The PTY must not go to a child that another thread of the app starts.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        let code = execResult(readEnd)
        guard code == 0 else {
            // The copy ends at once after its write. Reap it, so it does not stay as a zombie.
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            Darwin.close(master)
            throw fail(code)
        }
        // A write must not wait while it holds the lock, so the master does not block.
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        return (pid, master)
    }

    // The fork and the copy (the note of start). The parameters are only C values, so the copy
    // has no Swift value to release. The function is never inline, so no code of the caller can
    // move into the copy. The result is the pid of the copy, or -1 when forkpty fails (errno).
    // The copy never returns: it runs the program, or it writes the error number of the failed
    // exec to report and exits.
    @inline(never)
    private static func forkAndExec(
        master: UnsafeMutablePointer<Int32>, modes: UnsafeMutablePointer<termios>,
        window: UnsafeMutablePointer<winsize>,
        actions: UnsafePointer<posix_spawn_file_actions_t?>,
        attributes: UnsafePointer<posix_spawnattr_t?>,
        arguments: UnsafePointer<UnsafeMutablePointer<CChar>?>,
        environment: UnsafePointer<UnsafeMutablePointer<CChar>?>, report: Int32
    ) -> pid_t {
        let pid = forkpty(master, nil, modes, window)
        guard pid == 0 else { return pid }
        var code =
            tcgetpgrp(0) == getpid()
            ? posix_spawn(nil, arguments[0], actions, attributes, arguments, environment)
            : ENOTTY
        _ = Darwin.write(report, &code, MemoryLayout<Int32>.size)
        Darwin._exit(127)
    }

    private static func check(_ code: Int32, _ fail: (Int32) -> PTYError) throws(PTYError) {
        if code != 0 { throw fail(code) }
    }

    // The error number of a folder that is missing or not a folder, or nil.
    private static func folderProblem(_ directory: String) -> Int32? {
        var info = stat()
        if stat(directory, &info) != 0 { return errno }
        return info.st_mode & S_IFMT == S_IFDIR ? nil : ENOTDIR
    }

    // The exec of the program in the copy: it changes to the folder, keeps only descriptors 0, 1
    // and 2 (POSIX_SPAWN_CLOEXEC_DEFAULT closes all others), and gives each signal its default
    // action with an empty mask. The copy already leads its session, so the exec has no
    // POSIX_SPAWN_SETSID (a second setsid fails).
    private static func prepareExec(
        _ actions: inout posix_spawn_file_actions_t?, _ attributes: inout posix_spawnattr_t?,
        directory: String, _ fail: (Int32) -> PTYError
    ) throws(PTYError) {
        try check(posix_spawn_file_actions_addchdir(&actions, directory), fail)
        for descriptor: Int32 in 0...2 {
            try check(posix_spawn_file_actions_addinherit_np(&actions, descriptor), fail)
        }
        let flags =
            POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)), fail)
        var all = sigset_t()
        sigfillset(&all)
        try check(posix_spawnattr_setsigdefault(&attributes, &all), fail)
        var none = sigset_t()
        sigemptyset(&none)
        try check(posix_spawnattr_setsigmask(&attributes, &none), fail)
    }

    // The control characters of the PTY: the defaults of the system.
    private static let controlCharacters: [(slot: Int32, value: cc_t)] = [
        (VEOF, 4), (VERASE, 0x7f), (VWERASE, 23), (VKILL, 21), (VREPRINT, 18), (VINTR, 3),
        (VQUIT, 0x1c), (VSUSP, 26), (VDSUSP, 25), (VSTART, 17), (VSTOP, 19), (VLNEXT, 22),
        (VDISCARD, 15), (VMIN, 1), (VTIME, 0), (VSTATUS, 20),
    ]

    // The modes of the PTY: the usual terminal flags with UTF-8 input, the control characters, and
    // 38400 baud. Each other slot (VEOL, VEOL2 and the two spare slots) has the value of no
    // character (_POSIX_VDISABLE, 0xff), as in the defaults of the system.
    static func modes() -> termios {
        var modes = termios()
        modes.c_iflag = tcflag_t(ICRNL | IXON | IXANY | IMAXBEL | BRKINT | IUTF8)
        modes.c_oflag = tcflag_t(OPOST | ONLCR)
        modes.c_cflag = tcflag_t(CREAD | CS8 | HUPCL)
        modes.c_lflag = tcflag_t(
            ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL)
        withUnsafeMutableBytes(of: &modes.c_cc) { characters in
            for index in characters.indices { characters[index] = 0xff }
            for character in controlCharacters {
                characters[Int(character.slot)] = character.value
            }
        }
        cfsetispeed(&modes, speed_t(B38400))
        cfsetospeed(&modes, speed_t(B38400))
        return modes
    }

    // Copies of the strings as a C array with nil at the end. The start makes them before the
    // fork, so the copy needs no allocation.
    private static func cArray(_ strings: [String]) -> UnsafeMutablePointer<
        UnsafeMutablePointer<CChar>?
    > {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
            capacity: strings.count + 1)
        array.initialize(repeating: nil, count: strings.count + 1)
        for (index, string) in strings.enumerated() { array[index] = strdup(string) }
        return array
    }

    private static func free(
        _ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, count: Int
    ) {
        for index in 0..<count { Darwin.free(array[index]) }
        array.deinitialize(count: count + 1)
        array.deallocate()
    }

    // The error number that the copy wrote, or 0 when the pipe ended with no number (the exec
    // closed it). A write of 4 bytes to a pipe is atomic, so one read gets all 4 bytes or none.
    private static func execResult(_ descriptor: Int32) -> Int32 {
        var code: Int32 = 0
        var count: Int
        repeat {
            count = Darwin.read(descriptor, &code, MemoryLayout<Int32>.size)
        } while count < 0 && errno == EINTR
        return count == MemoryLayout<Int32>.size ? code : 0
    }
}

// MARK: - The waiting bytes

// The output that waits for a drain: the chunks of the reads, in order. A take moves a head
// index, so it does not move the chunks that stay. The taken chunks go when they are the larger
// part of the array.
struct ByteQueue {
    private var chunks: [[UInt8]] = []
    // The index of the first chunk that a take did not finish.
    private var head = 0
    // The number of bytes of the head chunk that a take took.
    private var taken = 0
    private(set) var count = 0

    var isEmpty: Bool { count == 0 }

    mutating func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        chunks.append(bytes)
        count += bytes.count
    }

    // The first bytes, at most limit, in order.
    mutating func take(_ limit: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(min(max(limit, 0), count))
        while out.count < limit, head < chunks.count {
            let first = chunks[head]
            let room = limit - out.count
            let left = first.count - taken
            if left <= room {
                out.append(contentsOf: first[taken...])
                head += 1
                taken = 0
            } else {
                out.append(contentsOf: first[taken..<(taken + room)])
                taken += room
            }
        }
        count -= out.count
        if head == chunks.count {
            chunks.removeAll(keepingCapacity: true)
            head = 0
        } else if head > chunks.count / 2 {
            chunks.removeFirst(head)
            head = 0
        }
        return out
    }
}
