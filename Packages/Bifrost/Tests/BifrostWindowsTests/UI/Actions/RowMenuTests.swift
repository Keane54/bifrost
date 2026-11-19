// The row menu of the Overview on the Bifrost menu (docs/behaviour/actions.md, "The row menu"):
// the entries of RowMenuModel in order, a disabled entry in its place with the title and the
// reason as its tooltip, the radio rows of Set priority and Change colour with their colour
// squares, the entries of the row of now while the menu is open, a press outside that only closes
// the menu, and a choice that runs its action on the row of now.
import AppKit
import BifrostLayout
import BifrostLook
import BifrostSessions
import BifrostTestSupport
import Foundation
import Observation
import Testing

@testable import BifrostWindows

// The Overview of the harness in a window that is never ordered front, with the row menu of the
// runner on the menu of the driver (ActionRunner.attach).
@MainActor
private final class OverviewWindow {
    let window = MenuDriver.window()
    let panels: OverviewPanels
    let body: OverviewPanel

    init(_ h: ActionsHarness, menu: BifrostMenu) async throws {
        let id = panel("overview:1")
        let model = OverviewModel(
            store: h.store, sessions: h.list, selection: h.selection, layout: h.layout,
            clock: h.clock, now: { Date(timeIntervalSince1970: 0) })
        panels = OverviewPanels(model: model, look: h.look, filter: { nil })
        h.layout.apply(.open(id))
        body = try #require(panels.body(for: id) as? OverviewPanel)
        let content = try #require(window.contentView)
        body.frame = content.bounds
        content.addSubview(body)
        h.runner.attach(model, menu: menu)
        let (body, rows) = (body, h.list)
        await waitUntil(within: .seconds(10)) {
            body.rows.input?.rows.count == rows.rows.count
                && body.rows.table.numberOfRows == rows.rows.count
        }
        body.layoutSubtreeIfNeeded()
    }

    var table: OverviewTable { body.rows.table }

    // The row IDs in the order of the table.
    var shownIDs: [String] { body.rows.input?.rows.map(\.sessionId) ?? [] }

    // A point in the row, in the coordinates of the table.
    func point(row: Int) -> NSPoint {
        let rect = table.rect(ofRow: row)
        return NSPoint(x: rect.minX + 40, y: rect.midY)
    }
}

@Suite("the row menu", .serialized, .timeLimit(.minutes(1)), .tags(.window))
@MainActor
struct RowMenuTests {
    // The ID of each row, with "-" for a separator.
    private func ids(_ rows: [MenuRow]) -> [String] {
        rows.map { $0.id ?? "-" }
    }

