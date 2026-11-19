import AppKit
import BifrostDailyUpdate
import BifrostSessions
import BifrostTestSupport
import Foundation
import SwiftUI
import Testing

@testable import BifrostSettings

// Settings > Daily update (docs/behaviour/daily-update.md, "Settings > Daily update"): the ticket
// source picker, the proposal of the tools, the work areas and the examples. The read of the MCP
// servers is a fake link, so no claude runs.

private let boardTools = [
    "mcp__board__list_items", "mcp__board__get_item", "mcp__board__update_item",
]
private let slackTools = ["mcp__plugin_slack_slack__slack_read_channel"]

private let inventory = MCPInventory(
    servers: [
        MCPServer(name: "board", status: "connected", tools: boardTools),
        MCPServer(name: "plugin:slack:slack", status: "connected", tools: slackTools),
        MCPServer(name: "claude.ai Claude Docs", status: "needs-auth"),
    ], tools: boardTools + slackTools)

// The texts that a field gave at the end of its edits.
@MainActor
private final class Ends {
    var texts: [String] = []
    var reverts = 0
}

// The text views of the many-line fields under the view.
@MainActor
private func areaViews(in view: NSView) -> [AreaTextView] {
    var found: [AreaTextView] = []
    var next: [NSView] = [view]
    while let item = next.popLast() {
        if let area = item as? AreaTextView { found.append(area) }
        next += item.subviews
    }
    return found
}

// The texts of the example boxes under the view, in sorted order: each many-line field but the
// format, which has the default template.
@MainActor
private func exampleTexts(in view: NSView) -> [String] {
    areaViews(in: view).map(\.string).filter { $0 != DailySettings.defaultTemplate }.sorted()
}

// What the fake links did.
@MainActor
private final class Calls {
    var reads = 0
    var panels = 0
    var asked: [ConfirmText] = []
    var answer = true
}

@MainActor
private func links(_ calls: Calls, read: InventoryRead = .found(inventory)) -> SettingsLinks {
    SettingsLinks(
        confirm: { text in
            calls.asked.append(text)
            return calls.answer
        },
        dailyUpdate: DailyUpdateLinks(
            readInventory: {
                calls.reads += 1
                return read
            }, openPanel: { calls.panels += 1 }))
}

