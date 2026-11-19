import BifrostFoundation
import BifrostKeyboard

// The chat input of one chat window (docs/behaviour/dictation.md, "The hold key"): the hold key of
// dictation and the input rules of the chat. ChatDictation owns the one chat input of a chat. Each
// text for the PTY goes through the dictation, which holds the keys while a final text types All
// state is on the main actor, and the hold time runs on the injected clock.
//
// The hold key:
// - When the key goes down, the hold key waits holdTime. When the key goes up before that, the key
//   types its text, as a normal key.
// - When the key stays down for holdTime, dictation starts, and the key types nothing. When the key
//   goes up, dictation stops.
// - When another key goes down during the wait, the key types its text first. Then the other key
//   goes to the terminal, and dictation does not start. So fast typing with rollover keeps each
//   space in its place.
// - Another key, a blur or a close during the hold stops dictation early.
// - A release or another key during the hold before the first level or text types the key first. No
//   green showed yet, so the user typed a slow space. After the first level or text, or during the
//   download, the key types nothing (docs/behaviour/dictation.md, The hold key).
// - The key-repeat events of the key do nothing.
// - The key with Cmd, Ctrl, Option or Shift is a normal key. So is a key during the composition of
//   an input method (KeyEvent.isDictationKey). While dictation cannot start, the key is a normal
//   key too.
// - A key that types its text stops a dictation and its typer first, as each key that goes to the
//   PTY does. While a final text types, it does not stop the typer.
//
// The other input: the rules of a key are ChatKeyAction. A click, a paste or a drop can send text
// or move the cursor of Claude's prompt, so it stops a dictation and its typer too. A cursor key in
// the data of the terminal (a mouse wheel with no mouse tracking sends the arrow keys with no key
// down) stops a dictation before it goes to the PTY. While a final text types, neither stops the
// typer. A choice that typed text can answer blocks the dictation.

// The dictation of a chat as its chat input sees it. ChatDictation in the app.
@MainActor
package protocol ChatInputDictation: AnyObject {
    // False when the dictation key must act as a normal key: the chat has no attach, it shows
    // the agent view, or Claude shows a choice.
    var canStart: Bool { get }
    // False while a hold has no first level or text: a release or another key types the key.
    var heard: Bool { get }
    // True when a key must not stop the typer of a final text.
    var waits: Bool { get }
    // The dictation key is held.
    func start()
    // The dictation key went up after the start.
    func stop()
    // Another key, a blur or a close during the hold: the dictation stops early.
    func cancel()
    // Input of the user goes to the PTY: a hold stops, and a typer stops unless a final text
    // types.
    func interrupt()
    // Escape, Ctrl+C or a choice: the dictation and each typer stop at once, and the keys that
    // wait go away.
    func block()
    // Make the speech engine ready.
    func warm()
    // Input of the user for the PTY.
    func input(_ data: String)
}

