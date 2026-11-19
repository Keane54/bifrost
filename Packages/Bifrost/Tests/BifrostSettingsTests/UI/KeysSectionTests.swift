import AppKit
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostKeyboard
@testable import BifrostSessions
@testable import BifrostSettings
import BifrostWindows

// Settings > Keys (docs/behaviour/keys.md, "Changing a key"): the groups and rows, the key
// recorder on a row, the refusals of a recorded key, Clear, Reset and Reset all keys, the search
// of the rows and the place of the error. The tests that show views use a window that is never
// ordered front, with no window key filter, so the recorder takes the keys that it has the focus
// for.
@MainActor
@Suite("Settings > Keys", .serialized, .timeLimit(.minutes(1)), .tags(.window))
struct KeysSectionTests {
    // The four groups show in the order always, single, hold, dictation, each under its title,
    // and the rows keep the slot order. Each row shows its key with the modifier symbols in the
    // order of the macOS menus (Chord.shown), or "No key" for Off.
    @Test func theGroupsAreInOrderWithTheDictationGroupLast() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.keys)
        let section = KeysSection(model: p.model, hit: nil)
        #expect(section.groups.map(\.group) == [.always, .single, .hold, .dictation])
        #expect(
            section.groups.map(\.title) == [
                "Shortcuts that work at all times",
                "Single keys (not in a chat window or a text box)", "Hold a key and click a row",
                "Hold to dictate in a chat window",
            ])
        #expect(await shownLabels(section) == KeySlot.all.map { $0.label(.plain) })
        let rows = section.groups.flatMap(\.rows)
        #expect(rows.first.map { KeysSection.keyText($0.binding) } == "⌘ N")
        #expect(rows.last?.label == "Dictation key")
        #expect(rows.last.map { KeysSection.keyText($0.binding) } == "␣")
        #expect(KeysSection.keyText(.off) == "No key")
        #expect(
            KeysSection.intro
                == "You can't record Esc or a plain Backspace, because the recorder uses them. "
                + "Reset brings back the default key.")
    }

    // Change starts the recorder on the row, and the recorder takes the focus. A refused key
    // shows its reason and the recording goes on. A good key of Close Panel saves only that slot,
    // the recording ends, and the focus goes to the panel. The key of a menu slot changed, so the
    // shell builds the menu again, and the menu shows the new key.
    @Test func aRecordedKeySavesAndTheMenuShowsIt() async throws {
        let s = try await ShownSettings()
        defer { s.close() }
        s.model.showTab(.keys)
        let before = s.store.settings
        let section = KeysSection(model: s.model, hit: nil)
        section.startRecording(.closePanel)
        #expect(await render(s.host) { s.window.firstResponder is KeyRecorderView })
        let recorder = try #require(s.recorder)
        #expect(recorder.isRecording)
        // Cmd+L is the key of Event log.
        #expect(s.window.performKeyEquivalent(with: try #require(s.key("l", [.meta]))))
        #expect(s.model.recording?.refusal == "Event log already uses this key.")
        #expect(recorder.isRecording)
        #expect(s.store.settings == before)
        #expect(s.window.performKeyEquivalent(with: try #require(s.key("k", [.meta, .shift]))))
        #expect(await waitUntil { s.store.settings.keys == ["close-panel:mod": "Mod+Shift+K"] })
        #expect(!recorder.isRecording)
        #expect(s.model.recording == nil)
        #expect(await render(s.host) { s.recorder == nil })
        #expect(await waitUntil { s.window.firstResponder === s.host })
        let row = section.groups.flatMap(\.rows).first { $0.slot == .closePanel }
        #expect(row.map { KeysSection.keyText($0.binding) } == "⇧ ⌘ K")
        #expect(row?.changed == true)
        let after = s.store.settings
        #expect(SettingsEffects.effects(before, after) == [.menu])
        let menu = MenuModel.make(appName: "Bifrost", keys: KeyMap(stored: after.keys))
        let items = menu.menus.flatMap(\.entries).compactMap { entry -> MenuItemModel? in
            guard case .item(let item) = entry else { return nil }
            return item
        }
        #expect(items.first { $0.action == .closePanel }?.key == chord("Mod+Shift+K"))
        #expect(s.model.error(of: KeysSection.row) == nil)
    }

    // A conflict names the action of the other slot, in the label set of the user. Nothing
    // saves.
    @Test func aConflictShowsTheNameOfTheOtherAction() async throws {
        let p = try await SettingsParts()
        let section = KeysSection(model: p.model, hit: nil)
        let open = keySlot("open:mod")
        section.startRecording(open)
        #expect(section.record(commandKey("N"), for: open) == nil)
        #expect(
            p.model.recording
                == SettingsModel.Recording(
                    slot: open, refusal: "New session already uses this key."))
        #expect(await p.model.save(.general(.labels)) { $0.labels = .space }.value)
        #expect(section.record(commandKey("N"), for: open) == nil)
        #expect(p.model.recording?.refusal == "Launch already uses this key.")
        #expect(p.store.settings.keys == nil)
        // A new recording starts with no reason.
        section.startRecording(keySlot("copy-id:mod"))
        #expect(p.model.recording == SettingsModel.Recording(slot: keySlot("copy-id:mod")))
    }

    // A dead key such as Option+E types a character, and the space bar is only for the
    // dictation key: the recorder refuses both with their reasons, and the recording goes on.
    // Esc then ends the recording with no change, and the focus goes to the panel.
    @Test func aKeyThatTypesACharacterIsRefused() async throws {
        let s = try await ShownSettings()
        defer { s.close() }
        s.model.showTab(.keys)
        let open = keySlot("open:key")
        KeysSection(model: s.model, hit: nil).startRecording(open)
        #expect(await render(s.host) { s.window.firstResponder is KeyRecorderView })
        s.window.sendEvent(try #require(s.key("e", [.alt])))
        #expect(s.model.recording?.refusal == "That key types a character. Try another one.")
        s.window.sendEvent(try #require(s.key("Space")))
        #expect(
            s.model.recording?.refusal == "The space bar can't be a shortcut. Try another one.")
        #expect(s.model.recording?.slot == open)
        s.window.sendEvent(try #require(s.key("Escape")))
        #expect(s.model.recording == nil)
        #expect(await render(s.host) { s.recorder == nil })
        #expect(await waitUntil { s.window.firstResponder === s.host })
        #expect(s.store.settings.keys == nil)
    }

    // Change on another row moves the recorder to that row: the first recording ends, and the
    // new recorder has the focus.
    @Test func changeOnAnotherRowMovesTheRecorder() async throws {
        let s = try await ShownSettings()
        defer { s.close() }
        s.model.showTab(.keys)
        let section = KeysSection(model: s.model, hit: nil)
        section.startRecording(keySlot("open:key"))
        #expect(await render(s.host) { s.window.firstResponder is KeyRecorderView })
        let first = try #require(s.recorder)
        section.startRecording(keySlot("rename:key"))
        #expect(await render(s.host) { s.recorder !== first && s.recorder?.isRecording == true })
        #expect(!first.isRecording)
        #expect(s.model.recording?.slot == keySlot("rename:key"))
        #expect(s.window.firstResponder === s.recorder)
        s.window.sendEvent(try #require(s.key("y")))
        #expect(await waitUntil { s.store.settings.keys == ["rename:key": "Y"] })
        #expect(await waitUntil { s.window.firstResponder === s.host })
    }

    // A recording during a search: at its end the recorder leaves the window, and the focus goes
    // to the search field, not to the window, where the single keys act.
    @Test func aRecordingDuringASearchGivesTheFocusToTheSearchAtItsEnd() async throws {
        let s = try await ShownSettings()
        defer { s.close() }
        s.model.query = "close panel"
        let hit = try #require(Self.keysHit(s.model))
        let section = KeysSection(model: s.model, hit: hit)
        #expect(section.shows(.closePanel))
        section.startRecording(.closePanel)
        #expect(await render(s.host) { s.window.firstResponder is KeyRecorderView })
        #expect(s.window.performKeyEquivalent(with: try #require(s.key("k", [.meta, .shift]))))
        #expect(await waitUntil { s.store.settings.keys == ["close-panel:mod": "Mod+Shift+K"] })
        let search = try #require(s.host.searchFieldView)
        #expect(await waitUntil { s.editingField === search })
        #expect(s.model.recording == nil)
        #expect(s.model.query == "close panel")
    }

    // A click on the prompt while the recorder records goes to a view of SwiftUI that does not
    // take the focus. So the recorder keeps the focus, and the recording goes on.
    @Test func aClickOnThePromptKeepsTheRecording() async throws {
        let s = try await ShownSettings()
        defer { s.close() }
        s.model.showTab(.keys)
        // The first row, so the prompt shows in the scroll area of the panel.
        let first = try #require(KeySlot.all.first)
        KeysSection(model: s.model, hit: nil).startRecording(first)
        #expect(await render(s.host) { s.window.firstResponder is KeyRecorderView })
        let recorder = try #require(s.recorder)
        let middle = NSPoint(x: recorder.bounds.midX, y: recorder.bounds.midY)
        let point = recorder.convert(middle, to: nil)
        let hit = try #require(s.window.contentView?.hitTest(point))
        #expect(hit.isDescendant(of: s.host))
        #expect(!hit.acceptsFirstResponder)
        try click(s.window, at: point)
        #expect(recorder.isRecording)
        #expect(s.window.firstResponder === recorder)
        #expect(s.model.recording?.slot == first)
    }

    // While Save runs, Change and Reset all keys are off: a recording or the confirm dialog could
    // save after Settings closed. Clear and Reset stay on, because Save waits for their saves.
    @Test func changeAndResetAllKeysAreOffWhileSaveRuns() async throws {
        let gate = WriteGate()
        defer { gate.openAll() }
        let p = try await SettingsParts(steps: gate.steps)
        p.model.showTab(.keys)
        let rename = keySlot("rename:key")
        let changed = p.model.save(KeysSection.row) { $0.keys = ["rename:key": "Y"] }
        try #require(await gate.waitUntilWriting())
        gate.open()
        #expect(await changed.value)
        let section = KeysSection(model: p.model, hit: nil)
        let row = try #require(section.groups.flatMap(\.rows).first { $0.slot == rename })
        p.model.links.confirm = { _ in true }
        #expect(section.canChange)
        #expect(section.canResetAll)
        #expect(section.canClear(row))
        #expect(section.canReset(row))
        let held = p.model.save(.general(.rowFlash)) { $0.rowFlash = false }
        try #require(await gate.waitUntilWriting())
        let save = Task.immediate { await p.model.saveAndClose() }
        #expect(p.model.isSaving)
        #expect(!section.canChange)
        #expect(!section.canResetAll)
        #expect(section.canClear(row))
        #expect(section.canReset(row))
        gate.open()
        #expect(await held.value)
        await save.value
        #expect(section.canChange)
        #expect(section.canResetAll)
        #expect(!p.isOpen)
        // An Off row has no Clear, and a row with its default key has no Reset.
        let open = try #require(section.groups.flatMap(\.rows).first { $0.slot == .closePanel })
        #expect(section.canClear(open))
        #expect(!section.canReset(open))
        #expect(!section.canClear(KeyRow(slot: rename, label: "", binding: .off, changed: true)))
    }

    // With no confirm dialog, Reset all keys is off, and a reset changes nothing: the build has
    // no button that does nothing. The dialog turns it on.
    @Test func resetAllKeysIsOffWithNoConfirmDialog() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.keys)
        let section = KeysSection(model: p.model, hit: nil)
        #expect(await section.clear(keySlot("open:key")).value)
        let changed = p.store.settings.keys
        #expect(p.model.links.confirm == nil)
        #expect(section.canChange)
        #expect(!section.canResetAll)
        #expect(await section.resetAll() == false)
        #expect(p.store.settings.keys == changed)
        p.model.links.confirm = { _ in false }
        #expect(section.canResetAll)
    }

    // Reset all keys asks first. With no confirm nothing changes. After the confirm each key is
    // its default, and the keys are an empty map.
    @Test func resetAllKeysAsksFirstAndSavesAnEmptyMap() async throws {
        let p = try await SettingsParts()
        let section = KeysSection(model: p.model, hit: nil)
        let open = keySlot("open:key")
        #expect(await section.clear(open).value)
        #expect(await section.record(commandKey("K"), for: keySlot("copy-id:mod"))?.value == true)
        let changed: JSONValue = ["open:key": .null, "copy-id:mod": "Mod+K"]
        #expect(p.store.settings.keys == changed)
        let asked = Asked()
        p.model.links.confirm = { asked.texts.append($0); return false }
        #expect(await section.resetAll() == false)
        #expect(asked.texts == [KeysSection.resetAllConfirm])
        #expect(KeysSection.resetAllConfirm.title == "Reset all keys")
        let body = "This puts every key back to its Bifrost default."
        #expect(KeysSection.resetAllConfirm.body == body)
        #expect(KeysSection.resetAllConfirm.confirm == "Reset all keys")
        #expect(p.store.settings.keys == changed)
        p.model.links.confirm = { asked.texts.append($0); return true }
        #expect(await section.resetAll())
        #expect(asked.texts.count == 2)
        #expect(p.store.settings.keys == [:])
        #expect(KeyMap(stored: p.store.settings.keys) == .defaults)
        #expect(section.groups.flatMap(\.rows).filter(\.changed).isEmpty)
    }

    // Reset all keys and the Reset of a row keep the entries that this version cannot read: a
    // slot of a later version and a key that a later version wrote. The row of such a key shows
    // the default key, so its Reset changes nothing. Clear and Reset change only their slot.
    @Test func theKeysOfALaterVersionStay() async throws {
        let p = try await SettingsParts()
        let later: JSONValue = ["future:mod": "Mod+J", "open:mod": "Hyper+K"]
        #expect(await p.model.save(KeysSection.row) { $0.keys = later }.value)
        let section = KeysSection(model: p.model, hit: nil)
        let open = keySlot("open:mod")
        let row = section.groups.flatMap(\.rows).first { $0.slot == open }
        #expect(row?.changed == false)
        #expect(await section.reset(open).value)
        #expect(p.store.settings.keys == later)
        let rename = keySlot("rename:key")
        #expect(await section.clear(rename).value)
        let cleared: JSONValue = ["future:mod": "Mod+J", "open:mod": "Hyper+K", "rename:key": .null]
        #expect(p.store.settings.keys == cleared)
        #expect(await section.reset(rename).value)
        #expect(p.store.settings.keys == later)
        p.model.links.confirm = { _ in true }
        #expect(await section.resetAll())
        #expect(p.store.settings.keys == later)
    }

    // Each row of Keys can be found: by the label of its action, and by its key in the form that
    // the row shows. The view shows the rows that match.
    @Test func eachKeysRowCanBeFound() async throws {
        let p = try await SettingsParts()
        for slot in KeySlot.all {
            // Each search of the model runs on the main actor. Each slot first lets the other
            // jobs of the main actor run, so the loop holds the main actor for one slot at a time.
            await Task.yield()
            p.model.query = slot.label(.plain)
            #expect(Self.keysHit(p.model)?.rows.contains(slot.text) == true, "\(slot)")
            guard let chord = KeyMap.defaults[slot].chord else { continue }
            p.model.query = chord.shown
            let hit = Self.keysHit(p.model)
            #expect(hit?.whole == true || hit?.rows.contains(slot.text) == true, "\(chord.shown)")
        }
        // Take control has a Cmd key and a single key.
        p.model.query = "take control"
        let hit = try #require(Self.keysHit(p.model))
        let section = KeysSection(model: p.model, hit: hit)
        #expect(await shownLabels(section) == ["Take control", "Take control"])
        #expect(section.groups.map(\.group) == [.always, .single])
    }

    // The error of a failed key save shows on the row of its slot. A search that hides that row
    // but still shows Keys moves the error to the top of the section, so Save keeps Settings open
    // with the error on the screen. The error of Reset all keys shows at the top.
    @Test func theKeysErrorShowsAtTheTopWhenItsRowIsHidden() async throws {
        let writes = FailingWrites()
        let p = try await SettingsParts(steps: writes.steps)
        p.model.showTab(.keys)
        let open = keySlot("open:key")
        #expect(await KeysSection(model: p.model, hit: nil).clear(open).value)
        writes.fail()
        #expect(await KeysSection(model: p.model, hit: nil).reset(open).value == false)
        let reason = try #require(p.model.error(of: KeysSection.row))
        #expect(p.model.keyErrorSlot == open)
        #expect(!KeysSection(model: p.model, hit: nil).errorAtTop)
        p.model.query = "event log"
        let hit = try #require(Self.keysHit(p.model))
        let hidden = KeysSection(model: p.model, hit: hit)
        #expect(!hidden.shows(open))
        #expect(hidden.errorAtTop)
        #expect(p.model.error(of: KeysSection.row) == reason)
        await p.model.saveAndClose()
        #expect(p.isOpen)
        // A search that hides the whole section drops the error.
        p.model.query = "row flash"
        #expect(p.model.error(of: KeysSection.row) == nil)
        p.model.query = ""
        p.model.showTab(.keys)
        p.model.links.confirm = { _ in true }
        #expect(await KeysSection(model: p.model, hit: nil).resetAll() == false)
        #expect(p.model.error(of: KeysSection.row) != nil)
        #expect(p.model.keyErrorSlot == nil)
        #expect(KeysSection(model: p.model, hit: nil).errorAtTop)
    }

    // MARK: - Helpers

    // The texts that the confirm closure of a test got.
    @MainActor
    private final class Asked {
        var texts: [ConfirmText] = []
    }

    // The match of Keys for the query of the model, or nil.
    private static func keysHit(_ model: SettingsModel) -> SearchHit? {
        model.hits?.first { $0.id == .keys }
    }

    // The steps of a safe write whose sync fails with an I/O error after fail().
    private final class FailingWrites: Sendable {
        private let failing = Mutex(false)

        func fail() { failing.withLock { $0 = true } }

        var steps: WriteSteps {
            WriteSteps(
                sync: { [self] handle in
                    if failing.withLock({ $0 }) { throw POSIXError(.EIO) }
                    try WriteSteps.system.sync(handle)
                }, rename: WriteSteps.system.rename)
        }
    }

    // A click of the left button at the point of the window: the down, then the up.
    private func click(_ window: NSWindow, at point: NSPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    // The key down of a letter of a US keyboard with Cmd.
    private func commandKey(_ letter: Character) -> KeyEvent {
        KeyEvent(
            keyCode: KeyCode(us: letter) ?? KeyCode(.space),
            characters: String(letter).lowercased(), modifiers: .command)
    }
}
