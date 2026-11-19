import AppKit
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Observation
import Testing

@testable import BifrostKeyboard
@testable import BifrostLayout
@testable import BifrostLook
@testable import BifrostWindows

// The wall time of a test: the age texts read it, and a test moves it with the manual clock.
@MainActor
final class TestWallClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)

    var milliseconds: Int { date.millisecondsSince1970 }

    func advance(_ seconds: Double) { date += seconds }
}

// What the parts record: the row IDs of the open action, of the hold command and of the row
// menu. It also holds the key filter of the window, which the window makes after the parts.
@MainActor
final class OverviewSinks {
    var opened: [String] = []
    var holdOpened: [String] = []
    var menus: [(id: String, point: NSPoint, view: NSView)] = []
    var filter: WindowKeyFilter?
}

// One Overview body in a window that is never ordered front: the model with a store in a test
// folder, a session list with the rows of the test, the layout with overview:1, and the key
// filter of the app on the window. The Interface scale is 100, so one layout unit is one point.
@MainActor
final class OverviewParts {
    static let panelID = panel("overview:1")

    let folder: TemporaryFolder
    let source: FakeRowSource
    let sessions: SessionListModel
    let selection: SelectionModel
    let layout: WindowLayoutModel
    let store: UIStateStore
    let clock: ManualClock
    let wall: TestWallClock
    let model: OverviewModel
    let look: PanelLook
    let panels: OverviewPanels
    let window: RecordingWindow
    let content: KeyRecordingView
    let body: OverviewPanel
    let commands: KeyCommands
    let filter: WindowKeyFilter
    let sinks: OverviewSinks

