import BifrostKeyboard

// The pure key rules of the chat input of a chat window: the dictation key and what a key does
// to a dictation. ChatInput runs them, with the hold key and its timer. The rules of the text
// that the chat writes to its pseudo-terminal are in PTYText.swift.

extension KeyEvent {
    // True when the event is the dictation key with no modifier, outside a composition, and the
    // key types one character. code is the physical key of the dictation key, or nil when the key
    // is Off. The key with Cmd, Ctrl, Option or Shift, a key during the composition of an input
    // method and a dead key are normal keys.
    package func isDictationKey(code: KeyCode?) -> Bool {
        guard let code, keyCode == code, modifiers.isEmpty, !isComposing,
            characters.unicodeScalars.count == 1,
            let scalar = characters.unicodeScalars.first
        else { return false }
        return scalar.properties.generalCategory != .control
    }

    // True for a modifier key alone: it types nothing.
    var isModifierKey: Bool {
        guard case .modifier = key else { return false }
        return true
    }
}

// What a key of a chat does to a dictation before the key goes on.
package enum DictationStop: Sendable, Equatable {
    // Stop a hold of dictation. A final text still types (ChatDictation.interrupt).
    case interrupt
    // Stop a dictation and each typer at once. The keys that wait go away (ChatDictation.block).
    case block
}

// What a key event of a chat does after the hold key: the stop of a dictation, and the route of
// the key.
package struct ChatKeyAction: Sendable, Equatable {
    package var stop: DictationStop?
    package var route: KeyRoute

    package init(stop: DictationStop? = nil, route: KeyRoute = .terminal) {
        self.stop = stop
        self.route = route
    }

    // The rules of a key in a chat, after the hold key. waits is true while the final text of a
    // released dictation types (ChatDictation.waits).
    // - Each key down stops a dictation and its typer before the key goes to the PTY. So a key
    //   cannot break the count of the typed text. A modifier key alone writes nothing, so it does
    //   not.
    // - While a final text types, a key does not stop the typer. The key waits in the input of
    //   the dictation.
    // - Escape and Ctrl+C stop each typer at once, also while a final text types. The keys that
    //   wait go away, so a waiting Enter cannot submit a part of the text
    //   (docs/behaviour/dictation.md, The typer).
    // - Shift+Enter gives a new line, not a submit (KeyRoute). During a composition of an input
    //   method, the key goes to the input method (row K2).
    package init(_ event: KeyEvent, waits: Bool) {
        self.init()
        if event.isDown && !event.isModifierKey {
            if Self.stopsAtOnce(event) {
                stop = .block
            } else if !waits {
                stop = .interrupt
            }
        }
        if !event.isComposing { route = KeyRoute(event) }
    }

    // Escape and Ctrl+C stop each typer at once, also while a final text types.
    private static func stopsAtOnce(_ event: KeyEvent) -> Bool {
        if event.key == .named(.escape) { return true }
        guard event.modifiers.contains(.control) else { return false }
        if event.keyCode.usCharacter == "C" { return true }
        guard case .text(let text) = event.key else { return false }
        return text.lowercased() == "c"
    }
}
