import BifrostFoundation
import Darwin

// A terminal model with no view for a hidden attach (the section "Processes" of the architecture
// design). BifrostChat makes it from a SwiftTerm Terminal (HiddenTerminalModel). Its replies (for
// example a cursor position report) go to the PTY, so Claude Code gets the answers that a chat
// window gives.
@MainActor
public protocol HiddenTerminal: AnyObject {
    // Feed a chunk of the output of the attach. The result is the replies of the terminal.
    func feed(_ bytes: [UInt8]) -> [UInt8]
}

// The session input (docs/behaviour/input.md): all text and keys that Bifrost types into a session
// go through it. Input goes only to an owned session that runs, through "claude attach <short id>".
//
// Each send and each Interrupt is a job: one async task. The jobs of a session run one after the
// other, in call order. A job checks the row, then it takes the chat attach of the session, or it
// opens a hidden attach (PTYView.input) at the session size and closes it at its end. It waits
// until the attach is ready, then it writes each step. Just before each write it checks the row,
// the attach, the short ID and the block again. An Interrupt cancels the task of each send of its
// session that did not write yet.
//
// The chat terminals own the chat attaches and read their output. A chat gives each chunk and the
// end of its attach to output and ended, and it gives chatOpening, opened, chatOpenFailed,
// setBlocked and leftKey. One attach serves each session: a chat open waits until the session has
// no job, and a job waits while a chat open runs.
@MainActor
public final class SessionInput {
    // An attach is ready for a send when its output was quiet for this time one time.
    fileprivate static let quietTime = Duration.milliseconds(1500)
    // A busy session never gets quiet. After this time, a wait ends and Bifrost writes nothing.
    private static let readyLimit = Duration.seconds(15)
    // A hidden attach closes this time after the last write.
    private static let closeDelay = Duration.seconds(1)
    // Two Esc open the rewind menu. So an Interrupt within this time of an Esc has no effect.
    private static let interruptGap = Duration.milliseconds(1500)
    // A working session shows a spinner, so its output never gets quiet. The Esc of an
    // Interrupt goes this time after the first output of the attach.
    private static let interruptConnect = Duration.milliseconds(300)
    // After an Esc, the next write to the session waits this time. Else the session can read
    // the Esc and the next bytes as one key.
    private static let escGap = Duration.milliseconds(200)
    // The left arrow key on an empty prompt opens the agent view. The chat window finds the
    // agent view some time later, so a send to that chat waits this time after the key.
    private static let leftKeyWait = Duration.seconds(2)

    private let ptys: PTYManager
    private let sizes: SessionSizeReader
    private let rows: () -> [SessionRow]
    private let makeTerminal: (TerminalSize) -> any HiddenTerminal
    private let timeline: Timeline
    private let log: any SessionsLog
    // The jobs of each session that did not end, in call order. The first job runs.
    private var queues: [String: [Job]] = [:]
    // The sessions with an Interrupt that waits or runs.
    private var interrupting: Set<String> = []
    // The number of the chat opens in flight of each session.
    private var chatOpens: [String: Int] = [:]
    // The output of each attach that a job can use: the chat attaches that opened, and the
    // hidden attach of a job.
    private var watches: [PTYView: OutputWatch] = [:]
    // The chats that show the agent view.
    private var blocked: Set<SessionID> = []
    // The time of the last left arrow key of each chat.
    private var leftKeys: [SessionID: Duration] = [:]
    // The time of the last Esc of each session.
    private var lastEsc: [String: Duration] = [:]

    // rows gives the rows of the last session list. makeTerminal makes the terminal model of a
    // hidden attach at the session size. All times come from the clock.
    public convenience init(
        ptys: PTYManager, sizes: SessionSizeReader, rows: @escaping () -> [SessionRow],
        makeTerminal: @escaping (TerminalSize) -> any HiddenTerminal,
        clock: any Clock<Duration>
    ) {
        self.init(
            ptys: ptys, sizes: sizes, rows: rows, makeTerminal: makeTerminal, clock: clock,
            log: SystemSessionsLog())
    }

