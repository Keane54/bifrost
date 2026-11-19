// The gate of the hold keys (D8). A hold key acts at its key up, and only when no row click used
// it. A hold key is a chord of one letter or digit with no modifier. The behaviour list is in
// docs/behaviour/keys.md.
package struct HoldGate: Sendable {
    private struct HeldKey: Sendable {
        // True when the key went down in the other zone.
        var active: Bool
        // True when a row click used the key.
        var used: Bool
    }

    // A claim of a primary pointer-down on a row: the hold key and the ID of the row.
    private struct Claim: Sendable {
        let key: Chord
        let target: String
    }

    private var keys: [Chord: HeldKey] = [:]
    // The claim of the last primary pointer-down on a row.
    private var claim: Claim?

    package init() {}

    // A key that is down already does nothing. This is the key repeat.
    package mutating func down(_ key: Chord, active: Bool) {
        if keys[key] != nil { return }
        keys[key] = HeldKey(active: active, used: false)
    }

    // Remove the key. Give true only when the key was down, active and not used.
    package mutating func up(_ key: Chord) -> Bool {
        let held = keys.removeValue(forKey: key)
        return held?.active == true && held?.used == false
    }

    // Give the one active key that is down and mark it used. Else give nil and mark nothing.
    package mutating func click() -> Chord? {
        let active = keys.filter(\.value.active)
        guard active.count == 1, let key = active.first?.key else { return nil }
        keys[key]?.used = true
        return key
    }

    // A primary pointer-down on a row. Claim the one active key that is down for this row and
    // mark it used. So a key up before the mouse up does not act on the selected row (final
    // review Important 2). A pointer-down with no such key removes an old claim.
    package mutating func press(_ target: String) -> Chord? {
        let key = click()
        claim = key.map { Claim(key: $0, target: target) }
        return key
    }

    // The click of a row. Give the key that the pointer-down on this row claimed, then remove
    // the claim. A click with no claim for this row gives nil.
    package mutating func release(_ target: String) -> Chord? {
        let current = claim
        claim = nil
        guard let current, current.target == target else { return nil }
        return current.key
    }

    // True while exactly one active key is down. Then a row click is a hold click, also when
    // the click used the key.
    package func holding() -> Bool {
        keys.values.filter(\.active).count == 1
    }

    // Forget all keys and the claim (window blur, a hidden window, the Cmd key, the key
    // recorder).
    package mutating func clear() {
        keys.removeAll()
        claim = nil
    }

    package func isDown(_ key: Chord) -> Bool {
        keys[key] != nil
    }
}

// A change of the hold gate for a key event that the hold keys themselves do not handle.
enum GateChange: Sendable, Equatable {
    // Forget all keys.
    case clear
    // Remove this key.
    case up(Chord)

    // macOS sends no key up for a key that goes up while Cmd is down. So a key down or a key up
    // of Cmd clears the gate. The hold key matches only its key with no modifier. When the user
    // pushes a modifier before the release of a hold key, its key up with the modifier removes
    // the key: a key that stays in the gate would change the next row click. Another event
    // gives nil.
    init?(_ event: KeyEvent, holdKeys: Set<Chord>) {
        if event.key == .modifier(.command) {
            self = .clear
        } else if !event.isDown, !event.modifiers.isEmpty, let key = event.holdKey(in: holdKeys) {
            self = .up(key)
        } else {
            return nil
        }
    }
}

extension KeyEvent {
    // The hold key of the event, with or without a modifier, or nil. The typed text gives the key
    // when it is an ASCII letter or digit. Else the place of the key gives it: a letter key, or a
    // key of the digit row. So Shift+1 ("!") and Option+O ("ø") give the keys 1 and O.
    func holdKey(in holdKeys: Set<Chord>) -> Chord? {
        var character: Character?
        if case .text(let text) = key, text.count == 1, let typed = text.first, typed.isASCII,
            typed.isLetter || typed.isNumber
        {
            character = Character(typed.uppercased())
        } else if let us = keyCode.usCharacter, keyCode.isLetter || keyCode.isDigitRow {
            character = us
        }
        guard let character else { return nil }
        let chord = Chord(key: .character(character))
        return holdKeys.contains(chord) ? chord : nil
    }
}
