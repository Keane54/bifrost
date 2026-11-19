import AppKit
import BifrostFoundation
import BifrostLook
import BifrostSessions
import BifrostTestSupport
import SwiftUI
import Testing

@testable import BifrostKeyboard
@testable import BifrostLayout
@testable import BifrostWindows

// The tab menu of a tab as rows of the Bifrost menu, and the choice of a row by its ID as the
// menu gives it. SwiftUI takes no synthetic click or drag in a window that is never ordered
// front, so the tests call the action of a click or of a double-click (the items of the views).
@MainActor
struct TabMenu {
    let rows: [MenuRow]
    // The action of the row with the ID.
    let act: (String) -> Void

    var items: [TabMenuItem] { rows.map { TabMenuItem(row: $0, act: act) } }

    // The labels of the rows. A separator is "-".
    var titles: [String] { items.map(\.title) }

    func item(_ title: String) -> TabMenuItem? { items.first { $0.title == title } }

    // Choose the row with the label, as a click on it does.
    func choose(_ title: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let id = item(title)?.row.id else {
            Issue.record("No menu row \(title)", sourceLocation: sourceLocation)
            return
        }
        act(id)
    }
}

// One row of a tab menu.
@MainActor
struct TabMenuItem {
    let row: MenuRow
    let act: (String) -> Void

    var title: String { row == .separator ? "-" : row.spec?.label ?? "" }
    var isEnabled: Bool { row.spec?.enabled ?? false }
    // The tooltip of a disabled row.
    var toolTip: String? { row.spec?.reason }
    var state: NSControl.StateValue {
        if case .check(_, true) = row { .on } else { .off }
    }
    var submenu: TabMenu? {
        guard case .submenu(_, let rows) = row else { return nil }
        return TabMenu(rows: rows, act: act)
    }
}

// The tab bar of an Overview (docs/behaviour/overview.md, The tab bar): the tabs in order with
// the active tab, the Add tab button, the rename in place and the tab menu.
// The rename field of a tab is a SwiftUI text field, so the suite takes its turn with the other
// tests of SwiftUI text fields (SharedFieldEditor).
@Suite("Overview tabs", .serialized, .sharedFieldEditor, .testTimeLimit, .tags(.window))
@MainActor
struct OverviewTabsTests {
    private static let rows = [
        overviewRow(1, name: "alpha", state: .working),
        overviewRow(2, name: "bravo", state: .idle),
        overviewRow(3, name: "charlie", state: .parked),
    ]

    private func tabs(_ p: OverviewParts) -> OverviewTabsView { p.body.tabBar.rootView }

    // The tab menu of the tab, with the rows of the config of now and the action of a row.
    private func tabMenu(
        _ p: OverviewParts, _ tab: String, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> TabMenu {
        let view = tabs(p)
        let config = p.model.config(OverviewParts.panelID)
        let found = try #require(
            config.tabs.first { $0.id == tab }, "no tab \(tab)", sourceLocation: sourceLocation)
        return TabMenu(rows: OverviewTabMenu.rows(config, tab: found)) { id in
            OverviewTabMenu.choose(
                id, model: p.model, panel: OverviewParts.panelID, tab: tab, rename: view.rename)
        }
    }

