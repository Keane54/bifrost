// The key editor of Settings > Keys (docs/behaviour/keys.md, "Changing a key"): the rows of the
// key list, the check of a recorded key, the key edit of a raw keys value and Reset all keys.
//
// The Keys section checks a recorded key against the keys of store.settings, then saves it with
// one edit of the newest keys, so each other entry stays (row S2 of docs/ports/stores):
//
//     var changes = KeyChanges(stored: $0.keys)
//     changes.set(.chord(chord), for: slot)
//     $0.keys = changes.stored(keeping: $0.keys)
//
// The check and the edit read the keys at two times. The store runs the edits one at a time, but
// an earlier edit can change the keys after the check. Then the save can give two slots of one
// class the same key. That is safe: the file can keep a conflict, and the first slot in slot
// order keeps the key (KeyMap.activeBindings). A key edit (KeyEdit) works the same way.
import BifrostFoundation

// One row of the key list.
package struct KeyRow: Sendable, Equatable {
    package var slot: KeySlot
    package var label: String
    // The key of the slot, or Off.
    package var binding: KeyBinding
    // True when the slot does not have its default key.
    package var changed: Bool
}

// The rows of one group of slots, with the title of the group.
package struct KeyRowGroup: Sendable, Equatable {
    package var group: SlotGroup
    package var title: String
    package var rows: [KeyRow]
}

// Why the key recorder refuses a recorded key. message gives the text for the user.
package enum RecordRefusal: Error, Sendable, Equatable {
    // The key has no chord: a digit of the keypad, F13, or the key left of 1 on an ISO keyboard.
    case cannotRead
    // A dead key with no Cmd and no Ctrl: alone it types nothing, and with the next key it types
    // a character, for example Option+E.
    case typesCharacter
    // A key on the space bar for a slot other than dictation. Only the dictation key can be
    // Space, because a tap of it still types a space.
    case space
    // The key map refuses the key for the slot.
    case binding(BindingRefusal)

    // A conflict names the action of the other slot in the label set of the user.
    package func message(labels: LabelSet) -> String {
        switch self {
        case .cannotRead: "Bifrost can't use this key. Try another one."
        case .typesCharacter: "That key types a character. Try another one."
        case .space: "The space bar can't be a shortcut. Try another one."
        case .binding(let refusal): refusal.message(labels: labels)
        }
    }
}

package enum KeyEditor {
    // The groups in the order always, single, hold, dictation (the order of SlotGroup), each
    // with its rows in slot order.
    package static func groups(_ changes: KeyChanges, _ labels: LabelSet) -> [KeyRowGroup] {
        let keys = KeyMap(changes)
        return SlotGroup.allCases.map { group in
            let rows = KeySlot.all.filter { $0.group == group }.map { slot in
                KeyRow(
                    slot: slot, label: slot.label(labels), binding: keys[slot],
                    changed: changes[slot] != nil)
            }
            return KeyRowGroup(group: group, title: group.title, rows: rows)
        }
    }

    // The chord of a recorded key for a slot, checked against the old keys. The chord is the key
    // as the key rules read it (Chord(event:)). The chat input reads the dictation key by its
    // place, so the dictation slot gets the US key at the place of the key (Chord(placeOf:)).
    // The first failure gives the refusal: a key with no chord, a dead key with no Cmd and no
    // Ctrl, a key on the space bar for a slot other than dictation, then the checks of the key
    // map (KeyMap.check(_:for:)).
    package static func checkRecorded(
        _ event: KeyEvent, slot: KeySlot, old: KeyMap
    ) -> Result<Chord, RecordRefusal> {
        let recorded = slot.group == .dictation ? Chord(placeOf: event) : Chord(event: event)
        guard let chord = recorded else { return .failure(.cannotRead) }
        // With Cmd or Ctrl a dead key types no accent, so it is a normal shortcut.
        if event.key == .dead && event.modifiers.isDisjoint(with: [.command, .control]) {
            return .failure(.typesCharacter)
        }
        if slot.group != .dictation && chord.key == .named(.space) { return .failure(.space) }
        do throws(BindingRefusal) {
            try old.check(chord, for: slot)
        } catch {
            return .failure(.binding(error))
        }
        return .success(chord)
    }

    // The stored keys after Reset all keys: each slot gets its default key. Each entry that this
    // version reads (KeyBinding(stored:for:)) goes. Each other entry stays: a slot that this
    // version does not know, and a key that it cannot read. So a reset keeps the keys of a later
    // version (row S2). A missing keys value, and a value that is not an object, give no change
    // and stay as they are.
    package static func resetAll(keeping value: JSONValue?) -> JSONValue? {
        guard case .object(var object)? = value else { return value }
        for slot in KeySlot.all {
            if let entry = object[slot.text], KeyBinding(stored: entry, for: slot) != nil {
                object.removeValue(forKey: slot.text)
            }
        }
        return .object(object)
    }
}

