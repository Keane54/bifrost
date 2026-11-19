// All chat terminals of the window and their lifecycle (docs/behaviour/chat.md, "The attach"). The
// open chat panels of the layout decide which terminals exist. A move of a body in the canvas does
// not start or end an attach, so a stack, a tab change, a minimise and a tear-out keep the attach.
//
// This object is the owner of each chat: it gives the attach check, the PTY manager, the session
// input, the attach history of each session and the session size, and it holds the clock and the
// parts that the chats share. It keeps no copy of the rows: each read goes to the session list, so
// the attach check and the pid of a session see a change of the registry in the same turn (user
// decision, 2026-11-16: the rows live in one place). Each chat owns the attach of its chat view
// (PTYView.chat). It gives each chunk and the end of its attach to the session input, with the
// start and the end of each open, the agent view block and each write with a left arrow key. A chat
// open waits until the session has no job of the session input. The size watcher reads the session
// size after each chunk with a full redraw and after each open, and it forgets the size at the end
// of an attach.
//
// The attached chats (AttachedChats): each terminal sets its session at each change of its
// attach, so the Overview knows the sessions that a chat window shows, with no process read.
//
// The dictation: each chat has its own dictation, and the chats share the dictation service. Each
// terminal listens to the events of its chat (DictationService.listen), and an event goes to the
// chat only while it has a PTY, so no event goes to a chat window that closed. onDictationLook
// gives the voice level of each chat that listens to its frame (nil: the chat does not listen).
// detachAll stops each dictation and each listen.
//
// The Take control loader (docs/behaviour/chat.md, "The Take control loader"): the action runner
// gives the steps start, stop and finish with the row ID of the session (startLoader, stopLoader,
// finishLoader). TakeControlLoader has the rules. The body of the chat shows the loader. While the
// loader shows and the chat has a terminal, a watch follows isShowingText of the terminal with
// Observations: a change to true is the step shown. The attach state changes only at its steps, so
// the watch gets no change for each chunk. Each path ends the loader: a stop, a shown after the
// finish, the time limit of 20 s after the finish, a finish with no terminal, and the close of the
// chat while the loader waits for the first output.
//
// While Take control runs, the chat of the session does not attach (holdsAttach). Take control
// ends the process in the other terminal and starts the session again in the background. The row
// can show the new process as an owned session before Take control checks that the process stays,
// and an attach at that time can stay on a session that the move did not finish. The restart of
// the action runner after a good Take control acts only on a chat that ended, so it does not
// replace such an attach. Thus the chat attaches when Take control ends: a stop or a finish of
// the loader.
import AppKit
import BifrostDictation
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostSessions
import BifrostSettings
import Observation

// The parts of the dictation that the chats share: the service, the vim mode check of a hold and
// the opener of a URL (the Microphone pane of System Settings).
@MainActor
public struct ChatDictationParts {
    package var service: DictationService
    package var vimMode: () async -> Bool
    package var openURL: (URL) -> Void

    public init(
        service: DictationService, vimMode: @escaping () async -> Bool,
        openURL: @escaping (URL) -> Void
    ) {
        self.service = service
        self.vimMode = vimMode
        self.openURL = openURL
    }
}

// The sessions that a chat window of Bifrost shows now: the attach of the window runs, also
// during a reattach after the agent view (AttachState.showsSession). The hidden attach of the
// session input is not a chat window, so it does not count. The Overview shows the Bifrost icon
// for these sessions. The set is observable, so a row icon changes when a chat attaches and when
// its attach ends.
@MainActor
@Observable
package final class AttachedChats {
    package private(set) var sessions: Set<String> = []

    package init() {}

    package func contains(_ sessionId: String) -> Bool { sessions.contains(sessionId) }

    // A value that does not change sets nothing, so no observer gets a change.
    func set(_ sessionId: String, attached: Bool) {
        guard sessions.contains(sessionId) != attached else { return }
        if attached {
            sessions.insert(sessionId)
        } else {
            sessions.remove(sessionId)
        }
    }
}

