import AppKit
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import SwiftUI
import Testing

@testable import BifrostKeyboard
@testable import BifrostLayout
@testable import BifrostLook
@testable import BifrostWindows

// The Overview Settings panel (docs/behaviour/overview.md, Overview Settings): the Tab picker,
// the column list with its drag, the locked kind row, the filter groups, the Tab colour group
// with its arrow keys and Reset to default. The panel edits the Overview of the test parts
// (overview:1), and the table of that Overview shows each change.
@Suite("Overview Settings panel", .serialized, .timeLimit(.minutes(1)), .tags(.window))
@MainActor
struct OverviewSettingsPanelTests {
    private static let settingsID = panel("overview-settings:1")
    private static let working = overviewRow(1, name: "alpha", state: .working)
    private static let idle = overviewRow(2, name: "bravo", state: .idle)
    private static let parked = overviewRow(3, name: "charlie", state: .parked)
    private static let external = overviewRow(4, name: "delta", state: .idle, kind: .external)

    // The parts and the panel body of overview-settings:1 below the Overview in the window.
    @MainActor
    private struct Shown {
        let parts: OverviewParts
        let host: NSView
        var view: OverviewSettingsPanel {
            get throws { try #require(host as? OverviewSettingsHost).rootView }
        }
    }

    private func shown(rows: [SessionRow] = []) async throws -> Shown {
        let p = try await OverviewParts(rows: rows, size: NSSize(width: 800, height: 700))
        p.body.frame = NSRect(x: 0, y: 0, width: 800, height: 260)
        p.body.autoresizingMask = []
        let panels = OverviewSettingsPanels(model: p.model, look: p.look)
        let host = try #require(panels.body(for: Self.settingsID))
        #expect(panels.body(for: Self.settingsID) === host)
        #expect(panels.body(for: OverviewParts.panelID) == nil)
        host.frame = NSRect(x: 0, y: 260, width: 360, height: 420)
        p.content.addSubview(host)
        p.layout.apply(.open(Self.settingsID))
        host.layoutSubtreeIfNeeded()
        return Shown(parts: p, host: host)
    }

    @Test func theColumnRowsFollowTheTabOrder() async throws {
        let s = try await shown()
        let p = s.parts
        let view = try s.view
        #expect(view.isOpen)
        #expect(view.columnRows.map(\.column) == OverviewColumn.allCases)
        #expect(view.columnRows.map(\.label).prefix(3) == ["Kind", "Name", "Priority"])
        #expect(view.columnRows.filter(\.visible).map(\.column) == OverviewColumn.defaultVisible)
        // A move from the header of the table moves the row too.
        p.update(.moveColumn("t1", .activity, before: .name))
        #expect(view.columnRows.map(\.column).prefix(3) == [.kind, .activity, .name])
        // A check box turns its column on and off, at its place in the order.
        view.setColumn(.branch, visible: true)
        #expect(p.tab.columns == [.kind, .activity, .name, .state, .project, .branch])
        view.setColumn(.branch, visible: false)
        #expect(p.tab.columns == [.kind, .activity, .name, .state, .project])
        // The Tab picker shows each tab with its colour, and a choice activates the tab in the
        // Overview. The rows of the panel are the rows of that tab.
        #expect(view.tabChoices.map(\.name) == p.config.tabs.map(\.name))
        #expect(view.tabChoices.filter(\.chosen).map(\.id) == ["t1"])
        view.choose(tab: "t3")
        #expect(p.config.active == "t3")
        #expect(view.columnRows.map(\.column) == OverviewColumn.allCases)
        await p.settle()
        #expect(p.rows.input?.tab == "t3")
    }

