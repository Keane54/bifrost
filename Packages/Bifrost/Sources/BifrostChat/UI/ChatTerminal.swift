// The shell of one chat window: the terminal view, its attach to one session and its chat input
// (docs/behaviour/chat.md).
//
// The attach: one AttachState. A window waits for a row that can attach. A window that is not
// focused reads the session size one time. Then one async method opens the attach of the view
// PTYView.chat, and the window owns the PTYAttach: it reads the output and the exit, and it writes,
// resizes and closes. Each chunk and the end of the attach also go to the session input and to the
// size watcher of the owner. Each end of the window writes one line (an exit, a failed write or a
// failed open) and closes the attach. A window that ended does not attach again by itself. Each
// close only detaches: SIGHUP to the attach child, and the session continues.
//
// The agent view: 250 ms after the last chunk, and at least each 1 s during output, the window
// reads the screen at once and takes the step of AgentView. The agent view blocks the input and
// makes the window attach again, at most 3 times in 60 s (the history of the owner).
//
// The size: SizeSync (the services of the chat) keeps the size facts and gives effects. The window
// runs them in order, at once, with one SizeSender on the clock of the owner. The frame of the
// terminal view is the frame of the size that SizeSync decided. TerminalFit has the cell and the
// scroll bar math: the fit is the panel size divided by the size of a cell. The sizeChanged call of
// SwiftTerm never resizes the PTY.
//
// A hidden terminal (a minimised frame, a back tab) stops its Metal renderer (TerminalMetal) and
// leaves its superview. The PTY and the terminal model stay. A visible terminal goes back and
// starts Metal again.
//
// The dictation of the chat: one ChatDictation of BifrostDictation. Its chatInput gets the keys,
// the data and the other input of the chat: the hold key starts and stops the dictation, and the
// text goes to the PTY through the dictation, so the keys can wait while a final text types. Each
// event of the dictation service for this view goes to it. The chat gives it the PTY (send), the
// block of the dictation key, the notice line and the look of the frame (deps.look). An end of the
// PTY, the agent view block, a reattach and the close stop the dictation and its typer at once. A
// new attach clears the typed text of the leading space.
import AppKit
import BifrostDictation
import BifrostFoundation
import BifrostKeyboard
import BifrostLayout
import BifrostSessions
import Observation
import SwiftTerm

// The state of a chat terminal, for the owner, the debug bench and the tests.
@MainActor
public struct ChatTerminalState: Sendable, Equatable {
    // The attach runs.
    public var attached: Bool
    // The window ended and shows why (an exit, a failed write or a failed open).
    public var ended: Bool
    // The input of the window is blocked while the window shows the agent view (D1).
    public var blocked: Bool
    // The note over the terminal, or nil.
    public var note: String?
    // The terminal draws with Metal.
    public var metal: Bool
}

// The attach of a chat window. Each case holds only its own facts, so a state that cannot occur
// cannot be made.
@MainActor
enum AttachState {
    // The window waits for the first session list, for a row that can attach, or for its panel.
    case waiting
    // A window that is not focused reads the session size one time before its first open.
    case readingSize
    // The open runs. A reattach after the agent view also blocks the input until it ends.
    case opening(Task<Void, Never>)
    case reattaching(Task<Void, Never>)
    // The attach runs. textShown: the screen showed text of this attach.
    case attached(textShown: Bool, agentView: AgentWatch)
    // The window ended and shows the line. gaveUp: the agent view guard gave up before the end.
    case ended(line: String, gaveUp: Bool)
    // The window closed. Nothing acts after this.
    case closed

    // True while the attach of the window runs, so the window shows its session. A reattach
    // after the agent view keeps the window on the session.
    var showsSession: Bool {
        switch self {
        case .attached, .reattaching: true
        case .waiting, .readingSize, .opening, .ended, .closed: false
        }
    }
}

@MainActor
@Observable
public final class ChatTerminal {
    package static let giveUpText =
        "The agent view opened 3 times in 60 seconds. Close this window and open it again."

    package let sessionId: String
    package let body: ChatPanelBody

