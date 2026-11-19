import BifrostFoundation
import Darwin

// MARK: - The child of a PTY

// The signal of a close. A close only detaches: the signal goes to the attach child, never to
// the session.
package enum CloseSignal: Sendable, CaseIterable {
    case hangup, terminate

    var number: Int32 { self == .hangup ? SIGHUP : SIGTERM }
}

// A PTY that did not open. The message is a native error text (ErrorText).
package struct PTYError: Error, Sendable, Equatable {
    package let message: String

    package init(message: String) { self.message = message }
}

// An event of the child of a PTY.
package enum PTYEvent: Sendable, Equatable {
    // Bytes wait, and no drain is in flight. The next drain takes them.
    case bytesWaiting
    // The child ended, after its last output, with its exit code: the code of an exit, or 0
    // when a signal ended the child. The events end after it.
    case exited(Int32)
}

// The child process of a PTY.
package protocol PTYChild: AnyObject, Sendable {
    var pid: pid_t { get }
    // The events of the child, in their order, for one reader.
    var events: AsyncStream<PTYEvent> { get }
    // Write the bytes to the terminal. The call does not wait.
    func write(_ bytes: [UInt8])
    func resize(_ size: TerminalSize)
    // Send the signal to the child by its pid. After the reap of the child, it does nothing.
    func signal(_ s: CloseSignal)
    // The bytes that wait, in order, at most limit. When bytes stay, the next bytesWaiting
    // event comes.
    func drain(limit: Int) -> [UInt8]
}

// Starts the child of a PTY. The call can wait a long time (the endpoint scanner of the Mac
// checks each program start), so the manager runs it on the blocking executor.
package protocol PTYSpawner: Sendable {
    func spawn(
        program: String, arguments: [String], environment: [String: String],
        directory: String, size: TerminalSize
    ) throws(PTYError) -> any PTYChild
}

// MARK: - The channel of a PTY

// One PTY child, from its spawn until its close or its exit: the engine that the attach of a view
// (PTYAttach) and the trust run (PTYRun) share. It holds the life of the child, the drain of its
// output with the flow control, the input, the size and the close. The owner of the open reads
// the output and the exit, writes, resizes and closes through its wrapper.
@MainActor
final class PTYChannel {
    // The most bytes of one drain. The flow control of PTYProcess uses the same size.
    nonisolated static let drainLimit = 262_144

    // The life of a channel. Only an open channel writes, resizes and gives output to its owner.
    private enum Life {
        // The spawn runs.
        case spawning
        // The child runs.
        case open(any PTYChild)
        // The owner closed the channel, or a cancel closed the open. The channel drains the
        // output of the child and drops it until the exit. nil: no child (during the spawn, and
        // after the exit).
        case closed(draining: (any PTYChild)?)
        // The child ended with the code, after its last output. The reader drains the bytes
        // that still wait, then the output ends. nil: no bytes wait.
        case exited(Int32, draining: (any PTYChild)?)
    }

    // The pid of the child. An open gives its wrapper only after the spawn, so the pid is set.
    private(set) var pid: pid_t = 0
    // The manager forgets the wrapper of the channel. The wrapper sets it after its init.
    var onEnd: () -> Void = {}

    private var life = Life.spawning
    // True from a bytesWaiting event of the child until the next drain.
    private var bytesWait = false
    // The one reader of the output while it waits for bytes or for the end.
    private var reader: CheckedContinuation<Void, Never>?
    private var exitWaiters: [CheckedContinuation<Int32?, Never>] = []

    init() {}

    // True from the end of the spawn until the close or the exit.
    var isOpen: Bool {
        if case .open = life { true } else { false }
    }

    // The exit code of the child, after its last output (see PTYAttach.exit).
    var exit: Int32? {
        get async {
            switch life {
            case .closed: nil
            case .exited(let code, _): code
            case .spawning, .open: await withCheckedContinuation { exitWaiters.append($0) }
            }
        }
    }

    // False when the channel is not open.
    func write(_ bytes: [UInt8]) -> Bool {
        guard case .open(let child) = life else { return false }
        child.write(bytes)
        return true
    }

    // A size below 1 does nothing.
    func resize(_ size: TerminalSize) {
        guard case .open(let child) = life, size.cols >= 1, size.rows >= 1 else { return }
        child.resize(size)
    }

