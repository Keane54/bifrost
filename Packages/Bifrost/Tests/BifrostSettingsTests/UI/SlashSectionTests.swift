import AppKit
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostKeyboard
@testable import BifrostSettings

// Settings > Slash commands (docs/behaviour/settings.md, "The slash list"): the field for a new
// command, Move up, Move down and Remove, the refusal reasons of the list and the empty list. The
// tests that show views use a window that is never ordered front.
@MainActor
@Suite("Settings > Slash commands", .serialized, .testTimeLimit, .tags(.window))
struct SlashSectionTests {
    // Enter in the field adds the trimmed command at the end of the list, and the field is empty
    // again. Move up, Move down and Remove change the list, and the rows show the new order. The
    // first command does not move up, and the last one does not move down.
    @Test func addMovesAndRemovesACommand() async throws {
        let s = try await ShownSettings()
        defer { s.close() }
        s.model.showTab(.slash)
        let field = try #require(await s.field(SlashSection.fieldLabel))
        let editor = try #require(s.type(" /review ", into: field))
        #expect(s.model.draftText(SlashSection.draftID) == " /review ")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let added = ["/compact", "/clear", "/context", "/review"]
        #expect(await waitUntil { s.store.settings.slashCommands == added })
        // The store has the new list before the save of the draft ends, so the test waits for
        // the end. A synchronous render cannot run the rest of the save on the main actor.
        #expect(await waitUntil { s.model.draftText(SlashSection.draftID).isEmpty })
        #expect(await waitUntil { editor.string.isEmpty })
        #expect(s.model.error(of: SlashSection.newRow) == nil)
        let section = SlashSection(model: s.model, hit: nil)
        #expect(await shownLabels(section) == added)
        #expect(await section.move("/review", by: -1).value)
        #expect(s.store.settings.slashCommands == ["/compact", "/clear", "/review", "/context"])
        #expect(await section.move("/compact", by: -1).value)
        #expect(await section.move("/context", by: 1).value)
        #expect(s.store.settings.slashCommands == ["/compact", "/clear", "/review", "/context"])
        #expect(await section.move("/compact", by: 1).value)
        #expect(await section.remove("/review").value)
        let moved = ["/clear", "/compact", "/context"]
        #expect(s.store.settings.slashCommands == moved)
        #expect(await shownLabels(section) == moved)
        #expect(s.model.error(of: SlashSection.listRow) == nil)
    }

    // A command that is already in the list is refused with its reason on the row of the field,
    // before a save starts, and the field keeps its text. A good save of the list does not clear
    // that reason, because the field is a row of its own. Save keeps Settings open while the
    // field has the refused text. A full list gives its own reason.
    @Test func aCopyIsRefusedWithItsReason() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.slash)
        let section = SlashSection(model: p.model, hit: nil)
        section.edit(" /compact ")
        #expect(section.add() == nil)
        #expect(p.model.error(of: SlashSection.newRow) == SettingsRefusal.slashCopy.message)
        #expect(SettingsRefusal.slashCopy.message == "That command is already in the list.")
        #expect(p.model.draftText(SlashSection.draftID) == " /compact ")
        #expect(p.store.settings.slashCommands == ["/compact", "/clear", "/context"])
        #expect(await section.move("/clear", by: -1).value)
        #expect(p.model.error(of: SlashSection.newRow) == SettingsRefusal.slashCopy.message)
        await p.model.saveAndClose()
        #expect(p.isOpen)
        // A new text clears the reason. A full list refuses the next command.
        section.edit("/review")
        #expect(p.model.error(of: SlashSection.newRow) == nil)
        let full = (1...SettingsText.maxSlashCommands).map { "/c\($0)" }
        #expect(await p.model.save(SlashSection.listRow) { $0.slashCommands = full }.value)
        #expect(section.add() == nil)
        #expect(p.model.error(of: SlashSection.newRow) == SettingsRefusal.slashFull.message)
        #expect(SettingsRefusal.slashFull.message == "You can keep up to 12 commands.")
        #expect(p.store.settings.slashCommands == full)
    }

    // The edit of a command adds it to the newest list. When an earlier save gave that list the
    // command, the check of the settings refuses the edit, so the command is never there two
    // times.
    @Test func aCommandThatAnEarlierSaveAddedIsRefused() async throws {
        let gate = WriteGate()
        defer { gate.openAll() }
        let p = try await SettingsParts(steps: gate.steps)
        p.model.showTab(.slash)
        let section = SlashSection(model: p.model, hit: nil)
        let earlier = p.model.save(SlashSection.listRow) { $0.slashCommands.append("/review") }
        try #require(await gate.waitUntilWriting())
        section.edit("/review")
        let enter = try #require(section.add())
        gate.openAll()
        #expect(await earlier.value)
        #expect(await enter.value == false)
        #expect(p.store.settings.slashCommands == ["/compact", "/clear", "/context", "/review"])
        #expect(p.model.error(of: SlashSection.newRow) == SettingsRefusal.slashList.message)
        #expect(p.model.draftText(SlashSection.draftID) == "/review")
    }

    // Move up and Remove find their command in the newest list. An earlier save that waits at
    // the write changes the list first, so each later change acts on that list, not on the list
    // of the click.
    @Test func moveAndRemoveActOnTheNewestList() async throws {
        let gate = WriteGate()
        defer { gate.openAll() }
        let p = try await SettingsParts(steps: gate.steps)
        p.model.showTab(.slash)
        let section = SlashSection(model: p.model, hit: nil)
        let earlier = section.remove("/clear")
        try #require(await gate.waitUntilWriting())
        #expect(p.store.settings.slashCommands == ["/compact", "/clear", "/context"])
        let move = section.move("/context", by: -1)
        let remove = section.remove("/compact")
        gate.openAll()
        #expect(await earlier.value)
        #expect(await move.value)
        #expect(await remove.value)
        // On the list of the click, the move would give /context before /clear.
        #expect(p.store.settings.slashCommands == ["/context"])
        #expect(p.model.error(of: SlashSection.listRow) == nil)
    }

    // An empty list shows "No commands yet." with the whole section. A search shows only the
    // commands that match, with no field and no empty line.
    @Test func theEmptyListShowsItsText() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.slash)
        let section = SlashSection(model: p.model, hit: nil)
        #expect(SlashSection.emptyText == "No commands yet.")
        #expect(!section.showsEmptyText)
        for command in ["/compact", "/clear", "/context"] {
            #expect(await section.remove(command).value)
        }
        #expect(p.store.settings.slashCommands.isEmpty)
        #expect(section.showsEmptyText)
        #expect(section.shown.isEmpty)
        // The title of the section still finds the empty list.
        p.model.query = "slash"
        guard case .hits(let hits) = p.model.content, let hit = hits.first else {
            Issue.record("The title did not find the section.")
            return
        }
        #expect(hit.whole)
        #expect(SlashSection(model: p.model, hit: hit).showsEmptyText)
        // A search for a command shows that command only.
        p.model.query = ""
        #expect(await p.model.save(SlashSection.listRow) { $0.slashCommands = ["/a", "/b"] }.value)
        p.model.query = "/b"
        guard case .hits(let found) = p.model.content, let match = found.first else {
            Issue.record("The search did not find /b.")
            return
        }
        let shown = SlashSection(model: p.model, hit: match)
        #expect(shown.shown == ["/b"])
        #expect(!shown.showsEmptyText)
        #expect(!p.model.isShown(SlashSection.newRow))
        #expect(await shownLabels(shown) == ["/b"])
    }
}