// MARK: - The key edit

// Why a key edit is refused. message gives the text for the user.
package enum KeyEditRefusal: Error, Sendable, Equatable {
    // The keys value is not a JSON object.
    case notAnObject
    // No slot has this stored ID.
    case unknownSlot(String)
    // The value is not null or a key that the slot can take.
    case badValue(KeySlot)
    // After the edit, two slots of one class share a key, and the old keys do not have that
    // conflict.
    case newConflict

    package var message: String {
        switch self {
        case .notAnObject: "Bifrost can't use that value for keys."
        case .unknownSlot(let id): "Bifrost has no shortcut called \"\(id)\"."
        case .badValue(let slot): "Bifrost can't use that value for \(slot.text)."
        case .newConflict: "Two actions can't share the same key."
        }
    }
}

// A checked edit of some keys: the new key of each named slot. The test port makes one from the
// raw keys value of a settings request. It checks the edit against the keys of store.settings,
// then saves it with one edit of the newest keys:
//
//     let edit = try KeyEdit(patch: value, old: store.settings.keys)
//     try await store.edit { $0.keys = edit.stored(keeping: $0.keys) }
package struct KeyEdit: Sendable, Equatable {
    // The new key of each named slot.
    package let bindings: [KeySlot: KeyBinding]

    // The edit of a raw keys value: an object of stored slot IDs, each with null (Off) or a
    // binding text. old is the stored keys before the edit. The first failure refuses the edit,
    // with the entries in the order of their IDs:
    // - Each ID names a slot.
    // - Each value is a key that the slot can take: the rule of the load of the file
    //   (KeyBinding(stored:for:)).
    // - The keys after the edit have no new conflict. A conflict of the old keys can stay: the
    //   same two slots with the same key.
    package init(patch: JSONValue, old: JSONValue?) throws(KeyEditRefusal) {
        guard case .object(let object) = patch else { throw .notAnObject }
        var bindings: [KeySlot: KeyBinding] = [:]
        for (id, entry) in object.sorted(by: { $0.key < $1.key }) {
            guard let slot = KeySlot(id) else { throw .unknownSlot(id) }
            guard let binding = KeyBinding(stored: entry, for: slot) else {
                throw .badValue(slot)
            }
            bindings[slot] = binding
        }
        let before = KeyChanges(stored: old)
        var after = before
        for (slot, binding) in bindings { after.set(binding, for: slot) }
        guard Self.sharedKeys(KeyMap(after)).isSubset(of: Self.sharedKeys(KeyMap(before))) else {
            throw .newConflict
        }
        self.bindings = bindings
    }

    // The stored keys after the edit. Only the named slots change, and each other entry stays
    // (KeyChanges.stored(keeping:)). An edit that gives each slot the key that it has gives the
    // same value, so the store writes nothing.
    package func stored(keeping value: JSONValue?) -> JSONValue {
        var changes = KeyChanges(stored: value)
        for (slot, binding) in bindings { changes.set(binding, for: slot) }
        return changes.stored(keeping: value)
    }

    // A conflict with its key.
    private struct SharedKey: Hashable {
        let conflict: KeyConflict
        let chord: Chord
    }

    private static func sharedKeys(_ map: KeyMap) -> Set<SharedKey> {
        Set(
            map.conflicts.compactMap { conflict in
                map[conflict.first].chord.map { SharedKey(conflict: conflict, chord: $0) }
            })
    }
}
