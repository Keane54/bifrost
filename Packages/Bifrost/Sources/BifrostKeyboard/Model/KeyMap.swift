// The key map: the key of each slot, from the default keys and the changes of the user. The
// settings file keeps the changes as raw JSON (row S2 of docs/ports/stores). KeyChanges reads and
// writes that form, and the app uses the typed values after that. The checks of a new key, the
// conflicts and the keys that act are rules of the map. The behaviour list is in
// docs/behaviour/keys.md.
import BifrostFoundation

// The key of a slot: a chord, or no key (Off).
package enum KeyBinding: Hashable, Sendable {
    case off
    case chord(Chord)

    package var chord: Chord? {
        guard case .chord(let chord) = self else { return nil }
        return chord
    }

    // The key of a stored entry of a slot: null is Off, and a text is a binding that the slot
    // can take. A conflict does not count, because the file can have one. Another value, a text
    // that is not a binding and a key that the slot refuses give nil.
    package init?(stored entry: JSONValue, for slot: KeySlot) {
        switch entry {
        case .null:
            self = .off
        case .string(let text):
            guard let chord = Chord(text) else { return nil }
            do throws(BindingRefusal) {
                try KeyMap.defaults.check(chord, for: slot)
            } catch .conflict {
                // A conflict of the file stays. The first slot keeps the key (activeBindings).
            } catch {
                return nil
            }
            self = .chord(chord)
        default:
            return nil
        }
    }
}

// The changes of the user: each slot that does not have its default key. A slot that is not in
// the changes has its default key, so changes[slot] != nil means that the slot has a change.
package struct KeyChanges: Equatable, Sendable, ExpressibleByDictionaryLiteral {
    package private(set) var bindings: [KeySlot: KeyBinding] = [:]

    // The changes of these keys. A key that is the default key of its slot is no change.
    package init(_ bindings: [KeySlot: KeyBinding] = [:]) {
        for (slot, binding) in bindings {
            set(binding, for: slot)
        }
    }

    package init(dictionaryLiteral elements: (KeySlot, KeyBinding)...) {
        self.init(Dictionary(uniqueKeysWithValues: elements))
    }

    // The change of a slot, or nil when the slot has its default key.
    package subscript(slot: KeySlot) -> KeyBinding? { bindings[slot] }

    package var isEmpty: Bool { bindings.isEmpty }

    // Give the slot this key. The default key of the slot removes its change.
    package mutating func set(_ binding: KeyBinding, for slot: KeySlot) {
        bindings[slot] = binding == .chord(slot.defaultBinding) ? nil : binding
    }

    // Give the slot its default key again.
    package mutating func reset(_ slot: KeySlot) {
        bindings[slot] = nil
    }
}

// MARK: - The stored form

extension KeyChanges {
    // The changes of the stored keys: the raw keys value of settings.json, an object of stored
    // slot IDs. Each entry that KeyBinding(stored:for:) reads is a change: null is Off, and a
    // text is a binding. A conflict stays, because the file can have one. An entry with no slot
    // and an entry that this version cannot read give no change. A value that is not an object
    // gives no change.
    package init(stored value: JSONValue?) {
        self.init()
        guard case .object(let object)? = value else { return }
        for slot in KeySlot.all {
            guard let entry = object[slot.text], let binding = KeyBinding(stored: entry, for: slot)
            else { continue }
            set(binding, for: slot)
        }
    }

    // The stored keys after a change of the keys that the app read from value, for a save of the
    // settings. Only a slot whose change is not the change of value gets a new entry: the stored
    // form of its key, null for Off, or no entry for its default key. Each other entry stays as
    // it is. So a save keeps the entries of the slots that this version does not know, and the
    // keys that a later version wrote and this version cannot read (row S2).
    package func stored(keeping value: JSONValue?) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if case .object(let old)? = value { object = old }
        let loaded = KeyChanges(stored: value)
        for slot in KeySlot.all where bindings[slot] != loaded[slot] {
            switch bindings[slot] {
            case nil: object.removeValue(forKey: slot.text)
            case .off?: object[slot.text] = JSONValue.null
            case .chord(let chord)?: object[slot.text] = .string(chord.text)
            }
        }
        return .object(object)
    }
}

// MARK: - The map

// The key of each slot: its default key, or the change of the user. The map has one entry for
// each slot.
public struct KeyMap: Equatable, Sendable {
    private let bindings: [KeySlot: KeyBinding]

    package init(_ changes: KeyChanges = KeyChanges()) {
        bindings = Dictionary(
            uniqueKeysWithValues: KeySlot.all.map { slot in
                (slot, changes[slot] ?? .chord(slot.defaultBinding))
            })
    }

    // The key map of the stored keys of the settings (Settings.keys).
    public init(stored value: JSONValue?) {
        self.init(KeyChanges(stored: value))
    }

    // The default key of each slot.
    public static let defaults = KeyMap()

    package subscript(slot: KeySlot) -> KeyBinding { bindings[slot] ?? .off }

    // The physical key of the dictation slot, or nil when the slot is Off. The chat input reads
    // the dictation key itself.
    package var dictationKey: KeyCode? { self[.dictation].chord?.physicalKey }

