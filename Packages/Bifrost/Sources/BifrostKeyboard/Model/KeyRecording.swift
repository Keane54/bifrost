// The key recording of Settings > Keys (docs/behaviour/keys.md, "Changing a key"): the state of
// the key recorder, and what the recorder does with each key down while it records. The key
// recorder view (BifrostSettings) keeps the state.

// The state of the key recorder: on while it records.
package struct KeyRecording: Sendable, Equatable {
    package private(set) var on = false

    package init() {}

    // Start (true) or end (false) the recording. True when the state changed, so the recorder
    // tells each start and each end one time.
    @discardableResult
    package mutating func set(_ on: Bool) -> Bool {
        guard self.on != on else { return false }
        self.on = on
        return true
    }

    // End the recording. True when a recording ended.
    @discardableResult
    package mutating func reset() -> Bool {
        set(false)
    }
}

extension KeyRecording {
    // What the recorder does with a key event while it records.
    package enum Step: Sendable, Equatable {
        // The key goes to the check of a recorded key.
        case record
        // The recording ends with no key.
        case end
        // The event is not a new key, so nothing happens.
        case ignore
    }

    // The step of a key event. A key up, a key repeat, a modifier key alone and a key of a
    // composition are not a new key. Esc ends the recording, and so do Backspace and Delete with
    // no modifier. Each other key down is recorded, also Tab, Enter and Space.
    package static func step(for event: KeyEvent) -> Step {
        guard event.isDown, !event.isRepeat, !event.isComposing else { return .ignore }
        switch event.key {
        case .modifier: return .ignore
        case .named(.escape): return .end
        case .named(.backspace), .named(.delete): return event.modifiers.isEmpty ? .end : .record
        default: return .record
        }
    }
}