    package let view: ChatTerminalView
    // The PTY view of the chat.
    let ptyView: PTYView
    // The session of the chat panel.
    private let session: SessionID
    // The chat panel of the chat. The look of the dictation of the chat goes to its frame.
    let panel: PanelID

    // The attach of the window.
    private(set) var attachState = AttachState.waiting
    // The task of the last read of the session size, until the window closes or ends. A test
    // keeps a copy of it and waits for its end.
    private(set) var sizeRead: Task<Void, Never>?
    // True when the time of the agent view check or of a size send came, and that timer did not
    // run yet (Debouncer.isDue).
    package var timersDue: Bool { agentCheck.isDue || sender.isDue }
    // The block of the input and the note, as the session input and the body got them.
    private var blocked = false
    private var note: String?

    // The owner gives the attach check, the PTY manager, the session input, the attach history,
    // the session size and the look of the frame. The parts that the chats share and that never
    // change come in the init.
    @ObservationIgnored private weak var owner: ChatTerminals?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let links: LinkOpener
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let dictationParts: ChatDictationParts?
    @ObservationIgnored private let metal: TerminalMetal
    // The attach that the window owns, from the end of its open until its close or its exit.
    // During a reattach, the old attach stays until just before the spawn of the new attach.
    @ObservationIgnored private var pty: PTYAttach?
    // The attach of the row of the window, or the reason why the window cannot attach.
    @ObservationIgnored private var target = AttachRules.target(nil, loaded: false)
    // The size facts, the sender of the sizes to the PTY, and true while the size effects run.
    @ObservationIgnored private var sizing = SizeSync()
    @ObservationIgnored private lazy var sender = SizeSender(
        clock: clock, attached: { [weak self] in self?.isAttached == true },
        send: { [weak self] in self?.sendSize($0) })
    @ObservationIgnored private var resizing = false
    // The next agent view check, and the time of the first chunk after the last check.
    @ObservationIgnored private let agentCheck: Debouncer
    @ObservationIgnored private var uncheckedSince: ContinuousClock.Instant?
    // The dictation of the chat, with the chat input (the hold key, Shift+Enter).
    @ObservationIgnored private lazy var dictation = ChatDictation(
        session: session, chat: self, service: dictationParts?.service, clock: clock,
        vimMode: dictationParts?.vimMode ?? { false })
    // SessionAlert.blocksPrompt of the row of the chat.
    @ObservationIgnored private var rowBlocks = false
    // The last view of the window.
    @ObservationIgnored private var shown = ChatView.hidden
    // The size that SizeSync gave the terminal view.
    @ObservationIgnored private var size = SizeRule.defaultTerm
    // True while the scroll bar shows (updateHistory).
    @ObservationIgnored private var history = false
    // The keys whose key down the chat dropped (isCommandText), until their key up.
    @ObservationIgnored private var droppedKeys: Set<KeyCode> = []

    init(
        session: SessionID, body: ChatPanelBody, font: NSFont, renderer: TerminalRenderer,
        owner: ChatTerminals
    ) {
        self.session = session
        sessionId = session.text
        panel = .chat(session)
        self.body = body
        self.owner = owner
        clock = owner.clock
        now = owner.now
        links = owner.links
        pasteboard = owner.pasteboard
        dictationParts = owner.dictation
        agentCheck = Debouncer(clock: owner.clock)
        ptyView = .chat(session)
        view = ChatTerminalView(sessionId: sessionId, font: font)
        metal = TerminalMetal(view: view, renderer: renderer, clock: owner.clock)
        view.chat = self
        body.adopt(self)
        body.dictationNotice.openSettings = { [weak self] in self?.openMicrophoneSettings() }
        publish()
        applySize()
        // The body can show in its frame already: measure it.
        panelChanged()
    }

    public var state: ChatTerminalState {
        ChatTerminalState(
            attached: isAttached, ended: isEnded, blocked: blocked, note: note,
            metal: view.isUsingMetalRenderer)
    }

    // True when the screen shows the first text of the attach, or the window ended and shows
    // why. The loader of Take control waits for this (phase 4b).
    package var isShowingText: Bool {
        switch attachState {
        case .attached(let textShown, _): textShown
        case .ended: true
        case .waiting, .readingSize, .opening, .reattaching, .closed: false
        }
    }

