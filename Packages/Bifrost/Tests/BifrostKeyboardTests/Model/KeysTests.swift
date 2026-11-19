// The slots, the bindings and the stored key changes (docs/behaviour/keys.md).
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation
@testable import BifrostKeyboard

private let zones: [FocusZone] = [.chat, .sendBox, .text, .control, .modal, .other]

private func allowedZones(_ slotId: String, _ binding: String) -> [FocusZone] {
    let slot = keySlot(slotId)
    let chord = chord(binding)
    return zones.filter { slot.acts(chord, in: $0) }
}

// The refusal of a key for a slot of a map, or nil when the slot takes the key.
private func refusal(_ slotId: String, _ binding: String, _ keys: KeyMap) -> BindingRefusal? {
    do throws(BindingRefusal) {
        try keys.check(chord(binding), for: keySlot(slotId))
        return nil
    } catch {
        return error
    }
}

private func conflict(_ id: String) -> BindingRefusal { .conflict(with: keySlot(id)) }

// The JSON value of a text, or nil when the text is not JSON.
private func json(_ text: String) -> JSONValue? {
    try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite("keys")
struct KeysTests {
    @Test("the slot table has all slots and the dictation slot with unique IDs")
    func slotCount() {
        #expect(KeySlot.all.count == 84)
        #expect(Set(KeySlot.all.map(\.description)).count == 84)
        #expect(KeySlot.all.filter { $0.group == .always }.count == 49)
        #expect(KeySlot.all.filter { $0.group == .single }.count == 24)
        #expect(KeySlot.all.filter { $0.group == .hold }.count == 10)
        #expect(KeySlot.all.filter { $0.group == .dictation }.count == 1)
        let menu = KeySlot.all.filter(\.isMenu).map(\.description).sorted()
        #expect(menu == ["close-panel:mod", "toggle-fullscreen:mod"])
    }

    @Test("the slot table keeps its order and defaults")
    func slotOrder() {
        let ids = KeySlot.all.map(\.description)
        #expect(ids[0] == "new-session:mod")
        #expect(ids[1] == "select-row.1:mod")
        #expect(ids[9] == "select-row.9:mod")
        #expect(ids[48] == "toggle-fullscreen:mod")
        #expect(ids[49] == "select-prev:key")
        #expect(ids[72] == "escape:key")
        #expect(ids[73] == "open:hold")
        #expect(ids[82] == "set-priority.5:hold")
        #expect(ids[83] == "dictation:hold")
        #expect(KeySlot.dictation.description == "dictation:hold")
        #expect(KeySlot("dictation:hold") == .dictation)
        #expect(KeySlot.dictation.command == .dictation)
        #expect(KeySlot.dictation.defaultBinding == chord("Space"))
        #expect(KeySlot.dictation.group == .dictation)
        let row3 = KeySlot("select-row.3:mod")
        #expect(row3?.command == .selectRow(3))
        #expect(row3?.defaultBinding == chord("Mod+3"))
        #expect(KeySlot("set-priority.0:mod")?.command == .setPriority(0))
        #expect(KeySlot("set-priority.0:mod")?.defaultBinding == chord("Mod+Control+0"))
        #expect(KeySlot("set-priority.4:hold")?.defaultBinding == chord("4"))
        #expect(KeySlot("set-priority.4:hold")?.group == .hold)
        #expect(KeySlot("load-layout.9:mod")?.defaultBinding == chord("Mod+Alt+9"))
        #expect(KeySlot("open:key2")?.defaultBinding == chord("Enter"))
        #expect(KeySlot("delete:mod")?.defaultBinding == chord("Mod+Alt+Shift+Backspace"))
        #expect(KeySlot("nope:mod") == nil)
        #expect(KeySlot("select-row.10:mod") == nil)
    }

    @Test("the default map has no conflicts and no reserved keys")
    func defaultsClean() {
        #expect(KeyMap.defaults.conflicts.isEmpty)
        for slot in KeySlot.all {
            #expect(BindingRefusal.reserved(slot.defaultBinding) == nil)
            #expect(Chord(slot.defaultBinding.description) == slot.defaultBinding)
        }
    }

    @Test("a binding gets sorted modifiers and standard aliases")
    func canonical() {
        #expect(Chord("shift+cmd+m")?.description == "Mod+Shift+M")
        #expect(Chord("Ctrl+Cmd+1")?.description == "Mod+Control+1")
        #expect(Chord("Option+Cmd+Shift+Backspace")?.description == "Mod+Alt+Shift+Backspace")
        #expect(Chord("esc")?.description == "Escape")
        #expect(Chord("return")?.description == "Enter")
        #expect(Chord("meta+up")?.description == "Mod+ArrowUp")
        #expect(Chord("Command+f12")?.description == "Mod+F12")
        #expect(Chord("Mod+\\")?.description == "Mod+\\")
        for text in [
            "Mod+Shift", "Mod+A+B", "Mod+Mod+A", "Cmd+Mod+A", "Hyper+A", "Mod+F13", "",
            "constructor+K", "__proto__+K", "Mod+toString",
        ] {
            #expect(Chord(text) == nil, "\(text)")
        }
        #expect(Chord("Mod+Alt+K") == Chord([.command, .option], key: .character("K")))
    }

    @Test("the reserved shortcuts and the menus are refused")
    func reserved() {
        let mac = [
            "Mod+Tab", "Mod+Space", "Mod+H", "Mod+M", "Mod+Q", "Mod+Alt+Escape", "Mod+Shift+3",
            "Mod+Shift+4", "Mod+Shift+5", "Mod+Shift+Q", "Mod+Shift+/", "Mod+Control+Q",
            "Control+Space",
        ]
        let menu = [
            "Mod+Z", "Mod+Shift+Z", "Mod+X", "Mod+C", "Mod+V", "Mod+A", "Mod+Alt+H", "Mod+=",
            "Mod+-",
        ]
        for binding in mac { #expect(BindingRefusal.reserved(chord(binding)) == .reservedByMac) }
        for binding in menu {
            #expect(BindingRefusal.reserved(chord(binding)) == .reservedByMenu)
        }
        #expect(BindingRefusal.reserved(chord("cmd+q")) == .reservedByMac)
        #expect(BindingRefusal.reserved(chord("Mod+N")) == nil)
    }

    @Suite("checking a binding")
    struct CheckBinding {
        let keys = KeyMap.defaults

        @Test("a conflict is refused and names the other slot")
        func refusesConflict() {
            #expect(refusal("new-session:mod", "Mod+L", keys) == conflict("event-log:mod"))
        }

        @Test("the current key of a slot is accepted")
        func acceptsCurrent() {
            #expect(refusal("open:mod", "cmd+enter", keys) == nil)
        }

        @Test
        func holdAndSingleShare() {
            #expect(refusal("open:hold", "O", keys) == nil)
            #expect(refusal("send-message:hold", "O", keys) == conflict("open:hold"))
            #expect(refusal("send-message:key", "O", keys) == conflict("open:key"))
        }

        @Test("a hold slot takes one letter or one digit")
        func holdForm() {
            for binding in ["Shift+O", "Control+O", "Mod+O", "Enter", "Alt+7", "/"] {
                #expect(refusal("open:hold", binding, keys) == .holdForm)
            }
            #expect(refusal("open:hold", "7", keys) == nil)
            #expect(refusal("open:hold", "k", keys) == nil)
        }

        @Test("a reserved key is refused")
        func refusesReserved() {
            #expect(refusal("open:mod", "Mod+Q", keys) == .reservedByMac)
            #expect(refusal("open:mod", "Mod+Z", keys) == .reservedByMenu)
        }

        @Test
        func menuNeedsMod() {
            for slotId in ["close-panel:mod", "toggle-fullscreen:mod"] {
                for binding in ["W", "Shift+W", "Control+W", "Alt+F", "Control+Shift+F"] {
                    #expect(refusal(slotId, binding, keys) == .menuNeedsCommand)
                }
            }
            #expect(refusal("close-panel:mod", "Mod+Shift+W", keys) == nil)
            #expect(refusal("toggle-fullscreen:mod", "Mod+Alt+F", keys) == nil)
            // A slot that the menu does not own keeps a key without Mod.
            #expect(refusal("new-session:mod", "Control+K", keys) == nil)
        }

        @Test
        func selfAndNull() {
            let changed = KeyMap([keySlot("event-log:mod"): .off])
            #expect(refusal("event-log:mod", "Mod+L", changed) == nil)
            #expect(refusal("new-session:mod", "Mod+L", changed) == nil)
        }
    }

    @Suite("custom keys")
    struct ParseCustomKeys {
        @Test("known slots with good keys stay")
        func keepsGood() {
            let data = json(
                #"""
                {"copy-id:key": null, "foo:mod": "Mod+J", "open:hold": "Shift+O",
                 "open:mod": "cmd+k", "stop:mod": "Mod+Q", "x": 5}
                """#)
            let kept = keyChanges(["copy-id:key": nil, "open:mod": "Mod+K"])
            #expect(KeyChanges(stored: data) == kept)
        }

        @Test("data that is not a plain object gives an empty object")
        func notObject() {
            #expect(KeyChanges(stored: json("null")).isEmpty)
            #expect(KeyChanges(stored: json("[]")).isEmpty)
            #expect(KeyChanges(stored: json("\"x\"")).isEmpty)
            #expect(KeyChanges(stored: nil).isEmpty)
        }

        @Test
        func dropsMenuWithoutMod() {
            let data = json(#"{"close-panel:mod": "W", "toggle-fullscreen:mod": "Mod+Alt+F"}"#)
            let kept = keyChanges(["toggle-fullscreen:mod": "Mod+Alt+F"])
            #expect(KeyChanges(stored: data) == kept)
        }

        @Test("a conflict in the file stays")
        func keepsConflict() {
            let parsed = KeyChanges(stored: json(#"{"new-session:mod": "cmd+l"}"#))
            #expect(parsed == keyChanges(["new-session:mod": "Mod+L"]))
        }

        // A key named "__proto__" is not a slot, so the stored changes keep only the slot.
        @Test("the prototype key is ignored")
        func prototypeKey() {
            let result = KeyChanges(stored: json(#"{"__proto__": "Mod+K", "open:mod": "Mod+K"}"#))
            #expect(Array(result.bindings.keys) == [keySlot("open:mod")])
        }
    }

    @Test("changes apply and null removes a key")
    func effective() {
        let keys = KeyMap(keyChanges(["open:mod": "Mod+K", "stop:mod": nil]))
        #expect(keys[keySlot("open:mod")] == .chord(chord("Mod+K")))
        #expect(keys[keySlot("stop:mod")] == .off)
        #expect(keys[keySlot("new-session:mod")] == .chord(chord("Mod+N")))
    }

    @Test("setting a slot key to its default removes the entry, and no change keeps the value")
    func setAndReset() {
        let open = keySlot("open:mod")
        let stop = keySlot("stop:mod")
        var changes = KeyChanges()
        changes.set(.chord(chord("cmd+enter")), for: open)
        #expect(changes.isEmpty)
        changes.set(.chord(chord("Mod+K")), for: open)
        #expect(changes == keyChanges(["open:mod": "Mod+K"]))
        let changed = changes
        changes.set(.chord(chord("Mod+K")), for: open)
        #expect(changes == changed)
        changes.set(.off, for: stop)
        #expect(changes == keyChanges(["open:mod": "Mod+K", "stop:mod": nil]))
        changes.reset(stop)
        #expect(changes == changed)
        changes.reset(stop)
        #expect(changes == changed)
        changes.set(.chord(chord("Mod+Enter")), for: open)
        #expect(changes.isEmpty)
    }

    @Test("conflicts list the pairs of one class in slot order")
    func conflicts() {
        let keys = KeyMap(keyChanges(["event-log:mod": "Mod+N", "send-message:hold": "O"]))
        let pairs = [
            KeyConflict(first: keySlot("new-session:mod"), second: keySlot("event-log:mod")),
            KeyConflict(first: keySlot("open:hold"), second: keySlot("send-message:hold")),
        ]
        #expect(keys.conflicts == pairs)
        #expect(KeyMap(keyChanges(["open:key": nil, "send-message:key": nil])).conflicts.isEmpty)
    }

    @Test("active bindings skip menu slots, null keys and later conflicts")
    func activeSkips() {
        let list = KeyMap(keyChanges(["event-log:mod": "Mod+N", "stop:mod": nil])).activeBindings
        let ids = list.filter { $0.chord == chord("Mod+N") }.map(\.slot.description)
        #expect(ids == ["new-session:mod"])
        #expect(!list.contains { $0.slot.isMenu })
        #expect(!list.contains { $0.slot == keySlot("stop:mod") })
        #expect(!list.contains { $0.slot == keySlot("event-log:mod") })
        #expect(list.count == 83 - 2 - 1 - 1)
    }

    @Test
    func menuKeepsKey() {
        let list = KeyMap(keyChanges(["event-log:mod": "Mod+W"])).activeBindings
        #expect(!list.contains { $0.slot == keySlot("event-log:mod") })
    }

    @Test("allowed keys follow the key rules")
    func allowedSpec() {
        let noModal: [FocusZone] = [.chat, .sendBox, .text, .control, .other]
        #expect(allowedZones("new-session:mod", "Mod+N") == noModal)
        #expect(allowedZones("copy-id:mod", "Control+K") == [.sendBox, .text, .control, .other])
        #expect(allowedZones("open:key", "O") == [.control, .other])
        #expect(allowedZones("open:key2", "Enter") == [.other])
        #expect(allowedZones("next-overview-tab:key", "Tab") == [.other])
        #expect(allowedZones("prev-overview-tab:key", "Shift+Tab") == [.other])
        #expect(allowedZones("escape:key", "Escape") == [.sendBox, .control, .other])
        #expect(allowedZones("select-next:key", "ArrowDown") == [.other])
        #expect(allowedZones("delete:key", "Shift+Backspace") == [.control, .other])
    }

    @Test("arrow keys, Home and End stay allowed with a control")
    func allowedControl() {
        let down = keySlot("select-next:key")
        let up = keySlot("select-prev:key")
        // A tab list, a radio group, a pop-up button and a menu move with these keys.
        #expect(down.acts(chord("ArrowDown"), in: .control) == false)
        #expect(down.acts(chord("ArrowDown"), in: .other) == true)
        #expect(allowedZones("select-prev:key", "ArrowUp") == [.other])
        #expect(allowedZones("select-prev:key", "ArrowLeft") == [.other])
        #expect(allowedZones("select-next:key", "ArrowRight") == [.other])
        #expect(allowedZones("select-next:key", "Shift+ArrowDown") == [.other])
        #expect(allowedZones("select-prev:key", "Home") == [.other])
        #expect(allowedZones("select-next:key", "End") == [.other])
        #expect(up.acts(chord("Home"), in: .control) == false)
        // Mod+ArrowDown works at all times. Another single key still acts on a control.
        #expect(allowedZones("select-next:mod", "Mod+ArrowDown").contains(.control))
        #expect(allowedZones("stop:key", "Backspace") == [.control, .other])
    }

    @Test("a hold key acts only in the other zone")
    func allowedHold() {
        #expect(allowedZones("open:hold", "O") == [.other])
        #expect(allowedZones("set-priority.3:hold", "3") == [.other])
    }

    @Suite("the dictation slot")
    struct DictationSlot {
        let keys = KeyMap.defaults

        @Test("a slot takes Space, a letter, a digit or punctuation with no modifier")
        func takes() {
            for binding in ["Space", "space", "k", "7", "/", "`"] {
                #expect(refusal("dictation:hold", binding, keys) == nil, "\(binding)")
            }
        }

        @Test("a modifier and a key that types no character are refused")
        func refuses() {
            for binding in ["Shift+Space", "Mod+K", "Alt+7", "Control+/", "Enter", "F5", "Tab"] {
                #expect(refusal("dictation:hold", binding, keys) == .dictationForm)
            }
        }

        @Test("the slot may share a key because it acts only in a chat window")
        func shares() {
            #expect(refusal("dictation:hold", "O", keys) == nil)
            #expect(refusal("dictation:hold", "1", keys) == nil)
            #expect(refusal("open:hold", "Space", keys) == .holdForm)
            #expect(KeyMap([.dictation: .chord(chord("O"))]).conflicts.isEmpty)
        }

        @Test("the slot can be Off and the stored key stays")
        func off() {
            #expect(KeyChanges(stored: json(#"{"dictation:hold": null}"#)) == [.dictation: .off])
            let slash = KeyChanges(stored: json(#"{"dictation:hold": "/"}"#))
            #expect(slash == [.dictation: .chord(chord("/"))])
            #expect(KeyChanges(stored: json(#"{"dictation:hold": "Shift+K"}"#)).isEmpty)
            #expect(KeyMap([.dictation: .off])[.dictation] == .off)
            #expect(KeyMap([.dictation: .off]).dictationKey == nil)
            #expect(KeyMap.defaults.dictationKey == KeyCode(.space))
        }

        @Test("the slot is not a registered binding and acts only in a chat window")
        func notRegistered() {
            #expect(!keys.activeBindings.contains { $0.slot == .dictation })
            #expect(allowedZones("dictation:hold", "Space") == [.chat])
        }
    }

    // The native menu gets a key equivalent: the key text and the modifier flags of the item.
    @Test func keyEquivalentGivesTheKeyAndTheModifiersOfTheMenuItem() {
        let cases: [(String, String, KeyEvent.Modifiers)] = [
            ("Mod+W", "w", .command), ("Mod+Control+F", "f", [.command, .control]),
            ("Mod+ArrowUp", "\u{F700}", .command), ("Mod+Enter", "\r", .command),
            ("Mod+Alt+Shift+Backspace", "\u{8}", [.command, .option, .shift]),
            ("Escape", "\u{1B}", []), ("Mod+ArrowLeft", "\u{F702}", .command),
            ("Mod+F12", "\u{F70F}", .command), ("Mod+F1", "\u{F704}", .command),
            ("Mod+Shift+/", "/", [.command, .shift]), ("Space", " ", []),
        ]
        for (binding, key, modifiers) in cases {
            #expect(chord(binding).keyEquivalent == key, "\(binding)")
            #expect(chord(binding).modifiers == modifiers, "\(binding)")
        }
    }

    @Test func theTwoMenuSlotsHaveTheirKeys() {
        #expect(KeyMap.defaults[.closePanel] == .chord(chord("Mod+W")))
        #expect(KeyMap.defaults[.toggleFullscreen] == .chord(chord("Mod+Control+F")))
        // A changed key of a menu slot gives its own key equivalent.
        let changed = KeyMap([.closePanel: .chord(chord("Mod+Shift+W"))])
        #expect(changed[.closePanel].chord?.keyEquivalent == "w")
        #expect(changed[.closePanel].chord?.modifiers == [.command, .shift])
    }
}