@MainActor
public final class ChatTerminals: PanelBodiesPart {
    // The look of the dictation of a chat: its panel and the voice level while it listens, else
    // nil. The shell gives it to the canvas.
    public var onDictationLook: (PanelID, Double?) -> Void = { _, _ in }

    // The sessions that a chat window shows now. Each terminal sets its session at each change
    // of its attach.
    package let attachedChats = AttachedChats()
    private(set) var ptys: PTYManager?
    private(set) var input: SessionInput?
    private let sizes: SessionSizeReader
    let clock: any Clock<Duration>
    let links: LinkOpener
    let pasteboard: NSPasteboard
    private let renderer: TerminalRenderer
    // The start of the chats as an instant, and the time now. The clock is injected (a manual
    // clock in the tests), so the time now is the start moved by the time since the start on
    // that clock. With the app clock (ContinuousClock) it is the time of that clock.
    let start: ContinuousClock.Instant
    let now: @Sendable () -> ContinuousClock.Instant
    let dictation: ChatDictationParts?
    // The listen of each terminal to the dictation service, by session ID.
    private var dictationListens: [String: Task<Void, Never>] = [:]
    #if DEBUG
    // The renderer of each new terminal of a session, for a run of the debug bench. A session
    // with no value gets the renderer of the app.
    package var benchRenderers: [String: TerminalRenderer] = [:]
    #endif
    private var terminals: [String: ChatTerminal] = [:]
    // The body of each chat panel that the canvas holds, by session ID. A new terminal of the
    // session uses it.
    private var bodies: [String: ChatPanelBody] = [:]
    // The times of the recent attaches of each session (AgentView), also after its window closed.
    var attachHistory: [String: [ContinuousClock.Instant]] = [:]
    private var views: [String: ChatView] = [:]
    // The Take control loaders by row ID, the time limit of each loader that waits only for the
    // first output, and the watch of the terminal of each loader. A test reads the loaders.
    private(set) var loaders = TakeControlLoader()
    private var loaderTimers: [String: TimerSlot] = [:]
    private var shownWatches: [String: ShownWatch] = [:]
    private var watchCount = 0
    // True when macOS asks for reduced motion. The rainbow of a loader then does not move. A
    // test gives a fixed value.
    package var reduceMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    // The rows of the session list now.
    private let rows: () -> [SessionRow]
    private var metrics = CanvasMetrics(interfaceScale: 100)
    private var font = ChatTerminalView.font(
        Settings().terminalFont, metrics: CanvasMetrics(interfaceScale: 100))
    private lazy var watcher = SessionSizeWatcher<PTYView>(
        read: { [sizes] pid in await sizes.read(pid: pid) },
        pidOf: { [weak self] view in self?.pid(ofView: view) },
        emit: { [weak self] view, size in self?.terminal(ofView: view)?.setSessionSize(size) },
        clock: clock)

    // ptys is nil until the app finds claude (attach(ptys:input:)). rows gives the rows of the
    // session list now. The clock is a monotonic clock. With no dictation, the dictation key acts
    // as a normal key with the notice of a missing engine.
    public init(
        ptys: PTYManager?, sizes: SessionSizeReader, rows: @escaping () -> [SessionRow],
        clock: any Clock<Duration>, links: LinkOpener, pasteboard: NSPasteboard,
        renderer: TerminalRenderer, dictation: ChatDictationParts? = nil
    ) {
        self.ptys = ptys
        self.rows = rows
        self.sizes = sizes
        self.clock = clock
        self.links = links
        self.pasteboard = pasteboard
        self.renderer = renderer
        let start = ContinuousClock.now
        let elapsed = Timeline(clock).now
        self.start = start
        now = { start.advanced(by: elapsed()) }
        self.dictation = dictation
    }