    // MARK: - The inputs of the owner

    // Each update of the session list. A window that waits attaches when its row can attach.
    func setRow(_ row: SessionRow?, loaded: Bool) {
        guard !isClosed else { return }
        // A choice that typed text can answer stops a dictation at once.
        rowBlocks = row?.alert.blocksPrompt ?? false
        dictation.chatInput.row(blocks: rowBlocks)
        target = AttachRules.target(row, loaded: loaded)
        attachIfReady()
        // The agent view waits for the row. When the row can attach, check the screen again.
        if case .attached(_, .waiting) = attachState, target.isReady { checkAgentView() }
        publish()
    }

    // The view of the window, and true when the window became focused.
    func setView(_ next: ChatView, focusGained: Bool) {
        guard !isClosed else { return }
        let lost = shown.focused && !next.focused
        shown = next
        // A window that lost the focus gives the keyboard focus back to its window.
        if lost, let window = view.window, window.firstResponder === view {
            window.makeFirstResponder(nil)
        }
        sizing.setView(next, focusGained: focusGained, attached: isAttached, now: now())
        runSize()
        attachIfReady()
        showTerminal(next.visible)
    }

    // The size of the session from the size watcher.
    func setSessionSize(_ size: TerminalSize?) {
        guard !isClosed else { return }
        sizing.setSessionSize(size, attached: isAttached, now: now())
        runSize()
    }

    #if DEBUG
    // The bytes of the output of this attach, for the debug bench.
    @ObservationIgnored package private(set) var benchOutput = 0
    #endif

    // A chunk of the attach. The session input and the size watcher get it first, then the
    // terminal.
    func received(_ chunk: [UInt8]) {
        owner?.input?.output(chat: session)
        // A full redraw: another client can have changed the size of the session.
        if PTYAttach.hasFullRedraw(chunk) { owner?.watchSessionSize(ptyView) }
        feed(chunk)
    }

    // The child of the PTY ended.
    func exited(code: Int32) {
        guard isAttached else { return }
        end("[process ended: code \(code)]")
    }

    // Use a new font. The cells change, so the fit and the screen size change. The frame goes to
    // zero first, so SwiftTerm does not resize the grid itself (its resize also resets modes of
    // the terminal). Then the frame of the size of SizeSync comes back with the new cells.
    func setFont(_ font: NSFont) {
        guard !isClosed, font != view.font else { return }
        view.setFrameSize(.zero)
        view.font = font
        applySize()
        panelChanged()
    }

    // Attach again after the end of the window (the Resume of phase 4). A window that did not
    // end does nothing. The attach waits for a row that can attach. The agent view guard starts
    // again, so the next agent view stops the input again. The attach history of the session
    // stays. The action runner calls it after Resume and Take control.
    package func restart() {
        guard case .ended = attachState else { return }
        move(to: .waiting)
        resetTerminal()
        attachIfReady()
    }

    // Take control of the session ended (ChatTerminals.holdsAttach). A window that waits attaches
    // now when its row can attach.
    func takeControlEnded() {
        guard !isClosed else { return }
        attachIfReady()
    }

    // The window closes. Close the attach (SIGHUP to the attach child). The session continues.
    func dispose() {
        guard !isClosed else { return }
        // The close stops a dictation, so the microphone closes: the stop goes to the service.
        dictation.dispose()
        // An open in flight is cancelled: the manager closes its new child when the spawn ends.
        switch attachState {
        case .opening(let task), .reattaching(let task): task.cancel()
        default: break
        }
        stopTimers()
        move(to: .closed)
        // Only the own attach closes, so a newer window of the session keeps its attach.
        closePTY()
        view.removeFromSuperview()
        view.chat = nil
        body.release(self)
        metal.close()
    }

    // MARK: - The inputs of the views

    // The body changed its size, or it went into a window or left it.
    func panelChanged() {
        guard !isClosed else { return }
        let panel = body.panelSize
        let fit = self.fit
        sizing.setPanel(
            panel, fit: fit.size(fitting: panel), screen: fit.screen(size), attached: isAttached,
            now: now())
        runSize()
        attachIfReady()
    }

    // The terminal view went into a window or left it.
    func windowChanged() {
        metal.windowChanged()
    }

