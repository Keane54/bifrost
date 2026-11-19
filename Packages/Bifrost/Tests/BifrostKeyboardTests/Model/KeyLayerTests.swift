// The key layer: the key commands of the window and the hold keys (docs/behaviour/keys.md). The
// window filter checks the same rules with real NSEvents (the 318 key scenarios).
import BifrostTestSupport
import Testing

@testable import BifrostKeyboard

// The command effect of the slot with this ID. The effect holds the slot.
private func command(_ id: String) -> KeyOutcome.Effect {
    .command(keySlot(id))
}

// The match score of an event for a binding, or nil.
private func score(_ event: KeyEvent, _ binding: String) -> MatchScore? {
    chord(binding).match(event)
}

// A key event of a US keyboard (see ev). With a place, the key at that place types the text, as
// another layout does: key(.keydown, "/", at: "7", shift: true) is Shift+7 of a German layout.
private func key(
    _ edge: Edge, _ text: String, at place: String? = nil, shift: Bool = false,
    alt: Bool = false, ctrl: Bool = false, meta: Bool = false, isRepeat: Bool = false
) -> KeyEvent {
    let mods = Mods(shift: shift, alt: alt, ctrl: ctrl, meta: meta, isRepeat: isRepeat)
    var event = ev(edge, place ?? text, mods)
    if place != nil {
        event.characters = text
        event.charactersIgnoringModifiers = text
    }
    return event
}

@Suite("the key layer")
struct KeyLayerTests {
    @Test("a Cmd key runs its command and stops the event, except in a dialog")
    func cmdKey() {
        var layer = KeyLayer(keys: .defaults)
        for zone in [FocusZone.chat, .sendBox, .text, .control, .other] {
            let outcome = layer.handle(
                key(.keydown, "n", meta: true), zone: zone, settingsOnTop: false)
            #expect(outcome.effects == [command("new-session:mod")], "\(zone)")
            #expect(outcome.consumed, "\(zone)")
        }
        let modal = layer.handle(
            key(.keydown, "n", meta: true), zone: .modal, settingsOnTop: false)
        #expect(modal.effects.isEmpty)
        #expect(!modal.consumed)
    }

    @Test("a single key acts outside a chat window and leaves the event in a chat window")
    func singleKey() {
        var layer = KeyLayer(keys: .defaults)
        let other = layer.handle(key(.keydown, "c"), zone: .other, settingsOnTop: false)
        #expect(other.effects == [command("copy-id:key")])
        let chat = layer.handle(key(.keydown, "c"), zone: .chat, settingsOnTop: false)
        #expect(chat.effects.isEmpty)
        #expect(!chat.consumed)
    }

    @Test
    func holdKeyUp() {
        var layer = KeyLayer(keys: .defaults)
        let down = layer.handle(key(.keydown, "o"), zone: .other, settingsOnTop: false)
        #expect(down.effects.isEmpty)
        #expect(down.consumed)
        let up = layer.handle(key(.keyup, "o"), zone: .other, settingsOnTop: false)
        #expect(up.effects == [command("open:key")])
    }

