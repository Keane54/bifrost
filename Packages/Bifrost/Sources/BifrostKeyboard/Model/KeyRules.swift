// The key rules of a chat terminal and of the send box. The behaviour list is in
// docs/behaviour/chat.md.

// Where a key of a chat goes.
package enum KeyRoute: Sendable, Equatable {
    // The terminal gets the key.
    case terminal
    // The chat takes the key and sends nothing to the PTY.
    case swallow
    // The chat takes the key and sends this text to the PTY in place of the text of the terminal.
    case send(String)

    // SwiftTerm sends a carriage return for Enter and also for Shift+Enter. So Claude Code submits
    // on both. Claude Code reads Escape and a carriage return as a new line. Its terminal setup
    // gives Shift+Enter the same text in VS Code (user decision, 2026-11-10).
    package static let newLineText = "\u{1b}\r"

    // The route of a key of a chat. Shift+Enter sends a new line at its key down, and its key up
    // goes nowhere. The terminal gets each other key.
    package init(_ event: KeyEvent) {
        guard event.key == .named(.enter), event.modifiers == .shift else {
            self = .terminal
            return
        }
        self = event.isDown ? .send(Self.newLineText) : .swallow
    }
}

extension KeyEvent {
    // True for the key that sends the text of the send box: Enter. Shift+Enter adds a line break,
    // and Enter during an input method composition does not send. The send box of phase 4b uses
    // it.
    package var isSendKey: Bool {
        key == .named(.enter) && !modifiers.contains(.shift) && !isComposing
    }
}
