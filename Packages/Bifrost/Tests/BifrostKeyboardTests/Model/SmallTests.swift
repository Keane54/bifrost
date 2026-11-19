// The small key rules: the labels of the keys, the parse of a raw chord, the focus zone, the plan
// of Esc and the send key of the send box (docs/behaviour/keys.md).
import BifrostFoundation
import BifrostTestSupport
import Testing

@testable import BifrostKeyboard

private func label(_ id: String, _ labels: LabelSet) -> String {
    keySlot(id).label(labels)
}

@Suite("key labels")
struct KeyLabelsTests {
    @Test
    func actionAndArg() {
        #expect(label("set-priority.3:mod", .plain) == "Set priority 3")
        #expect(label("set-priority.3:mod", .space) == "Set threat level 3")
        #expect(label("set-priority.0:key", .plain) == "Clear the priority")
        #expect(label("open-project:mod", .plain) == "Open project in the default app")
        #expect(label("open-project:mod", .space) == "Open cargo hold in the default app")
        #expect(label("select-row.4:mod", .plain) == "Select row 4")
        #expect(label("load-layout.2:mod", .plain) == "Load layout 2")
        #expect(label("escape:key", .plain) == "Open or close Settings, or leave the send box")
        #expect(label("dictation:hold", .plain) == "Dictation key")
    }

    @Test("a slot label has no trailing dots")
    func noDots() {
        #expect(label("send-message:mod", .plain) == "Send message")
        #expect(label("stop:key", .plain) == "Stop session")
    }

    @Test("every slot has a label")
    func eachSlot() {
        for slot in KeySlot.all {
            #expect(!slot.label(.plain).isEmpty, "\(slot)")
            #expect(!slot.label(.space).isEmpty, "\(slot)")
            #expect(!slot.label(.plain).hasSuffix("..."), "\(slot)")
        }
    }

    @Test("each group has a title")
    func groups() {
        #expect(SlotGroup.always.title == "Shortcuts that work at all times")
        #expect(SlotGroup.single.title == "Single keys (not in a chat window or a text box)")
        #expect(SlotGroup.hold.title == "Hold a key and click a row")
        #expect(SlotGroup.dictation.title == "Hold to dictate in a chat window")
    }
}

// The release of a hold key and the changes of the gate are in the release table
// (KeyRuleTableTests), and the key override is in the override table.
@Suite("raw chord")
struct RawChordTests {
    // A binding text gives a chord: its modifiers and its key.
    @Test
    func rawChordModifiers() {
        #expect(Chord("Mod+Shift+M") == Chord([.command, .shift], key: .character("M")))
        #expect(Chord("Escape") == Chord(key: .named(.escape)))
        #expect(Chord("Mod+Control+1") == Chord([.command, .control], key: .character("1")))
        #expect(Chord("Mod+Alt+S") == Chord([.command, .option], key: .character("S")))
        #expect(Chord("bad") == nil)
    }

    @Test
    func rawChordStandard() {
        #expect(Chord("shift+tab") == Chord(.shift, key: .named(.tab)))
        #expect(Chord("Cmd+/") == Chord(.command, key: .character("/")))
        #expect(Chord("") == nil)
    }
}

@Suite("focus zone")
struct FocusZoneTests {
    @Test("a modal wins over a chat in the focus zone")
    func modalFirst() {
        #expect(FocusZone(FocusTarget(kind: .text, inModal: true, chatSession: "S1")) == .modal)
        #expect(FocusZone(FocusTarget(kind: .other, inModal: true)) == .modal)
    }

    @Test("the terminal text area is the chat zone")
    func chat() {
        #expect(FocusZone(FocusTarget(kind: .text, chatSession: "S1")) == .chat)
    }

    @Test("the key recorder is the modal zone")
    func recorder() {
        #expect(FocusZone(FocusTarget(kind: .control, inKeyRecorder: true)) == .modal)
    }

    // The app classifies the AppKit view (text view, control, other view) before it makes the
    // FocusTarget. So the test checks the kinds.
    @Test("the focus zone can be send box, text, control or other")
    func zones() {
        #expect(FocusZone(FocusTarget(kind: .text, inSendBox: true)) == .sendBox)
        #expect(FocusZone(FocusTarget(kind: .text)) == .text)
        #expect(FocusZone(FocusTarget(kind: .control)) == .control)
        #expect(FocusZone(FocusTarget(kind: .other)) == .other)
        #expect(FocusZone(nil) == .other)
    }

    private let rows = ["S1", "S2"]