    @Test func theMenuHasTheEntriesInOrder() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)], all: [Entry.stopped(s2)])
        let owned = try #require(h.row(s1))
        #expect(
            ids(RowMenu.rows(owned, runner: h.runner)) == [
                "open", "send-message", "run-slash", "compact", "hand-over", "interrupt", "-",
                "set-priority", "watch-add", "rename", "show-info", "copy-id", "open-project",
                "open-in-terminal", "-", "stop", "delete",
            ])
        let labels = RowMenu.rows(owned, runner: h.runner).compactMap(\.spec?.label)
        #expect(labels.first == "Open")
        #expect(labels.contains("Send message..."))
        #expect(labels.last == "Delete session...")
        // With the chat open, Close window takes the place of Open. A parked row has Resume.
        h.layout.openChat(s2)
        let parked = try #require(h.row(s2))
        #expect(
            ids(RowMenu.rows(parked, runner: h.runner)) == [
                "send-message", "run-slash", "compact", "hand-over", "interrupt", "-",
                "set-priority", "watch-add", "rename", "show-info", "copy-id", "open-project",
                "open-in-terminal", "-", "resume", "close-window", "stop", "delete",
            ])
    }

    @Test func aDisabledItemHasItsReasonAsTheTooltip() async throws {
        let h = try await ActionsHarness(all: [Entry.stopped(s1)])
        let row = try #require(h.row(s1))
        let rows = RowMenu.rows(row, runner: h.runner)
        let stop = try #require(rows.first { $0.id == "stop" }?.spec)
        #expect(!stop.enabled)
        #expect(stop.reason == "Stop session\n\(ActionReasons.noProcess)")
        // A disabled submenu keeps its place and its tooltip, and its rows do not open.
        let slash = try #require(rows.first { $0.id == "run-slash" })
        #expect(slash.spec?.enabled == false)
        #expect(slash.spec?.reason == "Run slash command\n\(ActionReasons.parked)")
        #expect(slash.submenu == nil)
        // An enabled entry has no tooltip.
        #expect(rows.first { $0.id == "rename" }?.spec?.reason == nil)
    }

    @Test func thePrioritySubmenuChecksTheCurrentPriority() async throws {
        let h = try await ActionsHarness(
            store: RegistryStore(priorities: [s1: .p3], watch: [WatchEntry(s1, .amber)]),
            active: [Entry.running(s1)])
        let row = try #require(h.row(s1))
        let rows = RowMenu.rows(row, runner: h.runner)
        let priority = try #require(rows.first { $0.id == "set-priority" }?.submenu)
        let expected = (1...5).map { number in
            MenuRow.radio(
                MenuItemSpec(
                    id: "set-priority/\(number)", label: "\(number)",
                    swatch: ThemeTokens.priority(number)),
                checked: number == 3)
        }
        let none = MenuRow.radio(
            MenuItemSpec(id: "set-priority/none", label: "None", swatchSpace: true),
            checked: false)
        #expect(priority == expected + [none])
        // Change colour checks the watch colour, with the square of each colour.
        let colours = try #require(rows.first { $0.id == "watch-colour" }?.submenu)
        #expect(colours.count == WatchColour.allCases.count)
        #expect(
            colours.first { $0.id == "watch-colour/amber" }
                == .radio(
                    MenuItemSpec(
                        id: "watch-colour/amber", label: "Amber", swatch: ThemeTokens.watchAmber),
                    checked: true))
    }

    @Test func aChosenItemRunsItsAction() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        let driver = MenuDriver()
        let window = MenuDriver.window()
        defer {
            driver.menu.close()
            window.close()
        }
        let view = try #require(window.contentView)
        let row = try #require(h.row(s1))
        RowMenu.show(row, at: NSPoint(x: 40, y: 40), in: view, runner: h.runner, menu: driver.menu)
        let rename = try #require(
            try driver.root.list.state.rows.firstIndex { $0.id == "rename" })
        try driver.click(driver.row(rename))
        #expect(!driver.menu.isOpen)
        #expect(try h.renameDialog().sessionId == s1)
        try h.renameDialog().cancel()
        // A submenu choice runs with its value: Set priority, then 2.
        RowMenu.show(row, at: NSPoint(x: 40, y: 40), in: view, runner: h.runner, menu: driver.menu)
        let menu = RowMenu.menu(row, runner: h.runner)
        #expect(menu.choices["set-priority/2"]?.0 == .setPriority)
        #expect(menu.choices["set-priority/2"]?.1 == .priority(.p2))
        // Down from no highlight goes to the first row, and each Down passes a separator.
        let rows = try driver.root.list.state.rows
        let priority = try #require(rows.firstIndex { $0.id == "set-priority" })
        let downs = rows[0...priority].filter(\.takesHighlight).count
        for _ in 0..<downs { try driver.key("Down") }
        // Right opens the submenu with its first row highlighted.
        try driver.key("Right")
        try driver.key("Down")
        try driver.key("Return")
        await h.settle()
        #expect(h.row(s1)?.priority == .p2)
    }

    // A choice acts on the row of now, also before the menu shows a change: the watch of the
    // menu gets its turn on the main actor after the change. Another action that starts on the
    // session (Copy session ID) turns Stop off at once, and a click on the Stop entry that still
    // shows on does nothing: no confirmation shows.
    @Test func aChoiceActsOnTheRowOfNow() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        let driver = MenuDriver()
        let window = MenuDriver.window()
        defer {
            driver.menu.close()
            window.close()
        }
        let view = try #require(window.contentView)
        let row = try #require(h.row(s1))
        RowMenu.show(row, at: NSPoint(x: 40, y: 40), in: view, runner: h.runner, menu: driver.menu)
        let stop = try #require(try driver.root.list.state.rows.firstIndex { $0.id == "stop" })
        h.runner.run(.copyId, s1)
        #expect(h.runner.isRunning(s1))
        #expect(try driver.root.list.state.rows[stop].spec?.enabled == true)
        try driver.click(driver.row(stop))
        #expect(!driver.menu.isOpen)
        #expect(!h.dialogs.isOpen)
        await h.settle()
        #expect(!h.dialogs.isOpen)
    }

    // A prompt that comes up while the menu is open turns Send message off in the menu, so a
    // click on it chooses nothing and the menu stays open.
    @Test func aPromptTurnsSendMessageOffInTheOpenMenu() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        let driver = MenuDriver()
        let window = MenuDriver.window()
        defer {
            driver.menu.close()
            window.close()
        }
        let view = try #require(window.contentView)
        let row = try #require(h.row(s1))
        RowMenu.show(row, at: NSPoint(x: 40, y: 40), in: view, runner: h.runner, menu: driver.menu)
        let send = { () -> MenuItemSpec? in
            driver.menu.panels.first?.list.state.rows.first { $0.id == "send-message" }?.spec
        }
        #expect(send()?.enabled == true)
        await h.deps.show([Entry.running(s1, status: .waiting, waitingFor: "permission")]) {
            $0.first?.alert.blocksPrompt == true
        }
        await waitUntil(within: .seconds(10)) { send()?.enabled == false }
        #expect(send()?.reason == "Send message\n\(ActionReasons.redBox)")
        let index = try #require(
            try driver.root.list.state.rows.firstIndex { $0.id == "send-message" })
        try driver.click(driver.row(index))
        #expect(driver.menu.isOpen)
        #expect(h.sendBoxFocuses.isEmpty)
    }

    // Add to watchlist lists the eight colours as item rows, each with its colour square, and no
    // check.
    @Test func addToWatchlistHasTheColourSquares() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        let row = try #require(h.row(s1))
        let rows = RowMenu.rows(row, runner: h.runner)
        let colours = try #require(rows.first { $0.id == "watch-add" }?.submenu)
        #expect(
            colours
                == WatchColour.allCases.map { colour in
                    .item(
                        MenuItemSpec(
                            id: "watch-add/\(colour.rawValue)", label: colour.label,
                            swatch: colour.token))
                })
    }

    // The menu closes when its row leaves the list. A menu of another row stays when a row
    // goes, and the watch of a closed menu never closes a later menu.
    @Test func theMenuClosesWhenItsRowGoes() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1), Entry.running(s2)])
        let driver = MenuDriver()
        let window = MenuDriver.window()
        defer {
            driver.menu.close()
            window.close()
        }
        let view = try #require(window.contentView)
        let first = try #require(h.row(s1))
        let second = try #require(h.row(s2))
        RowMenu.show(
            first, at: NSPoint(x: 40, y: 40), in: view, runner: h.runner, menu: driver.menu)
        driver.menu.close()
        RowMenu.show(
            second, at: NSPoint(x: 40, y: 40), in: view, runner: h.runner, menu: driver.menu)
        await h.deps.show([Entry.running(s2)]) { rows in !rows.contains { $0.sessionId == s1 } }
        // The registry has no s1 row now. The observation of the test gives that value at once:
        // it does not wait for a change, it only proves that the change is there. The ten yields
        // of the main actor after it are the real wait: they give the watch of the menu its turns,
        // so a wrong close comes before the check.
        let rows = h.deps.registry
        let changes = Observations { rows.rows.contains { $0.sessionId == s1 } }
        for await present in changes where !present { break }
        for _ in 0..<10 { await Task.yield() }
        #expect(driver.menu.isOpen)
        await h.deps.show([]) { $0.isEmpty }
        await waitUntil(within: .seconds(10)) { !driver.menu.isOpen }
        #expect(!driver.menu.isOpen)
    }

    // While the menu is open, it shows the row of now: a row that parks turns Stop off in the
    // open menu, with its reason, and the menu stays open.
    @Test func theOpenMenuShowsTheEntriesOfTheRowOfNow() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)], all: [Entry.stopped(s1)])
        let driver = MenuDriver()
        let window = MenuDriver.window()
        defer {
            driver.menu.close()
            window.close()
        }
        let view = try #require(window.contentView)
        let row = try #require(h.row(s1))
        RowMenu.show(row, at: NSPoint(x: 40, y: 40), in: view, runner: h.runner, menu: driver.menu)
        let stop = { () -> MenuItemSpec? in
            driver.menu.panels.first?.list.state.rows.first { $0.id == "stop" }?.spec
        }
        #expect(stop()?.enabled == true)
        await h.deps.show([]) { $0.first?.state == .parked }
        await waitUntil(within: .seconds(10)) { stop()?.enabled == false }
        #expect(stop()?.reason == "Stop session\n\(ActionReasons.noProcess)")
        #expect(try driver.root.list.state.rows.contains { $0.id == "resume" })
        #expect(driver.menu.isOpen)
    }

    // The open menu also follows the locks of the session. While Stop waits for the park, the
    // session is locked and Delete is off. The lock frees just after the row parks, and then
    // Delete turns on in the menu that is still open.
    @Test func deleteTurnsOnInTheOpenMenuWhenTheStopWaitEnds() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)], all: [Entry.stopped(s1)])
        let driver = MenuDriver()
        let window = MenuDriver.window()
        defer {
            driver.menu.close()
            window.close()
        }
        let stop = Task { _ = try? await h.actions.run(.stop(s1)) }
        await waitUntil(within: .seconds(10)) { !h.calls.claudeRuns.isEmpty }
        #expect(h.calls.claudeRuns == [["stop", short1.text]])
        #expect(h.actions.isRunning(s1))
        let view = try #require(window.contentView)
        let row = try #require(h.row(s1))
        RowMenu.show(row, at: NSPoint(x: 40, y: 40), in: view, runner: h.runner, menu: driver.menu)
        let delete = { () -> MenuItemSpec? in
            driver.menu.panels.first?.list.state.rows.first { $0.id == "delete" }?.spec
        }
        #expect(delete()?.enabled == false)
        #expect(delete()?.reason == "Delete session\n\(ActionReasons.running)")
        await h.deps.show([]) { $0.first?.state == .parked }
        await h.finish(stop)
        #expect(!h.actions.isRunning(s1))
        await waitUntil(within: .seconds(10)) { delete()?.enabled == true }
        #expect(delete()?.enabled == true)
        #expect(driver.menu.isOpen)
    }

    // The row menu is a context menu: a press on another row of the Overview only closes the
    // menu, so that row does not get the selection. The release of the press then selects
    // nothing. With no menu, the same click selects the row.
    @Test func aPressOnAnotherRowOnlyClosesTheMenu() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1), Entry.running(s2)])
        let driver = MenuDriver()
        let overview = try await OverviewWindow(h, menu: driver.menu)
        defer {
            driver.menu.close()
            overview.window.close()
        }
        let ids = overview.shownIDs
        try #require(ids.count == 2)
        overview.table.send(.rightMouseDown, at: overview.point(row: 0))
        #expect(driver.menu.isOpen)
        #expect(h.selection.selectedId == nil)
        // The app gives each press to the menu first (its event monitor). A nil result stops the
        // press.
        let point = overview.table.convert(overview.point(row: 1), to: nil)
        let press = try MenuDriver.mouse(.leftMouseDown, at: point, in: overview.window)
        if let event = driver.menu.handleMouse(press) { overview.table.mouseDown(with: event) }
        overview.table.mouseUp(
            with: try MenuDriver.mouse(.leftMouseUp, at: point, in: overview.window))
        #expect(!driver.menu.isOpen)
        #expect(h.selection.selectedId == nil)
        overview.table.send(.leftMouseDown, at: overview.point(row: 1))
        overview.table.send(.leftMouseUp, at: overview.point(row: 1))
        #expect(h.selection.selectedId == ids[1])
    }

    // The menu of a row that went before the right-click shows nothing.
    @Test func aRowThatWentShowsNoMenu() async throws {
        let h = try await ActionsHarness(active: [Entry.running(s1)])
        let driver = MenuDriver()
        let window = MenuDriver.window()
        defer {
            driver.menu.close()
            window.close()
        }
        let view = try #require(window.contentView)
        let row = try #require(h.row(s1))
        await h.deps.show([]) { $0.isEmpty }
        RowMenu.show(row, at: NSPoint(x: 40, y: 40), in: view, runner: h.runner, menu: driver.menu)
        #expect(!driver.menu.isOpen)
    }
}