@MainActor
@Suite("Settings > Daily update", .serialized, .timeLimit(.minutes(1)), .tags(.window))
struct DailyUpdateSectionTests {
    @Test func theRowsAreInOrder() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.dailyUpdate)
        #expect(SettingsModel.built.contains(.dailyUpdate))
        #expect(
            await shownLabels(DailyUpdateSection(model: p.model))
                == DailyUpdateRow.allCases.map(\.rawValue))
        // The search finds a row by its label.
        p.model.query = "deadline"
        #expect(await shownLabels(DailyUpdateSection(model: p.model)) == ["Deadline"])
    }

    // Every server is offered, also a Slack server (user decision, 2026-11-18). A server that
    // is not connected is refused with its status.
    @Test func everyServerIsOffered() async throws {
        let calls = Calls()
        let p = try await SettingsParts()
        p.model.links = links(calls)
        p.model.showTab(.dailyUpdate)
        let section = DailyUpdateSection(model: p.model)
        #expect(section.sourceChoices.map(\.name) == [""])
        await section.findServers()
        #expect(calls.reads == 1)
        #expect(
            section.sourceChoices.map(\.name) == [
                "", "board", "plugin:slack:slack", "claude.ai Claude Docs",
            ])
        #expect(await section.choose(server: "plugin:slack:slack")?.value == true)
        #expect(p.store.settings.dailyUpdate?.source.server == "plugin:slack:slack")
        #expect(section.choose(server: "claude.ai Claude Docs") == nil)
        #expect(p.model.error(of: section.id(.source))?.contains("needs sign-in") == true)
        #expect(p.store.settings.dailyUpdate?.source.server == "plugin:slack:slack")
    }

    @Test func theProposedToolsWaitForTheConfirm() async throws {
        let calls = Calls()
        let p = try await SettingsParts()
        p.model.links = links(calls)
        let section = DailyUpdateSection(model: p.model)
        await section.findServers()
        #expect(await section.choose(server: "board")?.value == true)
        // The server saves with no tools. The read tools wait, ticked.
        #expect(p.store.settings.dailyUpdate?.source.tools == [])
        let proposed = ["mcp__board__list_items", "mcp__board__get_item"]
        #expect(section.currentProposal?.tools == proposed)
        #expect(section.toolRows.map(\.on) == [true, true, false])
        // A tick changes the proposal only.
        let get = try #require(section.toolRows.first { $0.name == "get_item" })
        #expect(section.set(tool: get, on: false) == nil)
        #expect(section.currentProposal?.tools == ["mcp__board__list_items"])
        #expect(p.store.settings.dailyUpdate?.source.tools == [])
        // The confirm saves the proposal, and then each tick saves at once.
        #expect(await section.useProposedTools()?.value == true)
        #expect(p.store.settings.dailyUpdate?.source.tools == ["mcp__board__list_items"])
        #expect(section.currentProposal == nil)
        let again = try #require(section.toolRows.first { $0.name == "get_item" })
        #expect(await section.set(tool: again, on: true)?.value == true)
        #expect(
            p.store.settings.dailyUpdate?.source.tools == [
                "mcp__board__list_items", "mcp__board__get_item",
            ])
        // A tool with a write word never gets a tick.
        let update = try #require(section.toolRows.first { $0.name == "update_item" })
        #expect(update.write)
        #expect(section.set(tool: update, on: true) == nil)
    }

    @Test func aFailedReadSaysWhy() async throws {
        let p = try await SettingsParts()
        p.model.links = links(Calls(), read: .failed)
        let section = DailyUpdateSection(model: p.model)
        await section.findServers()
        #expect(p.model.dailyUpdate.readError == DailyUpdateRows.readFailed)
        p.model.links = links(Calls(), read: .noClaude)
        await section.findServers()
        #expect(p.model.dailyUpdate.readError == "Bifrost couldn't find Claude Code.")
        // The default link has no claude.
        p.model.links = SettingsLinks()
        await section.findServers()
        #expect(p.model.dailyUpdate.readError == DailyUpdateRows.noClaude)
    }

    @Test func aSecondAreaThatTakesAllIsRefused() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.dailyUpdate)
        let section = DailyUpdateSection(model: p.model)
        #expect(await section.addArea(id: "a1")?.value == true)
        #expect(await section.addArea(id: "a2")?.value == true)
        #expect(p.store.settings.dailyUpdate?.areas.map(\.name) == ["Work area 1", "Work area 2"])
        #expect(await section.set(area: "a1", takesRest: true)?.value == true)
        #expect(section.set(area: "a2", takesRest: true) == nil)
        #expect(p.model.error(of: section.id(.areas)) == DailyUpdateRows.restReason)
        #expect(p.store.settings.dailyUpdate?.areas.map(\.takesRest) == [true, false])
        // The flag can move after the first area gives it up.
        #expect(await section.set(area: "a1", takesRest: false)?.value == true)
        #expect(await section.set(area: "a2", takesRest: true)?.value == true)
        #expect(p.store.settings.dailyUpdate?.areas.map(\.takesRest) == [false, true])
    }

    @Test func atMostThreeExamples() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.dailyUpdate)
        let section = DailyUpdateSection(model: p.model)
        for _ in 0..<3 { #expect(await section.addExample()?.value == true) }
        #expect(p.store.settings.dailyUpdate?.format.examples.count == 3)
        let ids = p.model.dailyUpdate.exampleIDs
        #expect(Set(ids).count == 3)
        #expect(!section.canAddExample)
        #expect(section.addExample() == nil)
        #expect(p.model.error(of: section.id(.examples)) == DailyUpdateRows.examplesReason)
        #expect(p.store.settings.dailyUpdate?.format.examples.count == 3)
        // The edit of an open field ends before the remove.
        let ended = Ends()
        p.model.endEditing = { ended.reverts += 1 }
        #expect(await section.removeExample(at: 1)?.value == true)
        #expect(ended.reverts == 1)
        #expect(section.canAddExample)
        // The other boxes keep their identity.
        #expect(p.model.dailyUpdate.exampleIDs == [ids[0], ids[2]])
        #expect(section.exampleItems.map(\.id) == [ids[0].uuidString, ids[2].uuidString])
        #expect(p.model.dailyUpdate.pendingExamples == nil)
    }

    // A remove takes its box with the text that the box kept. Box 2 of 3 holds a refused text;
    // after the remove of example 2, the box of the 3rd example shows its own text, and the end
    // of an edit there saves nothing over it.
    @Test func aRemoveTakesTheBoxAndItsRefusedText() async throws {
        let shown = try await ShownSettings()
        defer { shown.close() }
        var daily = DailySettings.defaults
        daily.format.examples = ["one", "two", "three"]
        try await shown.store.edit { $0.dailyUpdate = daily }
        shown.model.dailyUpdate.syncExamples(daily.format.examples)
        shown.model.showTab(.dailyUpdate)
        var found: AreaTextView?
        await render(shown.host) {
            found = areaViews(in: shown.host).first { $0.string == "two" }
            return found != nil
        }
        let box = try #require(found)
        let long = String(repeating: "e", count: 4001)
        #expect(shown.window.makeFirstResponder(box))
        box.selectAll(nil)
        box.insertText(long, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(shown.window.makeFirstResponder(shown.other))
        let section = DailyUpdateSection(model: shown.model)
        #expect(shown.model.error(of: section.id(.examples)) == DailyUpdateRows.examplesReason)
        #expect(await section.removeExample(at: 1)?.value == true)
        #expect(shown.store.settings.dailyUpdate?.format.examples == ["one", "three"])
        await render(shown.host) { exampleTexts(in: shown.host) == ["one", "three"] }
        #expect(exampleTexts(in: shown.host) == ["one", "three"])
        let third = try #require(areaViews(in: shown.host).first { $0.string == "three" })
        #expect(shown.window.makeFirstResponder(third))
        #expect(shown.window.makeFirstResponder(shown.other))
        #expect(shown.store.settings.dailyUpdate?.format.examples == ["one", "three"])
    }

    @Test func theTextRowsCheckTheirValues() async throws {
        let p = try await SettingsParts()
        p.model.showTab(.dailyUpdate)
        let section = DailyUpdateSection(model: p.model)
        guard case .refused(let reason) = section.saveTime("9.30", deadline: false) else {
            Issue.record("A bad time saved.")
            return
        }
        #expect(reason == DailyUpdateRows.timeReason)
        guard case .refused(let gap) = section.saveTime("09:55", deadline: false) else {
            Issue.record("A time 5 minutes before the deadline saved.")
            return
        }
        #expect(gap == DailyUpdateRows.gapReason)
        guard case .edit(let change) = section.saveTime("10:30", deadline: true) else {
            Issue.record("A good deadline was refused.")
            return
        }
        try await p.store.edit(change)
        #expect(p.store.settings.dailyUpdate?.deadline == ClockTime(hour: 10, minute: 30))
        // The last day cannot go.
        var days = DailySettings.defaults
        days.days = [3]
        try await p.store.edit { $0.dailyUpdate = days }
        #expect(section.toggle(day: 3) == nil)
        #expect(p.model.error(of: section.id(.days)) == DailyUpdateRows.daysReason)
    }

    @Test func removeAsksFirst() async throws {
        let calls = Calls()
        let p = try await SettingsParts()
        p.model.links = links(calls)
        let section = DailyUpdateSection(model: p.model)
        #expect(await section.addArea(id: "a1")?.value == true)
        calls.answer = false
        #expect(await section.removeArea("a1").value == false)
        #expect(calls.asked.map(\.title) == ["Remove Work area 1?"])
        #expect(p.store.settings.dailyUpdate?.areas.count == 1)
        calls.answer = true
        #expect(await section.removeArea("a1").value == true)
        #expect(p.store.settings.dailyUpdate?.areas.isEmpty == true)
    }

    // The format, an example and the description of an area each refuse a text over their
    // limit with their reason. A text that is the saved value saves nothing.
    @Test func theManyLineFieldsRefuseATextOverTheirLimit() async throws {
        let p = try await SettingsParts()
        let section = DailyUpdateSection(model: p.model)
        #expect(await section.addExample()?.value == true)
        #expect(await section.addArea(id: "a1")?.value == true)
        let template = DailySettings.defaultTemplate
        let cases: [(String, String, (String) -> TextSave, String)] = [
            (String(repeating: "f", count: 2001), template, section.saveTemplate,
             DailyUpdateRows.formatReason),
            (String(repeating: "e", count: 4001), "", { section.saveExample($0, at: 0) },
             DailyUpdateRows.examplesReason),
            (String(repeating: "d", count: 501), "", { section.saveArea("a1", \.description, $0) },
             DailyUpdateRows.descriptionReason),
        ]
        for (text, saved, save, reason) in cases {
            guard case .refused(let given) = DraftArea.end(text, saved: saved, save: save) else {
                Issue.record("A text over the limit saved: \(reason)")
                continue
            }
            #expect(given == reason)
        }
        let same = DraftArea.end(template + "\n", saved: template, save: section.saveTemplate)
        guard case .nothing = same else {
            Issue.record("The saved template saved again.")
            return
        }
        guard case .save = DraftArea.end("**Mine**", saved: template, save: section.saveTemplate)
        else {
            Issue.record("A good template did not save.")
            return
        }
    }

    // A refused text stays in the field after the next update of the view, here a new Interface
    // scale, so the user can correct it.
    @Test func aRefusedFormatStaysInTheField() async throws {
        let shown = try await ShownSettings()
        defer { shown.close() }
        shown.model.showTab(.dailyUpdate)
        let template = DailySettings.defaultTemplate
        var found: AreaTextView?
        await render(shown.host) {
            found = areaViews(in: shown.host).first { $0.string == template }
            return found != nil
        }
        let view = try #require(found)
        let long = String(repeating: "f", count: 2001)
        #expect(shown.window.makeFirstResponder(view))
        view.selectAll(nil)
        view.insertText(long, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(shown.window.makeFirstResponder(shown.other))
        let row = SettingsRowID(.dailyUpdate, .found(DailyUpdateRow.format.rawValue))
        #expect(shown.model.error(of: row) == DailyUpdateRows.formatReason)
        let size = view.font?.pointSize
        try await shown.store.edit { $0.interfaceScale = 120 }
        await render(shown.host) { view.font?.pointSize != size }
        #expect(view.string == long)
        #expect(shown.store.settings.dailyUpdate?.format.template ?? template == template)
    }

    // A many-line field has its own undo. Esc puts the saved text back with no undo and saves
    // nothing, and a new saved value clears the undo too.
    @Test func anEscapeAndANewValueClearTheUndoOfAField() {
        UITestApp.prepare()
        let ends = Ends()
        let area = SettingsTextArea(
            shown: "Saved", saved: "Saved", enabled: true, font: .systemFont(ofSize: 12),
            onEnd: { ends.texts.append($0) }, onRevert: { ends.reverts += 1 })
        let coordinator = area.makeCoordinator()
        let view = SettingsTextArea.makeTextView()
        view.delegate = coordinator
        view.show("Saved")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        window.contentView?.addSubview(view)
        #expect(window.makeFirstResponder(view))
        view.insertText(" more", replacementRange: NSRange(location: 5, length: 0))
        #expect(view.undoManager?.canUndo == true)
        let escape = #selector(NSResponder.cancelOperation(_:))
        #expect(coordinator.textView(view, doCommandBy: escape))
        #expect(view.string == "Saved")
        #expect(view.undoManager?.canUndo == false)
        #expect(ends.texts.isEmpty)
        #expect(ends.reverts == 1)
        #expect(window.makeFirstResponder(view))
        view.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        #expect(window.makeFirstResponder(nil))
        #expect(ends.texts == ["Saved!"])
        view.show("Other")
        #expect(view.undoManager?.canUndo == false)
    }

    @Test func theNoticeAndThePanelButton() async throws {
        let calls = Calls()
        let p = try await SettingsParts()
        p.model.links = SettingsLinks(
            dailyUpdate: DailyUpdateLinks(
                unavailable: { DailyStoreError.otherCopy.message },
                openPanel: { calls.panels += 1 }))
        let section = DailyUpdateSection(model: p.model)
        #expect(section.notice == "Daily update is running in another copy of Bifrost.")
        section.openPanel()
        #expect(calls.panels == 1)
        // A search hides the notice.
        p.model.query = "deadline"
        #expect(section.notice == nil)
    }
}
