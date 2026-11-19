// Tables of the key rules and of the key map. Each test runs one rule on a table of cases, and
// each case has its own name in the report. The cases are the edge cases of the rules: the
// forms of a binding, the reserved keys, the conflicts of a slot class, the zones of a key, the
// match scores of an event and the key overrides of the chat. The rules of the chat input are in
// ChatKeyRuleTableTests.swift of BifrostDictationTests. The window key filter runs the 318
// scenarios in BifrostWindowsTests.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation
@testable import BifrostKeyboard

private let esc = "\u{1b}"

// MARK: - The forms of a binding

private struct Form: Sendable, CustomTestStringConvertible {
    let text: String
    // The standard form, or nil when the text is not a binding.
    let standard: String?
    var testDescription: String { "\(text.debugDescription) is \(standard ?? "no binding")" }
}

private let bindingForms: [Form] = [
    // The names of the modifiers: Mod, Cmd, Command and Meta are one modifier.
    Form(text: "Mod+N", standard: "Mod+N"),
    Form(text: "mod+n", standard: "Mod+N"),
    Form(text: "Cmd+N", standard: "Mod+N"),
    Form(text: "Command+N", standard: "Mod+N"),
    Form(text: "Meta+N", standard: "Mod+N"),
    Form(text: "Ctrl+K", standard: "Control+K"),
    Form(text: "Control+K", standard: "Control+K"),
    Form(text: "Option+Q", standard: "Alt+Q"),
    Form(text: "Alt+Q", standard: "Alt+Q"),
    Form(text: "SHIFT+Tab", standard: "Shift+Tab"),
    // The order of the modifiers and of the key does not matter.
    Form(text: "Z+Mod", standard: "Mod+Z"),
    Form(text: "Shift+Mod+Z", standard: "Mod+Shift+Z"),
    Form(text: "Alt+Shift+Control+Mod+x", standard: "Mod+Control+Alt+Shift+X"),
    // A letter has upper case. A named key has its standard name, in any case.
    Form(text: "k", standard: "K"),
    Form(text: "Up", standard: "ArrowUp"),
    Form(text: "left", standard: "ArrowLeft"),
    Form(text: "RIGHT", standard: "ArrowRight"),
    Form(text: "Esc", standard: "Escape"),
    Form(text: "escape", standard: "Escape"),
    Form(text: "Return", standard: "Enter"),
    Form(text: "return", standard: "Enter"),
    Form(text: "space", standard: "Space"),
    Form(text: "pagedown", standard: "PageDown"),
    Form(text: "f12", standard: "F12"),
    Form(text: "Mod+Alt+Shift+Backspace", standard: "Mod+Alt+Shift+Backspace"),
    // Symbols are keys. The plus sign cannot be one, because it separates the parts.
    Form(text: "Mod+/", standard: "Mod+/"),
    Form(text: "Mod+[", standard: "Mod+["),
    Form(text: "Mod+,", standard: "Mod+,"),
    Form(text: "Control+`", standard: "Control+`"),
    // A text that is not a binding: no key, two keys, a modifier twice, an unknown key.
    Form(text: "", standard: nil),
    Form(text: "Mod+", standard: nil),
    Form(text: "+Mod", standard: nil),
    Form(text: "Mod+Shift", standard: nil),
    Form(text: "Mod+A+B", standard: nil),
    Form(text: "Alt+PageUp+=", standard: nil),
    Form(text: "Cmd+Mod+Z", standard: nil),
    Form(text: "Shift+SHIFT+A", standard: nil),
    Form(text: "Cmd+Meta+W", standard: nil),
    Form(text: "+", standard: nil),
    Form(text: "++", standard: nil),
    Form(text: "Mod++", standard: nil),
    Form(text: "+A", standard: nil),
    Form(text: "F13", standard: nil),
    Form(text: "Hyper", standard: nil),
    Form(text: "ab", standard: nil),
    Form(text: "1a", standard: nil),
    Form(text: "?", standard: nil),
    Form(text: "é", standard: nil),
    Form(text: "ß", standard: nil),
    Form(text: "toString", standard: nil),
    Form(text: "constructor", standard: nil),
    Form(text: "__proto__", standard: nil),
]

@Suite("The forms of a binding")
struct BindingFormTests {
    @Test("a text has its standard form or is no binding", arguments: bindingForms)
    fileprivate func standardForm(_ form: Form) {
        #expect(Chord(form.text)?.description == form.standard)
        // The standard form is a fixed point.
        if let standard = form.standard { #expect(Chord(standard)?.description == standard) }
    }

    @Test("a binding has a key equivalent for the menu", arguments: bindingForms)
    fileprivate func keyEquivalent(_ form: Form) {
        guard let chord = Chord(form.text) else { return }
        #expect(!chord.keyEquivalent.isEmpty)
        #expect(chord.keyEquivalent == chord.keyEquivalent.lowercased())
    }
}

// MARK: - The reserved keys

@Suite("The reserved keys")
struct ReservedKeyTests {
    @Test(
        "macOS keeps its own shortcuts",
        arguments: [
            "Mod+Tab", "Mod+Space", "Control+Space", "Mod+Q", "Mod+H", "Mod+M", "Mod+Shift+Q",
            "Mod+Shift+/", "Mod+Shift+3", "Mod+Shift+4", "Mod+Shift+5", "Mod+Alt+Escape",
            "Mod+Control+Q",
        ])
    func macKeeps(_ binding: String) {
        #expect(BindingRefusal.reserved(chord(binding)) == .reservedByMac)
    }

    @Test(
        "a Bifrost menu keeps its shortcuts",
        arguments: [
            "Mod+A", "Mod+Z", "Mod+Shift+Z", "Mod+X", "Mod+C", "Mod+V", "Mod+Alt+H", "Mod+-",
            "Mod+=",
        ])
    func menuKeeps(_ binding: String) {
        #expect(BindingRefusal.reserved(chord(binding)) == .reservedByMenu)
    }

    @Test("each spelling of a reserved key gives the reason", arguments: reservedSpellings)
    func spellings(_ text: String) {
        #expect(BindingRefusal.reserved(chord(text)) != nil)
    }

