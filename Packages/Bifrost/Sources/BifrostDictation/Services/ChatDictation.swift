import BifrostFoundation

// The dictation of one chat window (docs/behaviour/dictation.md): the chat input with the hold key
// of dictation (ChatInput), the events of the dictation service for the chat, the typer and the
// keys of the user that wait. The text goes to the PTY through the chat (DictationChat). All state
// is on the main actor, and the timers use the injected clock.
//
// The rules:
// - A hold reads the vim mode of Claude first. In vim mode, a dictated letter can run as a command,
//   so dictation stays off and the held key types its text (docs/behaviour/dictation.md, Vim
//   mode).
// - The final text of an end is typed only when the end answers the stop of a key release. After an
//   early stop, that end and all later events of that dictation do nothing. An end that answers no
//   stop of this chat is an early stop too, for example at the 2-minute limit.
// - An early stop or an error stops the typer of the dictation. The typed text stays.
// - The ready of the service opens no microphone: the service gives it before the engine tries. The
//   first level or text is the good start: the chat listens from then. A refused start, or an
//   error or a release before the good start, takes the path before ready: the key acts as a
//   normal key.
// - A start during a model download shows the download, and the microphone stays closed. A new hold
//   after ready opens it. At model-ready, the notice tells the user to hold the key again
//   (docs/behaviour/dictation.md, The dictation service).
// - The good start removes the notice of an earlier dictation. A notice with the System Settings
//   button stays until then. Each other notice of the service goes after serviceNoticeTime
//   (docs/behaviour/dictation.md, The look). The first downloading event of a hold also removes
//   the notice. The language notice shows at the good start, once for each chat.
// - The text of the chat goes to the PTY in one order (the lane): the text of each dictation in the
//   place of its start, and the keys of the user that wait. After a release, the keys wait while
//   the final text types, and then go (docs/behaviour/dictation.md, "The typer"). A key waits only
//   for the final texts of the dictations that began before it. A final text waits only for the
//   keys from before its dictation began. When the end does not come keyWait after the release, the
//   end does nothing and the keys go. After the end comes, its final text always types first. The
//   keys go at the end of the typer before them, so nothing checks the typer at an interval.
// - A typer writes at once, then waits the gap of that write before the next write. A new typer
//   writes only after the typer before it and its gap.
// - Other input of the user during a hold stops only the hold. A final text of an older dictation
//   still types, and the keys wait for it. Escape, Ctrl+C, a blocking choice and the end of the PTY
//   stop each typer at once, and the keys that wait go away (docs/behaviour/dictation.md, The
//   typer).
// - One dictation at a time in a chat. A new hold before the end of the last dictation waits for
//   that end, and for the first write of its final text.
// - The leading space of a dictation reads the end of the text that the chat sent to the PTY of
//   this attach (typedTail). A new attach clears it.

// The chat of a dictation: its PTY input and its view. ChatTerminal of BifrostChat in the app.
@MainActor
package protocol DictationChat: AnyObject {
    // True when the chat has a PTY. A start needs it, because the text goes to the PTY.
    var hasPTY: Bool { get }
    // True when the dictation key must act as a normal key: the chat has no attach, it shows
    // the agent view, or Claude shows a choice.
    var blocksDictation: Bool { get }
    // Send text of the chat to its PTY. False when the text did not go: the chat has no attach,
    // or its input is blocked.
    func send(_ text: String) -> Bool
    // The phase, the download progress or the notice of the dictation changed.
    func dictationViewChanged(_ view: DictationView)
    // The look of the frame changed: the voice level while the chat listens, else nil.
    func dictationLookChanged(_ level: Double?)
}

// The calls of the dictation of a chat to the dictation service.
@MainActor
package protocol DictationControl: AnyObject {
    func start(chat: SessionID)
    func stop(chat: SessionID)
    func warm()
}

extension DictationService: DictationControl {}