    init(rows: [SessionRow], size: NSSize = NSSize(width: 800, height: 300)) async throws {
        UITestApp.prepare()
        let source = FakeRowSource()
        let sessions = SessionListModel.reading(source)
        let selection = SelectionModel(list: sessions)
        let layout = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1200, h: 800)))
        let folder = try TemporaryFolder()
        let store = await UIStateStore.open(
            file: folder.url.appending(path: "ui-state.json"), clock: ManualClock(),
            log: Recorder<StoreEvent>())
        let sinks = OverviewSinks()
        let window = RecordingWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.actsAsKey = true
        window.appearance = NSAppearance(named: .darkAqua)
        let content = KeyRecordingView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        self.folder = folder
        self.source = source
        self.sessions = sessions
        self.selection = selection
        self.layout = layout
        self.store = store
        self.sinks = sinks
        self.window = window
        self.content = content
        let (clock, wall, look) = (ManualClock(), TestWallClock(), PanelLook())
        self.clock = clock
        self.wall = wall
        self.look = look
        let model = OverviewModel(
            store: store, sessions: sessions, selection: selection, layout: layout, clock: clock,
            now: { wall.date })
        let panels = OverviewPanels(model: model, look: look, filter: { sinks.filter })
        guard let body = panels.body(for: Self.panelID) as? OverviewPanel else {
            preconditionFailure("The Overview parts give no Overview body.")
        }
        let commands = KeyCommands(
            layout: layout, sideBar: SideBarModel(layout: layout, store: store),
            selection: selection, overviews: panels, openChat: { sinks.holdOpened.append($0) },
            menu: { _ in })
        self.commands = commands
        let filter = WindowKeyFilter(
            window: window, commands: commands, selection: selection,
            keys: KeyMap([.dictation: .off]))
        self.model = model
        self.panels = panels
        self.body = body
        self.filter = filter
        sinks.filter = filter
        model.open = { sinks.opened.append($0) }
        model.showRowMenu = { row, point, view in sinks.menus.append((row.sessionId, point, view)) }
        source.apply(rows: rows, error: nil)
        layout.apply(.open(Self.panelID))
        body.frame = content.bounds
        body.autoresizingMask = [.width, .height]
        content.addSubview(body)
        await settle()
    }

    deinit { folder.remove() }

    var rows: OverviewRowsView { body.rows }
    var table: OverviewTable { body.rows.table }
    var header: OverviewHeaderView { body.rows.header }
    var config: OverviewConfig { model.config(Self.panelID) }
    var tab: OverviewTab { config.activeTab }

    func update(_ action: OverviewAction) {
        model.update(Self.panelID, action)
    }

    // Wait until the table shows the values of the model now.
    func settle(sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitUntil(within: .seconds(10), sourceLocation: sourceLocation) { [self] in
            body.rows.input
                == TableInput(model: model, panel: Self.panelID, look: look)
                && body.rows.input?.rows.count == table.numberOfRows
        }
        body.layoutSubtreeIfNeeded()
    }

    // The row IDs in the order of the table.
    var shownIDs: [String] { rows.input?.rows.map(\.sessionId) ?? [] }

    func columnIndex(_ column: OverviewColumn) -> Int {
        table.column(withIdentifier: NSUserInterfaceItemIdentifier(column.rawValue))
    }

    // The middle of the cell of the row in the column, in the coordinates of the table.
    func cellPoint(row: Int, column: OverviewColumn = .name) -> NSPoint {
        let rect = table.frameOfCell(atColumn: columnIndex(column), row: row)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    // The text of the cell of the row in the column.
    func text(row: Int, column: OverviewColumn) -> String? {
        let cell = table.view(atColumn: columnIndex(column), row: row, makeIfNecessary: false)
        return (cell as? OverviewTextCell)?.text
    }

    func kindCell(row: Int) -> OverviewKindCell? {
        table.view(atColumn: columnIndex(.kind), row: row, makeIfNecessary: false)
            as? OverviewKindCell
    }

    // A mouse event on the table at the middle of the row (NSTableView.send).
    func mouse(
        _ type: NSEvent.EventType, row: Int, clicks: Int = 1, flags: NSEvent.ModifierFlags = []
    ) {
        mouse(type, at: cellPoint(row: row), clicks: clicks, flags: flags)
    }

    func mouse(
        _ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1,
        flags: NSEvent.ModifierFlags = []
    ) {
        table.send(type, at: point, clicks: clicks, flags: flags)
    }

    // The pointer moves over the middle of the row, or leaves the table (nil).
    func hover(row: Int?) {
        let point = row.map { cellPoint(row: $0) } ?? NSPoint(x: -50, y: -50)
        guard
            let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: table.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0,
                pressure: 0)
        else { return }
        if row == nil { table.mouseExited(with: event) } else { table.mouseMoved(with: event) }
    }

    // The colours of the row view of the row.
    func look(row: Int) -> RowLook? {
        (table.rowView(atRow: row, makeIfNecessary: false) as? OverviewRowView)?.look
    }

    func click(row: Int) {
        mouse(.leftMouseDown, row: row)
        mouse(.leftMouseUp, row: row)
    }

    func doubleClick(row: Int) {
        table.doubleClick(at: cellPoint(row: row))
    }

    // A click on the header of the column, as the table gives it: the table tracks the press
    // itself, so a test window gets the click from the delegate call.
    func clickHeader(_ column: OverviewColumn) {
        rows.tableView(table, didClick: table.tableColumns[columnIndex(column)])
    }

    // A drag of the header of the column to the place of another column: the table moves the
    // column live, and the end of the press commits the move. The table asks the delegate first.
    // The result is false when the delegate refuses the move.
    @discardableResult
    func dragHeader(_ column: OverviewColumn, toPlaceOf target: OverviewColumn) -> Bool {
        let from = columnIndex(column)
        let to = columnIndex(target)
        guard rows.tableView(table, shouldReorderColumn: from, toColumn: -1),
            rows.tableView(table, shouldReorderColumn: from, toColumn: to)
        else { return false }
        let before = rows.columnOrder
        table.moveColumn(from, toColumn: to)
        rows.headerDragEnded(before)
        return true
    }

    // The middle of the header of the column, in the coordinates of the header.
    func headerPoint(_ column: OverviewColumn) -> NSPoint {
        let rect = header.headerRect(ofColumn: columnIndex(column))
        return NSPoint(x: rect.midX, y: rect.midY)
    }


    func send(_ id: String, _ mods: Set<USKeyboard.Mod> = [], down: Bool = true) {
        guard
            let event = USKeyboard.keyEvent(
                down: down, id: id, mods: mods, isRepeat: false, window: window)
        else { return }
        window.sendEvent(event)
    }

    // The top left of the shown part of the rows, in the coordinates of the table.
    var scrolled: NSPoint { table.enclosingScrollView?.contentView.bounds.origin ?? .zero }

    // The 8-bit red, green and blue of a colour token.
    static func channels(_ token: TokenColour) -> [Int] {
        [token.r, token.g, token.b].map { Int(($0 * 255).rounded()) }
    }

    // The pixel of the image at the point of the view, as 8-bit red, green and blue.
    static func pixel(_ image: CGImage, at point: NSPoint, in view: NSView) -> [Int] {
        let pixels = Snapshot.pixels(image)
        let scale = CGFloat(Snapshot.scale)
        let x = Int(point.x * scale)
        let y = Int((view.isFlipped ? point.y : view.bounds.height - point.y) * scale)
        let start = (y * image.width + x) * 4
        return pixels[start..<(start + 3)].map(Int.init)
    }
}

// Rows for the tests: idle owned rows with the names and the times of the test.
@MainActor
func overviewRow(
    _ number: Int, name: String? = nil, state: SessionState = .idle, kind: SessionKind = .owned,
    cwd: String = "/work/demo/app", lastActivity: Int = 1
) -> SessionRow {
    let id = String(format: "5a0e%04d-0000-4000-8000-000000000000", number)
    return SessionRow.test(
        sessionId: id, name: name ?? "session \(number)", kind: kind, cwd: cwd, state: state,
        lastActivity: lastActivity)
}

// The sessions of the attached chats, for a test of the row icons: an observable set, as
// AttachedChats of the chat module is.
@MainActor
@Observable
private final class AttachedSessions {
    var sessions: Set<String> = []
}

// The Overview table (docs/behaviour/overview.md, The table): the columns of the tab, the header,
// the clicks of the rows, the empty texts, the keys, the colours of a watched row, the icon of the
// app that shows a row and the age texts.
@Suite("Overview table", .serialized, .timeLimit(.minutes(1)), .tags(.window))
@MainActor
struct OverviewTableTests {
    private static let three = [
        overviewRow(1, name: "bravo"), overviewRow(2, name: "alpha", state: .working),
        overviewRow(3, name: "charlie", state: .needsYou),
    ]