    @Test(
        "other keys are free",
        arguments: ["Mod+N", "Mod+Shift+A", "Control+A", "A", "Tab", "Shift+Tab", "Space", "bad"])
    func free(_ binding: String) {
        #expect(Chord(binding).flatMap(BindingRefusal.reserved) == nil)
    }
}

// Aliases and orders of Mod+Tab and of Mod+A.
private let reservedSpellings: [String] = {
    var spellings: [String] = []
    for modifier in ["Mod", "Cmd", "Command", "Meta", "mod"] {
        for key in ["Tab", "A", "Space"] {
            spellings += ["\(modifier)+\(key)", "\(key)+\(modifier)"]
        }
    }
    return spellings
}()

// MARK: - A binding for a slot

// The result of a binding text for a stored slot ID.
private enum SlotResult: Sendable, Equatable {
    // The slot takes the key.
    case takes
    // The slot refuses the key.
    case refused(BindingRefusal)
    // The text is not a binding, or no slot has the ID. The settings edge drops the entry.
    case noBinding
}

private struct SlotCase: Sendable, CustomTestStringConvertible {
    let slot: String
    let binding: String
    let result: SlotResult
    var testDescription: String { "\(slot) takes \(binding.debugDescription)" }

    func result(_ keys: KeyMap) -> SlotResult {
        guard let slot = KeySlot(slot), let chord = Chord(binding) else { return .noBinding }
        do throws(BindingRefusal) {
            try keys.check(chord, for: slot)
            return .takes
        } catch {
            return .refused(error)
        }
    }
}

private let macKeeps = SlotResult.refused(.reservedByMac)
private let menuKeeps = SlotResult.refused(.reservedByMenu)
private let badKey = SlotResult.noBinding
private let holdForm = SlotResult.refused(.holdForm)
private let dictationForm = SlotResult.refused(.dictationForm)
private func conflict(_ slot: String) -> SlotResult {
    .refused(.conflict(with: keySlot(slot)))
}

private let defaultKeys = KeyMap.defaults
private let changedKeys = KeyMap(keyChanges([
    "event-log:mod": nil, "open:hold": "K", "dictation:hold": "O",
]))

private let slotCases: [SlotCase] = [
    // A key with Cmd, in the always group.
    SlotCase(slot: "new-session:mod", binding: "Mod+N", result: .takes),
    SlotCase(slot: "new-session:mod", binding: "cmd+y", result: .takes),
    SlotCase(slot: "new-session:mod", binding: "Control+K", result: .takes),
    SlotCase(slot: "new-session:mod", binding: "F5", result: .takes),
    SlotCase(slot: "new-session:mod", binding: "Mod+3", result: conflict("select-row.3:mod")),
    SlotCase(slot: "new-session:mod", binding: "Mod+Tab", result: macKeeps),
    SlotCase(slot: "new-session:mod", binding: "Mod+Q", result: macKeeps),
    SlotCase(slot: "new-session:mod", binding: "Mod+Z", result: menuKeeps),
    SlotCase(slot: "new-session:mod", binding: "Mod+=", result: menuKeeps),
    SlotCase(slot: "new-session:mod", binding: "F13", result: badKey),
    SlotCase(slot: "new-session:mod", binding: "Hyper+K", result: badKey),
    SlotCase(slot: "new-session:mod", binding: "", result: badKey),
    SlotCase(slot: "no-such-slot", binding: "Mod+N", result: badKey),
    // A menu slot needs Cmd. Its own key and a free Cmd key are good.
    SlotCase(slot: "close-panel:mod", binding: "Mod+W", result: .takes),
    SlotCase(slot: "close-panel:mod", binding: "Mod+Shift+W", result: .takes),
    SlotCase(
        slot: "close-panel:mod", binding: "Control+K",
        result: .refused(.menuNeedsCommand)),
    SlotCase(
        slot: "toggle-fullscreen:mod", binding: "F5",
        result: .refused(.menuNeedsCommand)),
    SlotCase(slot: "toggle-fullscreen:mod", binding: "Mod+Q", result: macKeeps),
    // A hold slot takes one letter or digit with no modifier. It shares a key with a single key.
    SlotCase(slot: "open:hold", binding: "O", result: .takes),
    SlotCase(slot: "open:hold", binding: "k", result: .takes),
    SlotCase(slot: "open:hold", binding: "5", result: conflict("set-priority.5:hold")),
    SlotCase(slot: "open:hold", binding: "M", result: conflict("send-message:hold")),
    SlotCase(slot: "open:hold", binding: "Shift+K", result: holdForm),
    SlotCase(slot: "open:hold", binding: "Mod+K", result: holdForm),
    SlotCase(slot: "open:hold", binding: "Control+K", result: holdForm),
    SlotCase(slot: "open:hold", binding: "Alt+K", result: holdForm),
    SlotCase(slot: "open:hold", binding: "Enter", result: holdForm),
    SlotCase(slot: "open:hold", binding: "Space", result: holdForm),
    SlotCase(slot: "open:hold", binding: "/", result: holdForm),
    SlotCase(slot: "open:hold", binding: "F5", result: holdForm),
    SlotCase(slot: "open:hold", binding: "bad", result: badKey),
    SlotCase(slot: "open:key", binding: "M", result: conflict("send-message:key")),
    SlotCase(slot: "open:key", binding: "Mod+Shift+Y", result: .takes),
    // A single slot and a hold slot can share a key, so a hold key conflicts only with a hold key.
    SlotCase(slot: "open:key", binding: "O", result: .takes),
    // The dictation slot takes Space, a letter, a digit or a symbol, with no modifier.
    SlotCase(slot: "dictation:hold", binding: "Space", result: .takes),
    SlotCase(slot: "dictation:hold", binding: "k", result: .takes),
    SlotCase(slot: "dictation:hold", binding: "/", result: .takes),
    SlotCase(slot: "dictation:hold", binding: "`", result: .takes),
    SlotCase(slot: "dictation:hold", binding: "O", result: .takes),
    SlotCase(slot: "dictation:hold", binding: "Shift+K", result: dictationForm),
    SlotCase(slot: "dictation:hold", binding: "Mod+Space", result: dictationForm),
    SlotCase(slot: "dictation:hold", binding: "Enter", result: dictationForm),
    SlotCase(slot: "dictation:hold", binding: "F5", result: dictationForm),
    SlotCase(slot: "dictation:hold", binding: "Tab", result: dictationForm),
]

private let changedSlotCases: [SlotCase] = [
    // The slot that lost its key does not conflict. A changed key conflicts at its new place.
    SlotCase(slot: "new-session:mod", binding: "Mod+N", result: .takes),
    SlotCase(slot: "open:hold", binding: "K", result: .takes),
    SlotCase(slot: "open-in-terminal:hold", binding: "K", result: conflict("open:hold")),
    SlotCase(slot: "send-message:hold", binding: "O", result: .takes),
    SlotCase(slot: "open:key", binding: "K", result: .takes),
    SlotCase(slot: "close-panel:mod", binding: "Mod+Shift+W", result: .takes),
    // The dictation key O is in its own class, so a hold key can use O too.
    SlotCase(slot: "interrupt:hold", binding: "O", result: .takes),
]

@Suite("A binding for a slot")
struct SlotBindingTests {
    @Test("the default map gives the expected result", arguments: slotCases)
    fileprivate func onDefaults(_ item: SlotCase) {
        #expect(item.result(defaultKeys) == item.result)
    }