    // The init of a test, with the log that records the events.
    package init(
        ptys: PTYManager, sizes: SessionSizeReader, rows: @escaping () -> [SessionRow],
        makeTerminal: @escaping (TerminalSize) -> any HiddenTerminal,
        clock: any Clock<Duration>, log: any SessionsLog
    ) {
        self.ptys = ptys
        self.sizes = sizes
        self.rows = rows
        self.makeTerminal = makeTerminal
        self.timeline = Timeline(clock)
        self.log = log
    }

    // MARK: - The calls

    // Send the text as a message or a slash command. This throws the reason of a failure.
    package func send(_ session: String, _ text: String) async throws(InputRefusal) {
        switch InputPlan.plan(text) {
        case .refused(let refusal): throw refusal
        case .ready(_, let steps):
            if let refusal = await run(Job(.send, session, steps)) { throw refusal }
        }
    }

    // Send one Esc. A red box does not block it. A second Interrupt while one waits or runs has
    // no effect. The Interrupt first cancels each send of the session that did not write yet,
    // then it runs after the jobs before it, so one attach at a time stays open.
    public func interrupt(_ session: String) async throws(InputRefusal) {
        guard interrupting.insert(session).inserted else { return }
        for job in queues[session] ?? [] where job.kind == .send && !job.committed {
            job.task?.cancel()
        }
        if let refusal = await run(Job(.interrupt, session, InputPlan.interruptSteps)) {
            throw refusal
        }
    }

    // Return when the session has no job. A job can start while the caller waits, so the wait
    // checks again after each job.
    package func idle(_ session: String) async {
        while let last = queues[session]?.last?.task { _ = await last.value }
    }

    // True when the bytes that a chat window writes hold the left arrow key (normal or
    // application mode: ESC [ D or ESC O D).
    nonisolated package static func hasLeftKey(_ bytes: [UInt8]) -> Bool {
        bytes.firstRange(of: [0x1b, 0x5b, 0x44]) != nil
            || bytes.firstRange(of: [0x1b, 0x4f, 0x44]) != nil
    }

    // MARK: - The chat views

    // Only a chat window calls these, so each takes the session of the chat panel.

    // A chat window calls this before it opens the attach of its chat view. The call returns
    // when the session has no job, and it marks the open at once. Until the open ends (opened or
    // chatOpenFailed), each job of the session waits. During the spawn the manager has no attach
    // of the chat view, so a job could else open a hidden attach beside the attach of the chat.
    package func chatOpening(chat: SessionID) async {
        await idle(chat.text)
        chatOpens[chat.text, default: 0] += 1
    }

    // The open of the chat view ended with no attach: a refused open, a failed spawn, a close
    // during the spawn, or a window that closed during the wait.
    package func chatOpenFailed(chat: SessionID) {
        chatOpenEnded(chat.text)
        wake(chat.text)
    }

    // An attach to the short ID opened for the chat view. Its output starts a new watch, and the
    // block and the left arrow key of the old attach go. The open of the chat view ended.
    package func opened(chat: SessionID, shortId: ShortID) {
        watches[.chat(chat)] = OutputWatch(shortId: shortId)
        blocked.remove(chat)
        leftKeys[chat] = nil
        chatOpenEnded(chat.text)
        wake(chat.text)
    }

    // A chunk of output of the attach of the chat.
    package func output(chat: SessionID) {
        guard let watch = watches[.chat(chat)], watch.chunk(at: timeline.now()) else { return }
        wake(chat.text)
    }

    // The attach of the chat closed or its child ended.
    package func ended(chat: SessionID) { ended(view: .chat(chat)) }

    // The chat window shows the agent view (true), or not.
    package func setBlocked(chat: SessionID, _ isBlocked: Bool) {
        if isBlocked {
            blocked.insert(chat)
        } else {
            blocked.remove(chat)
        }
    }

    // The chat window wrote the left arrow key to its view.
    package func leftKey(chat: SessionID) {
        leftKeys[chat] = timeline.now()
    }

    // The attach of the view closed or its child ended.
    private func ended(view: PTYView) {
        watches[view] = nil
        if case .chat(let chat) = view {
            blocked.remove(chat)
            leftKeys[chat] = nil
        }
        wake(view.session)
    }

    // MARK: - The queue