    // SwiftTerm changed its grid: the frame of the size, the scroll bar, or a new cell size on a
    // screen with another backing scale (SwiftTerm measures the cells again and resizes its own
    // grid). The grid must have the size of SizeSync, and only SizeSync resizes the PTY. So a grid
    // of another size gets the frame of that size again, and the fit follows the cells.
    func gridChanged() {
        guard !isClosed else { return }
        let grid = view.terminalDimensions
        if grid.cols != size.cols || grid.rows != size.rows {
            applySize()
            panelChanged()
        }
        updateHistory()
    }

    // The text of the keys, a paste and the replies of the terminal, through the data rule of the
    // chat input. A reply that is not UTF-8 (a mouse report of the legacy encoding past column 94)
    // keeps its bytes: it is input with no key down, and it goes to the PTY as it is.
    func terminalData(_ bytes: [UInt8]) {
        guard !isClosed else { return }
        guard let text = String(validating: bytes, as: UTF8.self) else {
            dictation.chatInput.other()
            write(bytes)
            return
        }
        dictation.chatInput.data(text)
    }

    // A mouse down or a paste: input with no key down.
    func otherInput() {
        guard !isClosed else { return }
        dictation.chatInput.other()
    }

    // A Cmd+click on a link (LinkOpener.click).
    func openLink(_ link: String) {
        links.click(link)
    }

    // OSC 52: put the text on the pasteboard.
    func copy(_ content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - The keys

    // A key of the chat, from its terminal view (ChatKeyTarget). True when the chat takes it.
    func chatKey(_ event: KeyEvent, dictationKey: KeyCode?) -> Bool {
        guard !isClosed else { return false }
        // A repeat and the key up of a dropped key go nowhere too, so a kitty repeat or release
        // never comes without its press. A new key down of the code starts again.
        let follows = droppedKeys.contains(event.keyCode) && (!event.isDown || event.isRepeat)
        if !event.isDown || !event.isRepeat { droppedKeys.remove(event.keyCode) }
        if dictation.chatInput.key(event, dictationKey: dictationKey) { return true }
        if follows { return true }
        guard Self.isCommandText(event) else { return false }
        droppedKeys.insert(event.keyCode)
        return true
    }

    // A key down of Cmd with one printable character. The filter calls chatKey after the Bifrost
    // keys, and AppKit gives the menu its turn before the filter, so no Bifrost key and no menu
    // item took it. SwiftTerm sends such a key as a kitty key while Claude Code has the kitty
    // keyboard protocol on. The chat takes it, so the terminal does not get it.
    static func isCommandText(_ event: KeyEvent) -> Bool {
        guard event.isDown, event.modifiers.contains(.command) else { return false }
        // The space bar is a named key, but it is one printable character too.
        if case .named(.space) = event.key { return true }
        guard case .text(let text) = event.key, text.count == 1 else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            !scalar.properties.generalCategory.isControlOrPrivate
        }
    }

    // The terminal view got the key focus or lost it (ChatKeyTarget).
    func chatFocus(_ focused: Bool, dictationKey: KeyCode?) {
        guard !isClosed else { return }
        dictation.chatInput.focus(focused, dictationKey: dictationKey)
    }

    // MARK: - The dictation

    #if DEBUG
    // The view of the dictation of the chat, for the tests.
    var dictationView: DictationView { dictation.view }
    #endif