    @Test("a map with changed keys gives the expected result", arguments: changedSlotCases)
    fileprivate func onChanged(_ item: SlotCase) {
        #expect(item.result(changedKeys) == item.result)
    }

    @Test("a slot may keep its own key", arguments: KeySlot.all.map(\.description))
    func ownKey(_ id: String) throws {
        let slot = keySlot(id)
        // Some default keys are reserved, but a slot has none of them.
        try defaultKeys.check(slot.defaultBinding, for: slot)
    }

    @Test(
        "each refusal has its text for the user",
        arguments: [
            (BindingRefusal.reservedByMac, LabelSet.plain, "macOS keeps this shortcut for itself."),
            (.reservedByMenu, .plain, "A Bifrost menu already uses this shortcut."),
            (.menuNeedsCommand, .plain, "A menu shortcut needs Cmd."),
            (
                .holdForm, .plain,
                "A hold key must be a single letter or number, without Cmd, Ctrl, Option or Shift."
            ),
            (
                .dictationForm, .plain,
                "For dictation, use Space, a letter, a number or a symbol, without Cmd, Ctrl, "
                    + "Option or Shift."
            ),
            (.conflict(with: keySlot("event-log:mod")), .plain, "Event log already uses this key."),
            (.conflict(with: keySlot("open:mod")), .space, "Warp to already uses this key."),
        ])
    func message(_ refusal: BindingRefusal, _ labels: LabelSet, _ text: String) {
        #expect(refusal.message(labels: labels) == text)
    }
}

// MARK: - The zones of a key

private struct ZoneCase: Sendable, CustomTestStringConvertible {
    let slot: String
    let binding: String
    let zones: Set<FocusZone>
    var testDescription: String {
        "\(binding) of \(slot) acts in \(zones.map { "\($0)" }.sorted())"
    }
}

private let allButModal: Set<FocusZone> = [.chat, .sendBox, .text, .control, .other]

private let zoneCases: [ZoneCase] = [
    // A key with Cmd acts everywhere except in a dialog, also in a chat window.
    ZoneCase(slot: "new-session:mod", binding: "Mod+N", zones: allButModal),
    ZoneCase(slot: "close-panel:mod", binding: "Mod+W", zones: allButModal),
    ZoneCase(slot: "open:key", binding: "Mod+Shift+O", zones: allButModal),
    // A key with Ctrl acts in every zone except a chat window.
    ZoneCase(
        slot: "new-session:mod", binding: "Control+K", zones: [.sendBox, .text, .control, .other]),
    // A plain key acts outside a text box, a send box and a chat window. Control keys stay with
    // a control. Escape and Backspace and letters act on a control too.
    ZoneCase(slot: "open:key", binding: "O", zones: [.control, .other]),
    ZoneCase(slot: "open:key", binding: "Alt+O", zones: [.control, .other]),
    ZoneCase(slot: "set-priority.1:key", binding: "1", zones: [.control, .other]),
    ZoneCase(slot: "stop:key", binding: "Backspace", zones: [.control, .other]),
    ZoneCase(slot: "delete:key", binding: "Shift+Backspace", zones: [.control, .other]),
    ZoneCase(slot: "open:key2", binding: "Enter", zones: [.other]),
    ZoneCase(slot: "next-overview-tab:key", binding: "Tab", zones: [.other]),
    ZoneCase(slot: "prev-overview-tab:key", binding: "Shift+Tab", zones: [.other]),
    ZoneCase(slot: "select-next:key", binding: "ArrowDown", zones: [.other]),
    ZoneCase(slot: "select-next:key", binding: "Shift+ArrowDown", zones: [.other]),
    ZoneCase(slot: "select-next:key", binding: "Home", zones: [.other]),
    ZoneCase(slot: "select-next:key", binding: "End", zones: [.other]),
    ZoneCase(slot: "select-next:key", binding: "Space", zones: [.other]),
    // The Escape slot also acts in the send box (it leaves the send box), and on a control.
    ZoneCase(slot: "escape:key", binding: "Escape", zones: [.control, .other, .sendBox]),
    // A hold key acts only in the other zone, with any binding text.
    ZoneCase(slot: "open:hold", binding: "O", zones: [.other]),
    ZoneCase(slot: "send-message:hold", binding: "Mod+N", zones: [.other]),
    ZoneCase(slot: "set-priority.3:hold", binding: "3", zones: [.other]),
    // The dictation key acts only in a chat window, with any binding text.
    ZoneCase(slot: "dictation:hold", binding: "Space", zones: [.chat]),
    ZoneCase(slot: "dictation:hold", binding: "Mod+N", zones: [.chat]),
    ZoneCase(slot: "dictation:hold", binding: "Escape", zones: [.chat]),
    // A text that is not a binding acts nowhere, except for a hold or a dictation slot.
    ZoneCase(slot: "new-session:mod", binding: "bad", zones: []),
    ZoneCase(slot: "open:key", binding: "bad", zones: []),
]

@Suite("The zones of a key")
struct KeyZoneTests {
    @Test("a binding acts in its zones and never in a dialog", arguments: zoneCases)
    fileprivate func zones(_ item: ZoneCase) {
        let slot = keySlot(item.slot)
        guard let chord = Chord(item.binding) else {
            // A text that is not a binding is no key, so it acts in no zone.
            #expect(item.zones.isEmpty)
            return
        }
        let actual = Set(FocusZone.allCases.filter { slot.acts(chord, in: $0) })
        #expect(actual == item.zones)
        #expect(!slot.acts(chord, in: .modal))
    }
}

// MARK: - The key map

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private struct StoredKeys: Sendable, CustomTestStringConvertible {
    let name: String
    let stored: String
    let kept: [String: String?]
    var testDescription: String { name }
}

private let storedKeys: [StoredKeys] = [
    StoredKeys(name: "an object that is not a map gives no change", stored: "[]", kept: [:]),
    StoredKeys(name: "null gives no change", stored: "null", kept: [:]),
    StoredKeys(name: "a text gives no change", stored: "\"x\"", kept: [:]),
    StoredKeys(name: "a number gives no change", stored: "5", kept: [:]),
    StoredKeys(name: "true gives no change", stored: "true", kept: [:]),
    StoredKeys(
        name: "a good key stays in its standard form", stored: #"{"open:mod":"cmd+k"}"#,
        kept: ["open:mod": "Mod+K"]),
    StoredKeys(
        name: "an unknown slot goes", stored: #"{"foo:mod":"Mod+J","open:mod":"cmd+k","x":5}"#,
        kept: ["open:mod": "Mod+K"]),
    StoredKeys(
        name: "a key that is null stays as no key", stored: #"{"dictation:hold":null}"#,
        kept: ["dictation:hold": nil]),
    StoredKeys(
        name: "a value of another type goes",
        stored:
            #"{"set-priority.2:mod":{"a":1},"stop:mod":5,"open:mod":true,"copy-id:mod":["Mod+K"]}"#,
        kept: [:]),
    StoredKeys(
        name: "a hold key with a modifier goes",
        stored: #"{"set-priority.4:hold":"Mod+Shift","delete:mod":"Mod+9","open:hold":"Shift+O"}"#,
        kept: ["delete:mod": "Mod+9"]),
    StoredKeys(
        name: "a reserved key goes", stored: #"{"close-panel:mod":"W","stop:mod":"Mod+Q"}"#,
        kept: [:]),
    StoredKeys(
        name: "a key that is not a binding goes",
        stored: #"{"select-row.9:mod":"Hyper+K","settings:mod":"Hyper+K","stop:mod":"?"}"#,
        kept: [:]),
    StoredKeys(
        name: "a dictation key with a modifier goes", stored: #"{"dictation:hold":"Shift+K"}"#,
        kept: [:]),
    StoredKeys(
        name: "a dictation key can be a symbol", stored: #"{"dictation:hold":"/"}"#,
        kept: ["dictation:hold": "/"]),
    StoredKeys(
        name: "a conflict of the file stays",
        stored: #"{"copy-id:mod":"Mod+N"}"#, kept: ["copy-id:mod": "Mod+N"]),
    StoredKeys(
        name: "a menu slot needs Cmd",
        stored: #"{"close-panel:mod":"W","toggle-fullscreen:mod":"Mod+Alt+F"}"#,
        kept: ["toggle-fullscreen:mod": "Mod+Alt+F"]),
    StoredKeys(
        name: "the prototype key is no slot",
        stored: #"{"__proto__":"Mod+K","open:mod":"Mod+K"}"#, kept: ["open:mod": "Mod+K"]),
]

private struct SetStep: Sendable, CustomTestStringConvertible {
    enum Operation: Sendable {
        case set(KeyBinding)
        case reset
    }
    let slot: KeySlot
    let operation: Operation
    let result: KeyChanges
    let same: Bool
    var testDescription: String { "\(slot) \(operation)" }
}

private func set(_ slot: String, _ binding: String?) -> (KeySlot, SetStep.Operation) {
    (keySlot(slot), .set(binding.map { .chord(chord($0)) } ?? .off))
}

@Suite("The key map")
struct KeyMapTests {
    @Test("stored keys are read", arguments: storedKeys)
    fileprivate func parse(_ item: StoredKeys) throws {
        let changes = KeyChanges(stored: try json(item.stored))
        #expect(changes == keyChanges(item.kept))
    }

    @Test("a missing value changes nothing")
    func missing() {
        #expect(KeyChanges(stored: nil).isEmpty)
    }

    // The changes go back to the stored form and give the same changes again: a null for Off,
    // the standard form of each key, and the entries of an unknown slot as they were.
    @Test("stored keys go back to their stored form", arguments: storedKeys)
    fileprivate func roundTrip(_ item: StoredKeys) throws {
        let raw = try json(item.stored)
        let changes = KeyChanges(stored: raw)
        let stored = changes.stored(keeping: raw)
        #expect(KeyChanges(stored: stored) == changes)
        #expect(stored.unknownEntries == raw.unknownEntries)
        #expect(changes.stored(keeping: stored) == stored)
        // With no change, the stored keys stay as they are.
        if case .object = raw { #expect(stored == raw) }
    }

    // A key that is the default key of its slot is no change, also in the stored keys.
    @Test func theDefaultKeyOfASlotIsNoChange() throws {
        let open = keySlot("open:mod")
        #expect(KeyChanges([open: .chord(open.defaultBinding)]).isEmpty)
        #expect(KeyChanges(stored: try json(#"{"open:mod":"cmd+enter"}"#)).isEmpty)
        #expect(KeyChanges([open: .chord(chord("Mod+K"))])[open] == .chord(chord("Mod+K")))
    }

    @Test
    func setAndReset() {
        let first = keySlot("set-priority.0:key")
        let row = keySlot("select-row.1:mod")
        let log = keySlot("event-log:mod")
        let steps: [SetStep] = [
            SetStep(
                slot: first, operation: .set(.chord(chord("Mod+Shift+R"))),
                result: keyChanges(["set-priority.0:key": "Mod+Shift+R"]), same: false),
            SetStep(
                slot: first, operation: .set(.chord(chord("cmd+shift+r"))),
                result: keyChanges(["set-priority.0:key": "Mod+Shift+R"]), same: true),
            SetStep(
                slot: row, operation: .set(.chord(chord("k"))),
                result: keyChanges(["set-priority.0:key": "Mod+Shift+R", "select-row.1:mod": "K"]),
                same: false),
            SetStep(
                slot: row, operation: .set(.chord(chord("Mod+1"))),
                result: keyChanges(["set-priority.0:key": "Mod+Shift+R"]), same: false),
            SetStep(
                slot: log, operation: .set(.off),
                result: keyChanges(["set-priority.0:key": "Mod+Shift+R", "event-log:mod": nil]),
                same: false),
            SetStep(
                slot: keySlot("stop:mod"), operation: .reset,
                result: keyChanges(["set-priority.0:key": "Mod+Shift+R", "event-log:mod": nil]),
                same: true),
            SetStep(
                slot: log, operation: .reset,
                result: keyChanges(["set-priority.0:key": "Mod+Shift+R"]), same: false),
        ]
        var changes = KeyChanges()
        for step in steps {
            let before = changes
            switch step.operation {
            case .set(let binding): changes.set(binding, for: step.slot)
            case .reset: changes.reset(step.slot)
            }
            #expect(changes == step.result, "\(step)")
            #expect((changes == before) == step.same, "\(step)")
        }
    }

    @Test("a change sets the effective key and null removes it")
    func effective() {
        let keys = KeyMap(keyChanges(["open:mod": "Mod+K", "stop:mod": nil]))
        #expect(keys[keySlot("open:mod")] == .chord(chord("Mod+K")))
        #expect(keys[keySlot("stop:mod")] == .off)
        let copy = keySlot("copy-id:mod")
        #expect(keys[copy] == .chord(copy.defaultBinding))
        #expect(KeySlot.all.allSatisfy { KeyMap.defaults[$0] == .chord($0.defaultBinding) })
    }

    @Test("the default keys have no conflict and each slot is active or a menu slot")
    func defaults() {
        #expect(KeyMap.defaults.conflicts.isEmpty)
        let active = KeyMap.defaults.activeBindings.map(\.slot)
        let menu = KeySlot.all.filter(\.isMenu)
        #expect(menu == [.closePanel, .toggleFullscreen])
        let rest = KeySlot.all.filter { !active.contains($0) && !menu.contains($0) }
        #expect(rest == [.dictation])
    }

    @Test("two slots of one class with one key conflict and the first keeps the key")
    func conflicts() {
        let keys = KeyMap(keyChanges(["select-row.4:mod": "Mod+ArrowUp"]))
        let pair = KeyConflict(
            first: keySlot("select-row.4:mod"), second: keySlot("select-prev:mod"))
        #expect(keys.conflicts == [pair])
        let active = keys.activeBindings.filter { $0.chord == chord("Mod+ArrowUp") }
        #expect(active.map(\.slot) == [keySlot("select-row.4:mod")])
        #expect(!keys.activeBindings.contains { $0.slot == keySlot("select-prev:mod") })
    }

    @Test("a hold key and a single key may share one key")
    func classes() {
        let keys = KeyMap(keyChanges(["open:key": "O"]))
        #expect(keys.conflicts.isEmpty)
        let both = keys.activeBindings.filter { $0.chord == chord("O") }.map(\.slot)
        #expect(both == [keySlot("open:key"), keySlot("open:hold")])
    }

    @Test
    func menuKeepsKey() {
        let keys = KeyMap(keyChanges(["stop:mod": "Mod+W"]))
        #expect(keys.conflicts == [KeyConflict(first: .closePanel, second: keySlot("stop:mod"))])
        #expect(!keys.activeBindings.contains { $0.chord == chord("Mod+W") })
        #expect(keys[.closePanel] == .chord(chord("Mod+W")))
    }

    @Test("a slot with no key is in no list")
    func noKey() {
        let keys = KeyMap(keyChanges(["event-log:mod": nil, "close-panel:mod": nil]))
        #expect(!keys.activeBindings.contains { $0.slot == keySlot("event-log:mod") })
        #expect(keys[.closePanel] == .off)
        #expect(keys[.toggleFullscreen] == .chord(chord("Mod+Control+F")))
    }
}

extension JSONValue {
    // The entries of an object whose key names no slot.
    fileprivate var unknownEntries: [String: JSONValue] {
        guard case .object(let object) = self else { return [:] }
        return object.filter { KeySlot($0.key) == nil }
    }
}

// MARK: - The slots and the labels

@Suite("The slots and the labels")
struct SlotTableTests {
    @Test("the slots keep their number, order and IDs")
    func slots() {
        let all = KeySlot.all
        #expect(all.count == 84)
        #expect(Set(all.map(\.description)).count == 84)
        #expect(all.first?.description == "new-session:mod")
        #expect(all.last == .dictation)
        #expect(all.filter(\.isMenu) == [.closePanel, .toggleFullscreen])
        #expect(
            all.filter { $0.group == .hold }.map(\.defaultBinding.description) == [
                "O", "M", "I", "J", "X", "1", "2", "3", "4", "5",
            ])
        #expect(all.filter { $0.group == .dictation }.map(\.defaultBinding) == [chord("Space")])
        #expect(all.filter { $0.group == .single }.count == 24)
        #expect(all.filter { $0.group == .always }.count == 49)
    }

    @Test(
        "each slot has its stored ID and each default key is a standard binding",
        arguments: KeySlot.all)
    func defaultKey(_ slot: KeySlot) {
        #expect(KeySlot(slot.description) == slot)
        #expect(Chord(slot.defaultBinding.description) == slot.defaultBinding)
    }

    @Test(
        "a slot has a label for a plain app and for a space app",
        arguments: [
            ("new-session:mod", "New session", "Launch"),
            ("select-row.1:mod", "Select row 1", "Select row 1"),
            ("select-prev:mod", "Select the previous row", "Select the previous row"),
            ("focus-overview:mod", "Move focus to the Overview", "Move focus to the Overview"),
            ("open:mod", "Open", "Warp to"),
            ("send-message:mod", "Send message", "Hail"),
            ("run-slash:mod", "Run slash command", "Activate module"),
            ("interrupt:mod", "Interrupt", "Full stop"),
            ("show-info:mod", "Show Info", "Scan"),
            ("copy-id:mod", "Copy session ID", "Copy transponder ID"),
            (
                "open-project:mod", "Open project in the default app",
                "Open cargo hold in the default app"
            ),
            ("open-in-terminal:mod", "Open in terminal", "Jump to terminal"),
            ("take-control:mod", "Take control", "Commandeer"),
            ("resume:mod", "Resume", "Reactivate"),
            ("resume-all:mod", "Resume all", "Reactivate all"),
            ("set-priority.1:mod", "Set priority 1", "Set threat level 1"),
            ("set-priority.0:mod", "Clear the priority", "Clear the priority"),
            ("set-priority.0:key", "Clear the priority", "Clear the priority"),
            ("stop:mod", "Stop session", "Power down"),
            ("delete:mod", "Delete session", "Self-destruct"),
            ("load-layout.1:mod", "Load layout 1", "Load layout 1"),
            ("save-layout:mod", "Save the layout", "Save the layout"),
            ("toggle-fullscreen:mod", "Toggle Fullscreen", "Toggle Fullscreen"),
            ("rename:key", "Rename", "Set callsign"),
            (
                "escape:key", "Open or close Settings, or leave the send box",
                "Open or close Settings, or leave the send box"
            ),
            ("dictation:hold", "Dictation key", "Dictation key"),
        ])
    func labels(_ id: String, _ plain: String, _ space: String) {
        let slot = keySlot(id)
        #expect(slot.label(.plain) == plain)
        #expect(slot.label(.space) == space)
    }

    @Test(
        "each group has a title",
        arguments: [
            (SlotGroup.always, "Shortcuts that work at all times"),
            (.single, "Single keys (not in a chat window or a text box)"),
            (.hold, "Hold a key and click a row"),
            (.dictation, "Hold to dictate in a chat window"),
        ])
    func titles(_ group: SlotGroup, _ title: String) {
        #expect(group.title == title)
    }
}

// MARK: - The match of an event

private struct MatchCase: Sendable, CustomTestStringConvertible {
    // The typed text. An empty text is a dead key. A named key and a modifier key have no text.
    let text: String
    let code: KeyCode
    let mods: String
    let binding: String
    // 0 for no match, else the score: 3 direct, 2 with an implicit Shift, 1 by position.
    let score: Int

    // The score of the event for the binding, 0 for no match. A text that is not a binding never
    // matches.
    var actual: Int {
        Chord(binding).flatMap { $0.match(event) }?.rawValue ?? 0
    }
    var isComposing = false

    var event: KeyEvent {
        let mods = Mods(
            shift: mods.contains("S"), alt: mods.contains("A"), ctrl: mods.contains("C"),
            meta: mods.contains("M"), isComposing: isComposing)
        return KeyEvent(
            keyCode: code, characters: text, modifiers: mods.modifiers,
            isComposing: mods.isComposing)
    }

    var testDescription: String {
        let flags = mods.isEmpty ? "" : " with \(mods)"
        let typed = text.isEmpty ? "no text" : text.debugDescription
        return "\(typed) on key \(code.rawValue)\(flags) and \(binding): \(score)"
    }
}

private func hit(
    _ text: String, _ code: KeyCode?, _ mods: String, _ binding: String, _ score: Int
) -> MatchCase {
    guard let code else { preconditionFailure("no US key for \(text)") }
    return MatchCase(text: text, code: code, mods: mods, binding: binding, score: score)
}

// The key of a US keyboard that types this character.
private func us(_ character: Character) -> KeyCode? {
    KeyCode(us: character)
}

// Keys with no US character: the 5 and the Enter key of the keypad, and the key left of 1 on an
// ISO keyboard (it types "§").
private let keypad5 = KeyCode(rawValue: 87)
private let keypadEnter = KeyCode(rawValue: 76)
private let section = KeyCode(rawValue: 10)

private let matchCases: [MatchCase] = [
    // A letter that the key types matches by name: score 3, in either case.
    hit("c", us("C"), "", "C", 3), hit("c", us("C"), "C", "Control+C", 3),
    hit("c", us("C"), "M", "Mod+C", 3), hit("C", us("C"), "SM", "Mod+Shift+C", 3),
    hit("O", us("O"), "S", "Shift+O", 3), hit("f", us("F"), "CM", "Mod+Control+F", 3),
    hit("N", us("N"), "M", "Mod+N", 3),
    // The modifiers must be equal. No modifier is extra, and none is missing.
    hit("c", us("C"), "", "Mod+C", 0), hit("c", us("C"), "M", "C", 0),
    hit("c", us("C"), "CM", "Control+C", 0), hit("C", us("C"), "S", "C", 0),
    hit("c", us("C"), "A", "C", 0), hit("a", us("A"), "", "Mod+A", 0),
    // Option changes the letter, so the position gives score 1.
    hit("ø", us("O"), "A", "Alt+O", 1), hit("Ø", us("O"), "SA", "Alt+Shift+O", 1),
    hit("ß", us("S"), "AM", "Mod+Alt+S", 1), hit("Í", us("S"), "SAM", "Mod+Alt+Shift+S", 1),
    // Option+0 types "º", a letter of another script. It does not match Option+O (accepted).
    hit("º", us("0"), "A", "Alt+O", 0), hit("º", us("0"), "SA", "Alt+Shift+O", 0),
    hit("º", us("0"), "A", "Alt+0", 1),
    // Digits match by name with score 2: the key is not a letter, so Shift may be implicit.
    hit("1", us("1"), "", "1", 2), hit("1", us("1"), "M", "Mod+1", 2),
    hit("1", us("1"), "CM", "Mod+Control+1", 2), hit("0", us("0"), "M", "Mod+0", 2),
    // A shifted digit matches by position (score 1).
    hit("!", us("1"), "S", "Shift+1", 1), hit("!", us("1"), "SM", "Mod+Shift+1", 1),
    hit("¡", us("1"), "AM", "Mod+Alt+1", 1), hit("£", us("3"), "AM", "Mod+Alt+3", 1),
    hit("!", us("1"), "S", "1", 0), hit("!", us("1"), "", "Shift+1", 0),
    // A symbol with Shift: the key is the symbol, so Shift is implicit, and the name matches.
    hit("/", us("/"), "", "/", 2), hit("/", us("/"), "M", "Mod+/", 2),
    hit("/", us("/"), "C", "Control+/", 2), hit("?", us("/"), "S", "Shift+/", 1),
    hit("?", us("/"), "SM", "Mod+Shift+/", 1), hit("+", us("="), "SM", "Mod+Shift+=", 1),
    hit("=", us("="), "M", "Mod+=", 2), hit("[", us("["), "M", "Mod+[", 2),
    hit("`", us("`"), "M", "Mod+`", 2), hit(",", us(","), "M", "Mod+,", 2),
    // A dead key (no text) always falls back to the position, also on a letter key.
    hit("", us("`"), "M", "Mod+`", 1), hit("", us("E"), "AM", "Mod+Alt+E", 1),
    hit("", us("E"), "A", "Alt+E", 1), hit("", us("E"), "A", "Alt+O", 0),
    // A layout with symbols on the digit row: the position gives the digit.
    hit("&", us("1"), "M", "Mod+1", 1), hit("é", us("2"), "M", "Mod+2", 1),
    hit("ü", us("["), "M", "Mod+[", 1),
    // A letter of another script matches by position (score 1). A Latin letter with an accent
    // does not, because the user can type the name of that key.
    hit("ы", us("S"), "M", "Mod+S", 1), hit("ñ", us("N"), "M", "Mod+N", 0),
    hit("ö", us("O"), "M", "Mod+O", 0), hit("a", us("Q"), "M", "Mod+Q", 0),
    hit("+", us("/"), "M", "Mod+/", 0), hit("§", section, "M", "Mod+/", 0),
    // The dotless Turkish i matches I with score 2, and not with Alt.
    hit("ı", us("I"), "", "I", 2), hit("ı", us("I"), "M", "Mod+I", 2),
    // The key pad keys.
    hit("5", keypad5, "", "5", 2), hit("", keypadEnter, "M", "Mod+Enter", 3),
    // Named keys match by name with score 3. Shift is part of the chord.
    hit("", KeyCode(.enter), "", "Enter", 3), hit("", KeyCode(.enter), "M", "Mod+Enter", 3),
    hit("", KeyCode(.enter), "S", "Enter", 0), hit("", KeyCode(.escape), "", "Escape", 3),
    hit("", KeyCode(.tab), "", "Tab", 3), hit("", KeyCode(.tab), "S", "Shift+Tab", 3),
    hit("", KeyCode(.tab), "S", "Tab", 0), hit(" ", KeyCode(.space), "", "Space", 3),
    hit(" ", KeyCode(.space), "S", "Shift+Space", 3), hit(" ", KeyCode(.space), "M", "Space", 0),
    hit("", KeyCode(.arrowUp), "M", "Mod+ArrowUp", 3),
    hit("", KeyCode(.arrowDown), "", "ArrowDown", 3),
    hit("", KeyCode(.backspace), "S", "Shift+Backspace", 3),
    hit("", KeyCode(.backspace), "SM", "Mod+Shift+Backspace", 3),
    hit("", KeyCode(.backspace), "SAM", "Mod+Alt+Shift+Backspace", 3),
    hit("", KeyCode(.delete), "", "Delete", 3), hit("", KeyCode(.f5), "", "F5", 3),
    hit("", KeyCode(.f12), "M", "Mod+F12", 3), hit("", KeyCode(.f5), "S", "F5", 0),
    // A modifier key alone matches no binding.
    hit("", KeyCode(.shift), "S", "Shift+Tab", 0), hit("", KeyCode(.command), "M", "Mod+N", 0),
    // A text that is not a binding never matches.
    hit("a", us("A"), "", "bad", 0), hit("a", us("A"), "", "", 0),
]

@Suite("The match of an event")
struct MatchTableTests {
    @Test("an event scores each binding", arguments: matchCases)
    fileprivate func score(_ item: MatchCase) {
        #expect(item.actual == item.score)
    }

    @Test("an event of a composition matches nothing")
    func composing() {
        var shown = hit("n", us("N"), "M", "Mod+N", 0)
        #expect(shown.actual == 3)
        shown.isComposing = true
        #expect(shown.actual == 0)
        var enter = hit("", KeyCode(.enter), "", "Enter", 0)
        enter.isComposing = true
        #expect(enter.actual == 0)
    }
}

// MARK: - The release of a hold key

private struct ReleaseCase: Sendable, CustomTestStringConvertible {
    // The typed text, and the key. A modifier key has no text.
    let text: String
    let code: KeyCode
    let mods: String
    let hold: Set<Character>
    let released: Character?
    var testDescription: String {
        let typed = text.isEmpty ? "key \(code.rawValue)" : text.debugDescription
        return "\(typed) with \(mods.isEmpty ? "no modifier" : mods) in \(hold.sorted())"
    }

    func event(_ edge: Edge) -> KeyEvent {
        let mods = Mods(
            shift: mods.contains("S"), alt: mods.contains("A"), ctrl: mods.contains("C"),
            meta: mods.contains("M"))
        return KeyEvent(
            keyCode: code, characters: text, modifiers: mods.modifiers, isDown: edge == .keydown)
    }
}

private func release(
    _ text: String, _ code: KeyCode?, _ mods: String, _ hold: Set<Character>,
    _ released: Character?
) -> ReleaseCase {
    guard let code else { preconditionFailure("no US key for \(text)") }
    return ReleaseCase(text: text, code: code, mods: mods, hold: hold, released: released)
}

private let releaseCases: [ReleaseCase] = [
    // The key up of a hold key with a modifier gives the key. The typed text or the place of the
    // key names it.
    release("O", us("O"), "S", ["O", "1"], "O"), release("o", us("O"), "M", ["O", "1"], "O"),
    release("o", us("O"), "C", ["O", "1"], "O"), release("ø", us("O"), "A", ["O", "1"], "O"),
    release("Ø", us("O"), "SA", ["O", "X"], "O"), release("ø", us("O"), "AM", ["O", "X"], "O"),
    release("!", us("1"), "S", ["O", "1"], "1"), release("1", us("1"), "M", ["O", "1"], "1"),
    release("X", us("X"), "S", ["O", "X"], "X"),
    // A dead key gives the key of its place. The text "1" of the keypad gives the key 1.
    release("", us("O"), "A", ["O", "1"], "O"), release("1", keypad1, "S", ["1"], "1"),
    // No modifier: the registration of the plain key takes the event.
    release("o", us("O"), "", ["O", "1"], nil), release("1", us("1"), "", ["O", "1"], nil),
    // A key that is not a hold key.
    release("P", us("P"), "S", ["O", "1"], nil), release("@", us("2"), "S", ["O", "1"], nil),
    release("o", us("O"), "M", ["K"], nil), release("ø", us("O"), "A", ["K"], nil),
    // A key with no letter or digit has no hold key: a named key, a modifier key, and a keypad
    // key with no digit text (the keypad is not the digit row).
    release("", KeyCode(.enter), "S", ["O", "1"], nil), release("", keypad1, "S", ["1"], nil),
    release("", KeyCode(.shift), "S", ["O", "1"], nil),
    release("", KeyCode(.shift), "", ["O", "1"], nil),
]

private let keypad1 = KeyCode(rawValue: 83)

// The hold key of a letter or a digit.
private func holdChord(_ key: Character) -> Chord {
    Chord(key: .character(key))
}

@Suite("The release of a hold key")
struct ReleaseTableTests {
    @Test("a key up with a modifier gives the hold key", arguments: releaseCases)
    fileprivate func release(_ item: ReleaseCase) {
        let holdKeys = Set(item.hold.map(holdChord))
        let change = GateChange(item.event(.keyup), holdKeys: holdKeys)
        #expect(change == item.released.map { GateChange.up(holdChord($0)) })
        // A key down never changes the gate, except a Cmd key.
        #expect(GateChange(item.event(.keydown), holdKeys: holdKeys) == nil)
    }

    @Test(
        "a Cmd key clears the gate, on the left and on the right", arguments: [55, 54] as [UInt16])
    func cmdClears(_ code: UInt16) {
        for isDown in [true, false] {
            let event = KeyEvent(
                keyCode: KeyCode(rawValue: code), modifiers: isDown ? .command : [],
                isDown: isDown)
            #expect(GateChange(event, holdKeys: [holdChord("O")]) == .clear)
        }
    }
}

// MARK: - The text rules of the chat

@Suite("The text rules of the chat")
struct ChatTextTests {
    @Test("the new line text is ESC and a carriage return")
    func newLine() {
        #expect(KeyRoute.newLineText == "\(esc)\r")
    }

    // Only Shift+Enter has an override. Another key, or another modifier with Enter, has none.
    // The key down gives the new line text, and the key up gives an empty text (no input).
    @Test("a key can override another key", arguments: overrideCases)
    func override(_ key: String, _ mods: String, _ edge: Edge, _ text: String?) {
        let mods = Mods(
            shift: mods.contains("S"), alt: mods.contains("A"), ctrl: mods.contains("C"),
            meta: mods.contains("M"))
        let route: KeyRoute = text.map { $0.isEmpty ? .swallow : .send($0) } ?? .terminal
        #expect(KeyRoute(ev(edge, key, mods)) == route)
    }

    @Test("the Enter key of the keypad is Enter")
    func keypadEnter() {
        let enter = KeyEvent(keyCode: KeyCode(rawValue: 76), modifiers: .shift)
        #expect(KeyRoute(enter) == .send(KeyRoute.newLineText))
    }
}

private let overrideCases: [(String, String, Edge, String?)] = [
    ("Enter", "S", .keydown, "\(esc)\r"), ("Enter", "S", .keyup, ""),
    ("Enter", "", .keydown, nil), ("Enter", "A", .keydown, nil),
    ("Enter", "C", .keydown, nil), ("Enter", "M", .keydown, nil),
    ("Enter", "SM", .keydown, nil), ("Enter", "SC", .keydown, nil),
    ("Enter", "SA", .keydown, nil), ("Enter", "SAM", .keyup, nil),
    ("a", "S", .keydown, nil), ("a", "", .keydown, nil), ("Escape", "S", .keydown, nil),
    ("Escape", "", .keyup, nil),
]

// MARK: - The focus

private struct FocusCase: Sendable, CustomTestStringConvertible {
    let name: String
    let target: FocusTarget
    let zone: FocusZone
    // The change for a selected row S2 and the rows S1 and S2.
    let change: FocusChange
    var testDescription: String { name }
}

private let noChange = FocusChange(select: nil, clearGate: false)

private func focusCase(
    _ name: String, _ target: FocusTarget, _ zone: FocusZone, select: String? = nil,
    clearGate: Bool = false
) -> FocusCase {
    FocusCase(
        name: name, target: target, zone: zone,
        change: FocusChange(select: select, clearGate: clearGate))
}

private let focusCases: [FocusCase] = [
    focusCase("a text view", FocusTarget(kind: .text), .text),
    focusCase("a control", FocusTarget(kind: .control), .control),
    focusCase("another view", FocusTarget(kind: .other), .other),
    focusCase(
        "the send box wins over a text view", FocusTarget(kind: .text, inSendBox: true), .sendBox),
    focusCase("a dialog wins over a text view", FocusTarget(kind: .text, inModal: true), .modal),
    focusCase(
        "the key recorder is a dialog and clears the gate",
        FocusTarget(kind: .text, inKeyRecorder: true), .modal, clearGate: true),
    focusCase(
        "a chat window wins over the send box",
        FocusTarget(kind: .text, chatSession: "S9", inSendBox: true), .chat),
    focusCase(
        "a chat window of a known row selects the row",
        FocusTarget(kind: .text, chatSession: "S1"), .chat, select: "S1"),
    focusCase(
        "a chat window of the selected row selects nothing",
        FocusTarget(kind: .control, chatSession: "S2"), .chat),
    focusCase(
        "a chat window with an empty session is a chat zone only",
        FocusTarget(kind: .other, chatSession: ""), .chat),
    focusCase(
        "a dialog in a chat window still selects its row",
        FocusTarget(kind: .text, inModal: true, chatSession: "S1"), .modal, select: "S1"),
    focusCase(
        "the recorder in a chat window selects and clears",
        FocusTarget(kind: .other, inKeyRecorder: true, chatSession: "S1"), .modal, select: "S1",
        clearGate: true),
    focusCase(
        "rows of an Overview", FocusTarget(kind: .other, overviewRows: "overview:12"), .other),
    focusCase(
        "rows of an Overview with a text view",
        FocusTarget(kind: .text, overviewRows: "overview:1"), .text),
]

private struct EscapeCase: Sendable, CustomTestStringConvertible {
    let zone: FocusZone
    let handled: Bool
    let isRepeat: Bool
    let onTop: Bool
    let intent: EscapeIntent
    var testDescription: String {
        "\(zone), handled \(handled), repeat \(isRepeat), Settings on top \(onTop)"
    }
}

private let escapeCases: [EscapeCase] = {
    var cases: [EscapeCase] = []
    for zone in FocusZone.allCases {
        for handled in [false, true] {
            for isRepeat in [false, true] {
                for onTop in [false, true] {
                    let intent: EscapeIntent
                    if zone == .sendBox {
                        intent = .leaveSendBox
                    } else if handled || isRepeat || (zone != .other && zone != .control) {
                        intent = .none
                    } else {
                        intent = onTop ? .closeSettings : .openSettings
                    }
                    cases.append(
                        EscapeCase(
                            zone: zone, handled: handled, isRepeat: isRepeat, onTop: onTop,
                            intent: intent))
                }
            }
        }
    }
    return cases
}()

@Suite("The focus")
struct FocusTableTests {
    @Test("a target gives its zone and its change", arguments: focusCases)
    fileprivate func focus(_ item: FocusCase) {
        #expect(FocusZone(item.target) == item.zone)
        #expect(FocusChange(item.target, selectedId: "S2", rows: ["S1", "S2"]) == item.change)
    }

    @Test("no focus is the other zone with no change")
    func nothing() {
        #expect(FocusZone(nil) == .other)
        #expect(FocusChange(nil, selectedId: "S2", rows: ["S1", "S2"]) == noChange)
    }

    @Test("a session that is not a row selects nothing and a missing selection selects it")
    func selection() {
        let unknown = FocusTarget(kind: .text, chatSession: "S9")
        #expect(FocusChange(unknown, selectedId: nil, rows: ["S1", "S2"]) == noChange)
        let known = FocusTarget(kind: .text, chatSession: "S1")
        #expect(
            FocusChange(known, selectedId: nil, rows: ["S1", "S2"])
                == FocusChange(select: "S1", clearGate: false))
    }

    @Test("the Esc key gives its intent", arguments: escapeCases)
    fileprivate func escape(_ item: EscapeCase) {
        let intent = EscapeIntent(
            zone: item.zone, escapeHandled: item.handled, isRepeat: item.isRepeat,
            settingsOnTop: item.onTop)
        #expect(intent == item.intent)
    }
}