    isolated deinit {
        for listen in dictationListens.values { listen.cancel() }
        for watch in shownWatches.values { watch.task.cancel() }
    }

    // The PTY manager and the session input, when the app found claude after the window
    // showed.
    public func attach(ptys: PTYManager, input: SessionInput?) {
        self.ptys = ptys
        self.input = input
    }

    // Make a terminal for each new open chat, and dispose the terminal of each closed chat. Then
    // give each terminal its view, then its row of the session list now: the first attach knows
    // if the window shows. loaded is false until the first session list comes.
    public func sync(layout: WindowLayout, loaded: Bool) {
        let rows = self.rows()
        let openSessions = ChatViews.openChatIds(layout.frames)
        let openIds = openSessions.map(\.text)
        let open = Set(openIds)
        for id in terminals.keys.sorted() where !open.contains(id) {
            terminals.removeValue(forKey: id)?.dispose()
            dictationListens.removeValue(forKey: id)?.cancel()
            terminalEnded(id)
        }
        for session in openSessions where terminals[session.text] == nil {
            terminals[session.text] = makeTerminal(session)
            listen(session)
        }
        for id in loaders.sessionIds {
            watchShown(id)
            applyLoader(id)
        }
        let next = ChatViews.views(layout)
        let gained = ChatViews.gainedFocus(views, next)
        views = next
        // The last row of a session ID wins, as a Map of the rows does.
        let byId = Dictionary(
            rows.map { ($0.sessionId, $0) }, uniquingKeysWith: { _, last in last })
        for id in openIds {
            guard let terminal = terminals[id] else { continue }
            terminal.setView(next[id] ?? .hidden, focusGained: gained.contains(id))
            terminal.setRow(byId[id], loaded: loaded)
        }
        pruneHistories(open)
    }

    // The terminal font of the chats now. The trust terminal of Reviews uses it too.
    package var terminalFont: NSFont { font }

    // Use a new terminal font in each terminal and in each new one. The note of a body follows
    // the Interface scale.
    public func setFont(_ font: TerminalFont, metrics: CanvasMetrics) {
        self.metrics = metrics
        self.font = ChatTerminalView.font(font, metrics: metrics)
        for id in bodies.keys.sorted() { bodies[id]?.setMetrics(metrics) }
        for id in terminals.keys.sorted() { terminals[id]?.setFont(self.font) }
    }

    // True when the time of a timer of a terminal or of a read of a session size came, and that
    // timer did not run yet. A test that moves a manual clock waits until this is false.
    package var timersDue: Bool { terminals.values.contains(where: \.timersDue) || watcher.isDue }

    public func terminal(_ sessionId: String) -> ChatTerminal? {
        terminals[sessionId]
    }

    // The session IDs of the chats that have a terminal, in order.
    public var sessionIds: [String] { terminals.keys.sorted() }

    // The session of the chat whose terminal view is the first responder of its window, or nil.
    public var focusedSession: String? {
        sessionIds.first { id in
            guard let view = terminals[id]?.view, let window = view.window else { return false }
            return window.firstResponder === view
        }
    }

    // A window close or a quit: each chat stops its dictation and detaches (SIGHUP to each attach
    // child). The sessions continue. The next sync makes the terminals again, so the chats attach
    // again.
    public func detachAll() {
        for id in terminals.keys.sorted() {
            terminals.removeValue(forKey: id)?.dispose()
            dictationListens.removeValue(forKey: id)?.cancel()
            terminalEnded(id)
        }
        views = [:]
    }

    // MARK: - The Take control loader

    // Take control starts: the chat of the session shows the loader in place of the terminal.
    package func startLoader(_ sessionId: String) {
        stepLoader(sessionId) { $0.start(sessionId) }
    }

    // Take control failed: the loader goes.
    package func stopLoader(_ sessionId: String) {
        stepLoader(sessionId) { $0.stop(sessionId) }
    }