    @Test("a hold key and a row click run the hold command and the key up does nothing")
    func holdClick() {
        var layer = KeyLayer(keys: .defaults)
        _ = layer.handle(key(.keydown, "3"), zone: .other, settingsOnTop: false)
        layer.holdPress("S1")
        #expect(layer.holdClick("S1") == keySlot("set-priority.3:hold"))
        #expect(
            layer.handle(key(.keyup, "3"), zone: .other, settingsOnTop: false).effects
                .isEmpty)
    }

    // The native rule (an accepted change, docs/behaviour/keys.md): the key up of O removes it
    // from the gate, so the next row click is a plain click, not a hold click (open:hold).
    @Test("another key down before the key up cancels the key up")
    func pendingCancelled() {
        var layer = KeyLayer(keys: .defaults)
        _ = layer.handle(key(.keydown, "o"), zone: .other, settingsOnTop: false)
        let p = layer.handle(key(.keydown, "p"), zone: .other, settingsOnTop: false)
        #expect(p.effects == [command("open-project:key")])
        #expect(
            layer.handle(key(.keyup, "o"), zone: .other, settingsOnTop: false).effects
                .isEmpty)
        // The key up removed O from the gate: the next row click is a plain click.
        layer.holdPress("S2")
        #expect(layer.holdClick("S2") == nil)
    }

    @Test
    func repeatKeepsPending() {
        var layer = KeyLayer(keys: .defaults)
        _ = layer.handle(key(.keydown, "o"), zone: .other, settingsOnTop: false)
        _ = layer.handle(
            key(.keydown, "o", isRepeat: true), zone: .other, settingsOnTop: false)
        #expect(
            layer.handle(key(.keyup, "o"), zone: .other, settingsOnTop: false).effects == [
                command("open:key")
            ])
    }

    @Test("Esc waits for the end of the dispatch outside the send box")
    func escapeDefers() {
        var layer = KeyLayer(keys: .defaults)
        let other = layer.handle(
            key(.keydown, "Escape"), zone: .other, settingsOnTop: false)
        #expect(other.effects == [.deferEscape])
        #expect(!other.consumed)
        #expect(
            layer.finishEscape(zone: .other, handled: false, isRepeat: false, settingsOnTop: false)
                == .openSettings)
        let sendBox = layer.handle(
            key(.keydown, "Escape"), zone: .sendBox, settingsOnTop: false)
        #expect(sendBox.effects == [.escape(.leaveSendBox)])
        #expect(sendBox.consumed)
    }

    @Test("Cmd clears the gate and a key up with a modifier removes the hold key")
    func gateChanges() {
        var layer = KeyLayer(keys: .defaults)
        _ = layer.handle(key(.keydown, "o"), zone: .other, settingsOnTop: false)
        _ = layer.handle(
            key(.keydown, "Meta", meta: true), zone: .other, settingsOnTop: false)
        #expect(!layer.gate.isDown(chord("O")))
        _ = layer.handle(key(.keydown, "m"), zone: .other, settingsOnTop: false)
        _ = layer.handle(key(.keyup, "M", shift: true), zone: .other, settingsOnTop: false)
        #expect(!layer.gate.isDown(chord("M")))
    }

    @Test("only the matches with the best score fire")
    func bestScore() {
        // A German layout types "/" with Shift+7. The binding "/" matches it directly with an
        // implicit Shift (score 2). The binding Shift+7 matches it by position (score 1).
        var layer = KeyLayer(keys: KeyMap(keyChanges(["rename:key": "Shift+7"])))
        let outcome = layer.handle(
            key(.keydown, "/", at: "7", shift: true), zone: .other, settingsOnTop: false)
        #expect(outcome.effects == [command("run-slash:key")])
        #expect(score(key(.keydown, "/", at: "7", shift: true), "Shift+7") == .position)
    }

    @Test("a menu slot is not registered by the layer")
    func menuSlot() {
        var layer = KeyLayer(keys: .defaults)
        #expect(
            layer.handle(key(.keydown, "w", meta: true), zone: .other, settingsOnTop: false)
                .effects.isEmpty)
        #expect(!KeyMap.defaults.activeBindings.contains { $0.slot.isMenu })
    }

    @Test("focus on the key recorder clears the gate and focus in a chat selects its session")
    func focus() {
        var layer = KeyLayer(keys: .defaults)
        _ = layer.handle(key(.keydown, "o"), zone: .other, settingsOnTop: false)
        #expect(
            layer.focus(
                FocusTarget(kind: .control, inKeyRecorder: true), selectedId: "S2",
                rows: ["S1", "S2"]) == nil)
        #expect(!layer.gate.isDown(chord("O")))
        #expect(
            layer.focus(
                FocusTarget(kind: .text, chatSession: "S1"), selectedId: "S2", rows: ["S1", "S2"])
                == "S1")
    }
}