@MainActor
package final class ChatDictation {
    // The longest wait for the end after a stop. The session of the service ends in 1.5 s or
    // less.
    nonisolated package static let closeWait = Duration.seconds(3)
    // The time that the vim mode, refusal and model-ready notices show.
    nonisolated package static let noticeTime = Duration.seconds(6)
    // The time that a notice of the service with no button shows (docs/behaviour/dictation.md,
    // The look).
    nonisolated package static let serviceNoticeTime = Duration.seconds(12)
    // The longest wait of the keys for the end, from the release.
    nonisolated package static let keyWait = Duration.seconds(2)

    // idle: no dictation. checking: the vim mode read of a hold runs. starting: the service has
    // the start, and no level or text came. downloading: the speech model downloads, with its
    // progress. downloaded: the download ended during the hold. stopping: the key went up, and
    // the dictation waits for its end. closing: an early stop waits for the end, and the end does
    // nothing.
    private enum Phase {
        case idle
        case checking(Task<Void, Never>)
        case starting
        case downloading(Double)
        case downloaded, listening, stopping, closing

        var shown: DictationPhase {
            switch self {
            case .idle, .checking, .closing: .off
            case .starting: .starting
            case .downloading(let progress): .downloading(progress: progress)
            case .downloaded: .downloaded
            case .listening: .listening
            case .stopping: .stopping
            }
        }

        // The key is held, and the dictation has no stop yet.
        var holding: Bool {
            switch self {
            case .starting, .downloading, .downloaded, .listening: true
            default: false
            }
        }

        // The hold has no good start yet.
        var early: Bool {
            switch self {
            case .starting, .downloading, .downloaded: true
            default: false
            }
        }
    }

    // A part of the lane: the text of a dictation, or input of the user that waits.
    private enum Item {
        case text(DictationTyper)
        case key(String)

        var isKey: Bool {
            if case .key = self { true } else { false }
        }
    }

    // The session ID of the chat.
    private let session: SessionID
    private weak var chat: (any DictationChat)?
    private let service: (any DictationControl)?
    private let vimMode: () async -> Bool
    private let clock: any Clock<Duration>
    private var phase = Phase.idle {
        // A late answer of the vim mode read does nothing.
        didSet {
            if case .checking(let task) = oldValue, !isChecking { task.cancel() }
        }
    }
    // True when a hold waits for the end of the last dictation.
    private var holdWaits = false
    // True after the good start of the current dictation: its text events and its end type text.
    private var goodStart = false
    private var notice: DictationNotice?
    // True after the language notice showed in this chat.
    private var languageShown = false
    // The language of a ready with fallback true in the current dictation, or nil.
    private var fallbackLanguage: String?
    // The last voice level of the dictation that listens.
    private var level = 0.0
    private var disposed = false
    // The typer of the current or of the last dictation.
    private var typer: DictationTyper?
    // The text of each dictation and the keys of the user that wait, in the order of the PTY.
    private var lane: [Item] = []
    // The end of the text that the chat sent to the PTY of this attach (typedTail).
    private var tail = ""
    // True after keyWait passed since the release of the current dictation.
    private var keyWaitPassed = false
    private let closeTimer: TimerSlot
    private let noticeTimer: TimerSlot
    private let keyTimer: TimerSlot
    // The gap after the last write of a typer. Its end moves the lane again.
    private let gap: TimerSlot

    // The chat input of the chat: the hold key of dictation and the input rules. Its text for
    // the PTY goes through input(_:).
    package private(set) lazy var chatInput = ChatInput(dictation: self, clock: clock)
    // The view of the dictation: the phase, with the download progress, and the notice.
    package private(set) var view = DictationView(phase: .off, notice: nil)
    // The look of the frame: the voice level while the chat listens, else nil.
    package private(set) var look: Double?

    // service nil: the app has no speech engine. vimMode reads the vim mode of Claude. A read
    // that fails gives false.
    package init(
        session: SessionID, chat: any DictationChat, service: (any DictationControl)?,
        clock: any Clock<Duration>, vimMode: @escaping () async -> Bool
    ) {
        self.session = session
        self.chat = chat
        self.service = service
        self.vimMode = vimMode
        self.clock = clock
        closeTimer = TimerSlot(clock: clock)
        noticeTimer = TimerSlot(clock: clock)
        keyTimer = TimerSlot(clock: clock)
        gap = TimerSlot(clock: clock)
    }

    // False while a hold waits for its start: the vim mode read, or the first level or text.
    // Then the chat shows nothing yet, so the held key can still type its text
    // (docs/behaviour/dictation.md, The hold key).
    package var heard: Bool {
        switch phase {
        case .checking, .starting: false
        default: true
        }
    }

    // True when a key must not stop the typer: the final text of a released dictation still
    // types or waits for its end, and no hold runs.
    package var waits: Bool {
        !disposed && !isChecking && !phase.holding && finishing
    }

    // False when the dictation key must act as a normal key: the chat closed or blocks dictation.
    package var canStart: Bool {
        !disposed && chat?.blocksDictation == false
    }

    // MARK: - The inputs

    // The dictation key is held.
    package func start() {
        guard !disposed else { return }
        switch phase {
        case .stopping, .closing:
            holdWaits = true
        case .idle where typer?.waitsForTurn == true:
            holdWaits = true
        case .idle:
            check()
        default:
            break
        }
    }

    // The key went up after the start.
    package func stop() {
        guard !disposed else { return }
        switch phase {
        case .idle, .stopping, .closing:
            holdWaits = false
        case .checking:
            phase = .idle
        case .starting, .downloading, .downloaded, .listening:
            phase = .stopping
            // Before the good start, the end types nothing.
            if !goodStart { typer?.cancel() }
            service?.stop(chat: session)
            closeTimer.start(after: Self.closeWait) { [weak self] in self?.closeWaitEnded() }
            keyWaitPassed = false
            keyTimer.start(after: Self.keyWait) { [weak self] in self?.keyWaitEnded() }
        }
        publish()
        pump()
    }

    // Another key, a blur or a close during the hold.
    package func cancel() {
        guard !disposed else { return }
        cancelHold()
        pump()
    }

    // A key or other input of the user goes to the PTY. A hold stops early. A final text that
    // types, or waits for its end, goes on, and the keys wait for it. With no final text, each
    // typer stops at once, and the keys that wait go to the PTY.
    package func interrupt() {
        guard !disposed else { return }
        cancelHold()
        if !finishing { stopAll() }
        pump()
    }

    // Claude shows a blocking choice, the PTY ends, or the user pressed Escape or Ctrl+C.
    // Dictation stops, and each typer stops at once. The keys that wait go away, because they
    // could answer the choice or submit the prompt (docs/behaviour/dictation.md, The typer).
    package func block() {
        guard !disposed else { return }
        lane.removeAll { $0.isKey }
        stopAll()
    }

    // Input of the user for the PTY: keys, the text of the hold key and the replies of the
    // terminal. It waits while the final text of a released dictation types.
    package func input(_ data: String) {
        guard !disposed else { return }
        guard lane.contains(where: \.isKey) || waits else {
            send(data)
            return
        }
        lane.append(.key(data))
        endKeyWait()
        pump()
    }

    // An event of the dictation service for this chat.
    package func event(_ event: DictationViewEvent) {
        guard !disposed else { return }
        if case .level(let value) = event { level = value }
        switch phase {
        case .idle, .checking:
            break
        case .closing:
            // The end or the error of the early stop ends the wait.
            switch event {
            case .end, .error: settle()
            default: break
            }
        default:
            take(event)
        }
        // The level of an older dictation never shows in a new one.
        if view.phase != .listening { level = 0 }
        updateLook()
        pump()
    }

    // A new attach of the chat. Its prompt has no text of the older attach, so the leading space
    // of the next dictation reads only the text of this attach.
    package func clearTypedText() {
        tail = ""
    }

    // The chat got the key focus, or the dictation key went down: the speech engine gets ready.
    package func warm() {
        guard !disposed else { return }
        service?.warm()
    }

    // The chat closes. A hold stops, and a key that waits for the hold time types nothing. The
    // typed text stays, and nothing acts after this.
    package func dispose() {
        guard !disposed else { return }
        chatInput.close()
        if phase.holding { service?.stop(chat: session) }
        disposed = true
        holdWaits = false
        phase = .idle
        for case .text(let typer) in lane { typer.cancel() }
        lane = []
        for timer in [closeTimer, noticeTimer, keyTimer, gap] { timer.stop() }
        updateLook()
    }

    // MARK: - The hold

    private var isChecking: Bool {
        if case .checking = phase { true } else { false }
    }

    // The vim mode read of the hold, while it runs. A test waits until it ends or waits.
    var vimCheck: Task<Void, Never>? {
        if case .checking(let task) = phase { task } else { nil }
    }

    // The timers that run, with the hold timer of the chat input. A test that moves a manual
    // clock waits until each of them sleeps on the clock.
    var runningTimers: Int {
        [closeTimer, noticeTimer, keyTimer, gap].filter(\.isRunning).count
            + (chatInput.holdRunning ? 1 : 0)
    }

    // True while a typer of the lane has text to type: a final text, or a release whose end has
    // not come.
    private var finishing: Bool {
        lane.contains { item in
            if case .text(let typer) = item { !typer.cancelled } else { false }
        }
    }

    private func check() {
        let read = vimMode
        phase = .checking(
            Task { [weak self] in
                let on = await read()
                guard !Task.isCancelled else { return }
                self?.vimModeRead(on)
            })
    }

    private func vimModeRead(_ on: Bool) {
        guard !disposed, isChecking else { return }
        if !on {
            begin()
            return
        }
        phase = .idle
        setNotice(.vimMode, for: Self.noticeTime)
        publish()
        chatInput.fallback()
    }

    private func begin() {
        phase = .starting
        goodStart = false
        fallbackLanguage = nil
        // The text of this dictation goes after the text and the keys before it.
        let typer = DictationTyper()
        self.typer = typer
        lane.append(.text(typer))
        publish()
        guard let service else {
            event(.error(.unavailable))
            return
        }
        // The typed text goes to the PTY of the chat, so a start needs the PTY.
        guard chat?.hasPTY == true else {
            refuse(.noTerminal)
            return
        }
        service.start(chat: session)
    }

    // The chat refused the start. The notice gives the reason.
    private func refuse(_ refusal: DictationRefusal) {
        typer?.cancel()
        setNotice(.refused(refusal), for: Self.noticeTime)
        phase = .idle
        publish()
        pump()
        chatInput.fallback()
    }

    // Stop a hold early: the end of its dictation does nothing.
    private func cancelHold() {
        holdWaits = false
        switch phase {
        case .checking:
            phase = .idle
            publish()
        case .starting, .downloading, .downloaded, .listening:
            phase = .closing
            typer?.cancel()
            service?.stop(chat: session)
            closeTimer.start(after: Self.closeWait) { [weak self] in self?.closeWaitEnded() }
            publish()
        default:
            break
        }
    }

    // Stop the dictation and each typer at once. The keys that wait go first, in their order.
    private func stopAll() {
        cancelHold()
        if case .stopping = phase {
            // The end of the release does nothing now. The close wait runs already.
            phase = .closing
            publish()
        }
        let items = lane
        lane = []
        for case .text(let typer) in items { typer.cancel() }
        for case .key(let data) in items { send(data) }
    }

    // No end came, for example because the PTY of the chat closed. The typed text stays, and the
    // typer stops, so a key cannot go between its writes.
    private func closeWaitEnded() {
        switch phase {
        case .stopping:
            typer?.cancel()
            settle()
        case .closing:
            settle()
        default:
            break
        }
        pump()
    }

    private func keyWaitEnded() {
        keyWaitPassed = true
        endKeyWait()
    }

    // When the end does not come keyWait after the release, the end does nothing and the keys
    // that wait go. The live text stays.
    private func endKeyWait() {
        guard keyWaitPassed, case .stopping = phase, goodStart, lane.contains(where: \.isKey)
        else { return }
        phase = .closing
        typer?.cancel()
        publish()
        pump()
    }

    // The dictation ended. A hold that waits for it starts now.
    private func settle() {
        closeTimer.stop()
        phase = .idle
        publish()
        startWaitingHold()
    }

    // Start a hold that waits, when the final text of the last dictation has its turn.
    private func startWaitingHold() {
        guard holdWaits, case .idle = phase, typer?.waitsForTurn != true else { return }
        holdWaits = false
        check()
    }

    // The good start: the first level or text shows that the microphone is open. The notice of
    // an earlier dictation goes.
    private func hear() {
        phase = .listening
        goodStart = true
        setNotice(nil)
        if let language = fallbackLanguage, !languageShown {
            languageShown = true
            setNotice(.language(language), for: Self.serviceNoticeTime)
        }
        publish()
    }

    // An event of a dictation that starts, listens or waits for its end.
    private func take(_ event: DictationViewEvent) {
        switch event {
        case .ready(let language, let fallback):
            // The microphone is not open yet. The first level or text opens the chat (D10).
            guard phase.early else { return }
            fallbackLanguage = fallback ? language : nil
            publish()
        case .downloading(let value):
            guard phase.early else { return }
            // The engine runs, so the notice of an earlier failure goes.
            if case .starting = phase { setNotice(nil) }
            phase = .downloading(value)
            publish()
        case .modelReady:
            // The microphone stays closed. The key is still held.
            guard case .downloading = phase else { return }
            phase = .downloaded
            setNotice(.modelReady, for: Self.noticeTime)
            publish()
        case .level:
            if phase.early { hear() }
        case .text(let final, let volatile):
            // A text can come with no level before it.
            if phase.early { hear() }
            guard case .listening = phase else { return }
            typer?.give(final: final, volatile: volatile, end: false, lastSent: tail)
        case .end(let final):
            if case .stopping = phase {
                if goodStart { typer?.give(final: final, volatile: "", end: true, lastSent: tail) }
                pump()
            } else {
                // An end with no stop of this chat. A stop closes the microphone, in case the
                // end was a late end of an older dictation.
                typer?.cancel()
                service?.stop(chat: session)
            }
            settle()
        case .error(let code):
            typer?.cancel()
            // A "no" of the user keeps its System Settings button until the next good start.
            setNotice(.error(code), for: code == .micDenied ? nil : Self.serviceNoticeTime)
            guard phase.holding else {
                settle()
                return
            }
            phase = .idle
            publish()
            // An error in place of the start gives the key back.
            if !goodStart { chatInput.fallback() }
        }
    }

    // Show a notice. With a time, the notice goes after that time. With no time, it stays.
    private func setNotice(_ next: DictationNotice?, for time: Duration? = nil) {
        noticeTimer.stop()
        notice = next
        guard next != nil, let time else { return }
        noticeTimer.start(after: time) { [weak self] in
            self?.notice = nil
            self?.publish()
        }
    }

    private func publish() {
        guard !disposed else { return }
        let next = DictationView(phase: phase.shown, notice: notice)
        if next != view {
            view = next
            chat?.dictationViewChanged(next)
        }
        updateLook()
    }

    // The frame shows the green look with the level only while the chat listens.
    private func updateLook() {
        let next = !disposed && DictationLook.shows(view.phase) ? level : nil
        guard next != look else { return }
        look = next
        chat?.dictationLookChanged(next)
    }

    // MARK: - The lane

    // Write what the lane lets go now, in order. Then a hold that waits for the turn of a final
    // text can start.
    private func pump() {
        moveLane()
        startWaitingHold()
    }

    // A key goes when all before it went. A typer writes when all before it went and the gap of
    // the last write of a typer is over. A stopped typer leaves the lane at once, so a key does
    // not wait for its gap.
    private func moveLane() {
        while !disposed, let item = lane.first {
            switch item {
            case .key(let data):
                lane.removeFirst()
                send(data)
            case .text(let typer) where typer.cancelled:
                lane.removeFirst()
            case .text(let typer):
                guard !gap.isRunning else { return }
                typer.start(lastSent: tail)
                if let write = typer.nextWrite() {
                    send(write.data)
                    gap.start(after: TypingRules.gap(afterDeletes: write.deletes)) { [weak self] in
                        self?.pump()
                    }
                    return
                }
                // The text of a dictation with no end can still change, so it keeps its place.
                guard typer.ended else { return }
                lane.removeFirst()
            }
        }
    }

    // Send text to the PTY of the chat. The text that went adds to the end of the typed text.
    private func send(_ text: String) {
        guard chat?.send(text) == true else { return }
        tail = PTYText.typedTail(tail, text)
    }
}

extension ChatDictation: ChatInputDictation {}
