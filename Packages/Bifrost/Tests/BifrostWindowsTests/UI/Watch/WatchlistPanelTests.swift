// The Watchlist panel (docs/behaviour/panels.md, "The Watchlist"): the watched rows in watch
// order with their colours, a click, a double-click and a right-click on a row, the drag that
// moves a row through the registry, a drag that ends with no drop, the error line of a failed
// move, the empty text and the rows that never take the focus. A test window is never on the
// screen, so it has no drag session of AppKit: the test records the start of each session and
// calls the steps of the drop place and the end of the session itself. The rows come from a real
// registry on fake session lists (ActionsHarness), so no test runs a program or signals a
// process.
import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostSessions
import BifrostTestSupport
import Observation
import Testing

@testable import BifrostKeyboard
@testable import BifrostWindows

// The label set of the settings, as an observed value.
@MainActor
@Observable
final class LabelsValue {
    var labels = LabelSet.plain
}

// The Watchlist body in a window that is never ordered front, on the rows of a real registry. The
// action runner links the shared model, so a double-click runs Open and a right-click shows the
// row menu on the Bifrost menu. The key filter of the app is on the window, with the key commands,
// for the hold keys (D8): the open of a hold command goes to holdOpened. The Interface scale is
// 100, so one layout unit is one point.
@MainActor
final class WatchlistParts {
    static let names = [s1: "alpha", s2: "beta", s3: "gamma"]

    let h: ActionsHarness
    let overviews: OverviewModel
    let labels = LabelsValue()
    let driver = MenuDriver()
    let window = MenuDriver.window()
    let panels: WatchlistPanels
    let body: WatchlistPanel
    let filter: WindowKeyFilter
    // The row IDs of the open of each hold command.
    var holdOpened: [String] = []
    // True: the panel gets no registry, as before the start of the services.
    var registryGone = false
    // The session ID of each drag session that the panel started.
    var startedDrags: [String] = []

    init(watch: [WatchEntry] = [
        WatchEntry(s1, .red), WatchEntry(s2, .green), WatchEntry(s3, .lightBlue),
    ]) async throws {
        h = try await ActionsHarness(
            store: RegistryStore(aliases: Self.names, watch: watch),
            active: [Entry.running(s1), Entry.running(s2), Entry.running(s3)])
        overviews = OverviewModel(
            store: h.store, sessions: h.list, selection: h.selection, layout: h.layout,
            clock: ManualClock(), now: { Date(timeIntervalSince1970: 0) })
        h.runner.attach(overviews, menu: driver.menu)
        let registry = h.deps.registry
        weak var parts: WatchlistParts?
        let labels = labels
        panels = WatchlistPanels(
            model: overviews, registry: { parts?.registryGone == true ? nil : registry },
            labels: { labels.labels }, look: h.look, filter: { parts?.filter })
        let commands = KeyCommands(
            layout: h.layout, sideBar: SideBarModel(layout: h.layout, store: h.store),
            selection: h.selection,
            overviews: OverviewPanels(model: overviews, look: h.look, filter: { parts?.filter }),
            openChat: { parts?.holdOpened.append($0) }, menu: { _ in })
        window.actsAsKey = true
        filter = WindowKeyFilter(
            window: window, commands: commands, selection: h.selection,
            keys: KeyMap([.dictation: .off]))
        body = try #require(panels.body(for: .watchlist) as? WatchlistPanel)
        parts = self
        body.startDrag = { id, _ in parts?.startedDrags.append(id) }
        body.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(body)
        await settle()
    }

    isolated deinit {
        driver.menu.close()
        window.close()
    }

    var table: WatchlistTable { body.table }
    var shownIDs: [String] { body.input?.rows.map(\.sessionId) ?? [] }
    var registryOrder: [String] { WatchOrder.watched(h.deps.registry.rows).map(\.sessionId) }

    // Wait until the panel shows the values of now.
    func settle(sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitUntil(sourceLocation: sourceLocation) { [self] in
            body.input == WatchlistInput(model: overviews, labels: labels.labels, look: h.look)
                && body.input?.rows.count == table.numberOfRows
        }
        body.layoutSubtreeIfNeeded()
    }

    // A point of the row, in the coordinates of the table: 3 units into its upper half, or 3 units
    // above its bottom edge.
    func point(row: Int, upper: Bool = true) -> NSPoint {
        let rect = table.rect(ofRow: row)
        return NSPoint(x: rect.midX, y: upper ? rect.minY + 3 : rect.maxY - 3)
    }

    func look(row: Int) -> WatchRowLook? {
        rowView(row)?.look
    }