    // A right-click on the tab bar at the point: the tab menu shows on the Bifrost menu of the
    // model. The result is the menu that shows, with the choice of a row of the root menu as a
    // click on it does.
    private func barMenu(
        _ p: OverviewParts, at point: NSPoint, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> (TabMenu, MenuDriver) {
        let driver = try await click(p, at: point, sourceLocation: sourceLocation)
        try #require(driver.menu.isOpen, sourceLocation: sourceLocation)
        let rows = try driver.root.list.state.rows
        let menu = TabMenu(rows: rows) { id in
            guard let index = rows.firstIndex(where: { $0.id == id }),
                let view = try? driver.row(index)
            else { return }
            try? driver.click(view)
        }
        return (menu, driver)
    }

    // A right-click, or a Control-click with control, on the tab bar at the point, with the
    // Bifrost menu of a driver as the menu of the model. The tab bar gives no system menu.
    private func click(
        _ p: OverviewParts, at point: NSPoint, control: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> MenuDriver {
        let driver = MenuDriver()
        p.model.menu = driver.menu
        let host = p.body.tabBar
        host.layoutSubtreeIfNeeded()
        await waitUntil(sourceLocation: sourceLocation) {
            !host.rootView.frames.tabs.isEmpty
        }
        let event = try #require(
            NSEvent.mouseEvent(
                with: control ? .leftMouseDown : .rightMouseDown,
                location: host.convert(point, to: nil), modifierFlags: control ? [.control] : [],
                timestamp: 0, windowNumber: p.window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1),
            sourceLocation: sourceLocation)
        #expect(host.menu(for: event) == nil, sourceLocation: sourceLocation)
        if control {
            host.mouseDown(with: event)
        } else {
            host.rightMouseDown(with: event)
        }
        return driver
    }

    // Type the text and the named keys into the first responder of the window.
    private func type(_ p: OverviewParts, _ keys: [String]) {
        for key in keys {
            p.send(key)
            p.send(key, down: false)
        }
    }

    // True while the field editor of the name field is the first responder.
    private func editing(_ p: OverviewParts) -> Bool {
        guard let text = p.window.firstResponder as? NSText else { return false }
        return text.isDescendant(of: p.body.tabBar)
            || (text.delegate as? NSView)?.isDescendant(of: p.body.tabBar) == true
    }

    // Each row of the tab menu has a text ID, and the ID reads back as the same choice. An ID
    // that is not a row gives no choice.
    @Test func eachTabMenuChoiceReadsBackFromItsID() {
        let fixed: [TabMenuChoice] = [
            .rename, .filter, .columns, .reset, .moveLeft, .moveRight, .remove, .boxOnly,
            .watchedOnly,
        ]
        let all =
            fixed + TabFilter.allStates.map(TabMenuChoice.state)
            + OverviewColumn.allCases.filter { $0 != .kind }.map(TabMenuChoice.column)
        for choice in all { #expect(TabMenuChoice(id: choice.id) == choice) }
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(TabMenuChoice.state(.working).id == "state:0")
        for id in ["state:9", "state:", "column:kind", "column:none", "rename ", ""] {
            #expect(TabMenuChoice(id: id) == nil)
        }
    }

    @Test func addTabAddsTheNextTabAndActivates() async throws {
        let p = try await OverviewParts(rows: Self.rows)
        let view = tabs(p)
        #expect(
            view.tabs.map(\.name) == ["All", "Alerts", "Watched", "Working", "Idle", "Parked"])
        #expect(view.tabs.filter(\.active).map(\.id) == ["t1"])
        #expect(view.tabs.map(\.colour) == [0, 1, 5, 2, 3, 4])
        let add = view.addButton
        #expect(add.enabled)
        #expect(add.tip == "Add tab")
        add.action()
        #expect(view.tabs.map(\.id).last == "t6")
        #expect(view.tabs.last?.name == "Tab 6")
        #expect(view.tabs.filter(\.active).map(\.id) == ["t6"])
        // The table shows the rows of the new tab: the filter of All.
        await p.settle()
        #expect(p.rows.input?.tab == "t6")
        #expect(p.shownIDs.count == 2)
        // A click on a tab activates it.
        view.tabs[4].activate()
        #expect(p.config.active == "t4")
        await p.settle()
        #expect(p.rows.input?.tab == "t4")
    }

    @Test func theAddButtonIsOffAt12TabsWithItsReason() async throws {
        let p = try await OverviewParts(rows: Self.rows)
        let view = tabs(p)
        for _ in 0..<6 { view.addButton.action() }
        #expect(view.tabs.count == 12)
        let add = view.addButton
        #expect(!add.enabled)
        #expect(add.tip == "The Overview can have up to 12 tabs.")
        add.action()
        #expect(p.config.tabs.count == 12)
        // A tab fewer turns the button on again.
        p.update(.removeTab("t11"))
        #expect(view.addButton.enabled)
        #expect(view.addButton.tip == "Add tab")
    }

    @Test func removeIsOffForTheLastTabWithItsReason() async throws {
        let p = try await OverviewParts(rows: Self.rows)
        let menu = try tabMenu(p, "t1")
        #expect(menu.item("Remove tab")?.isEnabled == true)
        #expect(menu.item("Remove tab")?.toolTip == nil)
        menu.choose("Remove tab")
        // The tab to the left of the removed tab becomes active, or the first tab.
        #expect(p.config.tabs.map(\.id) == ["t2", "t0", "t3", "t4", "t5"])
        #expect(p.config.active == "t2")
        for id in ["t0", "t3", "t4", "t5"] { p.update(.removeTab(id)) }
        let last = try tabMenu(p, "t2")
        #expect(last.item("Remove tab")?.isEnabled == false)
        #expect(last.item("Remove tab")?.toolTip == "The Overview needs at least one tab.")
        // A right-click on the first tab shows its menu on the Bifrost menu.
        let (bar, driver) = try await barMenu(p, at: NSPoint(x: 6, y: 11))
        defer { driver.menu.close() }
        #expect(bar.item("Remove tab")?.isEnabled == false)
        #expect(bar.item("Remove tab")?.toolTip == "The Overview needs at least one tab.")
        #expect(p.config.tabs.map(\.id) == ["t2"])
    }

    @Test func aDoubleClickRenamesAndEnterSaves() async throws {
        let p = try await OverviewParts(rows: Self.rows)
        let view = tabs(p)
        view.tabs[1].rename()
        #expect(view.rename.tab == "t2")
        #expect(view.rename.draft == "Alerts")
        await waitUntil { editing(p) }
        // The field selects its text, so the typed text replaces the name.
        type(p, ["m", "i", "n", "e", "Enter"])
        await waitUntil { p.config.tabs[1].name == "mine" }
        #expect(view.rename.tab == nil)
        #expect(!view.rename.watching)
        #expect(view.tabs[1].name == "mine")
        // The rows get the focus back, so the Bifrost keys act on the Overview.
        await waitUntil { p.window.firstResponder === p.rows }
        // An empty name changes nothing.
        view.tabs[1].rename()
        await waitUntil { editing(p) }
        type(p, [" ", "Enter"])
        await waitUntil { view.rename.tab == nil }
        #expect(p.config.tabs[1].name == "mine")
    }

    // Rename... of the menu of a right-click starts the rename of its tab after the menu closed.
    @Test func renameOfTheMenuStartsTheRenameOfItsTab() async throws {
        let p = try await OverviewParts(rows: Self.rows)
        let view = tabs(p)
        let (menu, driver) = try await barMenu(p, at: NSPoint(x: 6, y: 11))
        #expect(menu.items.first?.title == "Rename...")
        menu.choose("Rename...")
        #expect(!driver.menu.isOpen)
        #expect(view.rename.tab == "t1")
        // The name field takes the focus, so typing goes in.
        await waitUntil { editing(p) }
        view.rename.cancel()
    }

    @Test func escCancelsARename() async throws {
        let p = try await OverviewParts(rows: Self.rows)
        let view = tabs(p)
        // Rename... of the tab menu opens the same field.
        try tabMenu(p, "t1").choose("Rename...")
        #expect(view.rename.tab == "t1")
        await waitUntil { editing(p) }
        type(p, ["x", "Escape"])
        await waitUntil { view.rename.tab == nil }
        await waitUntil { p.window.firstResponder === p.rows }
        #expect(p.config.tabs[0].name == "All")
        // The Esc of the field does not open Settings.
        #expect(p.layout.layout.frame(of: .settings) == nil)
    }

    // A second rename saves the first name before it shows its own field.
    @Test func aSecondRenameSavesTheFirstName() async throws {
        let p = try await OverviewParts(rows: Self.rows)
        let view = tabs(p)
        view.tabs[0].rename()
        await waitUntil { editing(p) }
        type(p, ["o", "n", "e"])
        view.tabs[1].rename()
        #expect(p.config.tabs[0].name == "one")
        #expect(view.rename.tab == "t2")
        #expect(view.rename.draft == "Alerts")
        // Rename... of the tab menu of another tab does the same.
        await waitUntil { editing(p) }
        type(p, ["t", "w", "o"])
        try tabMenu(p, "t0").choose("Rename...")
        #expect(p.config.tabs[1].name == "two")
        #expect(view.rename.tab == "t0")
    }

    // A click on another tab, on Add tab or on an item of the tab menu saves a rename first.
    @Test func aTabClickDuringARenameSavesIt() async throws {
        let p = try await OverviewParts(rows: Self.rows)
        let view = tabs(p)
        view.tabs[0].rename()
        await waitUntil { editing(p) }
        type(p, ["y"])
        view.tabs[2].activate()
        #expect(p.config.tabs[0].name == "y")
        #expect(p.config.active == "t0")
        #expect(view.rename.tab == nil)
        view.tabs[1].rename()
        await waitUntil { editing(p) }
        type(p, ["z"])
        view.addButton.action()
        #expect(p.config.tabs[1].name == "z")
        #expect(p.config.tabs.last?.id == "t6")
        view.tabs[3].rename()
        await waitUntil { editing(p) }
        type(p, ["w"])
        try tabMenu(p, "t4").choose("Move right")
        #expect(p.config.tabs.first { $0.id == "t3" }?.name == "w")
        #expect(view.rename.tab == nil)
        #expect(!view.rename.watching)
    }

    // While a rename runs, a press outside the field saves it before the view under the pointer
    // gets the press, and a press in the field does not. The loss of the key state of the window
    // (a switch to another app) saves it too.
    @Test func aClickOutsideOrAnotherAppSavesARename() async throws {
        let p = try await OverviewParts(rows: Self.rows)
        let view = tabs(p)
        #expect(!view.rename.watching)
        view.tabs[0].rename()
        #expect(view.rename.watching)
        await waitUntil { editing(p) }
        type(p, ["q"])
        let field = try #require(
            (p.window.firstResponder as? NSText)?.delegate as? NSView)
        func press(_ point: NSPoint, in target: NSView) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: target.convert(point, to: nil),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: p.window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
        }
        view.rename.pointerDown(
            try press(NSPoint(x: field.bounds.midX, y: field.bounds.midY), in: field))
        #expect(view.rename.tab == "t1")
        // A press on the rows.
        view.rename.pointerDown(try press(p.cellPoint(row: 0), in: p.table))
        #expect(p.config.tabs[0].name == "q")
        #expect(view.rename.tab == nil)
        #expect(!view.rename.watching)
        // A switch to another app.
        view.tabs[1].rename()
        await waitUntil { editing(p) }
        type(p, ["k"])
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: p.window)
        await waitUntil { p.config.tabs[1].name == "k" }
        #expect(view.rename.tab == nil)
    }

    @Test func theFilterSubmenuChangesTheRows() async throws {
        var boxed = overviewRow(4, name: "delta", state: .needsYou)
        boxed.alert = .yellow(since: 1)
        let p = try await OverviewParts(rows: Self.rows + [boxed])
        #expect(Set(p.shownIDs) == Set([Self.rows[0], Self.rows[1], boxed].map(\.sessionId)))
        let menu = try tabMenu(p, "t1")
        let filter = try #require(menu.item("Filter")?.submenu)
        #expect(
            filter.titles == [
                "Working", "Alert", "Error", "Idle", "Parked", "-", "Only rows with a box",
                "Only watched sessions",
            ])
        #expect(filter.items.map(\.state) == [.on, .on, .on, .on, .off, .off, .off, .off])
        filter.choose("Parked")
        #expect(p.tab.filter.states == [.working, .needsYou, .error, .idle, .parked])
        await p.settle()
        #expect(p.shownIDs.count == 4)
        try tabMenu(p, "t1").item("Filter")?.submenu?.choose("Only rows with a box")
        await p.settle()
        #expect(p.shownIDs == [boxed.sessionId])
        try tabMenu(p, "t1").item("Filter")?.submenu?.choose("Only rows with a box")
        try tabMenu(p, "t1").item("Filter")?.submenu?.choose("Only watched sessions")
        await p.settle()
        #expect(p.shownIDs.isEmpty)
        #expect(p.tab.filter.watchedOnly)
        #expect(!p.tab.filter.boxOnly)
        // The other tabs keep their filters.
        #expect(p.config.tabs[1].filter == OverviewConfig.standard.tabs[1].filter)
    }

    @Test func theColumnsSubmenuTogglesAColumn() async throws {
        let p = try await OverviewParts(rows: Self.rows)
        let menu = try tabMenu(p, "t1")
        let columns = try #require(menu.item("Columns")?.submenu)
        #expect(
            columns.titles == [
                "Name", "Priority", "State", "Project", "Branch", "Model", "Context %", "Cost",
                "Activity",
            ])
        #expect(columns.items.map(\.state) == [.on, .off, .on, .on, .off, .off, .off, .off, .on])
        // Reset is off for a tab with the default columns and filter.
        #expect(menu.item("Reset")?.isEnabled == false)
        #expect(
            menu.item("Reset")?.toolTip == "This tab already has the default columns and filter.")
        columns.choose("Branch")
        #expect(p.tab.columns == [.kind, .name, .state, .project, .branch, .activity])
        await p.settle()
        #expect(p.rows.input?.columns == [.kind, .name, .state, .project, .branch, .activity])
        try tabMenu(p, "t1").item("Columns")?.submenu?.choose("Name")
        #expect(p.tab.columns == [.kind, .state, .project, .branch, .activity])
        let changed = try tabMenu(p, "t1")
        #expect(changed.item("Reset")?.isEnabled == true)
        #expect(changed.item("Reset")?.toolTip == nil)
        changed.choose("Reset")
        #expect(p.tab.columns == OverviewColumn.defaultVisible)
    }

    @Test func moveLeftAndRightChangeTheOrder() async throws {
        let p = try await OverviewParts(rows: Self.rows)
        let view = tabs(p)
        let menu = try tabMenu(p, "t1")
        #expect(
            menu.titles == [
                "Rename...", "Filter", "Columns", "Reset", "Move left", "Move right", "-",
                "Remove tab",
            ])
        menu.choose("Move right")
        #expect(view.tabs.map(\.id) == ["t2", "t1", "t0", "t3", "t4", "t5"])
        try tabMenu(p, "t0").choose("Move left")
        #expect(view.tabs.map(\.id) == ["t2", "t0", "t1", "t3", "t4", "t5"])
        // A move off either end changes nothing.
        try tabMenu(p, "t2").choose("Move left")
        try tabMenu(p, "t5").choose("Move right")
        #expect(view.tabs.map(\.id) == ["t2", "t0", "t1", "t3", "t4", "t5"])
        // The active tab stays active.
        #expect(p.config.active == "t1")
    }

    // The host and each view in it refuse the first responder, so no tab is in the Tab loop of
    // the window, and a moving frame does not rebuild that loop (the section "The UI" of the
    // architecture design). Only the name field of a rename takes the focus.
    @Test func theTabButtonsAreNotFocusable() async throws {
        let p = try await OverviewParts(rows: Self.rows)
        let host = p.body.tabBar
        host.layoutSubtreeIfNeeded()
        #expect(!host.acceptsFirstResponder)
        #expect(!host.canBecomeKeyView)
        _ = p.window.makeFirstResponder(host)
        #expect(p.window.firstResponder !== host)
        var views: [NSView] = [host]
        var all: [NSView] = []
        while let view = views.popLast() {
            all.append(view)
            views += view.subviews
        }
        #expect(all.allSatisfy { !$0.acceptsFirstResponder && !$0.canBecomeKeyView })
        _ = p.window.makeFirstResponder(nil)
        p.window.selectNextKeyView(nil)
        #expect(!((p.window.firstResponder as? NSView)?.isDescendant(of: host) ?? false))
    }

    // A filter row through the real menu changes the filter and keeps the menu open with the new
    // check. The close gives the focus to the rows of the Overview.
    @Test func aFilterRowKeepsTheMenuOpenWithTheNewCheck() async throws {
        let p = try await OverviewParts(rows: Self.rows)
        // Another view has the focus before the menu, so the menu gives it back to that view.
        #expect(p.window.makeFirstResponder(p.content))
        let (_, driver) = try await barMenu(p, at: NSPoint(x: 6, y: 11))
        // Rename... is the first row, and Filter the second. Right opens the submenu with its
        // first row, Working, highlighted.
        try driver.key("Down")
        try driver.key("Down")
        try driver.key("Right")
        try driver.key("Return")
        #expect(driver.menu.isOpen)
        #expect(!p.tab.filter.states.contains(.working))
        let working = try driver.row(0, level: 1).row
        #expect(working == .check(MenuItemSpec(id: "state:0", label: "Working"), checked: false))
        try driver.key("Escape")
        try driver.key("Escape")
        #expect(!driver.menu.isOpen)
        await waitUntil { p.window.firstResponder === p.rows }
    }

    @Test func aControlClickOnATabOpensItsMenu() async throws {
        let p = try await OverviewParts(rows: Self.rows)
        let driver = try await click(p, at: NSPoint(x: 6, y: 11), control: true)
        defer { driver.menu.close() }
        #expect(driver.menu.isOpen)
        #expect(try driver.root.list.state.rows.first?.id == "rename")
    }

    // A right-click on the Add tab button or on the empty space after the tabs shows no menu.
    @Test func aRightClickOutsideTheTabsShowsNoMenu() async throws {
        let p = try await OverviewParts(rows: Self.rows)
        let width = p.body.tabBar.bounds.width
        let plus = try await click(p, at: NSPoint(x: width - 10, y: 11))
        #expect(!plus.menu.isOpen)
        let tabs = p.body.tabBar.rootView.frames.tabs.values
        let end = try #require(tabs.map(\.maxX).max())
        let empty = try await click(p, at: NSPoint(x: end + 20, y: 11))
        #expect(!empty.menu.isOpen)
    }

    // The VoiceOver action "Show menu" of a tab opens its menu below the tab.
    @Test func theShowMenuActionOpensTheMenuBelowTheTab() async throws {
        let p = try await OverviewParts(rows: Self.rows)
        let driver = MenuDriver()
        defer { driver.menu.close() }
        p.model.menu = driver.menu
        let host = p.body.tabBar
        host.layoutSubtreeIfNeeded()
        await waitUntil { !host.rootView.frames.tabs.isEmpty }
        tabs(p).tabs[0].showMenu()
        #expect(driver.menu.isOpen)
        let rect = try #require(host.rootView.frames.screenRect(of: "t1"))
        #expect(try driver.root.frame.maxY <= rect.minY)
    }
}