    // Run the job after the jobs before it in its session, and return its refusal or nil.
    private func run(_ job: Job) async -> InputRefusal? {
        let previous = queues[job.session]?.last?.task
        queues[job.session, default: []].append(job)
        let task = Task {
            _ = await previous?.value
            let refusal: InputRefusal?
            do throws(InputRefusal) {
                try await start(job)
                refusal = nil
            } catch {
                refusal = error
            }
            queues[job.session]?.removeAll { $0 === job }
            if queues[job.session]?.isEmpty == true { queues[job.session] = nil }
            if job.kind == .interrupt { interrupting.remove(job.session) }
            return refusal
        }
        job.task = task
        return await task.value
    }

    // Wake the wait of the job that runs in the session. It then checks what it waits for.
    private func wake(_ session: String) {
        queues[session]?.first?.wake.fire()
    }

    private func chatOpenEnded(_ session: String) {
        guard let count = chatOpens[session] else { return }
        chatOpens[session] = count > 1 ? count - 1 : nil
    }

    // MARK: - The job

    // The start of a job: the check of the row, then the chat attach of the session, or a hidden
    // attach at the size of the session. While a chat open runs, the job waits, then it starts
    // again with the state after the open.
    private func start(_ job: Job) async throws(InputRefusal) {
        while true {
            let target = try check(job)
            try job.checkCancel()
            if chatOpens[job.session] != nil {
                try await hold(job)
                continue
            }
            if let chat = chatView(job.session), ptys.attach(chat) != nil {
                return try await viaChat(job, view: chat)
            }
            guard let pid = target.pid else { throw .noPid }
            let size = await sizes.read(pid: pid)
            try job.checkCancel()
            guard let size, size.isValid else { throw .noSize }
            // A chat window can open during the read. The job then starts again and uses it.
            let chat = chatView(job.session).flatMap { ptys.attach($0) }
            if chat != nil || chatOpens[job.session] != nil {
                continue
            }
            // The rows can change during the read.
            return try await viaHidden(job, checked: check(job).attach, size: size)
        }
    }

    // The row must be an owned session that runs, with a short ID that "claude attach" accepts
    // (AttachRules.check). The result has the pid of the row and the checked hidden attach. For
    // a send, a prompt box blocks the job, because typed text can answer a prompt by accident.
    // Live state is a hint, not an authority: a line of the mod can clear the box, so a session
    // that the session list shows as waiting on a prompt (waitingFor) blocks a send too.
    private func check(_ job: Job) throws(InputRefusal) -> (pid: pid_t?, attach: CheckedAttach) {
        let rows = self.rows()
        guard let row = rows.first(where: { $0.sessionId == job.session }),
            let shortId = row.shortId,
            let attach = try? AttachRules.check(rows, view: .input(job.session), shortId: shortId)
        else { throw .notOwned }
        let listWaits = row.status == .waiting && row.waitingFor?.isEmpty == false
        if job.kind == .send && (row.alert.blocksPrompt || listWaits) {
            throw .prompt
        }
        return (row.pid, attach)
    }

    // Wait until each chat open of the session ended.
    private func hold(_ job: Job) async throws(InputRefusal) {
        while chatOpens[job.session] != nil {
            await job.wake.wait(until: nil, on: timeline)
            try job.checkCancel()
        }
    }

    // True when the view is a chat that shows the agent view.
    private func isBlocked(_ view: PTYView) -> Bool {
        view.chat.map { blocked.contains($0) } ?? false
    }

    // The chat view of a session. A row ID that is not a session ID has no chat.
    private func chatView(_ session: String) -> PTYView? {
        SessionID(session).map(PTYView.chat)
    }

    // Write into the chat attach of the session. Never close it.
    private func viaChat(_ job: Job, view: PTYView) async throws(InputRefusal) {
        if isBlocked(view) { throw .agentView }
        // The attach can close before its chat tells the end.
        guard let watch = watches[view] else { throw .chatGone }
        try await ready(job, view: view, watch: watch, limit: timeline.now() + Self.readyLimit)
        try await type(job, view: view, watch: watch) { [ptys] bytes in
            ptys.attach(view)?.write(bytes) ?? false
        }
    }