    func cell(row: Int) -> WatchRowCell? {
        table.view(atColumn: 0, row: row, makeIfNecessary: false) as? WatchRowCell
    }

    func click(row: Int) {
        table.send(.leftMouseDown, at: point(row: row))
        table.send(.leftMouseUp, at: point(row: row))
    }

    // A key event of the US keyboard through the window and its key filter.
    func send(_ id: String, down: Bool = true) {
        guard
            let event = USKeyboard.keyEvent(
                down: down, id: id, mods: [], isRepeat: false, window: window)
        else { return }
        window.sendEvent(event)
    }

    // The row view of the row.
    func rowView(_ row: Int) -> WatchRowView? {
        table.rowView(atRow: row, makeIfNecessary: false) as? WatchRowView
    }

    // A press on the row and a move of 10 units down: the drag session of the row starts.
    func drag(row: Int) {
        let start = point(row: row)
        table.send(.leftMouseDown, at: start)
        table.send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y + 10))
    }
}

@Suite("the Watchlist panel", .serialized, .timeLimit(.minutes(1)), .tags(.window))
@MainActor
struct WatchlistPanelTests {
    @Test func theWatchedRowsShowInWatchOrder() async throws {
        let p = try await WatchlistParts(watch: [WatchEntry(s3, .red), WatchEntry(s1, .green)])
        #expect(p.shownIDs == [s3, s1])
        #expect(p.table.numberOfRows == 2)
        #expect(p.table.rowHeight == 26)
        #expect(p.cell(row: 0)?.name.stringValue == "gamma")
        #expect(p.cell(row: 0)?.state.stringValue == OverviewFormat.stateLabel(.idle))
        #expect(p.cell(row: 0)?.icon.look != nil)
        #expect(p.look(row: 0) == WatchRowLook(watch: ThemeTokens.watchRed))
        #expect(p.look(row: 1) == WatchRowLook(watch: ThemeTokens.watchGreen))
        #expect(p.body.emptyText.isHidden)
        // A new colour and a move from elsewhere show at once.
        #expect(p.h.deps.registry.watchColour(s1, .amber))
        #expect(p.h.deps.registry.watchMove(s1, before: s3))
        await p.settle()
        #expect(p.shownIDs == [s1, s3])
        #expect(p.look(row: 0)?.watch == ThemeTokens.watchAmber)
    }

    @Test func aClickSelectsAndADoubleClickOpens() async throws {
        let p = try await WatchlistParts()
        p.click(row: 1)
        #expect(p.h.selection.selectedId == s2)
        await p.settle()
        #expect(p.look(row: 1)?.selected == true)
        #expect(p.look(row: 0)?.selected == false)
        // The selection of the table follows SelectionModel, so VoiceOver tells the selected row.
        #expect(p.table.selectedRowIndexes == IndexSet(integer: 1))
        // A move of less than 4 units is still a click, and moves nothing.
        let start = p.point(row: 2)
        p.table.send(.leftMouseDown, at: start)
        p.table.send(.leftMouseDragged, at: NSPoint(x: start.x + 3, y: start.y))
        p.table.send(.leftMouseUp, at: NSPoint(x: start.x + 3, y: start.y))
        #expect(p.h.selection.selectedId == s3)
        #expect(p.registryOrder == [s1, s2, s3])
        // A double-click runs Open of the action runner: the chat of the owned row opens.
        p.table.doubleClick(at: p.point(row: 0))
        #expect(p.h.selection.selectedId == s1)
        #expect(p.h.chatOpen(s1))
    }

    @Test func aRightClickShowsTheRowMenu() async throws {
        let p = try await WatchlistParts()
        p.table.send(.rightMouseDown, at: p.point(row: 1))
        #expect(p.driver.menu.isOpen)
        let row = try #require(p.h.row(s2))
        let rows = try p.driver.root.list.state.rows
        #expect(rows == RowMenu.rows(row, runner: p.h.runner))
        #expect(rows.contains { $0.id == "watch-colour" })
        #expect(rows.contains { $0.id == "watch-remove" })
        // A right-click does not change the selection.
        #expect(p.h.selection.selectedId == nil)
        p.driver.menu.close()
        // A Control-click is a right-click.
        p.table.send(.leftMouseDown, at: p.point(row: 0), flags: .control)
        #expect(p.driver.menu.isOpen)
        #expect(p.h.selection.selectedId == nil)
        p.driver.menu.close()
        // The Show Menu action of VoiceOver on a row gives its menu too.
        let view = try #require(p.table.rowView(atRow: 1, makeIfNecessary: false))
        #expect(view.accessibilityPerformShowMenu())
        #expect(p.driver.menu.isOpen)
        #expect(try p.driver.root.list.state.rows == RowMenu.rows(row, runner: p.h.runner))
        #expect(p.h.selection.selectedId == nil)
    }