    @Test("focus in a chat window selects its session")
    func selects() {
        #expect(
            FocusChange(FocusTarget(kind: .text, chatSession: "S1"), selectedId: "S2", rows: rows)
                == FocusChange(select: "S1", clearGate: false))
        #expect(
            FocusChange(FocusTarget(kind: .text, chatSession: "S1"), selectedId: nil, rows: rows)
                == FocusChange(select: "S1", clearGate: false))
    }

    @Test("focus in the chat of the selected or an unknown session selects nothing")
    func selectsNothing() {
        #expect(
            FocusChange(FocusTarget(kind: .text, chatSession: "S1"), selectedId: "S1", rows: rows)
                .select == nil)
        #expect(
            FocusChange(FocusTarget(kind: .text, chatSession: "S9"), selectedId: "S2", rows: rows)
                .select == nil)
        #expect(
            FocusChange(FocusTarget(kind: .text, chatSession: ""), selectedId: "S2", rows: rows)
                .select == nil)
    }

    @Test("focus outside a chat window selects nothing")
    func outside() {
        #expect(
            FocusChange(FocusTarget(kind: .text, inSendBox: true), selectedId: "S2", rows: rows)
                == FocusChange(select: nil, clearGate: false))
        #expect(
            FocusChange(nil, selectedId: "S2", rows: rows)
                == FocusChange(select: nil, clearGate: false))
    }

    @Test("focus on the key recorder clears the hold gate")
    func recorderClears() {
        #expect(
            FocusChange(
                FocusTarget(kind: .control, inKeyRecorder: true), selectedId: "S2", rows: rows)
                == FocusChange(select: nil, clearGate: true))
    }
}

// The plan of Esc (docs/behaviour/keys.md, "Escape"). settingsOnTop is true when Settings is the
// active panel of the top frame that is not minimised.
@Suite("key plan for Escape")
struct EscapeTests {
    @Test("the send box keeps its own Esc")
    func leaves() {
        #expect(EscapeIntent(zone: .sendBox, settingsOnTop: false) == .leaveSendBox)
        #expect(EscapeIntent(zone: .sendBox, settingsOnTop: true) == .leaveSendBox)
    }

    // The selection is app state. EscapeIntent does not read it, so the intent is the same for
    // each selection.
    @Test("Esc opens Settings and keeps the selection")
    func opens() {
        #expect(EscapeIntent(zone: .other, settingsOnTop: false) == .openSettings)
        #expect(EscapeIntent(zone: .control, settingsOnTop: false) == .openSettings)
    }

    @Test("Esc closes Settings when it is the active panel of the top frame")
    func closes() {
        #expect(EscapeIntent(zone: .other, settingsOnTop: true) == .closeSettings)
        #expect(EscapeIntent(zone: .control, settingsOnTop: true) == .closeSettings)
    }

    // Settings under another frame, Settings as a back tab and a minimised Settings frame all
    // give settingsOnTop false. The app computes it.
    @Test
    func bringsToFront() {
        #expect(EscapeIntent(zone: .other, settingsOnTop: false) == .openSettings)
    }

    @Test("Esc does nothing when another handler took the key")
    func handled() {
        #expect(EscapeIntent(zone: .other, escapeHandled: true, settingsOnTop: false) == .none)
        #expect(EscapeIntent(zone: .other, escapeHandled: true, settingsOnTop: true) == .none)
        // The send box still loses the focus.
        #expect(
            EscapeIntent(zone: .sendBox, escapeHandled: true, settingsOnTop: false) == .leaveSendBox
        )
    }

    @Test("a held Esc does not toggle Settings again")
    func repeats() {
        #expect(EscapeIntent(zone: .other, isRepeat: true, settingsOnTop: false) == .none)
        #expect(EscapeIntent(zone: .other, isRepeat: true, settingsOnTop: true) == .none)
        #expect(EscapeIntent(zone: .other, isRepeat: false, settingsOnTop: false) == .openSettings)
        // A repeat in the send box still leaves it. That has no effect after the first key down.
        #expect(EscapeIntent(zone: .sendBox, isRepeat: true, settingsOnTop: false) == .leaveSendBox)
    }

    @Test("Esc does nothing in a chat window, text field, dialog, menu or the key recorder")
    func otherZones() {
        for zone in [FocusZone.chat, .text, .modal] {
            #expect(EscapeIntent(zone: zone, settingsOnTop: false) == .none, "\(zone)")
            #expect(EscapeIntent(zone: zone, settingsOnTop: true) == .none, "\(zone)")
        }
    }
}

@Suite("send key")
struct IsSendKeyTests {
    @Test("Enter sends, Shift+Enter and composition do not")
    func sendKey() {
        let enter = KeyCode(.enter)
        #expect(KeyEvent(keyCode: enter, characters: "\r").isSendKey)
        #expect(KeyEvent(keyCode: KeyCode(rawValue: 76), characters: "\u{3}").isSendKey)
        #expect(!KeyEvent(keyCode: enter, modifiers: .shift).isSendKey)
        #expect(!KeyEvent(keyCode: enter, isComposing: true).isSendKey)
        #expect(!KeyEvent(keyCode: KeyCode(rawValue: 0), characters: "a").isSendKey)
    }
}