    // Open the checked hidden attach (PTYView.input, in the root folder) at the session size,
    // with a terminal model. An attach sets the session size for all clients (M3), so it opens
    // at the size now.
    // Each end of the job closes the attach (SIGHUP to the attach child only), 1 s after the
    // last write or at once after an error.
    private func viaHidden(
        _ job: Job, checked: CheckedAttach, size: TerminalSize
    ) async throws(InputRefusal) {
        let view = checked.view
        let limit = timeline.now() + Self.readyLimit
        let model = HiddenModel(terminal: makeTerminal(size))
        let opened: PTYAttach?
        do throws(PTYError) {
            opened = try await ptys.open(checked, size: size)
        } catch {
            log.record(.hiddenAttachFailed(message: error.message))
            throw .endedBeforeReady
        }
        guard let attach = opened else { throw .endedBeforeReady }
        let watch = OutputWatch(shortId: checked.shortId)
        watches[view] = watch
        let reader = read(attach, model: model, watch: watch)
        // Each end closes the attach, also an end by a cancel right after the open.
        defer {
            reader.cancel()
            attach.close()
            if watches[view] === watch { watches[view] = nil }
        }
        // A cancel during the spawn gives no attach: the manager closed the new child.
        try job.checkCancel()
        try await ready(job, view: view, watch: watch, limit: limit)
        try await type(job, view: view, watch: watch) { bytes in
            let written = attach.write(bytes)
            // A reply less than 200 ms after the Esc could join the Esc into one key.
            if bytes == [0x1b] { model.answers = false }
            return written
        }
        try? await timeline.sleep(until: timeline.now() + Self.closeDelay)
    }

    // Give each chunk of the hidden attach to its terminal model, and the replies of the model
    // to the attach. Then the chunk and the end go to the watch.
    private func read(_ attach: PTYAttach, model: HiddenModel, watch: OutputWatch)
        -> Task<Void, Never>
    {
        Task { [weak self] in
            for await chunk in attach.output {
                guard let self else { return }
                let replies = model.terminal.feed(chunk)
                if model.answers && !replies.isEmpty { _ = attach.write(replies) }
                if watch.chunk(at: timeline.now()) { wake(attach.view.session) }
            }
            guard let self, watches[attach.view] === watch else { return }
            ended(view: attach.view)
        }
    }

    // A send waits until the output of the attach was quiet for 1.5 s. An Interrupt waits until
    // 300 ms after the first output. Each waits at most until the limit, and an end of the
    // attach ends the wait at once.
    private func ready(_ job: Job, view: PTYView, watch: OutputWatch, limit: Duration)
        async throws(InputRefusal)
    {
        let gone: InputRefusal = view.chat != nil ? .chatGone : .endedBeforeReady
        while true {
            try job.checkCancel()
            guard watches[view] === watch else { throw gone }
            let now = timeline.now()
            guard now < limit else { throw .notReady }
            switch job.kind {
            case .send:
                if watch.isQuiet(at: now) { return }
                await job.wake.wait(until: min(watch.quietAt ?? limit, limit), on: timeline)
            case .interrupt:
                guard let first = watch.firstAt else {
                    await job.wake.wait(until: limit, on: timeline)
                    continue
                }
                guard now < first + Self.interruptConnect else { return }
                // The attach can end during the 300 ms.
                try? await timeline.sleep(until: first + Self.interruptConnect)
                guard watches[view] === watch else { throw gone }
                return
            }
        }
    }

    // Each step waits, then writes. Just before each write, the job checks the row, the attach
    // and the block. A prompt can open during a wait. Then the CR does not go, so it cannot
    // answer the prompt. The first write commits a send: an Interrupt cannot cancel it after
    // that, so the text never stays in the prompt without its CR.
    private func type(
        _ job: Job, view: PTYView, watch: OutputWatch, write: ([UInt8]) -> Bool
    ) async throws(InputRefusal) {
        let gone: InputRefusal = view.chat != nil ? .chatGone : .attachGone
        for step in job.steps {
            if step.delay > .zero {
                try await sleep(job, until: timeline.now() + step.delay)
            }
            let esc = job.kind == .interrupt && step.data == InputPlan.esc
            if esc, let last = lastEsc[job.session], timeline.now() - last < Self.interruptGap {
                return
            }
            try await gaps(job, view: view)
            let shortId = try check(job).attach.shortId
            guard watches[view] === watch else { throw gone }
            guard watch.shortId == shortId else { throw .oldAttach }
            if isBlocked(view) { throw .agentView }
            try job.checkCancel()
            job.committed = true
            guard write(Array(step.data.utf8)) else { throw gone }
            if esc { lastEsc[job.session] = timeline.now() }
        }
    }