    @Test func theTableShowsTheVisibleColumnsInTheTabOrderWithTheirWidths() async throws {
        let p = try await OverviewParts(rows: Self.three)
        let tab = p.tab.id
        p.update(.toggleColumn(tab, .branch))
        p.update(.moveColumn(tab, .project, before: .name))
        p.update(.setWidths(tab, [.name: 150]))
        await p.settle()
        let ids = p.table.tableColumns.map(\.identifier.rawValue)
        #expect(ids == ["kind", "project", "name", "state", "branch", "activity"])
        #expect(p.table.tableColumns.map(\.width) == [28, 200, 150, 84, 130, 112])
        #expect(p.table.rowHeight == 22)
        #expect(p.header.frame.height == 18)
        // At an Interface scale of 150, each length is 1.5 times as long.
        p.look.interfaceScale = 150
        await p.settle()
        #expect(p.table.tableColumns.map(\.width) == [42, 300, 225, 126, 195, 168])
        #expect(p.table.rowHeight == 33)
        #expect(p.header.frame.height == 27)
    }

    @Test func aHeaderClickSortsAndASecondClickReverses() async throws {
        let p = try await OverviewParts(rows: Self.three)
        #expect(p.shownIDs == [Self.three[1], Self.three[0], Self.three[2]].map(\.sessionId))
        #expect(p.header.sortMark(.name) == "▲")
        p.clickHeader(.state)
        await p.settle()
        #expect(p.tab.sort == SortSpec(column: .state))
        #expect(p.header.sortMark(.state) == "▲")
        #expect(p.header.sortMark(.name) == nil)
        // The State column sorts alert, working, idle.
        #expect(p.shownIDs == [Self.three[2], Self.three[1], Self.three[0]].map(\.sessionId))
        p.clickHeader(.state)
        await p.settle()
        #expect(p.tab.sort == SortSpec(column: .state, descending: true))
        #expect(p.header.sortMark(.state) == "▼")
        #expect(p.shownIDs == [Self.three[0], Self.three[1], Self.three[2]].map(\.sessionId))
    }

    @Test func theFirstClickOnContextCostOrActivitySortsDown() async throws {
        let p = try await OverviewParts(rows: Self.three)
        p.update(.toggleColumn(p.tab.id, .context))
        p.update(.toggleColumn(p.tab.id, .cost))
        await p.settle()
        for column in [OverviewColumn.context, .cost, .activity] {
            p.clickHeader(column)
            await p.settle()
            #expect(p.tab.sort == SortSpec(column: column, descending: true))
            #expect(p.header.sortMark(column) == "▼")
        }
    }

    // The table does the column work of the header: a column moves and resizes through the
    // column APIs of the table, and the header draws.
    @Test func theTableDoesTheColumnWorkOfTheHeader() async throws {
        let p = try await OverviewParts(rows: Self.three)
        #expect(p.table.allowsColumnReordering)
        #expect(p.table.allowsColumnResizing)
        #expect(p.table.tableColumns.allSatisfy { $0.resizingMask == .userResizingMask })
        #expect(p.table.headerView === p.header)
    }

    @Test func aHeaderDragMovesTheColumnAndTheKindColumnStays() async throws {
        let p = try await OverviewParts(rows: Self.three)
        func drag(_ from: OverviewColumn, to: OverviewColumn) async -> Bool {
            let moved = p.dragHeader(from, toPlaceOf: to)
            await p.settle()
            return moved
        }
        // A drop on a header to the right puts the column after it.
        #expect(await drag(.name, to: .project))
        #expect(p.tab.columns == [.kind, .state, .project, .name, .activity])
        // The kind column never moves.
        #expect(!(await drag(.kind, to: .project)))
        #expect(p.tab.columns == [.kind, .state, .project, .name, .activity])
        #expect(p.tab.sort == SortSpec(column: .name))
        // No column moves before the kind column: a drag onto it stops directly after it.
        #expect(!(await drag(.activity, to: .kind)))
        #expect(await drag(.activity, to: .state))
        #expect(p.tab.columns == [.kind, .activity, .state, .project, .name])
        let ids = p.table.tableColumns.map(\.identifier.rawValue)
        #expect(ids == ["kind", "activity", "state", "project", "name"])
        // A press that moved no column moves nothing and does not sort.
        p.rows.headerDragEnded(p.rows.columnOrder)
        await p.settle()
        #expect(p.tab.columns == [.kind, .activity, .state, .project, .name])
        #expect(p.tab.sort == SortSpec(column: .name))
    }

    // The one move of a column between two orders: the column and the header it went onto.
    @Test func theMoveOfAColumnComesFromTheTwoOrders() {
        let before: [OverviewColumn] = [.kind, .name, .state, .project, .activity]
        let right = OverviewRowsView.move(
            from: before, to: [.kind, .state, .project, .name, .activity])
        #expect(right?.0 == .name)
        #expect(right?.1 == .project)
        let left = OverviewRowsView.move(
            from: before, to: [.kind, .activity, .name, .state, .project])
        #expect(left?.0 == .activity)
        #expect(left?.1 == .name)
        #expect(OverviewRowsView.move(from: before, to: before) == nil)
        #expect(OverviewRowsView.move(from: before, to: [.kind, .name]) == nil)
    }