// The new tests of the accepted key changes (docs/behaviour/keys.md) and of the kept
// rule of the hold letters.
@Suite("The key changes of the native app")
struct KeyChangeTests {
    @Test func aRolloverKeyUpRemovesTheKeyFromTheGate() {
        var layer = KeyLayer(keys: .defaults)
        // O down, P down, O up: the key down of P cancels the key up of O, so O does not act.
        _ = layer.handle(key(.keydown, "o"), zone: .other, settingsOnTop: false)
        _ = layer.handle(key(.keydown, "p"), zone: .other, settingsOnTop: false)
        let up = layer.handle(key(.keyup, "o"), zone: .other, settingsOnTop: false)
        #expect(up.effects.isEmpty)
        // But the key up removes O from the gate.
        #expect(!layer.gate.isDown(chord("O")))
        #expect(!layer.holding())
        _ = layer.handle(key(.keyup, "p"), zone: .other, settingsOnTop: false)
        // Then a row click is a plain click.
        layer.holdPress("S2")
        #expect(layer.holdClick("S2") == nil)
        // The pending key-up rule stays for the command: a key repeat keeps the key up.
        _ = layer.handle(key(.keydown, "o"), zone: .other, settingsOnTop: false)
        let again = layer.handle(
            key(.keydown, "o", isRepeat: true), zone: .other, settingsOnTop: false)
        #expect(again.effects.isEmpty)
        let last = layer.handle(key(.keyup, "o"), zone: .other, settingsOnTop: false)
        #expect(last.effects == [command("open:key")])
    }

    @Test func optionZeroDoesNotMatchOptionO() {
        // Option+0 types "º" on a US layout. The letter compare has no compatibility mapping, so
        // "º" is not the letter O.
        let optionZero = key(.keydown, "º", at: "0", alt: true)
        #expect(score(optionZero, "Alt+O") == nil)
        let optionShiftZero = key(.keydown, "º", at: "0", shift: true, alt: true)
        #expect(score(optionShiftZero, "Alt+Shift+O") == nil)
        // A match by position stays: Option+O types "ø", and its position is O.
        let optionO = key(.keydown, "ø", at: "o", alt: true)
        #expect(score(optionO, "Alt+O") == .position)
        // A letter still compares with no case, and with its accent.
        #expect(score(key(.keydown, "o"), "O") == .direct)
        #expect(score(key(.keydown, "é", at: "e"), "E") == nil)
        // The key layer gives no command for Option+0 with a key Alt+O.
        var layer = KeyLayer(keys: KeyMap(keyChanges(["open:mod": "Alt+O"])))
        let outcome = layer.handle(optionZero, zone: .other, settingsOnTop: false)
        #expect(outcome.effects.isEmpty)
    }

    // A user decision (2026-11-15): the single-key commands of the
    // hold keys (O, M, I, J, X and 1 to 5) do nothing on a focused control. KeySlot.acts allows
    // them there, but the hold key takes these keys, and a hold key is active only in the other
    // zone.
    @Test func holdLettersDoNothingOnAFocusedControl() throws {
        var layer = KeyLayer(keys: .defaults)
        let holds = KeySlot.all.filter { $0.group == .hold }
        #expect(holds.count == 10)
        for slot in holds {
            let binding = slot.defaultBinding
            let single = KeySlot.all.first { $0.group == .single && $0.defaultBinding == binding }
            if let single { #expect(single.acts(binding, in: .control), "\(binding)") }
            let text = binding.description.lowercased()
            let down = layer.handle(key(.keydown, text), zone: .control, settingsOnTop: false)
            let up = layer.handle(key(.keyup, text), zone: .control, settingsOnTop: false)
            #expect(down.effects.isEmpty && !down.consumed, "\(binding)")
            #expect(up.effects.isEmpty, "\(binding)")
        }
        // In the other zone the same key acts.
        let up = layer.handle(key(.keydown, "o"), zone: .other, settingsOnTop: false)
        #expect(up.consumed)
        let open = layer.handle(key(.keyup, "o"), zone: .other, settingsOnTop: false)
        #expect(open.effects == [command("open:key")])
    }
}