    // Wait for the Esc gap, and for a send the wait after a left arrow key. A new left arrow key
    // during the wait starts the wait again. The gaps of one step wait at most 15 s.
    private func gaps(_ job: Job, view: PTYView) async throws(InputRefusal) {
        let limit = timeline.now() + Self.readyLimit
        while true {
            let now = timeline.now()
            var until = lastEsc[job.session].map { $0 + Self.escGap } ?? now
            if job.kind == .send, let key = view.chat.flatMap({ leftKeys[$0] }) {
                until = max(until, key + Self.leftKeyWait)
            }
            guard until > now else { return }
            guard until <= limit else { throw .notReady }
            try await sleep(job, until: until)
        }
    }

    // Sleep on the clock. A cancel ends the sleep of a send that did not write yet.
    private func sleep(_ job: Job, until time: Duration) async throws(InputRefusal) {
        try? await timeline.sleep(until: time)
        try job.checkCancel()
    }

}

// MARK: - The parts of a job

// One send or Interrupt of a session.
@MainActor
private final class Job {
    enum Kind {
        case send, interrupt
    }

    let kind: Kind
    let session: String
    let steps: [InputStep]
    let wake = Wake()
    var task: Task<InputRefusal?, Never>?
    // True after the first write. An Interrupt cancels only a send that did not write yet.
    var committed = false

    init(_ kind: Kind, _ session: String, _ steps: [InputStep]) {
        self.kind = kind
        self.session = session
        self.steps = steps
    }

    // An Interrupt cancelled this send before its first write.
    func checkCancel() throws(InputRefusal) {
        if kind == .send && !committed && Task.isCancelled { throw .cancelled }
    }
}

// The output of one attach, from its open. The attach is connected after its first chunk. It is
// ready for a send after its output was quiet for 1.5 s one time, and it stays ready.
@MainActor
private final class OutputWatch {
    let shortId: ShortID
    private(set) var firstAt: Duration?
    private var lastAt: Duration?
    private var settled = false

    init(shortId: ShortID) {
        self.shortId = shortId
    }

    // The time when the output is quiet, if no chunk comes before it.
    var quietAt: Duration? { lastAt.map { $0 + SessionInput.quietTime } }

    func isQuiet(at time: Duration) -> Bool {
        settled || quietAt.map { time >= $0 } == true
    }

    // A chunk came. The result is true for the first chunk.
    func chunk(at time: Duration) -> Bool {
        if isQuiet(at: time) { settled = true }
        lastAt = time
        guard firstAt == nil else { return false }
        firstAt = time
        return true
    }
}

// The terminal model of a hidden attach. Its replies go to the attach until the Esc of an
// Interrupt, and nowhere after it (the attach closes 1 s later).
@MainActor
private final class HiddenModel {
    let terminal: any HiddenTerminal
    var answers = true

    init(terminal: any HiddenTerminal) {
        self.terminal = terminal
    }
}

// The wait of a job for an event of its session: the end of a chat open, the first chunk of an
// attach or the end of an attach. The wait also ends at its time on the clock and at a cancel of
// the task of the job. After the wait, the job checks again what it waits for.
@MainActor
private final class Wake {
    private var waiting: CheckedContinuation<Void, Never>?
    private var alarm: Task<Void, Never>?

    func wait(until time: Duration?, on timeline: Timeline) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting = continuation
                guard let time else { return }
                alarm = Task { [weak self] in
                    guard (try? await timeline.sleep(until: time)) != nil, !Task.isCancelled
                    else { return }
                    self?.fire()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fire() }
        }
    }

    func fire() {
        alarm?.cancel()
        alarm = nil
        waiting?.resume()
        waiting = nil
    }
}

extension PTYView {
    // The session of a chat view, or nil for a hidden attach.
    fileprivate var chat: SessionID? {
        if case .chat(let session) = self { session } else { nil }
    }
}