    @Test func aResizeChangesOnlyItsColumnAndClamps() async throws {
        let p = try await OverviewParts(rows: Self.three)
        func resize(_ column: OverviewColumn, by delta: CGFloat) async {
            let tableColumn = p.table.tableColumns[p.columnIndex(column)]
            tableColumn.width += delta
            await p.settle()
        }
        await resize(.name, by: 40)
        #expect(p.tab.widths == [.name: 224])
        #expect(p.table.tableColumns.map(\.width) == [28, 224, 84, 200, 112])
        // A resize does not sort.
        #expect(p.tab.sort == SortSpec(column: .name))
        await resize(.name, by: 1000)
        #expect(p.tab.widths == [.name: 600])
        await resize(.state, by: -1000)
        #expect(p.tab.widths == [.name: 600, .state: 24])
        #expect(p.table.tableColumns.map(\.width) == [28, 600, 24, 200, 112])
        // A width that the table shows from the config writes nothing.
        p.update(.setWidths(p.tab.id, [.project: 120]))
        await p.settle()
        #expect(p.tab.widths == [.name: 600, .state: 24, .project: 120])
    }

    @Test func aClickSelectsAndADoubleClickOpens() async throws {
        let p = try await OverviewParts(rows: Self.three)
        // A press on the text of a cell goes to the table.
        let driver = MouseDriver(window: p.window)
        #expect(driver.hitView(at: p.cellPoint(row: 1), in: p.table) === p.table)
        let ids = p.shownIDs
        p.click(row: 1)
        #expect(p.selection.selectedId == ids[1])
        #expect(p.window.firstResponder === p.rows)
        #expect(p.sinks.opened.isEmpty)
        p.doubleClick(row: 2)
        #expect(p.selection.selectedId == ids[2])
        #expect(p.sinks.opened == [ids[2]])
        // The selection of the table follows SelectionModel, so VoiceOver tells the selected
        // row. The row view draws the colours.
        await p.settle()
        #expect(p.table.selectedRowIndexes == IndexSet(integer: 2))
        p.selection.selectedId = nil
        await p.settle()
        #expect(p.table.selectedRowIndexes.isEmpty)
        p.selection.selectedId = ids[2]
        await p.settle()
        // A press and a release on two rows is no click.
        p.mouse(.leftMouseDown, row: 0)
        p.mouse(.leftMouseUp, row: 1)
        #expect(p.selection.selectedId == ids[2])
    }

    @Test func aDoubleClickDuringAHoldDoesNotOpen() async throws {
        let p = try await OverviewParts(rows: Self.three)
        let ids = p.shownIDs
        p.selection.selectedId = ids[0]
        p.rows.focus()
        // O is the hold key of open: while it is down, a click on a row runs the hold command on
        // the row and keeps the selection (D8).
        p.send("o")
        p.doubleClick(row: 2)
        p.send("o", down: false)
        #expect(p.sinks.opened.isEmpty)
        #expect(p.sinks.holdOpened.contains(ids[2]))
        #expect(p.selection.selectedId == ids[0])
    }

    @Test func aRightClickCallsShowRowMenuAndKeepsTheSelection() async throws {
        let p = try await OverviewParts(rows: Self.three)
        let ids = p.shownIDs
        p.selection.selectedId = ids[0]
        p.mouse(.rightMouseDown, row: 2)
        #expect(p.sinks.menus.map(\.id) == [ids[2]])
        let menu = try #require(p.sinks.menus.first)
        #expect(menu.view === p.rows)
        let expected = p.rows.convert(p.cellPoint(row: 2), from: p.table)
        #expect(menu.point == expected)
        #expect(p.selection.selectedId == ids[0])
        // A Control-click is a right-click.
        p.mouse(.leftMouseDown, row: 1, flags: .control)
        #expect(p.sinks.menus.map(\.id) == [ids[2], ids[1]])
        #expect(p.selection.selectedId == ids[0])
        // A right-click below the rows gives no menu.
        p.mouse(.rightMouseDown, at: NSPoint(x: 40, y: p.table.rect(ofRow: 2).maxY + 30))
        #expect(p.sinks.menus.count == 2)
        // The Show Menu action of VoiceOver on a row gives its menu too.
        let view = try #require(p.table.rowView(atRow: 1, makeIfNecessary: false))
        #expect(view.accessibilityPerformShowMenu())
        #expect(p.sinks.menus.map(\.id) == [ids[2], ids[1], ids[1]])
        #expect(p.selection.selectedId == ids[0])
    }

    @Test func theEmptyTextsOfTheOverview() async throws {
        let p = try await OverviewParts(rows: [])
        #expect(!p.rows.emptyText.isHidden)
        #expect(p.rows.emptyText.stringValue == "No sessions.")
        // The All tab does not show a parked row.
        p.source.apply(rows: [overviewRow(1, state: .parked)], error: nil)
        await p.settle()
        #expect(!p.rows.emptyText.isHidden)
        #expect(p.rows.emptyText.stringValue == "No sessions match the filters of this tab.")
        p.source.apply(rows: Self.three, error: nil)
        await p.settle()
        #expect(p.rows.emptyText.isHidden)
        #expect(p.table.numberOfRows == 3)
    }

