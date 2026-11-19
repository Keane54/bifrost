import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostTestSupport
import SwiftUI
import Testing

@testable import BifrostKeyboard
@testable import BifrostSettings

// The Settings panel (docs/behaviour/settings.md): the tabs, the search, Cmd+F and Esc in the
// search field, the later sections, the errors of the rows and the Save button. The tests with a
// host show the panel in a window that is never ordered front.
@MainActor
@Suite("the Settings panel", .serialized, .testTimeLimit, .tags(.window))
struct SettingsPanelTests {
    @Test func theTabsAreInTheElectronOrder() async throws {
        #expect(
            SettingsPanel.tabs.map(\.title) == [
                "General", "Slash commands", "Keys", "Reviews", "Daily update", "Live details",
                "Skills", "Modules", "Updates",
            ])
        let p = try await SettingsParts()
        #expect(p.model.activeTab == .general)
    }

    // With no search the tabs show the section of the active tab. A query shows the hits of each
    // section, in the order of the tabs, and no tab is active. Spaces only are no search.
    @Test func aQueryShowsTheHitsAndAnEmptyQueryShowsTheTabs() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.keys)
        #expect(p.model.content == .section(.keys))
        p.model.query = "flash"
        #expect(p.model.activeTab == nil)
        let flash = SearchHit(id: .general, title: "General", whole: false, rows: ["Row flash"])
        #expect(p.model.content == .hits([flash]))
        p.model.query = "slash"
        guard case .hits(let hits) = p.model.content else {
            Issue.record("no hits")
            return
        }
        #expect(hits.first?.id == .slash)
        #expect(hits.first?.whole == true)
        p.model.query = "   "
        #expect(p.model.content == .section(.keys))
        #expect(p.model.activeTab == .keys)
    }

    // A query with no match shows the line with the trimmed query, and a screen reader hears it.
    @Test func theNoMatchTextShows() async throws {
        let p = try await SettingsParts()
        p.model.query = " xyz "
        #expect(p.model.content == .noMatch(#"No settings match "xyz"."#))
        #expect(p.model.countText == #"No settings match "xyz"."#)
        #expect(p.said == [#"No settings match "xyz"."#])
    }

    // Cmd+F moves the focus to the search field while the focus is in Settings, or while no view
    // has the focus and Settings is on top. With the focus in another view, Cmd+F goes on.
    @Test func cmdFFocusesTheSearch() async throws {
        let s = try await ShownSettings()
        defer { s.close() }
        let search = try #require(s.host.searchFieldView)
        let cmdF = try #require(
            USKeyboard.keyEvent(
                down: true, id: "f", mods: [.meta], isRepeat: false, window: s.window))
        #expect(s.window.firstResponder === s.window)
        #expect(s.host.focusPlace() == .none)
        #expect(s.window.performKeyEquivalent(with: cmdF))
        #expect(s.editingField === search)
        #expect(s.host.focusPlace() == .settings)
        // In the panel: the field keeps the focus.
        #expect(s.window.performKeyEquivalent(with: cmdF))
        #expect(s.editingField === search)
        // The focus in another view.
        #expect(s.window.makeFirstResponder(s.other))
        #expect(s.host.focusPlace() == .other)
        #expect(!s.window.performKeyEquivalent(with: cmdF))
        #expect(s.editingField === s.other)
        // No focus, and Settings is not on top.
        #expect(s.window.makeFirstResponder(nil))
        s.parts.layout.apply(.open(.watchlist))
        #expect(!s.window.performKeyEquivalent(with: cmdF))
        #expect(s.window.firstResponder === s.window)
        // Cmd+Shift+F is not Cmd+F.
        s.parts.layout.apply(.open(.settings))
        let shifted = try #require(
            USKeyboard.keyEvent(
                down: true, id: "f", mods: [.meta, .shift], isRepeat: false, window: s.window))
        #expect(!s.window.performKeyEquivalent(with: shifted))
        // The key recorder keeps Cmd+F while it records.
        let recorder = KeyRecorderView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        var recorded: [String] = []
        recorder.onKey = { recorded.append(Chord(event: $0)?.text ?? "none") }
        s.host.addSubview(recorder)
        recorder.begin()
        #expect(s.host.focusPlace() == .settings)
        #expect(s.window.performKeyEquivalent(with: cmdF))
        #expect(recorder.isRecording)
        #expect(recorded == ["Mod+F"])
        #expect(s.window.firstResponder === recorder)
    }

    // Cmd+F puts the caret at the end of the search text, and a search field that edits keeps
    // its selection, as the search input of the Electron app does.
    @Test func cmdFPutsTheCaretAtTheEndOfTheSearch() async throws {
        let s = try await ShownSettings()
        defer { s.close() }
        let search = try #require(s.host.searchFieldView)
        #expect(s.window.makeFirstResponder(search))
        let editor = try #require(s.window.firstResponder as? NSTextView)
        editor.insertText("flash", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(s.model.query == "flash")
        #expect(s.window.makeFirstResponder(nil))
        let cmdF = try #require(s.key("f", [.meta]))
        #expect(s.window.performKeyEquivalent(with: cmdF))
        #expect(s.window.firstResponder === editor)
        #expect(editor.string == "flash")
        #expect(editor.selectedRange == NSRange(location: 5, length: 0))
        editor.selectedRange = NSRange(location: 1, length: 2)
        #expect(s.window.performKeyEquivalent(with: cmdF))
        #expect(editor.selectedRange == NSRange(location: 1, length: 2))
    }

    // Esc in the search field clears the query, then it closes Settings. The key goes the real
    // way: the window, the field editor and the delegate of the field. During a composition Esc
    // does neither.
    @Test func escClearsThenCloses() async throws {
        let s = try await ShownSettings()
        defer { s.close() }
        let search = try #require(s.host.searchFieldView)
        #expect(s.window.makeFirstResponder(search))
        let editor = try #require(s.window.firstResponder as? NSTextView)
        editor.insertText("flash", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(s.model.query == "flash")
        let escape = try #require(s.key("Escape"))
        s.window.sendEvent(escape)
        #expect(s.model.query.isEmpty)
        #expect(s.parts.isOpen)
        try #require(await render(s.host) { editor.string.isEmpty })
        editor.insertText("flash", replacementRange: NSRange(location: NSNotFound, length: 0))
        // During a composition Esc keeps the text and Settings.
        editor.setMarkedText(
            "か", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        let composing = s.model.query
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(s.model.query == composing)
        #expect(s.parts.isOpen)
        editor.unmarkText()
        s.window.sendEvent(escape)
        #expect(s.model.query.isEmpty)
        #expect(s.parts.isOpen)
        s.window.sendEvent(escape)
        #expect(!s.parts.isOpen)
    }

    // Each open of the panel runs the open hook of the model one time: a new body of the panel,
    // and the model of a panel that was open before the settings store opened. The same body
    // again, and a model with no open panel, run nothing.
    @Test func eachOpenOfThePanelRunsTheOpenHook() async throws {
        let p = try await SettingsParts()
        let opens = Counter()
        p.model.links.onPanelOpen = { opens.count += 1 }
        let panels = SettingsPanels()
        panels.attach(p.model)
        #expect(opens.count == 0)
        let body = panels.body(for: .settings)
        #expect(opens.count == 1)
        #expect(panels.body(for: .settings) === body)
        #expect(panels.body(for: .overview(1)) == nil)
        #expect(opens.count == 1)
        panels.releaseBody(for: .settings)
        _ = panels.body(for: .settings)
        #expect(opens.count == 2)
        // A body that waits for the model: the attach is the open.
        let waiting = SettingsPanels()
        _ = waiting.body(for: .settings)
        waiting.attach(p.model)
        #expect(opens.count == 3)
    }

    // A section of a later build shows the later text, and the search does not find it, even by
    // its title.
    @Test func aLaterSectionShowsTheLaterText() async throws {
        #expect(LaterSection.text == "This section comes in a later build of Bifrost Dev.")
        let p = try await SettingsParts()
        let later: [SettingsSection] = [.modules]
        #expect(SettingsSection.allCases.filter { !SettingsModel.built.contains($0) } == later)
        for section in later {
            p.model.showTab(section)
            #expect(p.model.content == .section(section))
            p.model.query = section.title
            #expect(p.model.content == .noMatch("No settings match \"\(section.title)\"."))
        }
        // The body of a later section is the later text. A built section is not.
        UITestApp.prepare()
        let text = NSHostingView(rootView: LaterSection(model: p.model)).fittingSize
        #expect(text.height > 0)
        for section in SettingsSection.allCases {
            let view = SectionBody(model: p.model, section: section, hit: nil)
            let body = NSHostingView(rootView: view)
            if later.contains(section) {
                #expect(body.fittingSize == text, "\(section)")
            } else {
                #expect(body.fittingSize != text, "\(section)")
            }
        }
    }

    // A refused save shows its reason on its row, and on no other row. A good save of the row
    // clears it.
    @Test func aRefusedSaveShowsItsReasonOnItsRow() async throws {
        let p = try await SettingsParts()
        let escalation = SettingsRowID.general(.escalation)
        let flash = SettingsRowID.general(.rowFlash)
        #expect(await p.model.save(escalation) { $0.escalationMinutes = 500 }.value == false)
        #expect(await p.model.save(flash) { $0.rowFlash = false }.value)
        let reason = SettingsError.refused(.field(.escalationMinutes)).message
        #expect(p.model.error(of: escalation) == reason)
        #expect(p.model.error(of: flash) == nil)
        #expect(p.store.settings.escalationMinutes == 10)
        #expect(await p.model.save(escalation) { $0.escalationMinutes = 20 }.value)
        #expect(p.model.error(of: escalation) == nil)
    }

    // Save closes Settings only when each draft saved. A refused draft keeps Settings open with
    // its reason. A good draft saves, and Save closes Settings.
    @Test func saveClosesSettingsOnlyWhenEachDraftSaved() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.slash)
        p.model.editDraft(1, row: newSlashRow, text: "no slash", save: slashDraft(p.model))
        await p.model.saveAndClose()
        #expect(p.isOpen)
        #expect(p.model.error(of: newSlashRow) == SettingsRefusal.slashStart.message)
        p.model.editDraft(1, row: newSlashRow, text: "/plan", save: slashDraft(p.model))
        await p.model.saveAndClose()
        #expect(!p.isOpen)
        #expect(p.store.settings.slashCommands.last == "/plan")
        #expect(p.model.error(of: newSlashRow) == nil)
    }

    // A row that a search hides drops its error and its save state, so Save closes Settings. So
    // does a row of a section that a tab change hides, and a draft whose field the search hides.
    @Test func aHiddenRowDropsItsSaveStateAndItsError() async throws {
        let p = try await SettingsParts()
        let escalation = SettingsRowID.general(.escalation)
        p.model.save(escalation) { $0.escalationMinutes = -1 }
        await p.model.saveAndClose()
        #expect(p.isOpen)
        #expect(p.model.error(of: escalation) != nil)
        // The row matches: it keeps its error.
        p.model.query = "escalation"
        #expect(p.model.isShown(escalation))
        #expect(p.model.error(of: escalation) != nil)
        p.model.query = "flash"
        #expect(!p.model.isShown(escalation))
        #expect(p.model.error(of: escalation) == nil)
        p.model.query = ""
        #expect(p.model.error(of: escalation) == nil)
        await p.model.saveAndClose()
        #expect(!p.isOpen)
        // A tab change.
        p.model.open()
        p.model.save(escalation) { $0.escalationMinutes = -1 }
        await p.model.saveAndClose()
        #expect(p.isOpen)
        p.model.showTab(.keys)
        #expect(p.model.error(of: escalation) == nil)
        await p.model.saveAndClose()
        #expect(!p.isOpen)
        // A draft whose field the search hides: its text goes, and Save adds nothing.
        p.model.open(.slash)
        p.model.editDraft(1, row: newSlashRow, text: "/compact", save: slashDraft(p.model))
        await p.model.saveAndClose()
        #expect(p.isOpen)
        p.model.query = "compact"
        #expect(!p.model.isShown(newSlashRow))
        #expect(p.model.draftText(1).isEmpty)
        await p.model.saveAndClose()
        #expect(!p.isOpen)
    }

    // A text field of a row in the panel: Save ends its edit through the host of the panel, so
    // the typed text saves before Save waits, and Save closes Settings after the save.
    @Test func saveSavesTheTextOfTheFocusedField() async throws {
        let s = try await ShownSettings()
        defer { s.close() }
        let host = Self.snapField(s.model)
        s.host.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let text = try #require(Self.textFields(in: host).first)
        #expect(s.window.makeFirstResponder(text))
        let editor = try #require(s.window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("12", replacementRange: NSRange(location: NSNotFound, length: 0))
        await s.model.saveAndClose()
        #expect(s.store.settings.snapDistance == 12)
        #expect(!s.parts.isOpen)
    }

    // The end of the edit of the host ends an edit in the panel, also of the search field, and
    // keeps an edit outside the panel.
    @Test func theHostEndsTheEditOfAFieldOfThePanel() async throws {
        let s = try await ShownSettings()
        defer { s.close() }
        let search = try #require(s.host.searchFieldView)
        #expect(s.window.makeFirstResponder(search))
        let editor = try #require(s.window.firstResponder as? NSTextView)
        editor.insertText("fla", replacementRange: NSRange(location: NSNotFound, length: 0))
        s.host.endEditing()
        #expect(s.window.firstResponder === s.window)
        #expect(s.model.query == "fla")
        #expect(s.window.makeFirstResponder(s.other))
        s.host.endEditing()
        #expect(s.editingField === s.other)
    }

    // While Save runs, the text fields and the search field are off. They are on again after it.
    @Test func theFieldsAreOffWhileSaveRuns() async throws {
        let gate = WriteGate()
        defer { gate.openAll() }
        let s = try await ShownSettings(steps: gate.steps)
        defer { s.close() }
        let host = Self.snapField(s.model)
        s.host.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let field = try #require(Self.textFields(in: host).first)
        let search = try #require(s.host.searchFieldView)
        #expect(field.isEnabled && search.isEnabled)
        s.model.save(.general(.rowFlash)) { $0.rowFlash = false }
        try #require(await gate.waitUntilWriting())
        let save = Task.immediate { await s.model.saveAndClose() }
        #expect(await render(s.host) { !field.isEnabled && !search.isEnabled })
        #expect(s.model.isSaving)
        gate.open()
        await save.value
        #expect(await render(s.host) { field.isEnabled && search.isEnabled })
    }

    // MARK: - Helpers

    // The number of calls of a closure of a test.
    @MainActor
    private final class Counter {
        var count = 0
    }

    // The field of the snap distance: a whole number saves.
    static func snapField(_ model: SettingsModel) -> NSHostingView<DraftField> {
        let row = SettingsRowID.general(.snap)
        let field = DraftField(model: model, row: row, label: "Snap", saved: "8", width: 64) {
            text in
            guard let number = NumberRow.wholeNumber(text) else { return .refused("No.") }
            return .edit { $0.snapDistance = number }
        }
        let host = NSHostingView(rootView: field)
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        return host
    }

    static func textFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        var next: [NSView] = [view]
        while let item = next.popLast() {
            if let field = item as? NSTextField, field.isEditable { found.append(field) }
            next += item.subviews
        }
        return found
    }
}

extension ShownSettings {
    var store: SettingsStore { parts.store }
}