    @Test func aDragMovesTheRowThroughTheRegistry() async throws {
        let p = try await WatchlistParts()
        // A move of less than 4 units starts no drag.
        let start = p.point(row: 0)
        p.table.send(.leftMouseDown, at: start)
        p.table.send(.leftMouseDragged, at: NSPoint(x: start.x + 3, y: start.y))
        #expect(p.startedDrags.isEmpty)
        // A move past it starts the drag session of the row, and the row fades.
        p.table.send(.leftMouseDragged, at: p.point(row: 1))
        #expect(p.startedDrags == [s1])
        #expect(p.look(row: 0)?.dragged == true)
        #expect(p.rowView(0)?.alphaValue == 0.4)
        #expect(p.rowView(1)?.alphaValue == 1)
        // A drop at the place that the row has now shows no line and is no drop.
        #expect(!p.body.dropProposed(s1, aboveRow: 0))
        #expect(!p.body.dropProposed(s1, aboveRow: 1))
        #expect((0..<3).allSatisfy { p.look(row: $0)?.line == nil })
        // Above the last row the line is above it, and at the end it is below it.
        #expect(p.body.dropProposed(s1, aboveRow: 2))
        #expect(p.look(row: 2)?.line == .above)
        #expect(p.body.dropProposed(s1, aboveRow: 3))
        #expect(p.look(row: 2)?.line == .below)
        // Out of the table, no line shows.
        p.body.dropLeft()
        #expect((0..<3).allSatisfy { p.look(row: $0)?.line == nil })
        #expect(p.body.dropProposed(s1, aboveRow: 3))
        #expect(p.body.drop(s1, aboveRow: 3))
        p.body.dragEnded()
        #expect(p.registryOrder == [s2, s3, s1])
        await p.settle()
        #expect(p.shownIDs == [s2, s3, s1])
        #expect((0..<3).allSatisfy { p.look(row: $0)?.dragged == false })
        #expect((0..<3).allSatisfy { p.rowView($0)?.alphaValue == 1 })
        // A drag is never a click: the session had the pointer, and a late release does nothing.
        p.table.send(.leftMouseUp, at: p.point(row: 2))
        #expect(p.h.selection.selectedId == nil)
        #expect(p.body.error == nil)
    }

    // A drag session that ends with no drop on the table (Esc, or a drop outside the table) moves
    // nothing and selects nothing, and the row and the line go back.
    @Test func aDragWithNoDropMovesNothing() async throws {
        let p = try await WatchlistParts()
        p.drag(row: 0)
        #expect(p.body.dropProposed(s1, aboveRow: 3))
        #expect(p.look(row: 2)?.line == .below)
        p.body.dragEnded()
        #expect(p.look(row: 0)?.dragged == false)
        #expect(p.look(row: 2)?.line == nil)
        #expect(p.registryOrder == [s1, s2, s3])
        #expect(p.h.selection.selectedId == nil)
        // A drop place after the end of the drag is no drop place.
        #expect(!p.body.dropProposed(s1, aboveRow: 3))
        // A press with no drag is still a click.
        p.click(row: 1)
        #expect(p.h.selection.selectedId == s2)
    }

    @Test func aFailedMoveShowsItsReasonUntilTheClose() async throws {
        let p = try await WatchlistParts()
        p.registryGone = true
        p.drag(row: 0)
        #expect(!p.body.drop(s1, aboveRow: 3))
        p.body.dragEnded()
        #expect(p.registryOrder == [s1, s2, s3])
        #expect(p.body.error == ActionReasons.gone)
        #expect(!p.body.errorLine.isHidden)
        #expect(p.body.errorLine.label.stringValue == ActionReasons.gone)
        #expect(!p.body.errorLine.closeButton.isHidden)
        p.body.layoutSubtreeIfNeeded()
        #expect(p.body.errorLine.frame.maxY == p.body.bounds.maxY)
        #expect(p.body.scrollView.frame.maxY == p.body.errorLine.frame.minY)
        p.body.errorLine.closeButton.performClick(nil)
        #expect(p.body.error == nil)
        #expect(p.body.errorLine.isHidden)
        // A move that works clears the line too.
        p.registryGone = false
        p.drag(row: 2)
        #expect(p.body.drop(s3, aboveRow: 0))
        p.body.dragEnded()
        #expect(p.registryOrder == [s3, s1, s2])
        #expect(p.body.error == nil)
    }