    // End the channel, then send the signal to its child by its pid. A close after the close or
    // the exit does nothing, so no signal goes to a reaped pid. A close during the spawn closes
    // the open: the new child gets SIGHUP when its spawn ends.
    func close(signal: CloseSignal = .hangup) {
        switch life {
        case .spawning:
            life = .closed(draining: nil)
            end()
        case .open(let child):
            life = .closed(draining: child)
            end()
            child.signal(signal)
            dropOutput()
        case .closed, .exited:
            return
        }
    }

    // The next chunk for the reader, or nil at the end. When bytes stay after a drain, the
    // child gives the next bytesWaiting event in a later turn. A cancel of the task of the
    // reader ends its output, and the bytes stay in the child.
    fileprivate func next() async -> [UInt8]? {
        precondition(reader == nil, "The output of a PTY has one reader.")
        while !Task.isCancelled {
            switch life {
            case .closed:
                return nil
            case .open(let child) where bytesWait, .exited(_, let child?) where bytesWait:
                bytesWait = false
                let bytes = child.drain(limit: Self.drainLimit)
                if !bytes.isEmpty { return bytes }
            case .exited(let code, _):
                life = .exited(code, draining: nil)
                return nil
            case .spawning, .open:
                await withTaskCancellationHandler {
                    await withCheckedContinuation { reader = $0 }
                } onCancel: {
                    Task { @MainActor in self.wakeReader() }
                }
            }
        }
        return nil
    }

    // MARK: The events of the manager and of the child

    // The spawn ended. One task reads the events of the child on the main actor, in their
    // order, until the exit. It starts after the open gives the wrapper, so the caller gets the
    // wrapper before the first output and the exit. A close during the spawn closed the channel:
    // the new child gets SIGHUP at once.
    fileprivate func started(_ child: any PTYChild) {
        pid = child.pid
        Task {
            for await event in child.events { received(event) }
        }
        switch life {
        case .spawning:
            life = .open(child)
        case .closed:
            life = .closed(draining: child)
            child.signal(.hangup)
        case .open, .exited:
            break
        }
    }

    private func received(_ event: PTYEvent) {
        switch event {
        case .bytesWaiting:
            bytesWait = true
            if case .closed = life { dropOutput() } else { wakeReader() }
        case .exited(let code):
            switch life {
            case .open(let child):
                // The reader drains the bytes that still wait, then it gets the end.
                life = .exited(code, draining: bytesWait ? child : nil)
                end()
            case .closed:
                life = .closed(draining: nil)
            case .spawning, .exited:
                break
            }
        }
    }

    // The channel leaves the manager. The reader and each caller of exit get the end.
    private func end() {
        onEnd()
        wakeReader()
        let code: Int32? = if case .exited(let code, _) = life { code } else { nil }
        let waiters = exitWaiters
        exitWaiters = []
        for waiter in waiters { waiter.resume(returning: code) }
    }

    private func wakeReader() {
        reader?.resume()
        reader = nil
    }

    // Drain the bytes that wait and drop them. When bytes stay, the child gives the next
    // bytesWaiting event in a later turn.
    private func dropOutput() {
        guard bytesWait, case .closed(let child?) = life else { return }
        bytesWait = false
        _ = child.drain(limit: Self.drainLimit)
    }
}

// The output of a PTY: one drain for each element (see PTYAttach.output).
package struct PTYOutput: AsyncSequence, Sendable {
    package typealias Element = [UInt8]
    package typealias Failure = Never

    let channel: PTYChannel

    package func makeAsyncIterator() -> Iterator { Iterator(channel: channel) }

    package struct Iterator: AsyncIteratorProtocol {
        let channel: PTYChannel

        package func next() async -> [UInt8]? { await channel.next() }
    }
}

// MARK: - The attach

