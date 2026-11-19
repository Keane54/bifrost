// The key editor of Settings > Keys (docs/behaviour/keys.md, "Changing a key"): the rows of the
// key list, the check of a recorded key, the key edit and Reset all keys.
import BifrostTestSupport
import Testing

@testable import BifrostFoundation
@testable import BifrostKeyboard

// The key event of a key code, with its text and modifiers.
private func event(
    _ code: UInt16, _ text: String, _ modifiers: KeyEvent.Modifiers = []
) -> KeyEvent {
    KeyEvent(keyCode: KeyCode(rawValue: code), characters: text, modifiers: modifiers)
}

// The key event of a binding on a US keyboard: the key at its place, with the modifiers.
private func event(_ binding: String) -> KeyEvent {
    let parsed = chord(binding)
    switch parsed.key {
    case .named(let name):
        return KeyEvent(
            keyCode: KeyCode(name), characters: name == .space ? " " : "",
            modifiers: parsed.modifiers)
    case .character(let character):
        let code = KeyCode(us: character) ?? KeyCode(.space)
        return KeyEvent(
            keyCode: code, characters: String(character).lowercased(),
            modifiers: parsed.modifiers)
    }
}

// The result of the check of a recorded binding for a slot, as the binding text or the refusal.
private func recorded(
    _ slotId: String, _ binding: String, _ keys: KeyMap = .defaults
) -> Result<String, RecordRefusal> {
    KeyEditor.checkRecorded(event(binding), slot: keySlot(slotId), old: keys).map(\.text)
}

// The refusal of a key edit, or nil when the edit is good.
private func editRefusal(_ patch: JSONValue, old: JSONValue? = nil) -> KeyEditRefusal? {
    do throws(KeyEditRefusal) {
        _ = try KeyEdit(patch: patch, old: old)
        return nil
    } catch {
        return error
    }
}

@Suite("the key editor")
struct KeyEditorTests {
    @Test func theGroupsAreInOrderWithTheDictationGroupLast() {
        let groups = KeyEditor.groups(KeyChanges(), .plain)
        #expect(groups.map(\.group) == [.always, .single, .hold, .dictation])
        #expect(groups.map(\.rows.count) == [49, 24, 10, 1])
        #expect(groups.map(\.title) == SlotGroup.allCases.map(\.title))
        let first = groups[0].rows[0]
        #expect(first.slot == keySlot("new-session:mod"))
        #expect(first.label == "New session")
        #expect(first.binding == .chord(chord("Mod+N")))
        #expect(!first.changed)
        // The rows keep the slot order.
        #expect(groups.flatMap(\.rows).map(\.slot) == KeySlot.all)
        let dictation = groups[3]
        #expect(dictation.title == "Hold to dictate in a chat window")
        #expect(dictation.rows.map(\.label) == ["Dictation key"])
        #expect(dictation.rows.map(\.binding) == [.chord(chord("Space"))])
    }

    // A changed slot is marked, and Off shows as no key. Only the changed slot is marked.
    @Test func aChangedRowIsMarkedAndOffIsNoKey() {
        let rows = KeyEditor.groups(keyChanges(["copy-id:key": nil]), .plain).flatMap(\.rows)
        let row = rows.first { $0.slot == keySlot("copy-id:key") }
        #expect(row?.binding == .off)
        #expect(row?.changed == true)
        #expect(rows.filter(\.changed).count == 1)
        let off = KeyEditor.groups(keyChanges(["dictation:hold": nil]), .plain)
        #expect(off.last?.rows.first?.binding == .off)
    }

    @Test func aRowShowsTheChangedKeyAndTheLabelOfTheLabelSet() {
        let rows = KeyEditor.groups(keyChanges(["open:mod": "Mod+K"]), .space).flatMap(\.rows)
        let open = rows.first { $0.slot == keySlot("open:mod") }
        #expect(open?.binding == .chord(chord("Mod+K")))
        #expect(open?.changed == true)
        #expect(rows.first { $0.slot == keySlot("take-control:mod") }?.label == "Commandeer")
    }