@MainActor
package final class ChatInput {
    // The time that the dictation key must stay down before dictation starts.
    nonisolated package static let holdTime = Duration.milliseconds(250)

    private enum Hold {
        case idle
        // The key is down, and the hold time did not pass. The timer starts the hold.
        case waiting(code: KeyCode, text: String)
        // Dictation started, and the key is still down.
        case holding(code: KeyCode, text: String)
        // The key typed its text or stopped its dictation. It is a normal key until it goes up.
        case released(code: KeyCode)

        var code: KeyCode? {
            switch self {
            case .idle: nil
            case .waiting(let code, _), .holding(let code, _), .released(let code): code
            }
        }
    }

    // ChatDictation owns its chat input, so the dictation lives longer than the input.
    private unowned let dictation: any ChatInputDictation
    private let holdTime: Duration
    // The timer of a key that waits for the hold time.
    private let holdSlot: TimerSlot
    // True while the hold timer runs. A test counts it (ChatDictation.runningTimers).
    var holdRunning: Bool { holdSlot.isRunning }
    private var hold = Hold.idle {
        // The end of a wait stops its timer. A timer that wakes after this does nothing.
        didSet {
            if case .waiting = hold {} else { holdSlot.stop() }
        }
    }

    package init(
        dictation: any ChatInputDictation, clock: any Clock<Duration>,
        holdTime: Duration = ChatInput.holdTime
    ) {
        self.dictation = dictation
        self.holdSlot = TimerSlot(clock: clock)
        self.holdTime = holdTime
    }

    // The timer of a key that waits for the hold time, or nil. A test waits for it.
    package var holdTimer: Task<Void, Never>? { holdSlot.task }

    // A key down or a key up, after the Bifrost keys. dictationKey is the physical key of the
    // dictation key, or nil when the key is Off. True when the chat input takes the event: the
    // terminal must not get it.
    package func key(_ event: KeyEvent, dictationKey: KeyCode?) -> Bool {
        // Read the wait before the hold key acts. So a key of a live dictation still stops it.
        let waits = dictation.waits
        let held = event.isDown ? holdDown(event, dictationKey) : holdUp(event)
        if held {
            if event.isDown && !event.isRepeat { dictation.warm() }
            return true
        }
        let action = ChatKeyAction(event, waits: waits)
        switch action.stop {
        case .interrupt: dictation.interrupt()
        case .block: dictation.block()
        case nil: break
        }
        switch action.route {
        case .terminal:
            return false
        case .swallow:
            return true
        case .send(let text):
            dictation.input(text)
            return true
        }
    }

    // The data of the terminal for the PTY: the text of the keys, a paste and the replies.
    package func data(_ text: String) {
        if PTYText.movesCursor(text) && !dictation.waits { dictation.interrupt() }
        dictation.input(text)
    }

    // A mouse down, a paste or a drop: input that comes with no key down.
    package func other() {
        if !dictation.waits { dictation.interrupt() }
    }

    // A registry update of the row of the chat. blocks is SessionAlert.blocksPrompt of the row.
    package func row(blocks: Bool) {
        if blocks { dictation.block() }
    }

    // The chat got the key focus: the speech engine gets ready, only with a dictation key. The
    // chat lost the key focus: a waiting key types its text, and a hold stops.
    package func focus(_ focused: Bool, dictationKey: KeyCode?) {
        if focused {
            if dictationKey != nil { dictation.warm() }
        } else {
            leave(typing: true)
        }
    }

    // The chat closes. A waiting key types nothing, and a hold stops.
    package func close() {
        leave(typing: false)
    }

    // Dictation could not start. The held key types its text, as a normal key.
    package func fallback() {
        guard case .holding(let code, let text) = hold else { return }
        hold = .released(code: code)
        typeKey(text)
    }

    // MARK: - The hold key

    // A key down. True when the hold key takes it.
    private func holdDown(_ event: KeyEvent, _ code: KeyCode?) -> Bool {
        guard event.isDictationKey(code: code) else {
            otherKey()
            return false
        }
        switch hold {
        case .idle:
            break
        case .released where !event.isRepeat:
            // The key up did not come, because macOS sends none while Cmd is down. Start again.
            hold = .idle
        default:
            // A repeat, or a second key down with no key up.
            return true
        }
        guard !event.isRepeat, dictation.canStart, let code else { return false }
        hold = .waiting(code: code, text: event.characters)
        holdSlot.start(after: holdTime) { [weak self] in self?.holdTimeReached() }
        return true
    }

    // A key up. True when it is the key up of the held key.
    private func holdUp(_ event: KeyEvent) -> Bool {
        guard let code = hold.code, event.keyCode == code else { return false }
        let before = hold
        hold = .idle
        switch before {
        case .waiting(_, let text):
            typeKey(text)
        case .holding(_, let text):
            if !dictation.heard { typeKey(text) }
            dictation.stop()
        case .idle, .released:
            break
        }
        return true
    }

    // Another key goes down.
    private func otherKey() {
        switch hold {
        case .waiting(let code, let text):
            hold = .released(code: code)
            typeKey(text)
        case .holding(let code, let text):
            hold = .released(code: code)
            if !dictation.heard { typeKey(text) }
            dictation.cancel()
        case .idle, .released:
            break
        }
    }

    // Leave the hold. A waiting key types its text when typing is true.
    private func leave(typing: Bool) {
        let before = hold
        hold = .idle
        switch before {
        case .waiting(_, let text):
            if typing { typeKey(text) }
        case .holding:
            dictation.cancel()
        case .idle, .released:
            break
        }
    }

    // The key stayed down for the hold time.
    private func holdTimeReached() {
        guard case .waiting(let code, let text) = hold else { return }
        guard dictation.canStart else {
            hold = .released(code: code)
            typeKey(text)
            return
        }
        hold = .holding(code: code, text: text)
        dictation.start()
    }

    // The key types its text, as a normal key.
    private func typeKey(_ text: String) {
        if !dictation.waits { dictation.interrupt() }
        dictation.input(text)
    }
}