    // Check a key for a slot. The first failure gives the refusal: the form of a dictation or a
    // hold key, a menu key without Cmd, a key that macOS or a Bifrost menu keeps, then a conflict
    // with the first other slot of the same class that has the key.
    package func check(_ chord: Chord, for slot: KeySlot) throws(BindingRefusal) {
        switch slot.group {
        case .dictation:
            guard chord.isPlain && chord.key.typesCharacter else { throw .dictationForm }
        case .hold:
            guard chord.isPlain && chord.key.isLetterOrDigit else { throw .holdForm }
        case .always, .single:
            // The menu gets the key of a menu slot. A key without Cmd would act in a chat window
            // and in a text box, but a menu key must not act there.
            if slot.isMenu && !chord.modifiers.contains(.command) { throw .menuNeedsCommand }
            if let refusal = BindingRefusal.reserved(chord) { throw refusal }
        }
        let other = KeySlot.all.first {
            $0 != slot && $0.slotClass == slot.slotClass && self[$0] == .chord(chord)
        }
        if let other { throw .conflict(with: other) }
    }

    // Each pair of slots of one class with the same key, in slot order.
    package var conflicts: [KeyConflict] {
        let bound = KeySlot.all.compactMap { slot in self[slot].chord.map { (slot, $0) } }
        var pairs: [KeyConflict] = []
        for (index, (first, chord)) in bound.enumerated() {
            for (second, other) in bound[(index + 1)...]
            where other == chord && second.slotClass == first.slotClass {
                pairs.append(KeyConflict(first: first, second: second))
            }
        }
        return pairs
    }

    // The keys that the key layer runs, in slot order. When two slots of one class have a key,
    // the first slot keeps it. A menu slot keeps its key too, but it is not in the list: the menu
    // gets its key first. The dictation slot is not in the list: the chat input reads its key.
    package var activeBindings: [ActiveBinding] {
        var list: [ActiveBinding] = []
        var taken: [SlotClass: Set<Chord>] = [:]
        for slot in KeySlot.all where slot.group != .dictation {
            guard let chord = self[slot].chord,
                taken[slot.slotClass, default: []].insert(chord).inserted
            else { continue }
            if !slot.isMenu { list.append(ActiveBinding(slot: slot, chord: chord)) }
        }
        return list
    }
}

package struct ActiveBinding: Equatable, Sendable {
    package let slot: KeySlot
    package let chord: Chord
}

// Two slots of one class with the same key. first comes before second in slot order.
package struct KeyConflict: Hashable, Sendable {
    package let first: KeySlot
    package let second: KeySlot

    package init(first: KeySlot, second: KeySlot) {
        self.first = first
        self.second = second
    }
}

// The classes of slots. Two slots of one class cannot share a key. Slots of two classes can. The
// dictation key acts only in a chat window, and no other key without a modifier acts there. So
// the dictation slot has a class of its own.
enum SlotClass: Hashable, Sendable {
    case key, hold, dictation
}

extension KeySlot {
    var slotClass: SlotClass {
        switch group {
        case .always, .single: .key
        case .hold: .hold
        case .dictation: .dictation
        }
    }
}

// MARK: - The refusals

// Why a slot cannot take a key.
package enum BindingRefusal: Error, Equatable, Sendable {
    // macOS keeps the shortcut.
    case reservedByMac
    // The Edit menu, the app menu or a Zoom item of the View menu has the shortcut.
    case reservedByMenu
    // A menu slot needs Cmd.
    case menuNeedsCommand
    // A hold key must be a plain letter or digit.
    case holdForm
    // The dictation key must be a plain key that types a character.
    case dictationForm
    // Another slot of the same class has the key.
    case conflict(with: KeySlot)

    // The refusal of a key that macOS or a Bifrost menu keeps, or nil.
    package static func reserved(_ chord: Chord) -> BindingRefusal? {
        if macKeeps.contains(chord) { return .reservedByMac }
        if menuKeeps.contains(chord) { return .reservedByMenu }
        return nil
    }

    // The text for the user. A conflict names the action of the other slot in the label set of
    // the user.
    package func message(labels: LabelSet) -> String {
        switch self {
        case .reservedByMac: "macOS keeps this shortcut for itself."
        case .reservedByMenu: "A Bifrost menu already uses this shortcut."
        case .menuNeedsCommand: "A menu shortcut needs Cmd."
        case .holdForm:
            "A hold key must be a single letter or number, without Cmd, Ctrl, Option or Shift."
        case .dictationForm:
            "For dictation, use Space, a letter, a number or a symbol, without Cmd, Ctrl, Option "
                + "or Shift."
        case .conflict(let other): "\(other.label(labels)) already uses this key."
        }
    }

    // The shortcuts that macOS keeps.
    private static let macKeeps = chords([
        "Mod+Tab", "Mod+Space", "Mod+H", "Mod+M", "Mod+Q", "Mod+Alt+Escape", "Mod+Shift+3",
        "Mod+Shift+4", "Mod+Shift+5", "Mod+Shift+Q", "Mod+Shift+/", "Mod+Control+Q",
        "Control+Space",
    ])

    // The shortcuts of the Edit menu, the app menu and the Zoom items of the View menu.
    private static let menuKeeps = chords([
        "Mod+Z", "Mod+Shift+Z", "Mod+X", "Mod+C", "Mod+V", "Mod+A", "Mod+Alt+H", "Mod+=", "Mod+-",
    ])

    private static func chords(_ texts: [String]) -> Set<Chord> {
        Set(texts.compactMap { Chord($0) })
    }
}