    // The key list shows a key as the macOS menus do: the modifier symbols in the order Control,
    // Option, Shift, Cmd, then the key, each part apart. The search finds a key by this form.
    @Test(
        arguments: [
            ("Mod+Shift+T", "⇧ ⌘ T"), ("Mod+Control+F", "⌃ ⌘ F"), ("Mod+ArrowUp", "⌘ ↑"),
            ("Mod+Alt+Shift+Control+K", "⌃ ⌥ ⇧ ⌘ K"), ("ArrowDown", "↓"), ("ArrowLeft", "←"),
            ("ArrowRight", "→"), ("Mod+Enter", "⌘ ↵"), ("Alt+Escape", "⌥ Esc"),
            ("Shift+Backspace", "⇧ ⌫"), ("Delete", "⌦"), ("Shift+Tab", "⇧ ⇥"), ("Space", "␣"),
            ("Mod+PageDown", "⌘ PageDown"), ("Home", "Home"), ("F5", "F5"), ("Shift+/", "⇧ /"),
            ("Mod+1", "⌘ 1"),
        ])
    func aKeyShowsInTheFormOfTheMenus(_ binding: String, _ shown: String) {
        #expect(chord(binding).shown == shown)
    }

    // A key with no conflict gives its chord.
    @Test func aFreeKeyGivesItsChord() {
        #expect(recorded("open:mod", "Mod+K") == .success("Mod+K"))
        // Option+O types ø, and the chord has the key at its place.
        let option = KeyEditor.checkRecorded(
            event(31, "ø", .option), slot: keySlot("open:key"), old: .defaults)
        #expect(option.map(\.text) == .success("Alt+O"))
        #expect(recorded("close-panel:mod", "Mod+Shift+W") == .success("Mod+Shift+W"))
        // The slot can take its own key again.
        #expect(recorded("open:mod", "Mod+Enter") == .success("Mod+Enter"))
    }

    // A conflict names the other slot.
    @Test func aConflictNamesTheOtherSlot() {
        let eventLog = RecordRefusal.binding(.conflict(with: keySlot("event-log:mod")))
        #expect(recorded("open:mod", "Mod+L") == .failure(eventLog))
    }

    // The recorded key is the key that the layout types, when the key rules read it so. The
    // dictation slot gets the US key at the place of the key, because the chat input reads the
    // dictation key by its place.
    @Test func aRecordedKeyIsTheKeyThatTheLayoutTypes() {
        func check(_ event: KeyEvent, _ slotId: String) -> Result<String, RecordRefusal> {
            KeyEditor.checkRecorded(event, slot: keySlot(slotId), old: .defaults).map(\.text)
        }
        // QWERTZ: the key labelled Y is at the place of the US Z.
        let shiftY = KeyEvent(
            keyCode: KeyCode(rawValue: 6), characters: "Y", modifiers: [.command, .shift])
        #expect(check(shiftY, "open:mod") == .success("Mod+Shift+Y"))
        let undo = KeyEvent(keyCode: KeyCode(rawValue: 16), characters: "z", modifiers: .command)
        #expect(check(undo, "open:mod") == .failure(.binding(.reservedByMenu)))
        // AZERTY: Cmd+A is Select All, at the place of the US Q.
        let selectAll = event(12, "a", .command)
        #expect(check(selectAll, "open:mod") == .failure(.binding(.reservedByMenu)))
        #expect(check(event(12, "a"), "open:key") == .success("A"))
        #expect(check(event(12, "a"), "dictation:hold") == .success("Q"))
        // QWERTZ Ö: the key rules read no binding for it with no modifier, but it can be the
        // dictation key.
        #expect(check(event(41, "ö"), "open:key") == .failure(.cannotRead))
        #expect(check(event(41, "ö"), "dictation:hold") == .success(";"))
    }

