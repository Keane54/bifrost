// The Bifrost keys (docs/behaviour/keys.md, "What happens when you press a key"). The layer finds
// the command of a key event.
//
// The window event filter calls handle(_:zone:settingsOnTop:) before the views get the event. Only
// a key that its slot allows in the zone takes the event and runs its command. So a chat window
// gets every other key unchanged.
//
// The rules of one key event:
// - Each chord that matches the event with the best score acts. A lower score does not act.
// - A key down acts again for each key repeat.
// - A hold key acts at its key up, and only when its key down matched first. The key down of any
//   other key (not a repeat) between the two cancels that key up, so the hold key does not act.
// - The key up of a hold key always removes the key from the hold gate, also when the key up does
//   not act. So the next row click is a plain click (row K1).

// What the key layer did with one event.
package struct KeyOutcome: Sendable, Equatable {
    package enum Effect: Sendable, Equatable {
        // A key ran the command of its slot. What the command does is app logic.
        case command(KeySlot)
        // Esc gave this intent at once (in the send box, or at the key up of a hold key).
        case escape(EscapeIntent)
        // Esc waits for the end of the dispatch: no other handler must take it. Call finishEscape
        // after the views had the event.
        case deferEscape
    }

    // True when the layer took the event: the views and the chat input must not get it.
    package var consumed = false
    package var effects: [Effect] = []

    package init() {}
}