    @Test func theTableTakesNoKeyOfItsOwn() async throws {
        let p = try await OverviewParts(rows: Self.three)
        #expect(!p.table.acceptsFirstResponder)
        #expect(!p.header.acceptsFirstResponder)
        // A call of makeFirstResponder for the table gives the first responder to the window.
        _ = p.window.makeFirstResponder(p.table)
        #expect(p.window.firstResponder !== p.table)
        p.rows.focus()
        #expect(p.window.firstResponder === p.rows)
        // A key that no Bifrost key uses goes up the responder chain, past the table.
        p.send("q")
        #expect(p.content.keys == ["q"])
        guard
            let key = USKeyboard.keyEvent(
                down: true, id: "z", mods: [], isRepeat: false, window: p.window)
        else {
            Issue.record("No key event.")
            return
        }
        p.table.keyDown(with: key)
        #expect(p.content.keys == ["q", "z"])
        // The arrow keys are Bifrost keys: they move the selection of SelectionModel in the rows
        // of the focused Overview, never the selection of the table.
        p.send("ArrowDown")
        #expect(p.selection.selectedId == p.shownIDs[0])
        #expect(p.table.selectedRowIndexes.isEmpty)
        #expect(p.content.keys == ["q", "z"])
    }

    @Test func theRowsViewHasTheOverviewRowsMark() async throws {
        let p = try await OverviewParts(rows: Self.three)
        let rows = try #require(
            (p.panels.body(for: OverviewParts.panelID) as? OverviewPanel)?.rows)
        #expect(rows === p.rows)
        #expect(rows.identifier == FocusMark.overviewRows(OverviewParts.panelID))
        // The rows are not in the Tab loop. A click on a row focuses them.
        #expect(!rows.canBecomeKeyView)
        _ = p.window.makeFirstResponder(nil)
        p.click(row: 0)
        #expect(p.window.firstResponder === rows)
        let focus = KeyFocus(p.window.firstResponder, in: p.window)
        #expect(focus.zone == .other)
        #expect(focus.target?.overviewRows == "overview:1")
        // A press on the header focuses the rows too, and its header has the tint until the
        // table ends the press. The table tracks the press itself, so the test gives the two
        // steps of the press.
        _ = p.window.makeFirstResponder(nil)
        let before = p.header.pressBegan(at: p.headerPoint(.name))
        #expect(p.window.firstResponder === rows)
        #expect(p.header.pressedColumn == .name)
        p.header.pressEnded(before)
        #expect(p.header.pressedColumn == nil)
    }

    @Test func aNewSelectionScrollsItsRowIntoView() async throws {
        let rows = (1...60).map { overviewRow($0, name: String(format: "row %02d", $0)) }
        let p = try await OverviewParts(rows: rows, size: NSSize(width: 800, height: 200))
        let last = try #require(p.shownIDs.last)
        #expect(!p.table.visibleRect.intersects(p.table.rect(ofRow: 59)))
        p.selection.selectedId = last
        await p.settle()
        await waitUntil(within: .seconds(5)) {
            p.table.visibleRect.contains(p.table.rect(ofRow: 59))
        }
        // The first row is out of view now. Its selection scrolls back to it.
        p.selection.selectedId = p.shownIDs[0]
        await p.settle()
        await waitUntil(within: .seconds(5)) {
            p.table.visibleRect.contains(p.table.rect(ofRow: 0))
        }
    }

    @Test func aWatchedRowHasItsColourAndStripe() async throws {
        var watched = overviewRow(1, name: "alpha")
        watched.watch = RowWatch(colour: .amber, order: 0)
        let p = try await OverviewParts(rows: [watched, overviewRow(2, name: "bravo")])
        let rowView = try #require(p.table.rowView(atRow: 0, makeIfNecessary: false))
        let look = try #require((rowView as? OverviewRowView)?.look)
        #expect(look.watch == ThemeTokens.watchAmber)
        #expect((p.table.rowView(atRow: 1, makeIfNecessary: false) as? OverviewRowView)?.look.watch
            == nil)
        // The pixels: the stripe of 3 units in the full colour at the left edge, then the colour
        // at 12 % over the panel colour.
        let ground = ThemeTokens.panel(transparency: 0)
        let pixels = Snapshot.pixels(
            try #require(Snapshot.image(of: rowView, background: ground.nsColor)))
        let width = Int(rowView.bounds.width) * Snapshot.scale
        let middle = Int(rowView.bounds.height) * Snapshot.scale / 2
        func pixel(_ x: Int) -> [Int] {
            let start = (middle * width + x) * 4
            return pixels[start..<(start + 3)].map(Int.init)
        }
        func near(_ one: [Int], _ two: [Double]) -> Bool {
            zip(one, two).allSatisfy { abs(Double($0) - $1) <= 2 }
        }
        let amber = ThemeTokens.watchAmber
        let back = [ground.r, ground.g, ground.b].map { $0 * 255 }
        let tint = zip([amber.r, amber.g, amber.b].map { $0 * 255 }, back).map {
            $0 * 0.12 + $1 * 0.88
        }
        #expect(near(pixel(2), [amber.r * 255, amber.g * 255, amber.b * 255]))
        // A stripe of 3 units is 6 pixels wide at scale 2.
        #expect(near(pixel(5), [amber.r * 255, amber.g * 255, amber.b * 255]))
        #expect(near(pixel(8), tint))
        #expect(near(pixel(width - 4), tint))
        // The selection shows on top of the watch colour, and the stripe stays.
        p.selection.selectedId = watched.sessionId
        await p.settle()
        #expect((rowView as? OverviewRowView)?.look.selected == true)
        let selected = Snapshot.pixels(
            try #require(Snapshot.image(of: rowView, background: ground.nsColor)))
        let start = (middle * width + 2) * 4
        #expect(near(selected[start..<(start + 3)].map(Int.init), pixel(2).map(Double.init)))
        let inner = (middle * width + width - 4) * 4
        #expect(selected[inner..<(inner + 3)].map(Int.init) != pixel(width - 4))
    }

    @Test func anExternalRowShowsTheIconOfItsTerminalApp() async throws {
        let calls = Recorder<String>()
        let image = NSImage(size: NSSize(width: 32, height: 32))
        let icons = SessionAppIcons(
            lookup: { bundle in
                calls.record(bundle)
                return bundle == "/Applications/Example Term.app" ? image : nil
            }, bifrost: { nil })
        let term = TerminalApp(name: "Example Term", bundle: "/Applications/Example Term.app")
        let p = try await OverviewParts(rows: [
            overviewRow(1, name: "alpha", kind: .external),
            overviewRow(2, name: "bravo", kind: .external), overviewRow(3, name: "charlie"),
        ])
        p.model.appIcon = { [icons] row in
            icons.icon(
                SessionIconRules.holder(
                    row, inChat: false, terminal: row.kind == .external ? term : nil))
        }
        await waitUntil(within: .seconds(10)) {
            p.rows.input?.appIcons.count == 2
        }
        await p.settle()
        for row in 0..<2 {
            let look = try #require(p.kindCell(row: row)?.icon.look)
            #expect(look.glyph == .app(image))
            #expect(look.title == "Example Term")
            #expect(p.kindCell(row: row)?.icon.glyphView.image === image)
        }
        // The owned row with no app keeps the Bifrost mark.
        #expect(p.kindCell(row: 2)?.icon.look?.glyph == .mark)
        // One lookup for the bundle path of the two rows.
        #expect(calls.values == ["/Applications/Example Term.app"])
    }

    // An owned row in a chat window of Bifrost shows the icon of the running app, an owned row
    // with a claude attach client in a terminal shows the icon of that terminal app, and an owned
    // row that nothing shows also shows the icon of the running app. When the
    // chat attaches, the icon changes at once: the table reads the attached chats during its
    // observation.
    @Test func anOwnedRowShowsTheIconOfTheAppThatShowsIt() async throws {
        let bifrostImage = NSImage(size: NSSize(width: 32, height: 32))
        let warpImage = NSImage(size: NSSize(width: 32, height: 32))
        let warp = TerminalApp(name: "Warp", bundle: "/Applications/Warp.app")
        let icons = SessionAppIcons(
            lookup: { $0 == warp.bundle ? warpImage : nil }, bifrost: { bifrostImage })
        let chats = AttachedSessions()
        let alpha = overviewRow(1, name: "alpha")
        let bravo = overviewRow(2, name: "bravo")
        let p = try await OverviewParts(rows: [alpha, bravo, overviewRow(3, name: "charlie")])
        p.model.appIcon = { [icons, chats] row in
            icons.icon(
                SessionIconRules.holder(
                    row, inChat: chats.sessions.contains(row.sessionId),
                    terminal: row.sessionId == bravo.sessionId ? warp : nil))
        }
        // Each owned row has an app: Bifrost, or Warp for bravo.
        await waitUntil(within: .seconds(10)) { p.rows.input?.appIcons.count == 3 }
        await p.settle()
        #expect(p.kindCell(row: 0)?.icon.look?.glyph == .app(bifrostImage))
        #expect(p.kindCell(row: 1)?.icon.look?.glyph == .app(warpImage))
        #expect(p.kindCell(row: 1)?.icon.look?.title == "Warp")
        // The chat of alpha attaches, and the chat of bravo too: a chat comes before Warp.
        chats.sessions = [alpha.sessionId, bravo.sessionId]
        await waitUntil(within: .seconds(10)) {
            p.kindCell(row: 0)?.icon.look?.glyph == .app(bifrostImage)
                && p.kindCell(row: 1)?.icon.look?.glyph == .app(bifrostImage)
        }
        #expect(p.kindCell(row: 0)?.icon.look?.title == "Bifrost")
        // The chat of bravo ends: Warp shows again.
        chats.sessions = [alpha.sessionId]
        await waitUntil(within: .seconds(10)) {
            p.kindCell(row: 1)?.icon.look?.glyph == .app(warpImage)
        }
        #expect(p.kindCell(row: 2)?.icon.look?.glyph == .app(bifrostImage))
    }

    // The icon of a terminal app comes from the path of its bundle. A path that is not an app
    // bundle that exists gives no icon, so the row keeps its glyph.
    @Test func theIconOfATerminalAppComesFromThePathOfItsBundle() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bundle = folder.appending("Term.app")
        try FileManager.default.createDirectory(
            atPath: bundle, withIntermediateDirectories: false)
        let file = folder.appending("File.app")
        try Data().write(to: URL(fileURLWithPath: file))
        #expect(SessionAppIcons.bundleIcon(bundle) != nil)
        #expect(SessionAppIcons.bundleIcon(folder.appending("Missing.app")) == nil)
        #expect(SessionAppIcons.bundleIcon(file) == nil)
        #expect(SessionAppIcons.bundleIcon(folder.path) == nil)
        #expect(SessionAppIcons.bundleIcon("dev.warp.Warp-Stable") == nil)
    }

    @Test func theAgeTextChangesAtItsStep() async throws {
        let p = try await OverviewParts(rows: [])
        let now = p.wall.milliseconds
        p.source.apply(
            rows: [
                overviewRow(1, name: "alpha", lastActivity: now - 59_000),
                overviewRow(2, name: "bravo", lastActivity: now - 3_000_000),
            ], error: nil)
        await p.settle()
        #expect(p.text(row: 0, column: .activity) == "59 s")
        #expect(p.text(row: 1, column: .activity) == "50 min")
        // The earliest step of the rows: 1 s, until "1 min".
        await p.clock.waitForSleepers(1)
        p.wall.advance(1)
        p.clock.advance(by: .seconds(1))
        await waitUntil(within: .seconds(10)) {
            p.text(row: 0, column: .activity) == "1 min"
        }
        // The next step is a minute.
        await p.clock.waitForSleepers(1)
        p.wall.advance(30)
        p.clock.advance(by: .seconds(30))
        #expect(p.text(row: 0, column: .activity) == "1 min")
        p.wall.advance(30)
        p.clock.advance(by: .seconds(30))
        await waitUntil(within: .seconds(10)) {
            p.text(row: 0, column: .activity) == "2 min"
                && p.text(row: 1, column: .activity) == "51 min"
        }
    }

    // A stack tab hides the body and shows it again: out of the window the age timer stops, and
    // back in the window the texts show the time of now and the timer waits again.
    @Test func theAgeTextsCatchUpWhenThePanelComesBack() async throws {
        let p = try await OverviewParts(rows: [])
        p.source.apply(
            rows: [overviewRow(1, name: "alpha", lastActivity: p.wall.milliseconds - 59_000)],
            error: nil)
        await p.settle()
        #expect(p.text(row: 0, column: .activity) == "59 s")
        await p.clock.waitForSleepers(exactly: 1)
        p.body.removeFromSuperview()
        await p.clock.waitUntilNoSleepers()
        p.wall.advance(61)
        p.clock.advance(by: .seconds(61))
        #expect(p.text(row: 0, column: .activity) == "59 s")
        p.content.addSubview(p.body)
        #expect(p.text(row: 0, column: .activity) == "2 min")
        await p.clock.waitForSleepers(exactly: 1)
    }

    // The header has the panel colour: a row that scrolls under it does not show through.
    @Test func theHeaderHidesTheRowsThatScrollUnderIt() async throws {
        var rows = (1...60).map { overviewRow($0, name: String(format: "row %02d", $0)) }
        rows[1].watch = RowWatch(colour: .white, order: 0)
        let p = try await OverviewParts(rows: rows, size: NSSize(width: 800, height: 200))
        p.look.panelTransparency = 0
        p.selection.selectedId = rows[0].sessionId
        await p.settle()
        p.rows.focus()
        p.send("PageDown")
        #expect(p.scrolled.y > 0)
        p.rows.layoutSubtreeIfNeeded()
        let image = try #require(Snapshot.image(of: p.rows, background: .red))
        // A point of the header with no text: the right part of the Name header.
        let name = p.header.headerRect(ofColumn: p.columnIndex(.name))
        let point = p.rows.convert(
            NSPoint(x: name.maxX - 20, y: name.midY), from: p.header)
        let panel = OverviewParts.channels(ThemeTokens.panel(transparency: 0))
        let pixel = OverviewParts.pixel(image, at: point, in: p.rows)
        #expect(zip(pixel, panel).allSatisfy { abs($0 - $1) <= 2 })
    }

    // The keys that no Bifrost key takes scroll the rows, as in the Electron app. The arrow keys
    // up and down stay Bifrost keys and move the selection.
    @Test func theScrollKeysScrollTheRows() async throws {
        let rows = (1...60).map { overviewRow($0, name: String(format: "row %02d", $0)) }
        let p = try await OverviewParts(rows: rows, size: NSSize(width: 400, height: 200))
        p.rows.focus()
        let top = p.scrolled.y
        p.send("PageDown")
        let page = p.scrolled.y - top
        #expect(page > 100)
        p.send("Space")
        #expect(abs(p.scrolled.y - (top + 2 * page)) < 1)
        p.send("Space", [.shift])
        #expect(abs(p.scrolled.y - (top + page)) < 1)
        p.send("PageUp")
        #expect(p.scrolled.y == top)
        p.send("End")
        #expect(p.table.visibleRect.maxY >= p.table.rect(ofRow: 59).maxY)
        p.send("Home")
        #expect(p.scrolled.y == top)
        // The columns are wider than the panel: Right and Left scroll them by 40 units.
        p.send("ArrowRight")
        #expect(p.scrolled.x == 40)
        p.send("ArrowLeft")
        #expect(p.scrolled.x == 0)
        // A key with Command does not scroll: it goes on up the responder chain. The arrow keys
        // move the selection.
        p.send("End", [.meta])
        #expect(p.scrolled.y == top)
        #expect(p.content.keys.count == 1)
        p.send("ArrowDown")
        p.send("ArrowDown")
        #expect(p.selection.selectedId == p.shownIDs[1])
        #expect(p.scrolled.y == top)
        // A key that does not scroll goes on up the responder chain.
        p.send("q")
        #expect(p.content.keys.last == "q")
        #expect(p.content.keys.count == 2)
    }

    // A press gives the row the press tint until the release, and the pointer gives the hover.
    @Test func aPressAndAHoverTintTheRow() async throws {
        let p = try await OverviewParts(rows: Self.three)
        p.mouse(.leftMouseDown, row: 1)
        #expect(p.look(row: 1)?.pressed == true)
        #expect(p.look(row: 0)?.pressed == false)
        p.mouse(.leftMouseUp, row: 1)
        #expect(p.look(row: 1)?.pressed == false)
        p.hover(row: 2)
        #expect(p.look(row: 2)?.hovered == true)
        #expect(p.look(row: 1)?.hovered == false)
        p.hover(row: nil)
        #expect(p.look(row: 2)?.hovered == false)
        // A row whose chat is open has the hover colour too.
        let id = p.shownIDs[0]
        p.layout.apply(.open(panel("chat:\(id)")))
        await p.settle()
        #expect(p.look(row: 0)?.openChat == true)
        #expect(p.look(row: 0)?.overlay == ThemeTokens.hover)
    }

    // A re-sort under a still pointer gives the hover to the row that is under it now.
    @Test func theHoverFollowsTheRowUnderAStillPointer() async throws {
        let p = try await OverviewParts(rows: Self.three)
        p.hover(row: 0)
        let first = p.shownIDs[0]
        #expect(p.look(row: 0)?.hovered == true)
        p.update(.sortBy(p.tab.id, .name))
        await p.settle()
        #expect(p.shownIDs[0] != first)
        #expect(p.look(row: 0)?.hovered == true)
        #expect(p.look(row: 2)?.hovered == false)
    }

    // A stop (the body leaves its window) clears the pointer, the hover and the press. So a row
    // that comes under the old pointer place later does not take the hover.
    @Test func aStopClearsThePointerTheHoverAndThePress() async throws {
        let p = try await OverviewParts(rows: Self.three)
        p.hover(row: 0)
        p.mouse(.leftMouseDown, row: 1)
        #expect(p.look(row: 0)?.hovered == true)
        #expect(p.look(row: 1)?.pressed == true)
        p.rows.stop()
        #expect(p.look(row: 0)?.hovered == false)
        #expect(p.look(row: 1)?.pressed == false)
        p.update(.sortBy(p.tab.id, .name))
        await p.settle()
        #expect((0..<3).allSatisfy { p.look(row: $0)?.hovered == false })
        // The release of the old press selects nothing.
        p.mouse(.leftMouseUp, row: 1)
        #expect(p.selection.selectedId == nil)
    }

    // The cells of a parked row have the parked colour, except the state label of its tone.
    @Test func aParkedRowHasTheParkedColourInTheTable() async throws {
        let p = try await OverviewParts(rows: [overviewRow(1, name: "alpha", state: .parked)])
        p.update(.activate("t5"))
        await p.settle()
        let name = p.table.view(atColumn: p.columnIndex(.name), row: 0, makeIfNecessary: false)
        #expect((name as? OverviewTextCell)?.label.textColor == ThemeTokens.parked.nsColor)
        #expect(p.kindCell(row: 0)?.icon.glyphView.contentTintColor == ThemeTokens.parked.nsColor)
    }

    // The error line shows the friendly reason of a failed update, and the reason of a missing
    // claude. A good update hides it.
    @Test func theErrorLineShowsTheReasonOfTheSessionList() async throws {
        let p = try await OverviewParts(rows: Self.three)
        #expect(p.body.errorLine.isHidden)
        let failed = AgentListError.commandFailed(detail: "exit 1")
        p.source.apply(rows: Self.three, error: failed)
        await waitUntil(within: .seconds(10)) { !p.body.errorLine.isHidden }
        #expect(p.body.errorLine.label.stringValue == failed.message)
        // The rows of the update stay.
        #expect(p.table.numberOfRows == 3)
        p.body.layoutSubtreeIfNeeded()
        #expect(p.body.errorLine.frame.maxY == p.body.bounds.maxY)
        #expect(p.body.rows.frame.maxY == p.body.errorLine.frame.minY)
        p.source.apply(rows: Self.three, error: nil)
        await waitUntil(within: .seconds(10)) { p.body.errorLine.isHidden }
        p.sessions.claudeMissing()
        await waitUntil(within: .seconds(10)) { !p.body.errorLine.isHidden }
        #expect(p.body.errorLine.label.stringValue == AgentListError.claudeNotFound.message)
        await p.settle()
        #expect(p.rows.emptyText.stringValue == "No sessions.")
    }

    // The header cell of the sort column has the sort direction, for VoiceOver.
    @Test func theSortColumnTellsItsDirection() async throws {
        let p = try await OverviewParts(rows: Self.three)
        func direction(_ column: OverviewColumn) -> NSAccessibilitySortDirection {
            p.table.tableColumns[p.columnIndex(column)].headerCell.accessibilitySortDirection()
        }
        #expect(direction(.name) == .ascending)
        #expect(direction(.state) == .unknown)
        p.update(.sortBy(p.tab.id, .state))
        p.update(.sortBy(p.tab.id, .state))
        await p.settle()
        #expect(direction(.state) == .descending)
        #expect(direction(.name) == .unknown)
    }
}