    // An event of the dictation service for the view of this chat.
    func dictationEvent(_ event: DictationViewEvent) {
        guard !isClosed else { return }
        dictation.event(event)
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: DictationNoticeView.microphoneSettings) else { return }
        dictationParts?.openURL(url)
    }

    // MARK: - The attach

    private var isAttached: Bool {
        if case .attached = attachState { true } else { false }
    }

    private var isOpening: Bool {
        switch attachState {
        case .opening, .reattaching: true
        default: false
        }
    }

    private var isEnded: Bool {
        if case .ended = attachState { true } else { false }
    }

    private var isClosed: Bool {
        if case .closed = attachState { true } else { false }
    }

    // A window that waits attaches when its row can attach.
    private func attachIfReady() {
        guard case .waiting = attachState, case .ready(let shortId, _) = target else { return }
        // While Take control of the session runs, the row can already show the new process, but
        // the move is not done. The window attaches when Take control ends (takeControlEnded).
        guard owner?.holdsAttach(sessionId) != true else { return }
        // A visible window waits for the size of its panel, so the attach gets the right size.
        guard !sizing.waitsForPanel else { return }
        if sizing.needsSessionSize {
            readSessionSize()
        } else {
            let size = sizing.openSize
            move(to: .opening(Task { await open(shortId: shortId, size: size) }))
            sizing.open(at: size, now: now())
            runSize()
        }
    }

    // One read of the session size before the first open of a window that is not focused. A
    // session with no pid gives no size.
    private func readSessionSize() {
        move(to: .readingSize)
        sizeRead = Task { [weak self] in
            guard let self, case .readingSize = attachState else { return }
            let size = await owner?.readSessionSize(sessionId)
            guard case .readingSize = attachState else { return }
            sizing.sessionRead(size)
            move(to: .waiting)
            attachIfReady()
        }
    }

    // Attach again at the size of the terminal: the agent view showed. The terminal resets, and
    // the dictation of the old attach stops.
    private func reattach(shortId: ShortID) {
        let size = sizing.terminal
        move(to: .reattaching(Task { await open(shortId: shortId, size: size) }))
        resetTerminal()
        sizing.open(at: size, now: now())
        runSize()
    }

    // Open the PTY of "claude attach <short id>" in the folder of the row. The size must be good,
    // and the rows of now must allow the attach of this chat view. The spawn runs off the main
    // actor. The close of the window cancels this task (C6): a window that closed before the open
    // started does not open, and the manager closes a new child at once (SIGHUP to its pid only).
    //
    // One attach serves each session (D1). So the open first waits until the jobs of the session
    // input ended, and the session input marks the open in the same turn: a job of the session
    // then waits until the open ends. The rows can change during the wait, so the open checks
    // them again after it. Each end of the open with no attach clears the mark. A reattach closes
    // the old attach after the wait, just before the spawn.
    private func open(shortId: ShortID, size: TerminalSize) async {
        guard size.isValid else { return openFailed(AttachRefusal.badSize.message) }
        guard let ptys = owner?.ptys else {
            return openFailed(AttachRefusal.claudeNotFound.message)
        }
        do throws(AttachRefusal) {
            _ = try checkOpen(shortId)
        } catch {
            return openFailed(error.message)
        }
        guard !Task.isCancelled else { return }
        let input = owner?.input
        await input?.chatOpening(chat: session)
        var told = false
        defer { if !told { input?.chatOpenFailed(chat: session) } }
        guard !Task.isCancelled else { return }
        let checked: CheckedAttach
        do throws(AttachRefusal) {
            checked = try checkOpen(shortId)
        } catch {
            return openFailed(error.message)
        }
        closePTY()
        do throws(PTYError) {
            let attach = try await ptys.open(checked, size: size)
            told = opened(attach, shortId: shortId)
        } catch {
            openFailed(error.message)
        }
    }

    // The check of the open of this chat view with the rows of the session list now (D1). A
    // chat with no owner has no rows.
    private func checkOpen(_ shortId: ShortID) throws(AttachRefusal) -> CheckedAttach {
        guard let owner else { throw .notOwnedAttach }
        return try owner.checkAttach(ptyView, shortId: shortId)
    }

    // The open ended. attach is nil when another part cancelled the open (a quit): the manager
    // closed the new child, and the window then ends at its next write. The result is true when
    // the attach went to the session input.
    private func opened(_ attach: PTYAttach?, shortId: ShortID) -> Bool {
        guard isOpening, !Task.isCancelled else {
            attach?.close()
            return false
        }
        move(to: .attached(textShown: false, agentView: .watching))
        if let attach {
            pty = attach
            read(attach)
            // The typed text of an older attach is not in the prompt of this attach, so the
            // leading space of the next dictation reads only the text of this attach.
            dictation.clearTypedText()
            owner?.input?.opened(chat: session, shortId: shortId)
            owner?.watchSessionSize(ptyView)
        }
        // The panel can change during the open.
        sizing.attached(now: now())
        runSize()
        return attach != nil
    }

    // The open failed. There is no new try: the user closes the window and opens it again. This
    // stops a loop of errors.
    private func openFailed(_ message: String) {
        guard isOpening else { return }
        end("[open failed: \(message)]")
    }

    // Give each chunk of the attach to received, then its end to the owner, and its exit code to
    // exited. The output of an attach that the window closed goes nowhere. A close by another
    // part (a quit) gives no exit code: the window still counts as attached until its next write.
    private func read(_ attach: PTYAttach) {
        Task { [weak self] in
            for await chunk in attach.output {
                guard let self, self.pty === attach else { return }
                received(chunk)
            }
            let code = await attach.exit
            guard let self, self.pty === attach else { return }
            pty = nil
            attachEnded()
            if let code { exited(code: code) }
        }
    }

    // Feed a chunk to the terminal. During a reattach the old attach can still give a chunk: the
    // window has no attach then, and the chunk goes nowhere.
    private func feed(_ bytes: [UInt8]) {
        guard isAttached else { return }
        #if DEBUG
        benchOutput += bytes.count
        #endif
        view.feed(byteArray: bytes[...])
        // A reply of the terminal during the feed can end the window, so read the state again.
        if case .attached(let textShown, let agentView) = attachState {
            if agentView != .gaveUp { scheduleAgentCheck() }
            // Until the screen shows text, each chunk checks the screen.
            if !textShown, screenShowsText() {
                move(to: .attached(textShown: true, agentView: agentView))
            }
        }
        updateHistory()
    }

    // The keys and the replies of the terminal. Input while the input is blocked, or with no
    // attach, goes nowhere. A write that fails ends the window: the attach is gone, but no exit
    // came.
    private func write(_ bytes: [UInt8]) {
        guard case .attached(_, .watching) = attachState else { return }
        // The left arrow key can open the agent view. A send to this view then waits.
        if SessionInput.hasLeftKey(bytes) { owner?.input?.leftKey(chat: session) }
        if pty?.write(bytes) != true { end("[input failed: the attach ended]") }
    }

    // Mark the window as ended and write one line. Each end closes the attach.
    private func end(_ line: String) {
        let gaveUp = if case .attached(_, .gaveUp) = attachState { true } else { false }
        stopTimers()
        move(to: .ended(line: line, gaveUp: gaveUp))
        closePTY()
        // The PTY ended: a dictation stops, and types nothing more.
        dictation.block()
        view.feed(text: "\r\n\(line)\r\n")
        updateHistory()
    }

    // Close the attach of the window (SIGHUP to the attach child only) and tell the owner. The
    // session continues.
    private func closePTY() {
        guard let pty else { return }
        self.pty = nil
        pty.close()
        attachEnded()
    }

    // The attach closed or its child ended.
    private func attachEnded() {
        owner?.input?.ended(chat: session)
        owner?.forgetSessionSize(ptyView)
    }

    // A reset of the terminal: the dictation of the old attach stops, and the lines go.
    private func resetTerminal() {
        dictation.block()
        view.resetToInitialState()
        updateHistory()
    }

    // MARK: - The agent view

    // The next check: 250 ms after the last chunk, and at most 1 s after the first chunk since
    // the last check.
    private func scheduleAgentCheck() {
        let time = now()
        let first = uncheckedSince ?? time
        uncheckedSince = first
        let delay = AgentView.checkDelay(firstAt: first, now: time)
        agentCheck.schedule(after: delay) { [weak self] in self?.checkAgentView() }
    }

    // Read the screen at once and take the step of the agent view guard. The agent view lists the
    // sessions of all projects (D10).
    private func checkAgentView() {
        agentCheck.cancel()
        uncheckedSince = nil
        guard case .attached(let textShown, let watch) = attachState, watch != .gaveUp else {
            return
        }
        let time = now()
        let history = owner?.attachHistory[sessionId] ?? []
        let step = AgentView.step(
            watch, agentView: AgentView.isAgentView(AgentView.joinWrapped(screenRows())),
            targetReady: target.isReady, history: history, now: time)
        let recent = AgentView.recentAttaches(history, now: time)
        switch step {
        case .none:
            return
        case .free:
            // The agent view closed while the reattach waited for the row. The input starts
            // again.
            move(to: .attached(textShown: textShown, agentView: .watching))
        case .giveUp:
            owner?.attachHistory[sessionId] = recent
            move(to: .attached(textShown: textShown, agentView: .gaveUp))
        case .wait:
            // The row cannot attach now. The input stays blocked, and the note gives the reason.
            // The next update of a row that can attach checks the screen again.
            owner?.attachHistory[sessionId] = recent
            move(to: .attached(textShown: textShown, agentView: .waiting))
        case .reattach:
            guard case .ready(let shortId, _) = target else { return }
            owner?.attachHistory[sessionId] = recent + [time]
            reattach(shortId: shortId)
        }
    }

    // MARK: - The state

    // Move to the next state, then tell the owner (AttachedChats), the session input, the
    // dictation and the body what changed.
    private func move(to next: AttachState) {
        attachState = next
        owner?.attachedChats.set(sessionId, attached: next.showsSession)
        guard !isClosed else { return }
        let nextBlocked =
            switch next {
            case .reattaching: true
            case .attached(_, let watch): watch != .watching
            case .waiting, .readingSize, .opening, .ended, .closed: false
            }
        if nextBlocked != blocked {
            blocked = nextBlocked
            // The session input also refuses a send to the chat view while it shows the agent
            // view.
            owner?.input?.setBlocked(chat: session, nextBlocked)
            // A dictation of the agent view stops, and types nothing more.
            if nextBlocked { dictation.block() }
        }
        publish()
    }

    // Show the note: the give-up text, or the reason of a target that is refused while the
    // window waits. The window that ended also waits.
    private func publish() {
        let next: String? =
            switch attachState {
            case .waiting, .ended(_, false), .attached(_, .waiting): target.reason
            case .ended(_, true), .attached(_, .gaveUp): Self.giveUpText
            case .readingSize, .opening, .reattaching, .attached(_, .watching), .closed: nil
            }
        guard next != note, !isClosed else { return }
        note = next
        body.showNote(next)
    }

    // Stop the timers of the agent view check and of the size, and cancel and release the read of
    // the session size. dispose() and each end of the window call this.
    private func stopTimers() {
        agentCheck.cancel()
        uncheckedSince = nil
        sender.stop()
        sizeRead?.cancel()
        sizeRead = nil
    }

    // MARK: - The size

    // Run each size effect in order. A resize of the terminal changes the screen size, so an
    // effect can give new effects, and the loop then runs them too.
    private func runSize() {
        guard !resizing else { return }
        resizing = true
        defer { resizing = false }
        var effects = sizing.takeEffects()
        while !effects.isEmpty {
            for effect in effects { perform(effect) }
            effects = sizing.takeEffects()
        }
    }

    private func perform(_ effect: SizeEffect) {
        switch effect {
        case .resizeTerminal(let next):
            size = next
            applySize()
            // The screen size changed: the zoom follows it.
            panelChanged()
        case .send(let next, let bump):
            sender.queue(next, bump: bump)
        case .scale(let scale, let blocksPointer):
            body.setScale(scale, blocksPointer: blocksPointer)
        case .focusTerminal:
            // The press of the frame ends first.
            Task { [weak self] in self?.takeFocus() }
        }
    }

    // A size of the sender goes to the PTY. A failed resize does not end the attach.
    private func sendSize(_ next: TerminalSize) {
        guard !isClosed else { return }
        sizing.sent(now: now())
        if next.isValid { pty?.resize(next) }
    }

    // Give the keyboard focus to the terminal, unless a dialog of the window has it.
    private func takeFocus() {
        guard !isClosed, shown.focused, let window = view.window else { return }
        guard KeyFocus(window.firstResponder, in: window).zone != .modal else { return }
        window.makeFirstResponder(view)
    }

    // MARK: - The view

    // The geometry of the terminal now: the cell of the font and the scroll bar while it shows.
    private var fit: TerminalFit {
        let grid = view.terminalDimensions
        let scrollBar = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        return TerminalFit(
            optimalFrame: view.getOptimalFrameSize().size, cols: grid.cols, rows: grid.rows,
            scrollBar: history ? scrollBar : 0)
    }

    // Give the terminal view the frame of the size of SizeSync.
    private func applySize() {
        guard let frame = fit.frame(size) else { return }
        view.frame = CGRect(origin: .zero, size: frame)
    }

    // The screen reads use the copied reads of SwiftTerm. The view does not give its Terminal, so
    // the chat cannot read a BufferLine. Each read takes the terminal lock one time and copies one
    // string for each row: the second cell of a wide character has no text, an unwritten cell
    // before text is a space, and SwiftTerm trims the unwritten cells at the end of the row.
    //
    // The viewport is the live screen on the alternate screen ("claude attach" always uses it),
    // and on a normal screen at the end of its scrollback. After a scroll back, a read copies the
    // live rows from a content snapshot, which copies each cell: the reads are of the live screen,
    // not of the scroll position.
    private var viewportIsLive: Bool { !view.canScroll || view.scrollPosition >= 1 }

    // The rows of the live screen, from the top, each with its wrap flag.
    private func screenRows() -> [ScreenRow] {
        guard viewportIsLive else {
            let region = TerminalContentRegion.history(maximumScrollbackRows: -1)
            guard let snapshot = view.terminalContentSnapshot(region: region) else { return [] }
            return snapshot.rows.map { ScreenRow(text: $0.text, wrapped: $0.isWrapped) }
        }
        return view.terminalStateSnapshot().visibleRows.map {
            ScreenRow(text: $0.text, wrapped: $0.isWrapped)
        }
    }

    // True when a row of the live screen has text. The read copies the text of each row under
    // one lock. The check of the rows stops at the first row with text.
    private func screenShowsText() -> Bool {
        guard viewportIsLive else { return screenRows().contains { !$0.isBlank } }
        let rows = view.visibleRowsText(0..<view.terminalDimensions.rows)
        return rows.contains { !ScreenRow(text: $0, wrapped: false).isBlank }
    }

    // The scroll bar shows only while the normal screen has lines above it. canScroll of
    // SwiftTerm is false on the alternate screen, which has no scrollback, so one read under one
    // lock tells both. The scroll bar takes a part of the width, so the frame and the fit change
    // too.
    private func updateHistory() {
        let next = view.canScroll
        guard next != history else {
            // New lines change the knob of the slider.
            if history { view.slider.needsDisplay = true }
            return
        }
        history = next
        view.showScrollBar(next)
        applySize()
        panelChanged()
    }

    // A hidden terminal stops Metal and leaves its superview. A visible one goes back.
    private func showTerminal(_ visible: Bool) {
        if visible {
            if view.superview !== body.host { body.host.addSubview(view) }
            metal.setVisible(true)
        } else {
            metal.setVisible(false)
            view.removeFromSuperview()
        }
    }
}

