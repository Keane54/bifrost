import BifrostFoundation
import BifrostLayout
import BifrostTestSupport
import Testing

@testable import BifrostKeyboard
@testable import BifrostSettings

// The model of the Settings panel: the saves of the rows, the drafts and the Save button
// (docs/behaviour/settings.md, "Saving"). Each test uses a real settings store in a temporary
// folder. A WriteGate holds a write, so a test can see what waits for it.
@MainActor
@Suite("the Settings model", .serialized, .timeLimit(.minutes(1)))
struct SettingsModelTests {
    // Save adds a typed command one time. The field is empty before the save ends, so a second
    // Save after the end adds nothing.
    @Test func aSecondSaveAfterTheEndDoesNotAddTheCommandAgain() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.slash)
        p.model.editDraft(1, row: newSlashRow, text: " /review ", save: slashDraft(p.model))
        await p.model.saveAndClose()
        #expect(p.store.settings.slashCommands == ["/compact", "/clear", "/context", "/review"])
        #expect(p.model.draftText(1).isEmpty)
        #expect(!p.isOpen)
        p.model.open()
        await p.model.saveAndClose()
        #expect(p.store.settings.slashCommands == ["/compact", "/clear", "/context", "/review"])
        #expect(!p.isOpen)
    }

    // While a dialog of the window shows, for example the confirmation of Reset all keys, Save
    // does nothing: a reset that the user confirms later cannot save after Settings closed.
    @Test func saveDoesNothingWhileADialogShows() async throws {
        let p = try await SettingsParts()
        let dialog = DialogFlag()
        p.model.links.dialogShows = { dialog.shows }
        await p.model.saveAndClose()
        #expect(p.isOpen)
        dialog.shows = false
        await p.model.saveAndClose()
        #expect(!p.isOpen)
    }

    // A save that waits for its write keeps Settings open. Save closes Settings when the write
    // ends.
    @Test func aSuspendedStoreSaveKeepsSettingsOpenUntilItEnds() async throws {
        let gate = WriteGate()
        defer { gate.openAll() }
        let p = try await SettingsParts(steps: gate.steps)
        let flash = p.model.save(.general(.rowFlash)) { $0.rowFlash = false }
        try #require(await gate.waitUntilWriting())
        // The Save runs at once to its wait.
        let save = Task.immediate { await p.model.saveAndClose() }
        #expect(p.model.isSaving)
        #expect(p.isOpen)
        gate.open()
        #expect(await flash.value)
        await save.value
        #expect(!p.model.isSaving)
        #expect(!p.isOpen)
        #expect(!p.store.settings.rowFlash)
    }

    // A refused draft keeps Settings open with its reason on its row. A new text clears the
    // reason, and an empty field lets Save close Settings.
    @Test func aRefusedDraftKeepsSettingsOpen() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.slash)
        p.model.editDraft(1, row: newSlashRow, text: "/compact", save: slashDraft(p.model))
        await p.model.saveAndClose()
        #expect(p.isOpen)
        #expect(p.model.error(of: newSlashRow) == SettingsRefusal.slashCopy.message)
        #expect(p.model.draftText(1) == "/compact")
        // Another refused text gives its own reason.
        let long = "/" + String(repeating: "a", count: 300)
        p.model.editDraft(1, row: newSlashRow, text: long, save: slashDraft(p.model))
        #expect(p.model.error(of: newSlashRow) == nil)
        await p.model.saveAndClose()
        #expect(p.isOpen)
        #expect(p.model.error(of: newSlashRow) == SettingsRefusal.slashTooLong.message)
        p.model.editDraft(1, row: newSlashRow, text: " ", save: slashDraft(p.model))
        await p.model.saveAndClose()
        #expect(!p.isOpen)
        #expect(p.store.settings.slashCommands == ["/compact", "/clear", "/context"])
    }

    // Save first ends the edit of the focused field, so the save of its text starts before Save
    // waits. The text then counts: a refused text keeps Settings open. The model keeps its
    // closures, so a closure holds the model weakly: else the parts never go, and their folder
    // stays in the temporary folder.
    @Test func saveEndsTheEditOfTheFocusedFieldFirst() async throws {
        let p = try await SettingsParts()
        let row = SettingsRowID.general(.escalation)
        var ends = 0
        p.model.endEditing = { [weak model = p.model] in
            ends += 1
            model?.save(row) { $0.escalationMinutes = 999 }
        }
        await p.model.saveAndClose()
        #expect(ends == 1)
        #expect(p.isOpen)
        #expect(p.model.error(of: row) == SettingsError.refused(.field(.escalationMinutes)).message)
        p.model.endEditing = { [weak model = p.model] in
            model?.save(row) { $0.escalationMinutes = 20 }
        }
        await p.model.saveAndClose()
        #expect(!p.isOpen)
        #expect(p.store.settings.escalationMinutes == 20)
    }

    // One Save runs at a time. A second Save during the wait of the first does nothing, and
    // the draft fields take no new text until the first Save ends.
    @Test func oneSaveRunsAtATime() async throws {
        let gate = WriteGate()
        defer { gate.openAll() }
        let p = try await SettingsParts(steps: gate.steps)
        p.model.showTab(.slash)
        p.model.editDraft(1, row: newSlashRow, text: "/review", save: slashDraft(p.model))
        let first = Task.immediate { await p.model.saveAndClose() }
        try #require(await gate.waitUntilWriting())
        var ends = 0
        p.model.endEditing = { ends += 1 }
        await p.model.saveAndClose()
        #expect(ends == 0)
        p.model.editDraft(1, row: newSlashRow, text: "/other", save: slashDraft(p.model))
        #expect(p.model.saveDraft(1) == nil)
        #expect(p.model.draftText(1) == "/review")
        #expect(p.isOpen)
        gate.open()
        await first.value
        #expect(!p.isOpen)
        #expect(p.store.settings.slashCommands == ["/compact", "/clear", "/context", "/review"])
    }

    // Enter saves a draft, and Save starts while that write still runs. The draft is out of the
    // drafts of Save, so Save waits for the save of Enter and adds nothing more. The edit of this
    // draft does not check for a copy, so a second save would add the command again.
    @Test func saveDuringTheSaveOfEnterAddsTheCommandOneTime() async throws {
        let gate = WriteGate()
        defer { gate.openAll() }
        let p = try await SettingsParts(steps: gate.steps)
        p.model.showTab(.slash)
        let append: (String) -> TextSave = { text in .edit { $0.slashCommands.append(text) } }
        p.model.editDraft(1, row: newSlashRow, text: "/review", save: append)
        let enter = try #require(p.model.saveDraft(1))
        #expect(p.model.saveDraft(1) == nil)
        try #require(await gate.waitUntilWriting())
        let save = Task.immediate { await p.model.saveAndClose() }
        #expect(p.isOpen)
        gate.open()
        #expect(await enter.value)
        await save.value
        #expect(p.store.settings.slashCommands == ["/compact", "/clear", "/context", "/review"])
        #expect(p.model.error(of: newSlashRow) == nil)
        #expect(!p.isOpen)
        #expect(gate.writes == 1)
    }

    // A save of Enter that fails puts the draft back, so a later Save tries it again and keeps
    // Settings open with the reason.
    @Test func aFailedSaveOfEnterPutsTheDraftBack() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.slash)
        let refused: (String) -> TextSave = { _ in .edit { $0.escalationMinutes = 999 } }
        p.model.editDraft(1, row: newSlashRow, text: "/review", save: refused)
        let enter = try #require(p.model.saveDraft(1))
        #expect(await enter.value == false)
        #expect(p.model.draftText(1) == "/review")
        let reason = SettingsError.refused(.field(.escalationMinutes)).message
        #expect(p.model.error(of: newSlashRow) == reason)
        await p.model.saveAndClose()
        #expect(p.isOpen)
        #expect(p.model.error(of: newSlashRow) == reason)
    }

    // While Save waits, a tab click, an open at a section and a new query change nothing, so a
    // save that fails later still keeps Settings open with its reason.
    @Test func theTabsAndTheSearchWaitForSave() async throws {
        let gate = WriteGate()
        defer { gate.openAll() }
        let p = try await SettingsParts(steps: gate.steps)
        let escalation = SettingsRowID.general(.escalation)
        p.model.save(.general(.rowFlash)) { $0.rowFlash = false }
        try #require(await gate.waitUntilWriting())
        // This edit waits for the held write, then the check refuses it.
        p.model.save(escalation) { $0.escalationMinutes = 999 }
        let save = Task.immediate { await p.model.saveAndClose() }
        p.model.showTab(.keys)
        p.model.open(.slash)
        p.model.query = "flash"
        #expect(p.model.section == .general)
        #expect(p.model.query.isEmpty)
        gate.open()
        await save.value
        #expect(p.isOpen)
        let reason = SettingsError.refused(.field(.escalationMinutes)).message
        #expect(p.model.error(of: escalation) == reason)
        p.model.showTab(.keys)
        #expect(p.model.section == .keys)
    }

    // A change of the settings from outside the panel can hide a row during a search. The row
    // then drops its error.
    @Test func aChangeFromOutsideDropsARowThatTheSearchHides() async throws {
        let p = try await SettingsParts()
        let list = SettingsRowID(.slash, .withHit("list"))
        p.model.query = "/context"
        #expect(p.model.isShown(list))
        p.model.refuse(list, reason: "Not now.")
        #expect(p.model.error(of: list) == "Not now.")
        try await p.store.edit { $0.slashCommands = ["/compact"] }
        try #require(await waitUntil { p.model.error(of: list) == nil })
        #expect(!p.model.isShown(list))
        await p.model.saveAndClose()
        #expect(!p.isOpen)
    }

    // A close of the panel during the wait of Save stops that Save. It does not close a later
    // view of the panel.
    @Test func aCloseOfThePanelStopsAWaitingSave() async throws {
        let gate = WriteGate()
        defer { gate.openAll() }
        let p = try await SettingsParts(steps: gate.steps)
        p.model.save(.general(.rowFlash)) { $0.rowFlash = false }
        try #require(await gate.waitUntilWriting())
        let save = Task.immediate { await p.model.saveAndClose() }
        p.model.close()
        p.model.panelClosed()
        await save.value
        p.model.open()
        gate.open()
        try #require(await waitUntil { !p.store.settings.rowFlash })
        #expect(p.isOpen)
        #expect(!p.model.isSaving)
    }

    // A good save of a row clears its error. A closed error no longer keeps Settings open. The
    // last save that a row started gives its state.
    @Test func theLastSaveOfARowGivesItsError() async throws {
        let p = try await SettingsParts()
        let row = SettingsRowID.general(.poll)
        let reason = SettingsError.refused(.field(.pollSeconds)).message
        let bad = p.model.save(row) { $0.pollSeconds = 0 }
        let good = p.model.save(row) { $0.pollSeconds = 5 }
        #expect(await bad.value == false)
        #expect(await good.value)
        #expect(p.model.error(of: row) == nil)
        #expect(await p.model.save(row) { $0.pollSeconds = 0 }.value == false)
        #expect(p.model.error(of: row) == reason)
        p.model.closeError(row)
        #expect(p.model.error(of: row) == nil)
        await p.model.saveAndClose()
        #expect(!p.isOpen)
        #expect(p.store.settings.pollSeconds == 5)
    }

    // A refusal before a save, such as a text that is not a number, shows on its row and keeps
    // Settings open.
    @Test func aRefusalBeforeASaveShowsOnItsRow() async throws {
        let p = try await SettingsParts()
        let row = SettingsRowID.general(.snap)
        p.model.refuse(row, reason: NumberRow.notANumber(0...32))
        #expect(p.model.error(of: row) == "Enter a whole number from 0 to 32.")
        await p.model.saveAndClose()
        #expect(p.isOpen)
        #expect(NumberRow.wholeNumber("12") == 12)
        #expect(NumberRow.wholeNumber("12.0") == 12)
        #expect(NumberRow.wholeNumber("1e1") == 10)
        #expect(NumberRow.wholeNumber("12.5") == nil)
        #expect(NumberRow.wholeNumber("twelve") == nil)
        #expect(NumberRow.wholeNumber("") == nil)
    }

    // A screen reader hears the number of matches one time for each new text. No search tells
    // nothing.
    @Test func theCountLineIsToldOneTimeForEachText() async throws {
        let p = try await SettingsParts()
        p.model.query = "flash"
        p.model.query = "flash "
        p.model.query = "zzz"
        p.model.query = ""
        #expect(p.said == ["1 setting matches.", #"No settings match "zzz"."#])
    }

    // The search looks only at the rows that the panel shows: the General rows with the
    // Introduction row, the slash commands, the keys, the Reviews rows, the Daily update rows, the
    // words of Live details and Skills, and the Updates rows.
    @Test func theSearchLooksOnlyAtTheShownRows() async throws {
        let p = try await SettingsParts()
        let index = p.model.index
        #expect(
            index.map(\.id) == [
                .general, .slash, .keys, .reviews, .dailyUpdate, .live, .skills, .updates,
            ])
        #expect(index.first?.rows.map(\.id) == GeneralRow.allCases.map(\.rawValue))
        p.model.query = "introduction"
        #expect(p.model.hits?.map(\.id) == [.general])
        #expect(p.model.isShown(.general(.introduction)))
        // The live model gives the words of the two sections.
        p.model.query = "checking"
        #expect(p.model.hits?.map(\.id) == [.live, .skills])
        p.model.extraIndex(.live, words: ["Live details", "plugin"])
        p.model.query = "checking"
        #expect(p.model.hits?.map(\.id) == [.skills])
    }

    // Cmd+F needs the focus in Settings, or no focus and Settings on top. A Bifrost key on
    // Cmd+F acts first.
    @Test func cmdFNeedsTheFocusInSettingsOrSettingsOnTop() async throws {
        let p = try await SettingsParts()
        let cmdF = KeyEvent(
            keyCode: KeyCode(rawValue: 3), characters: "f", charactersIgnoringModifiers: "f",
            modifiers: .command)
        #expect(p.model.isSearchShortcut(cmdF, focus: .settings))
        #expect(p.model.isSearchShortcut(cmdF, focus: .none))
        #expect(!p.model.isSearchShortcut(cmdF, focus: .other))
        p.layout.apply(.open(.watchlist))
        #expect(!p.model.isSearchShortcut(cmdF, focus: .none))
        #expect(p.model.isSearchShortcut(cmdF, focus: .settings))
        try await p.store.edit { $0.keys = .object(["event-log:mod": .string("Mod+F")]) }
        #expect(!p.model.isSearchShortcut(cmdF, focus: .settings))
    }

    // The model reads the problem of the login item that the services keep, so General can show
    // its text under Start at login.
    @Test func theModelReadsTheProblemOfTheLoginItem() async throws {
        let p = try await SettingsParts()
        #expect(p.model.links.loginItemProblem() == nil)
        p.model.links.loginItemProblem = { .needsApproval }
        #expect(p.model.links.loginItemProblem()?.message == LoginItemError.needsApproval.message)
    }

    // A tab shows its section and ends the search. The Introduction row asks for the
    // introduction, and the section stays when Settings closes.
    @Test func aTabEndsTheSearchAndTheSectionStays() async throws {
        let p = try await SettingsParts()
        p.model.query = "flash"
        #expect(p.model.activeTab == nil)
        p.model.showTab(.keys)
        #expect(p.model.query.isEmpty)
        #expect(p.model.activeTab == .keys)
        p.model.close()
        p.model.panelClosed()
        p.model.open()
        #expect(p.model.section == .keys)
        p.model.open(.slash)
        #expect(p.model.section == .slash)
        // With no Setup dialog, the Introduction row changes nothing.
        p.model.showIntroduction()
        #expect(p.model.section == .slash)
    }
}

// A dialog that shows until the test ends it.
@MainActor
private final class DialogFlag {
    var shows = true
}