    @Test func theEmptyTextNamesTheMenuItem() async throws {
        let p = try await WatchlistParts(watch: [])
        #expect(p.shownIDs.isEmpty)
        #expect(!p.body.emptyText.isHidden)
        #expect(
            p.body.emptyText.stringValue
                == "Nothing on your watchlist yet. Right-click a session and choose Add to "
                + "watchlist.")
        p.labels.labels = .space
        await p.settle()
        #expect(
            p.body.emptyText.stringValue
                == "Nothing on your watchlist yet. Right-click a session and choose Track.")
        // A watched row hides the text.
        #expect(p.h.deps.registry.watchAdd(s2, .white))
        await p.settle()
        #expect(p.body.emptyText.isHidden)
        #expect(p.shownIDs == [s2])
    }

    @Test func theRowsAreNotFocusable() async throws {
        let p = try await WatchlistParts()
        #expect(!p.body.acceptsFirstResponder)
        #expect(!p.body.canBecomeKeyView)
        #expect(!p.table.acceptsFirstResponder)
        #expect(!p.table.canBecomeKeyView)
        #expect(!p.body.errorLine.closeButton.acceptsFirstResponder)
        // The table refuses the focus also when the window asks it.
        _ = p.window.makeFirstResponder(p.table)
        #expect(p.window.firstResponder !== p.table)
        let before = p.window.firstResponder
        p.click(row: 1)
        #expect(p.window.firstResponder === before)
        #expect(p.h.selection.selectedId == s2)
    }

    @Test func aClickDuringAHoldRunsTheHoldCommand() async throws {
        let p = try await WatchlistParts()
        p.h.selection.selectedId = s1
        // O is the hold key of open: while it is down, a click on a row runs the hold command on
        // the row and keeps the selection, and a double-click does not open the row (D8).
        p.send("o")
        p.table.doubleClick(at: p.point(row: 2))
        p.send("o", down: false)
        #expect(p.holdOpened.contains(s3))
        #expect(p.h.selection.selectedId == s1)
        #expect(!p.h.chatOpen(s3))
        // A single click during the hold runs the hold command too.
        p.holdOpened = []
        p.send("o")
        p.table.send(.leftMouseDown, at: p.point(row: 1))
        p.table.send(.leftMouseUp, at: p.point(row: 1))
        p.send("o", down: false)
        #expect(p.holdOpened == [s2])
        #expect(p.h.selection.selectedId == s1)
        #expect(!p.h.chatOpen(s2))
    }

    // The panel leaves the window during a drag: the drag ends, with no dim row and no line.
    @Test func aDragEndsWhenThePanelLeavesTheWindow() async throws {
        let p = try await WatchlistParts()
        p.drag(row: 0)
        #expect(p.body.dropProposed(s1, aboveRow: 3))
        #expect(p.rowView(0)?.alphaValue == 0.4)
        p.body.removeFromSuperview()
        #expect(p.look(row: 0)?.dragged != true)
        #expect(!p.body.dropProposed(s1, aboveRow: 3))
        #expect(p.registryOrder == [s1, s2, s3])
    }

    // The table shows a row until its next update. A row that left the session list in the
    // meantime gets no click and no menu.
    @Test func aRowThatLeftTheListGetsNoClickAndNoMenu() async throws {
        let p = try await WatchlistParts()
        p.h.deps.registry.forget(s2)
        #expect(!p.h.list.rows.contains { $0.sessionId == s2 })
        #expect(p.shownIDs == [s1, s2, s3])
        p.table.doubleClick(at: p.point(row: 1))
        p.table.send(.rightMouseDown, at: p.point(row: 1))
        #expect(p.h.selection.selectedId == nil)
        #expect(!p.h.chatOpen(s2))
        #expect(!p.driver.menu.isOpen)
        await p.settle()
        #expect(p.shownIDs == [s1, s3])
    }

    // A press during a hold claims the hold key for its row. On a row that left the list, the
    // release runs no hold command. The press of the next click replaces the old claim, so a click
    // on another row with no hold key selects that row and runs nothing.
    @Test func aHoldClaimOnARowThatLeftTheListActsOnNothingLater() async throws {
        let p = try await WatchlistParts()
        p.h.deps.registry.forget(s2)
        p.send("o")
        p.table.send(.leftMouseDown, at: p.point(row: 1))
        p.table.send(.leftMouseUp, at: p.point(row: 1))
        p.send("o", down: false)
        #expect(p.holdOpened.isEmpty)
        #expect(p.h.selection.selectedId == nil)
        p.table.send(.leftMouseDown, at: p.point(row: 2))
        p.table.send(.leftMouseUp, at: p.point(row: 2))
        #expect(p.holdOpened.isEmpty)
        #expect(p.h.selection.selectedId == s3)
        #expect(!p.h.chatOpen(s2))
    }
}