// MARK: - DictationChat

extension ChatTerminal: DictationChat {
    // True while the attach of the chat is open.
    package var hasPTY: Bool { pty?.isOpen == true }

    package var blocksDictation: Bool {
        guard !isClosed, case .attached(_, .watching) = attachState else { return true }
        return rowBlocks
    }

    // Text of the chat for the PTY: the keys, the hold key and the writes of dictation.
    package func send(_ text: String) -> Bool {
        guard case .attached(_, .watching) = attachState else { return false }
        write(Array(text.utf8))
        return true
    }

    package func dictationViewChanged(_ view: DictationView) {
        body.showDictationNotice(DictationNoticeText.line(view))
    }

    package func dictationLookChanged(_ level: Double?) {
        owner?.dictationLook(panel, level)
    }
}

@MainActor
extension AttachTarget {
    fileprivate var isReady: Bool {
        if case .ready = self { true } else { false }
    }

    // The reason of a refused target, or nil.
    fileprivate var reason: String? {
        if case .refused(let reason) = self { reason.message } else { nil }
    }
}

@MainActor
extension Unicode.GeneralCategory {
    // A control character, a format character, a surrogate, a private character (for example the
    // function keys of AppKit, U+F700 and up) or no character: not printable.
    fileprivate var isControlOrPrivate: Bool {
        switch self {
        case .control, .format, .surrogate, .privateUse, .unassigned: true
        default: false
        }
    }
}
