// The chat of the key scenarios: a real SwiftTerm terminal view as the first responder of the
// chat, with a real chat input (ChatInput of BifrostDictation). It stands in for the chat
// terminal. The dictation of the chat input is the state of the scenario: each call goes to the
// log, and each input goes to the log of the PTY. No process runs, so no shell, no program and
// no Claude session runs. The scenarios read only the bytes for the PTY, so no shell is
// necessary.
import AppKit
import BifrostTestSupport
import SwiftTerm

@testable import BifrostDictation
@testable import BifrostKeyboard
@testable import BifrostWindows

// The terminal view of the chat. It is a ChatKeyTarget, as the chat terminal view is.
final class StandInChatView: TerminalView, ChatKeyTarget {
    var sessionId = "S1"
    var onKey: ((KeyEvent, KeyCode?) -> Bool)?
    var onFocus: ((Bool, KeyCode?) -> Void)?

    init() {
        let options = TerminalOptions(cols: 100, rows: 20, scrollback: 500)
        super.init(
            frame: NSRect(x: 0, y: 0, width: 760, height: 340),
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), options: options)
        optionAsMetaKey = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // The input method of the chat. The tests have no real input method. During a composition
    // (marked text), an input method of macOS keeps each key that the terminal gives to
    // interpretKeyEvents. So this view keeps the key too.
    override func interpretKeyEvents(_ eventArray: [NSEvent]) {
        if hasMarkedText() { return }
        super.interpretKeyEvents(eventArray)
    }

    var isComposing: Bool { hasMarkedText() }

    func chatKey(_ event: KeyEvent, dictationKey: KeyCode?) -> Bool {
        onKey?(event, dictationKey) ?? false
    }

    func chatFocus(_ focused: Bool, dictationKey: KeyCode?) {
        onFocus?(focused, dictationKey)
    }
}

// The dictation of the scenarios. The scenario sets its state: a block of the session (a choice
// of Claude shows), the first level or text of the hold, and a final text that types.
@MainActor
final class GateDictation: ChatInputDictation {
    private let state: GateState

    init(state: GateState) {
        self.state = state
    }

    var canStart: Bool { !state.blocked }
    var heard: Bool { state.heard }
    var waits: Bool { state.waits }
    func start() { state.record("dict:start") }
    func stop() { state.record("dict:stop") }
    func cancel() { state.record("dict:cancel") }
    func interrupt() { state.record("dict:interrupt") }
    func block() { state.record("dict:block") }
    func warm() { state.record("dict:warm") }
    func input(_ data: String) { state.recordPty(Array(data.utf8)) }
}

@MainActor
final class TerminalHost: NSObject, TerminalViewDelegate {
    let view = StandInChatView()
    let dictation: GateDictation
    let input: ChatInput
    // While it is not nil, the text of the terminal goes here and not to the chat input (the
    // calibration).
    var capture: [UInt8]?

    init(state: GateState, holdTime: Duration, clock: ManualClock) {
        let dictation = GateDictation(state: state)
        let input = ChatInput(dictation: dictation, clock: clock, holdTime: holdTime)
        self.dictation = dictation
        self.input = input
        super.init()
        view.terminalDelegate = self
        view.onKey = { input.key($0, dictationKey: $1) }
        view.onFocus = { input.focus($0, dictationKey: $1) }
    }

    // MARK: TerminalViewDelegate

    // The text that the terminal sends for a key, a paste or a reply.
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if capture != nil {
            capture?.append(contentsOf: data)
            return
        }
        input.data(String(decoding: data, as: UTF8.self))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
}