    // The check reads the old keys: a changed slot has its new key, not its default.
    @Test func theCheckSeesTheChangedKeyOfAnotherSlot() {
        let keys = KeyMap(keyChanges(["event-log:mod": "Mod+K"]))
        #expect(recorded("open:mod", "Mod+L", keys) == .success("Mod+L"))
        #expect(
            recorded("open:mod", "Mod+K", keys)
                == .failure(.binding(.conflict(with: keySlot("event-log:mod")))))
    }

    // The checks of the key map give their refusals.
    @Test func theKeyMapChecksGiveTheirRefusals() {
        #expect(recorded("open:mod", "Mod+Q") == .failure(.binding(.reservedByMac)))
        #expect(recorded("open:mod", "Mod+C") == .failure(.binding(.reservedByMenu)))
        #expect(recorded("open:hold", "Shift+O") == .failure(.binding(.holdForm)))
        #expect(recorded("close-panel:mod", "Shift+W") == .failure(.binding(.menuNeedsCommand)))
        #expect(recorded("dictation:hold", "K") == .success("K"))
        #expect(recorded("dictation:hold", "Shift+Space") == .failure(.binding(.dictationForm)))
        #expect(recorded("dictation:hold", "Mod+Space") == .failure(.binding(.dictationForm)))
    }

    // Only the dictation key can be Space. Each other slot refuses a key on the space bar.
    @Test func onlyTheDictationKeyCanBeSpace() {
        let free = KeyMap(keyChanges(["dictation:hold": nil]))
        #expect(recorded("dictation:hold", "Space", free) == .success("Space"))
        for slot in ["open:hold", "copy-id:key", "open:mod", "escape:key"] {
            for binding in ["Space", "Shift+Space", "Alt+Space", "Mod+Shift+Space"] {
                #expect(recorded(slot, binding) == .failure(.space), "\(slot) \(binding)")
            }
        }
    }

    // A keypad digit, F13 and the key left of 1 on an ISO keyboard have no chord. A dead key
    // (Option+E) types a character after the next key.
    @Test func aKeyThatCannotBeAChordIsRefused() {
        for code in [83, 105, 10] as [UInt16] {
            let result = KeyEditor.checkRecorded(
                event(code, "1"), slot: keySlot("open:mod"), old: .defaults)
            #expect(result == .failure(.cannotRead), "\(code)")
        }
        let dead = KeyEditor.checkRecorded(
            event(14, "", .option), slot: keySlot("open:key"), old: .defaults)
        #expect(dead == .failure(.typesCharacter))
    }

    // With Cmd or Ctrl a dead key types no accent, so it is a shortcut at its place.
    @Test func aDeadKeyWithCmdOrCtrlIsAShortcut() {
        for (modifiers, binding) in [
            ([.command, .option], "Mod+Alt+E"), ([.control, .option], "Control+Alt+E"),
        ] as [(KeyEvent.Modifiers, String)] {
            let result = KeyEditor.checkRecorded(
                event(14, "", modifiers), slot: keySlot("open:mod"), old: .defaults)
            #expect(result.map(\.text) == .success(binding))
        }
    }

    // Each refusal has a friendly text. A conflict names the other action in the label set of
    // the user.
    @Test func eachRefusalHasItsText() {
        let texts: [(RecordRefusal, String)] = [
            (.cannotRead, "Bifrost can't use this key. Try another one."),
            (.typesCharacter, "That key types a character. Try another one."),
            (.space, "The space bar can't be a shortcut. Try another one."),
            (.binding(.reservedByMac), "macOS keeps this shortcut for itself."),
            (.binding(.conflict(with: keySlot("take-control:mod"))),
                "Take control already uses this key."),
        ]
        for (refusal, text) in texts {
            #expect(refusal.message(labels: .plain) == text)
        }
        let conflict = RecordRefusal.binding(.conflict(with: keySlot("take-control:mod")))
        #expect(conflict.message(labels: .space) == "Commandeer already uses this key.")
        let editTexts: [(KeyEditRefusal, String)] = [
            (.notAnObject, "Bifrost can't use that value for keys."),
            (.unknownSlot("nope:mod"), "Bifrost has no shortcut called \"nope:mod\"."),
            (.badValue(keySlot("open:mod")), "Bifrost can't use that value for open:mod."),
            (.newConflict, "Two actions can't share the same key."),
        ]
        for (refusal, text) in editTexts {
            #expect(refusal.message == text)
        }
    }

    // MARK: - The key edit

    // A key edit names some slots with their new keys. A good edit changes only those slots.
    @Test func aKeyEditChangesOnlyTheNamedKeys() throws {
        let old: JSONValue = [
            "future:mod": "Mod+J", "open:mod": "Hyper+K", "stop:key": .null, "rename:key": 5,
        ]
        let edit = try KeyEdit(
            patch: ["copy-id:mod": "Mod+Shift+K", "dictation:hold": .null], old: old)
        #expect(
            edit.stored(keeping: old) == [
                "future:mod": "Mod+J", "open:mod": "Hyper+K", "stop:key": .null, "rename:key": 5,
                "copy-id:mod": "Mod+Shift+K", "dictation:hold": .null,
            ])
        // A key in another spelling gets the standard form, and a default key has no entry.
        let spelled = try KeyEdit(patch: ["stop:key": "backspace", "open:key": "shift+o"], old: old)
        #expect(
            spelled.stored(keeping: old) == [
                "future:mod": "Mod+J", "open:mod": "Hyper+K", "rename:key": 5,
                "open:key": "Shift+O",
            ])
        // An empty edit changes nothing.
        #expect(try KeyEdit(patch: [:], old: old).stored(keeping: old) == old)
    }

    // The checks of each value: the slot must exist, and the value is null or a key that the
    // slot can take. The first bad entry refuses the edit.
    @Test func aKeyEditRefusesAnUnknownSlotABadValueAndANewConflict() {
        #expect(editRefusal("Mod+K") == .notAnObject)
        #expect(editRefusal(["nope:mod": "Mod+K"]) == .unknownSlot("nope:mod"))
        let bad: [(String, JSONValue)] = [
            ("open:mod", 5), ("open:mod", "Hyper+K"), ("open:mod", "Mod+Q"), ("open:mod", true),
            ("open:hold", "Shift+O"), ("close-panel:mod", "W"), ("dictation:hold", "Mod+K"),
            ("open:mod", ["key": "K"]),
        ]
        for (id, value) in bad {
            #expect(editRefusal([id: value]) == .badValue(keySlot(id)), "\(id) \(value)")
        }
        // Mod+L is the key of the Event log.
        #expect(editRefusal(["open:mod": "Mod+L"]) == .newConflict)
        // The edit sees the new keys of the edit: two named slots with one key conflict.
        #expect(editRefusal(["open:mod": "Mod+K", "copy-id:mod": "Mod+K"]) == .newConflict)
        // A move of the Event log first frees its key.
        #expect(editRefusal(["open:mod": "Mod+L", "event-log:mod": "Mod+Shift+L"]) == nil)
        // Slots of two classes can share a key.
        #expect(editRefusal(["open:key": "K", "open:hold": "K"]) == nil)
    }

    // A conflict that the old keys already have stays: an edit of another slot, or the same
    // key again, is good. A new pair, or the same pair with another key, is a new conflict.
    @Test func aKeyEditKeepsAConflictOfTheOldKeys() throws {
        let old: JSONValue = ["event-log:mod": "Mod+N"]
        #expect(KeyMap(stored: old).conflicts.count == 1)
        #expect(editRefusal(["open:mod": "Mod+K"], old: old) == nil)
        #expect(editRefusal(["event-log:mod": "Mod+N"], old: old) == nil)
        let moved: JSONValue = ["event-log:mod": "Mod+N", "new-session:mod": "Mod+K"]
        #expect(editRefusal(moved, old: old) == nil)
        // The pair moves to another key: a new conflict.
        #expect(
            editRefusal(["event-log:mod": "Mod+K", "new-session:mod": "Mod+K"], old: old)
                == .newConflict)
        // A third slot joins the key.
        #expect(editRefusal(["open:mod": "Mod+N"], old: old) == .newConflict)
        let edit = try KeyEdit(patch: ["open:mod": "Mod+K"], old: old)
        let saved = edit.stored(keeping: old)
        #expect(saved == ["event-log:mod": "Mod+N", "open:mod": "Mod+K"])
        #expect(KeyMap(stored: saved).conflicts == KeyMap(stored: old).conflicts)
    }

    // MARK: - Reset all keys

    // Reset all keys gives each slot its default key. An entry that this version cannot read
    // stays, so a reset never deletes the keys of a later version (row S2).
    @Test func resetAllKeysKeepsTheEntriesThisVersionCannotRead() {
        let old: JSONValue = [
            "future:mod": "Mod+J", "open:mod": "Hyper+K", "rename:key": 5, "stop:key": .null,
            "copy-id:mod": "cmd+shift+k", "open:key": "O", "close-panel:mod": "W",
            "event-log:mod": "Mod+N",
        ]
        let reset = KeyEditor.resetAll(keeping: old)
        #expect(
            reset == [
                "future:mod": "Mod+J", "open:mod": "Hyper+K", "rename:key": 5,
                "close-panel:mod": "W",
            ])
        #expect(KeyMap(stored: reset) == .defaults)
    }

    // A missing keys value, and a value that is not an object, stay as they are.
    @Test func resetAllKeysLeavesAMissingOrABadKeysValue() {
        #expect(KeyEditor.resetAll(keeping: nil) == nil)
        for value in ["x", 5, [], .null] as [JSONValue] {
            #expect(KeyEditor.resetAll(keeping: value) == value)
        }
    }
}