// One PTY of a view, from its open until its close or the exit of its child. The caller of the
// open owns it: it reads the output and the exit, writes, resizes and closes.
@MainActor
package final class PTYAttach {
    // The most bytes of one drain. The flow control of PTYProcess uses the same size.
    nonisolated package static let drainLimit = PTYChannel.drainLimit

    // A full redraw: clear the screen. The terminal of a client sends it after a resize.
    static let fullRedraw: [UInt8] = [0x1b, 0x5b, 0x32, 0x4a]

    package let view: PTYView
    let channel = PTYChannel()

    // remove takes the attach out of the manager at its close or its exit.
    init(view: PTYView, remove: @escaping (PTYAttach) -> Void) {
        self.view = view
        channel.onEnd = { [weak self] in
            if let self { remove(self) }
        }
    }

    // The pid of the child. An open gives the attach only after the spawn, so the pid is set.
    package var pid: pid_t { channel.pid }

    // The output of the child, in order, for one reader: a second reader that waits at the same
    // time stops the app (a precondition). Each element is one drain of at most drainLimit
    // bytes. The drain comes when the reader asks, at most one in each turn of the main actor,
    // and the child keeps its bytes until then (with flow control: PTYProcess). So the main
    // actor stays free during a burst. The output ends at the exit and at the close. The output
    // that the child gives after a close goes nowhere: the attach drains it and drops it until
    // the exit.
    package nonisolated var output: PTYOutput { PTYOutput(channel: channel) }

    // True from the end of the spawn until the close or the exit.
    package var isOpen: Bool { channel.isOpen }

    // The exit code of the child, after its last output. The code of an exit, or 0 when a signal
    // ended the child. nil when a close came first: the exit of a closed attach goes nowhere.
    package var exit: Int32? {
        get async { await channel.exit }
    }

    // True when the bytes hold ESC [ 2 J. The size watcher reads the session size then. A
    // sequence that two chunks split is missed. The next redraw or open recovers it.
    package static func hasFullRedraw(_ bytes: [UInt8]) -> Bool {
        bytes.firstRange(of: fullRedraw) != nil
    }

    // False when the attach is not open.
    package func write(_ bytes: [UInt8]) -> Bool { channel.write(bytes) }

    // A size below 1 does nothing.
    package func resize(_ size: TerminalSize) { channel.resize(size) }

    // End the attach, then send the signal to its child. A close only detaches: the signal goes
    // to the attach child by its pid, never to the session. The type allows only SIGHUP and
    // SIGTERM. A close after the close or the exit does nothing, so no signal goes to a reaped
    // pid. A close during the spawn closes the open: the new child gets SIGHUP when its spawn
    // ends.
    package func close(signal: CloseSignal = .hangup) { channel.close(signal: signal) }
}

// MARK: - The trust run

// The PTY of a trust run: claude with no arguments in a review clone, so that the user can answer
// the trust prompt of Claude Code (PTYManager.openTrust). It has no session and no view, so the
// list of the attaches, the attach of a view and the session input never see it. The caller of
// the open owns it, as the owner of an attach does: it reads the output and the exit, writes the
// keys of the user, resizes and closes. A close sends SIGHUP to its claude.
@MainActor
package final class PTYRun {
    let channel = PTYChannel()

    // remove takes the run out of the manager at its close or its exit.
    init(remove: @escaping (PTYRun) -> Void) {
        channel.onEnd = { [weak self] in
            if let self { remove(self) }
        }
    }

    package var pid: pid_t { channel.pid }

    // The output of claude, for one reader (see PTYAttach.output).
    package nonisolated var output: PTYOutput { PTYOutput(channel: channel) }

    package var isOpen: Bool { channel.isOpen }

    // The exit code of claude after its last output, or nil when a close came first.
    package var exit: Int32? {
        get async { await channel.exit }
    }

    // False when the run is not open.
    package func write(_ bytes: [UInt8]) -> Bool { channel.write(bytes) }

    package func resize(_ size: TerminalSize) { channel.resize(size) }

    package func close(signal: CloseSignal = .hangup) { channel.close(signal: signal) }
}

// MARK: - The manager