    // Take control worked. The loader stays until the terminal shows Claude. With no open chat,
    // the loader goes at once.
    package func finishLoader(_ sessionId: String) {
        let hasTerminal = terminals[sessionId] != nil
        stepLoader(sessionId) { hasTerminal ? $0.finish(sessionId) : $0.stop(sessionId) }
    }

    // True while the chat of the session shows the loader.
    package func showsLoader(_ sessionId: String) -> Bool {
        loaders.shows(sessionId)
    }

    #if DEBUG
    // The task of the time limit of the loader of the session, or nil. A test waits for it.
    package func loaderTimer(_ sessionId: String) -> Task<Void, Never>? {
        loaderTimers[sessionId]?.task
    }
    #endif

    // True while Take control of the session runs. The chat of the session does not attach until
    // Take control ends.
    func holdsAttach(_ sessionId: String) -> Bool {
        loaders.runs(sessionId)
    }

    private func stepLoader(_ id: String, _ step: (inout TakeControlLoader) -> Void) {
        let held = loaders.runs(id)
        step(&loaders)
        // Only a loader that waits for the first output has the time limit.
        if !loaders.waits(id) {
            loaderTimers.removeValue(forKey: id)?.stop()
        } else if loaderTimers[id] == nil {
            let timer = TimerSlot(clock: clock)
            timer.start(after: TakeControlLoader.timeLimit) { [weak self] in
                self?.loaderTimers[id] = nil
                self?.stepLoader(id) { $0.timeLimitPassed(id) }
            }
            loaderTimers[id] = timer
        }
        if loaders.shows(id) {
            watchShown(id)
        } else {
            shownWatches.removeValue(forKey: id)?.task.cancel()
        }
        applyLoader(id)
        // Take control ended: a chat that waits attaches now, to the moved session.
        if held && !loaders.runs(id) { terminals[id]?.takeControlEnded() }
    }

    // The terminal of the session went. A loader that waits only for the first output of that
    // terminal goes too. A loader of a Take control that runs stays: its finish or its stop
    // comes later.
    private func terminalEnded(_ id: String) {
        shownWatches.removeValue(forKey: id)?.task.cancel()
        if loaders.waits(id) { stepLoader(id) { $0.stop(id) } }
    }

    // Follow isShowingText of the terminal of the session while the loader shows. The value at
    // the start of the watch is read at once. A later change to true is the step shown. A watch
    // that ends by itself (its terminal went) removes its own entry, and never the entry of a
    // newer watch.
    private func watchShown(_ id: String) {
        guard shownWatches[id] == nil, loaders.shows(id), let terminal = terminals[id] else {
            return
        }
        watchCount += 1
        let number = watchCount
        let changes = Observations { terminal.isShowingText }
        let start = terminal.isShowingText
        let task = Task { [weak self, weak terminal] in
            var before = start
            for await showing in changes {
                guard let self, let terminal, terminals[id] === terminal else { break }
                if !before && showing { stepLoader(id) { $0.shown(id) } }
                before = showing
            }
            if self?.shownWatches[id]?.number == number { self?.shownWatches[id] = nil }
        }
        shownWatches[id] = ShownWatch(number: number, task: task)
    }

    // Show the state of the loader on the body of the session, with the name of its row now.
    private func applyLoader(_ id: String) {
        guard let body = terminals[id]?.body ?? bodies[id] else { return }
        guard loaders.shows(id) else {
            body.showLoader(nil, reduceMotion: false)
            return
        }
        let name = rows().first { $0.sessionId == id }?.name
        body.showLoader(TakeControlLoader.text(name: name), reduceMotion: reduceMotion())
    }

    // The watch of the terminal of a loader, with its number.
    private struct ShownWatch {
        let number: Int
        let task: Task<Void, Never>
    }

    // MARK: - The dictation