package struct KeyLayer: Sendable {
    // What the key of a chord does.
    private enum Action: Sendable {
        // The key runs the command of its slot at the key down.
        case key(KeySlot)
        // A hold key. Its key down puts it in the hold gate. Its key up runs the slot of the same
        // key that is not a hold slot, when there is one (D8). A row click while the key is down
        // runs the hold slot (holdClick).
        case hold(up: KeySlot?)
    }

    private struct Entry: Sendable {
        let chord: Chord
        let action: Action
    }

    // The key up of a hold key that waits: armed by its key down, or cancelled by the key down of
    // another key.
    private enum PendingUp: Sendable {
        case armed
        case cancelled
    }

    // The chords that act, in the order of the match: the keys in slot order, then the hold keys.
    private let entries: [Entry]
    // The hold slot of each hold key.
    private let holdSlots: [Chord: KeySlot]
    private let holdKeys: Set<Chord>
    private var pendingUps: [Chord: PendingUp] = [:]
    private(set) var gate = HoldGate()

    package init(keys: KeyMap) {
        let active = keys.activeBindings
        // The map gives each hold slot its own key, as two slots of one class cannot share one.
        let holds = active.filter { $0.slot.group == .hold }
        let others = active.filter { $0.slot.group != .hold }
        let holdKeys = Set(holds.map(\.chord))
        let keyEntries = others.filter { !holdKeys.contains($0.chord) }.map {
            Entry(chord: $0.chord, action: .key($0.slot))
        }
        let holdEntries = holds.map { hold in
            let up = others.first { $0.chord == hold.chord }?.slot
            return Entry(chord: hold.chord, action: .hold(up: up))
        }
        entries = keyEntries + holdEntries
        holdSlots = Dictionary(uniqueKeysWithValues: holds.map { ($0.chord, $0.slot) })
        self.holdKeys = holdKeys
    }

    // One key down or key up. zone is the focus zone at the time of the event. settingsOnTop is
    // true when Settings is the active panel of the top frame (for the Esc rule).
    package mutating func handle(
        _ event: KeyEvent, zone: FocusZone, settingsOnTop: Bool
    ) -> KeyOutcome {
        var outcome = KeyOutcome()
        for entry in fired(event) {
            run(
                entry, isDown: event.isDown, zone: zone, settingsOnTop: settingsOnTop,
                into: &outcome)
        }
        switch GateChange(event, holdKeys: holdKeys) {
        case .clear?: gate.clear()
        case .up(let key)?: _ = gate.up(key)
        case nil: break
        }
        // The rollover rule (row K1): the key up of a hold key removes it from the gate, also
        // when the key down of another key cancelled its key up.
        if !event.isDown, let key = event.holdKey(in: holdKeys), gate.isDown(key) {
            _ = gate.up(key)
        }
        return outcome
    }

    // The entries that act for this event: the matches with the best score.
    private mutating func fired(_ event: KeyEvent) -> [Entry] {
        if event.isDown && !event.isRepeat {
            // The key down of another key cancels each pending key up.
            pendingUps = pendingUps.mapValues { _ in .cancelled }
        }
        var matches: [(entry: Entry, score: MatchScore)] = []
        for entry in entries {
            if let score = score(of: entry, for: event) { matches.append((entry, score)) }
        }
        guard let best = matches.map(\.score).max() else { return [] }
        return matches.filter { $0.score == best }.map(\.entry)
    }

    // The score of an entry for an event, or nil when the entry does not act.
    private mutating func score(of entry: Entry, for event: KeyEvent) -> MatchScore? {
        let score = entry.chord.match(event)
        switch (entry.action, event.isDown) {
        case (.key, true):
            return score
        case (.key, false):
            return nil
        case (.hold, true):
            // The key down of a hold key arms its key up. A key repeat arms it again.
            if score != nil { pendingUps[entry.chord] = .armed }
            return score
        case (.hold, false):
            // A hold key has no modifier, so only the key up of its own key ends the wait.
            guard let score, let pending = pendingUps.removeValue(forKey: entry.chord),
                case .armed = pending
            else { return nil }
            return score
        }
    }

    private mutating func run(
        _ entry: Entry, isDown: Bool, zone: FocusZone, settingsOnTop: Bool,
        into outcome: inout KeyOutcome
    ) {
        switch entry.action {
        case .key(let slot):
            // Return at once when the zone does not allow the key (D5).
            guard slot.acts(entry.chord, in: zone) else { return }
            if slot.command == .escape && zone != .sendBox {
                // Esc does not take the event. It acts at the end of the dispatch (D26).
                outcome.effects.append(.deferEscape)
                return
            }
            outcome.consumed = true
            outcome.effects.append(effect(for: slot, zone: zone, settingsOnTop: settingsOnTop))
        case .hold where isDown:
            // A hold key goes down. It is active only in the other zone (docs/behaviour/keys.md,
            // "Where a shortcut can act").
            let active = zone == .other
            gate.down(entry.chord, active: active)
            if active { outcome.consumed = true }
        case .hold(let up):
            // A hold key goes up. With no row click during the hold, the key runs the command of
            // its slot that is not a hold slot (D8). The focus can move during the hold: then the
            // key does not act.
            guard gate.up(entry.chord), let up, up.acts(entry.chord, in: zone) else { return }
            outcome.effects.append(effect(for: up, zone: zone, settingsOnTop: settingsOnTop))
        }
    }

    // The effect of a slot that acts. Only the deferred Esc reads the key repeat.
    private func effect(
        for slot: KeySlot, zone: FocusZone, settingsOnTop: Bool
    ) -> KeyOutcome.Effect {
        guard slot.command == .escape else { return .command(slot) }
        return .escape(EscapeIntent(zone: zone, settingsOnTop: settingsOnTop))
    }

    // The end of the dispatch of an Esc that waited. handled is true when another handler took
    // the key. The zone is the zone at the key down, before a handler moved the focus.
    package func finishEscape(
        zone: FocusZone, handled: Bool, isRepeat: Bool, settingsOnTop: Bool
    ) -> EscapeIntent {
        EscapeIntent(
            zone: zone, escapeHandled: handled, isRepeat: isRepeat, settingsOnTop: settingsOnTop)
    }

    // A primary pointer-down on a row. It claims a held hold key for the row (D8).
    package mutating func holdPress(_ row: String) {
        _ = gate.press(row)
    }

    // A row click. The hold slot when the pointer-down of this click claimed a held hold key,
    // else nil (a plain click).
    package mutating func holdClick(_ row: String) -> KeySlot? {
        gate.release(row).flatMap { holdSlots[$0] }
    }

    // True while a row click is a hold click. Then a double-click does not select or open a row.
    package func holding() -> Bool {
        gate.holding()
    }

    // The window lost the focus or became hidden. No key up comes, so the gate forgets all keys.
    package mutating func blur() {
        gate.clear()
    }

    // A new first responder. It can select the session of a chat window and clear the gate.
    package mutating func focus(
        _ target: FocusTarget?, selectedId: String?, rows: [String]
    ) -> String? {
        let change = FocusChange(target, selectedId: selectedId, rows: rows)
        if change.clearGate { gate.clear() }
        return change.select
    }
}