// The manager starts one PTY for each view (docs/behaviour/pty.md). It runs only "claude attach
// <short id>" with the claude program of the claude runner: it makes the arguments itself from a
// ShortID, so no caller gives free arguments to claude, and a short ID can never be an option.
// An open takes only a CheckedAttach, which only AttachRules.check makes, so no caller can open
// a PTY without the check. Each PTY gets the child env of the claude runner, with TERM and
// COLORTERM. An open gives a PTYAttach, and the caller of the open owns it.
//
// The second checked form is the trust run (openTrust): claude with no arguments in a folder that
// TrustRuns.check allowed, through the same spawner and env. The manager keeps at most one trust
// run, apart from the attaches: list(), attach(_:) and the session input never see it, and
// closeAll() closes it too.
//
// The spawn (forkpty and posix_spawn) runs on the blocking executor. On a Mac with an endpoint
// scanner, posix_spawn waits for the scan of each program start, so a spawn on the main actor
// could stop the UI at each chat open, and a spawn on the cooperative pool could hold a thread
// that other async work needs. The attaches stay on the main actor, and the order rules stay:
// - An open of a view closes the old attach of the view first, before the spawn.
// - The output and the exit of an old child go only to its closed attach, so they go nowhere.
// - A cancel of the open task, a closeAll or a newer open of the view during the spawn cancels
//   the open. When the spawn ends, the new child gets SIGHUP to its pid only, and the open gives
//   nil, so no caller gets that child. An open whose task is cancelled before the spawn starts
//   no child.
// - The output and the exit of a child that come during its spawn wait until the open ends. So
//   the caller always gets the attach before the first output and the exit.
@MainActor
public final class PTYManager {
    private let claude: ClaudeRunner
    private let spawner: any PTYSpawner
    // The attach of each view, from the start of its open until its close or its exit: one PTY
    // for each view.
    private var attaches: [PTYView: PTYAttach] = [:]
    // The trust run, from the start of its open until its close or its exit.
    private var trust: PTYRun?

    package init(claude: ClaudeRunner, spawner: any PTYSpawner = SystemPTYSpawner()) {
        self.claude = claude
        self.spawner = spawner
    }

    // The path of the claude program that each PTY runs. The debug bench checks that it is the
    // fake claude.
    public var claudePath: String { claude.path }

    // Open a PTY of "claude attach <short id>" for the view of the check, in its folder. nil: the
    // open was cancelled, and the manager closed the new child. A spawn error throws, and the
    // view has no attach.
    package func open(_ checked: CheckedAttach, size: TerminalSize) async throws(PTYError)
        -> PTYAttach?
    {
        let view = checked.view
        attaches[view]?.close()
        guard !Task.isCancelled else { return nil }
        let attach = PTYAttach(view: view) { [weak self] in self?.remove($0) }
        attaches[view] = attach
        try await start(
            attach.channel, arguments: ["attach", checked.shortId.text],
            directory: checked.directory, size: size)
        return attach.isOpen ? attach : nil
    }

    // Open the trust run of the check: claude with no arguments in its folder. A new trust run
    // closes the old one first, before the spawn. nil: the open was cancelled (a cancel of the
    // task, a closeAll or a newer trust run during the spawn), and the manager closed the new
    // child. A spawn error throws.
    package func openTrust(_ checked: CheckedTrustRun, size: TerminalSize) async throws(PTYError)
        -> PTYRun?
    {
        trust?.close()
        guard !Task.isCancelled else { return nil }
        let run = PTYRun { [weak self] in self?.removeTrust($0) }
        trust = run
        try await start(run.channel, arguments: [], directory: checked.folder, size: size)
        return run.isOpen ? run : nil
    }

    // Spawn claude with the arguments in the folder for the channel, on the blocking executor.
    // A spawn error closes the channel and throws. A cancel of the task during the spawn closes
    // the channel, so the new child gets SIGHUP.
    private func start(
        _ channel: PTYChannel, arguments: [String], directory: String, size: TerminalSize
    ) async throws(PTYError) {
        let environment = ChildEnvironment.make(from: claude.environment, pty: true)
        let (spawner, program) = (self.spawner, claude.path)
        let child: any PTYChild
        do throws(PTYError) {
            child = try await BlockingExecutor.run { () throws(PTYError) -> any PTYChild in
                try spawner.spawn(
                    program: program, arguments: arguments, environment: environment,
                    directory: directory, size: size)
            }
        } catch {
            channel.close()
            throw error
        }
        if Task.isCancelled { channel.close() }
        channel.started(child)
    }

    // The open attach of the view, or nil. An open in flight gives no attach until it ends.
    package func attach(_ view: PTYView) -> PTYAttach? {
        guard let attach = attaches[view], attach.isOpen else { return nil }
        return attach
    }

    // Each open attach one time, in the order of the views.
    package func list() -> [PTYAttach] {
        attaches.values.filter(\.isOpen).sorted { $0.view < $1.view }
    }

    // Close each attach and the trust run with SIGHUP. An open in flight is cancelled.
    package func closeAll() {
        for view in attaches.keys.sorted() { attaches[view]?.close() }
        trust?.close()
    }

    private func remove(_ attach: PTYAttach) {
        if attaches[attach.view] === attach { attaches[attach.view] = nil }
    }

    private func removeTrust(_ run: PTYRun) {
        if trust === run { trust = nil }
    }
}