    // The task that gives the events of the dictation service to the terminal of the chat. A
    // test waits for its end after a new listen ends its stream.
    func dictationListen(_ sessionId: String) -> Task<Void, Never>? { dictationListens[sessionId] }

    // Give each event of the dictation service for the chat to the terminal of the chat, only
    // while that chat has a PTY.
    private func listen(_ session: SessionID) {
        let id = session.text
        guard let events = dictation?.service.listen(for: session) else { return }
        dictationListens[id] = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                guard let terminal = terminals[id], terminal.hasPTY else { continue }
                terminal.dictationEvent(event)
            }
        }
    }

    // MARK: - PanelBodiesPart

    // The body of a chat panel, or nil for another panel. The body of a session that has a
    // terminal is the body of its terminal.
    public func body(for panel: PanelID) -> NSView? {
        guard case .chat(let session) = panel else { return nil }
        let id = session.text
        if let body = terminals[id]?.body ?? bodies[id] {
            bodies[id] = body
            return body
        }
        let body = ChatPanelBody(metrics: metrics)
        bodies[id] = body
        applyLoader(id)
        return body
    }

    // The panel is in no frame now. The next body of the session is a new body. The attach ends
    // only when the next sync does not find the chat.
    public func releaseBody(for panel: PanelID) {
        guard case .chat(let session) = panel else { return }
        bodies[session.text] = nil
    }

    // MARK: - Private

    private func makeTerminal(_ session: SessionID) -> ChatTerminal {
        let id = session.text
        let body = bodies[id] ?? ChatPanelBody(metrics: metrics)
        bodies[id] = body
        #if DEBUG
        let renderer = benchRenderers[id] ?? self.renderer
        #else
        let renderer = self.renderer
        #endif
        return ChatTerminal(
            session: session, body: body, font: font, renderer: renderer, owner: self)
    }

    private func terminal(ofView view: PTYView) -> ChatTerminal? {
        switch view {
        case .chat(let session): terminals[session.text]
        case .input: nil
        }
    }

    // The pid of the session of an owned row that is not parked: the first row of the session
    // ID.
    private func pid(ofSession id: String) -> pid_t? {
        guard let row = rows().first(where: { $0.sessionId == id }), row.isOwnedAndNotParked
        else { return nil }
        return row.pid
    }

    private func pid(ofView view: PTYView) -> pid_t? {
        switch view {
        case .chat(let session): pid(ofSession: session.text)
        case .input: nil
        }
    }

    // Keep only the attaches of the last 60 seconds. Remove an empty history of a closed chat.
    private func pruneHistories(_ open: Set<String>) {
        let time = now()
        for id in attachHistory.keys.sorted() {
            let times = AgentView.recentAttaches(attachHistory[id] ?? [], now: time)
            attachHistory[id] = times.isEmpty && !open.contains(id) ? nil : times
        }
    }
}

// MARK: - For the chats

extension ChatTerminals {
    // The check of a PTY open of the view with the rows of the session list now (D1).
    func checkAttach(_ view: PTYView, shortId: ShortID) throws(AttachRefusal) -> CheckedAttach {
        try AttachRules.check(rows(), view: view, shortId: shortId)
    }

    // The size of the session from its other clients. nil: no process or no size.
    func readSessionSize(_ sessionId: String) async -> TerminalSize? {
        guard let pid = pid(ofSession: sessionId) else { return nil }
        return await sizes.read(pid: pid)
    }

    // The size of the session of the view can be new: an open or a full redraw.
    func watchSessionSize(_ view: PTYView) {
        watcher.poke(view)
    }

    // The attach of the view ended.
    func forgetSessionSize(_ view: PTYView) {
        watcher.forget(view)
    }

    // The look of the frame of a chat panel: the voice level while the chat listens, else nil.
    func dictationLook(_ panel: PanelID, _ level: Double?) {
        onDictationLook(panel, level)
    }
}