    @Test func aDragOfARowMovesTheColumn() async throws {
        let s = try await shown()
        let p = s.parts
        let view = try s.view
        let list = LayoutSize(w: 340, h: 220)
        let order = view.columnRows.map(\.column)
        // The upper half of the Name row (the second row of 22 units) puts State before Name.
        let drop = try #require(
            ColumnDrop(column: .state, at: LayoutPoint(x: 100, y: 27), rows: list, order: order))
        #expect(drop.before == .name)
        #expect(drop.inside)
        #expect(view.moves(drop))
        view.release(drop)
        #expect(p.tab.order.prefix(4) == [.kind, .state, .name, .priority])
        #expect(view.columnRows.map(\.column).prefix(4) == [.kind, .state, .name, .priority])
        await p.settle()
        #expect(p.rows.input?.columns == [.kind, .state, .name, .project, .activity])
        // A point below the list is on the lower half of the last row: the end.
        let end = try #require(
            ColumnDrop(
                column: .name, at: LayoutPoint(x: 10, y: 230), rows: list,
                order: view.columnRows.map(\.column)))
        #expect(end.before == nil)
        view.release(end)
        #expect(p.tab.order.last == .name)
        // A point above the list is on the upper half of the first row: just after kind.
        let top = try #require(
            ColumnDrop(
                column: .name, at: LayoutPoint(x: 10, y: -10), rows: list,
                order: view.columnRows.map(\.column)))
        view.release(top)
        #expect(p.tab.order.prefix(3) == [.kind, .name, .state])
        // A drop on the dragged row moves nothing, and shows no line.
        let same = try #require(
            ColumnDrop(
                column: .name, at: LayoutPoint(x: 10, y: 33),
                rows: list, order: view.columnRows.map(\.column)))
        #expect(!view.moves(same))
    }

    @Test func aReleaseOutsideTheDropAreaMovesNothing() async throws {
        let s = try await shown()
        let p = s.parts
        let view = try s.view
        let list = LayoutSize(w: 340, h: 220)
        let order = view.columnRows.map(\.column)
        let far = try #require(
            ColumnDrop(column: .state, at: LayoutPoint(x: 365, y: 27), rows: list, order: order))
        #expect(!far.inside)
        #expect(!view.moves(far))
        view.release(far)
        #expect(p.tab.order == OverviewColumn.allCases)
        // 24 units outside the list is still in the drop area.
        let near = try #require(
            ColumnDrop(column: .state, at: LayoutPoint(x: 364, y: 27), rows: list, order: order))
        #expect(near.inside)
        view.release(near)
        #expect(p.tab.order.prefix(3) == [.kind, .state, .name])
        // The list has 4 units of padding above and below the rows, and the margin of 24 units
        // starts at its edge: 220 + 4 + 24 = 248.
        let order2 = view.columnRows.map(\.column)
        let low = try #require(
            ColumnDrop(column: .cost, at: LayoutPoint(x: 10, y: 248), rows: list, order: order2))
        #expect(low.inside)
        let below = try #require(
            ColumnDrop(column: .cost, at: LayoutPoint(x: 10, y: 249), rows: list, order: order2))
        #expect(!below.inside)
        let high = try #require(
            ColumnDrop(column: .cost, at: LayoutPoint(x: 10, y: -28), rows: list, order: order2))
        #expect(high.inside)
    }

    @Test func theKindRowIsLockedWithItsReason() async throws {
        let s = try await shown()
        let p = s.parts
        let view = try s.view
        let kind = try #require(view.columnRows.first)
        #expect(kind == ColumnRow(column: .kind, label: "Kind", visible: true, locked: true))
        #expect(view.tip(for: kind) == "The kind column always stays first and on.")
        #expect(view.columnRows.dropFirst().allSatisfy { view.tip(for: $0) == nil })
        // Its box does not turn it off, and the row cannot move.
        view.setColumn(.kind, visible: false)
        #expect(p.tab.columns.first == .kind)
        let order = view.columnRows.map(\.column)
        #expect(
            ColumnDrop(
                column: .kind, at: LayoutPoint(x: 10, y: 100),
                rows: LayoutSize(w: 340, h: 220), order: order) == nil)
        // A row dropped before kind lands just after it.
        let first = try #require(
            ColumnDrop(
                column: .cost, at: LayoutPoint(x: 10, y: 2),
                rows: LayoutSize(w: 340, h: 220), order: order))
        view.release(first)
        #expect(p.tab.order.prefix(2) == [.kind, .cost])
    }

    @Test func theColourArrowKeysWrap() async throws {
        let s = try await shown()
        let p = s.parts
        let view = try s.view
        let names = OverviewSettingsPanel.colourNames
        #expect(names.count == 12)
        #expect(names.first == "Cyan")
        #expect(names.last == "Sky blue")
        #expect(view.tabChoices.first(where: \.chosen)?.colour == 0)
        var found: [NSView] = [s.host]
        var picker: TabColourPicker?
        while let next = found.popLast() {
            if let match = next as? TabColourPicker { picker = match }
            found += next.subviews
        }
        let colours = try #require(picker)
        #expect(colours.selected == 0)
        // The group is a control: the Bifrost keys leave its arrow keys to it.
        #expect(p.window.makeFirstResponder(colours))
        #expect(KeyFocus(colours, in: p.window).zone == .control)
        p.send("ArrowLeft")
        #expect(p.tab.colour == 11)
        p.send("ArrowRight")
        #expect(p.tab.colour == 0)
        p.send("ArrowRight")
        #expect(p.tab.colour == 1)
        // Each other key leaves the colour as it is.
        p.send("ArrowUp")
        #expect(p.tab.colour == 1)
        // A click on a swatch chooses its colour.
        colours.choose(7)
        #expect(p.tab.colour == 7)
        await waitUntil { colours.selected == 7 }
    }

    @Test func resetIsOffForADefaultTab() async throws {
        let s = try await shown()
        let p = s.parts
        let view = try s.view
        #expect(view.reset.title == "Reset to default")
        #expect(!view.reset.enabled)
        #expect(view.reset.tip == "This tab already has the default columns and filter.")
        view.setFilter(.state(.parked), on: true)
        #expect(view.reset.enabled)
        #expect(view.reset.tip == nil)
        view.reset.action()
        #expect(p.tab.filter == OverviewConfig.standard.tabs[0].filter)
        #expect(!view.reset.enabled)
        // A move of a column turns it on too. Reset keeps the name and the colour.
        p.update(.moveColumn("t1", .cost, before: .name))
        p.update(.setTabColour("t1", 9))
        p.update(.renameTab("t1", name: "Mine"))
        #expect(view.reset.enabled)
        view.reset.action()
        #expect(p.tab.order == OverviewColumn.allCases)
        #expect(p.tab.colour == 9)
        #expect(p.tab.name == "Mine")
    }

    @Test func theFiltersChangeTheRowsOfTheTab() async throws {
        var watched = overviewRow(5, name: "echo", state: .working)
        watched.watch = RowWatch(colour: .green, order: 0)
        var boxed = overviewRow(6, name: "foxtrot", state: .needsYou)
        boxed.alert = .red(.prompt, since: 1)
        let rows = [Self.working, Self.idle, Self.parked, Self.external, watched, boxed]
        let s = try await shown(rows: rows)
        let p = s.parts
        let view = try s.view
        #expect(view.filterGroups.map(\.title) == ["States", "Kinds", "Boxes", "Watchlist"])
        #expect(
            view.filterGroups.map { $0.items.map(\.label) } == [
                ["Working", "Alert", "Error", "Idle", "Parked"], ["Owned", "External"],
                ["Only rows with a box"], ["Only watched sessions"],
            ])
        #expect(
            view.filterGroups.map { $0.items.map(\.on) } == [
                [true, true, true, true, false], [true, true], [false], [false],
            ])
        func ids(_ list: [SessionRow]) -> Set<String> { Set(list.map(\.sessionId)) }
        let viewIDs = { ids(p.model.viewRows(OverviewParts.panelID)) }
        #expect(viewIDs() == ids(rows).subtracting([Self.parked.sessionId]))
        view.setFilter(.state(.parked), on: true)
        #expect(viewIDs() == ids(rows))
        view.setFilter(.kind(.owned), on: false)
        #expect(viewIDs() == [Self.external.sessionId])
        view.setFilter(.kind(.owned), on: true)
        view.setFilter(.boxOnly, on: true)
        #expect(viewIDs() == [boxed.sessionId])
        view.setFilter(.boxOnly, on: false)
        view.setFilter(.watchedOnly, on: true)
        #expect(viewIDs() == [watched.sessionId])
        #expect(view.filterGroups.map { $0.items.map(\.on) }.last == [true])
        await p.settle()
        #expect(p.shownIDs == [watched.sessionId])
        // The states keep their order, whatever order the changes came in.
        #expect(p.tab.filter.states == [.working, .needsYou, .error, .idle, .parked])
    }

    // A closed Overview shows no rows, so the panel shows only its text. A minimised Overview is
    // open. The small snapshot reads the text that the host shows.
    @Test func aClosedOverviewShowsItsText() async throws {
        let s = try await shown()
        let p = s.parts
        let view = try s.view
        let frame = try #require(p.layout.layout.frame(of: OverviewParts.panelID))
        p.layout.apply(.minimise(frame.id))
        #expect(view.isOpen)
        p.layout.apply(.close(OverviewParts.panelID))
        #expect(!view.isOpen)
        #expect(OverviewSettingsPanel.closedText == "This Overview is closed.")
        s.host.setFrameSize(NSSize(width: 360, height: 48))
        await waitUntil { !view.isOpen }
        Snapshot(bundle: .module, target: "BifrostWindowsTests").check(
            s.host, named: "overview-settings-closed",
            background: ThemeTokens.panel(transparency: 0).nsColor)
    }
}
