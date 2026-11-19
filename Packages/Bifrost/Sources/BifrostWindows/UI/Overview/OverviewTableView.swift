// The rows of an Overview (docs/behaviour/overview.md, The table): the header and the rows of the
// active tab. The rows are an NSTableView (user decision, 2026-11-16): its column API fits the
// column rules (the fixed kind column, the own width clamp, the own sort cycle and the place of a
// hidden column), and it reuses the views of its cells for a live list.
//
// - The table has one column for each visible column of the tab, in the tab order, with its
//   width. The column APIs of the table do the pointer work of the header: a click on a header
//   sorts (tableView(_:didClick:)), a drag of a header moves its column, and a drag of the edge
//   between two headers resizes the left column only. The kind column never moves, and no
//   column moves before it. A drag of a column moves it live in the table; at the end of the
//   drag one change of the config gives the move (headerDragEnded(_:)). The header
//   (OverviewHeaderView) draws the labels, the sort mark and the press tint itself.
// - The selection is SelectionModel. The table refuses each selection of the user, and its own
//   selection only follows SelectionModel, so VoiceOver tells the selected row. The row view
//   draws the colours of a row (OverviewRowView), and the table draws no selection. The Show
//   Menu action of VoiceOver on a row opens the row menu.
// - The rows view takes the first responder at a click. It has the Overview rows mark, so the
//   focus zone is "other" and the Bifrost keys act on the rows. The table and the header never
//   take the first responder, and the table gives each key to the next responder. A key that no
//   Bifrost key took comes to the rows view: the scroll keys scroll the rows (RowsScroll), and
//   each other key goes on to the next responder.
// - One TimerSlot changes the age texts of the Activity column at the earliest step of the rows.
//   It stops while the panel is in no window. When the panel comes back, the texts show the time
//   of now and the timer starts again.
// - The panel gives a new TableInput at each change of a value that the table shows. A value
//   equal to the last one does nothing, so the table does no work when nothing changes.
// - After the rows of the tab come the Starting rows of the New session starts (StartingSession).
//   They have the plain look and give no click, no menu and no hover. A new one scrolls into
//   view.
import AppKit
import BifrostFoundation
import BifrostKeyboard
import BifrostLayout
import BifrostLook
import BifrostSessions

// The values that the table of one Overview shows.
package struct TableInput: Equatable, Sendable {
    package var tab: String
    // The visible columns in the tab order, and their widths in layout units.
    package var columns: [OverviewColumn]
    package var widths: [Double]
    package var sort: SortSpec
    // The rows of the active tab, in the view order.
    package var rows: [SessionRow]
    // The Starting rows after the rows (OverviewModel.startingRows).
    package var starting: [StartingSession]
    // True when the session list has rows. The empty text tells whether the filters hide them.
    package var listHasRows: Bool
    package var selected: String?
    package var openChats: Set<SessionID>
    package var rowFlash: Bool
    // The icon of the app that shows each row that has one, by row ID.
    package var appIcons: [String: AppIcon]
    package var metrics: CanvasMetrics
    // The Panel transparency in percent, for the fill of the header.
    package var transparency: Int

    @MainActor
    package init(model: OverviewModel, panel: PanelID, look: PanelLook) {
        let tab = model.config(panel).activeTab
        let all = model.sessions.rows
        self.tab = tab.id
        columns = tab.tableColumns.map(\.column)
        widths = tab.tableColumns.map(\.width)
        sort = tab.sort
        rows = OverviewRows.view(all, tab: tab)
        starting = model.startingRows
        listHasRows = !all.isEmpty
        selected = model.selection.selectedId
        openChats = model.openChats
        rowFlash = model.rowFlash
        appIcons = model.appIcons(rows)
        metrics = look.metrics
        transparency = look.panelTransparency
    }

    // The start of the Starting row at the index of the table, or nil for a row of the tab.
    package func start(at index: Int) -> StartingSession? {
        let place = index - rows.count
        return starting.indices.contains(place) ? starting[place] : nil
    }
}

// The rows view of one Overview: the scroll view with the table and its header, and the empty
// text. It is the data source and the delegate of the table.
@MainActor
package final class OverviewRowsView: NSView, NSTableViewDataSource, NSTableViewDelegate,
    SessionRowsPointer
{
    // The texts of an empty table: no session at all, or no row that the filters of the tab show.
    package static let noSessions = "No sessions."
    package static let noMatch = "No sessions match the filters of this tab."
    private static let rowViewID = NSUserInterfaceItemIdentifier("overview-row")

    package let panel: PanelID
    private let model: OverviewModel
    // The key filter of the window, for the hold keys of a row click (D8).
    private let filter: () -> WindowKeyFilter?
    package let scrollView = NSScrollView()
    package let table = OverviewTable()
    package let header = OverviewHeaderView()
    package let emptyText = PassiveLabel(labelWithString: "")
    package private(set) var input: TableInput?
    private let ageTimer: TimerSlot
    // The row under the pointer, and the row with the primary button down, by row ID.
    private var hoveredRow: String?
    private var pressedRow: String?
    // The pointer in the coordinates of the window while it is over the table. A row that moves
    // under a still pointer takes the hover.
    private var pointer: NSPoint?

    package init(panel: PanelID, model: OverviewModel, filter: @escaping () -> WindowKeyFilter?) {
        self.panel = panel
        self.model = model
        self.filter = filter
        ageTimer = TimerSlot(clock: model.clock)
        super.init(frame: .zero)
        identifier = FocusMark.overviewRows(panel)
        table.rows = self
        table.pointer = self
        header.rows = self
        table.headerView = header
        table.cornerView = nil
        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        emptyText.textColor = ThemeTokens.textDim.nsColor
        emptyText.isHidden = true
        addSubview(emptyText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override package var isFlipped: Bool { true }
    override package var acceptsFirstResponder: Bool { true }
    // The rows are not in the Tab loop of the window. A click or the focus key focuses them.
    override package var canBecomeKeyView: Bool { false }

    override package func mouseDown(with event: NSEvent) { focus() }

    // A key that no Bifrost key took. A scroll key scrolls the rows, and each other key goes to
    // the next responder.
    override package func keyDown(with event: NSEvent) {
        guard let key = KeyEvent(event, isComposing: false), let move = RowsScroll(key) else {
            super.keyDown(with: event)
            return
        }
        scroll(move)
    }

    // Make the rows view the first responder, so the Bifrost keys act on this Overview.
    package func focus() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    override package func layout() {
        super.layout()
        scrollView.frame = bounds
        guard let metrics = input?.metrics else { return }
        let padding = metrics.points(8)
        let height = emptyText.intrinsicContentSize.height
        emptyText.frame = NSRect(
            x: padding,
            y: metrics.points(OverviewSizes.headerHeight) + metrics.points(2),
            width: max(0, bounds.width - 2 * padding), height: height)
    }

    // The panel is in no window: the age timer stops, and the pointer and the press go, also on
    // the header.
    package func stop() {
        ageTimer.stop()
        pointer = nil
        hoveredRow = nil
        pressedRow = nil
        refreshRowLooks()
        header.stop()
    }

    // The panel is in a window again: the age texts show the time of now, and the age timer
    // starts again.
    package func resume() {
        ageTick()
    }

    // MARK: - The values

    package func apply(_ new: TableInput) {
        guard new != input else { return }
        let old = input
        input = new
        let metrics = new.metrics
        let scaleChanged = old?.metrics != metrics
        if scaleChanged { applyMetrics(metrics) }
        let columnsChanged = scaleChanged || old?.columns != new.columns
        if columnsChanged {
            setColumns(new)
        } else if old?.widths != new.widths {
            for (index, width) in new.widths.enumerated() {
                table.tableColumns[index].width = metrics.points(width)
            }
        }
        if columnsChanged || old?.widths != new.widths || old?.sort != new.sort
            || old?.transparency != new.transparency
        {
            header.columnsChanged()
        }
        if columnsChanged || old?.sort != new.sort { showSortIndicator(new.sort) }
        reloadRows(old: columnsChanged ? nil : old, new: new)
        // A new Starting row scrolls into view.
        if let added = new.starting.last,
            old?.starting.contains(where: { $0.id == added.id }) != true
        {
            table.scrollRowToVisible(new.rows.count + new.starting.count - 1)
        }
        table.showSelection(new.selected, in: new.rows)
        hoveredRow = pointerRow()
        refreshRowLooks()
        if new.selected != old?.selected, let selected = new.selected,
            let index = new.rows.firstIndex(where: { $0.sessionId == selected })
        {
            table.scrollRowToVisible(index)
        }
        emptyText.isHidden = !new.rows.isEmpty || !new.starting.isEmpty
        emptyText.stringValue = new.listHasRows ? Self.noMatch : Self.noSessions
        needsLayout = true
        scheduleAge()
    }

    private func applyMetrics(_ metrics: CanvasMetrics) {
        table.rowHeight = metrics.points(OverviewSizes.rowHeight)
        header.frame.size.height = metrics.points(OverviewSizes.headerHeight)
        emptyText.font = Fonts.ui(metrics.points(OverviewSizes.textSize), weight: .regular)
        scrollView.tile()
    }

    private func setColumns(_ input: TableInput) {
        let metrics = input.metrics
        for column in table.tableColumns.reversed() { table.removeTableColumn(column) }
        for (column, width) in zip(input.columns, input.widths) {
            let tableColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            // The header draws the labels. The title is the name of the column for
            // accessibility: the kind column has no label, so its name is "Kind".
            tableColumn.title = column == .kind ? "Kind" : column.label
            tableColumn.minWidth = metrics.points(OverviewColumn.minWidth)
            tableColumn.maxWidth = metrics.points(OverviewColumn.maxWidth)
            tableColumn.width = metrics.points(width)
            tableColumn.resizingMask = .userResizingMask
            table.addTableColumn(tableColumn)
        }
    }

    // The sort for VoiceOver: the header cell of the sort column has the indicator image of its
    // direction, and so its sort direction. The header draws its own mark, not the image.
    private func showSortIndicator(_ sort: SortSpec) {
        let name = sort.descending ? "NSDescendingSortIndicator" : "NSAscendingSortIndicator"
        for tableColumn in table.tableColumns {
            let isSort = tableColumn.identifier.rawValue == sort.column.rawValue
            table.setIndicatorImage(isSort ? NSImage(named: name) : nil, in: tableColumn)
        }
    }

    // Reload the rows that changed. A change of the row IDs, of the columns, of the Row flash
    // setting or of the Starting rows reloads all rows. With no old value, all rows reload.
    private func reloadRows(old: TableInput?, new: TableInput) {
        table.reloadChanged(
            old: old?.rows, new: new.rows, oldIcons: old?.appIcons ?? [:], newIcons: new.appIcons,
            all: old?.rowFlash != new.rowFlash || old?.starting != new.starting,
            columns: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    // MARK: - The age texts

    // Start the age timer at the earliest step of the rows. With no Activity column, or with no
    // rows, no timer runs.
    private func scheduleAge() {
        guard let input, input.columns.contains(.activity), window != nil else {
            ageTimer.stop()
            return
        }
        let now = model.nowMilliseconds
        guard
            let step = input.rows.map({ TimeText.ageStep(since: $0.lastActivity, now: now) }).min()
        else {
            ageTimer.stop()
            return
        }
        ageTimer.start(after: step) { [weak self] in self?.ageTick() }
    }

    private func ageTick() {
        guard let input, let column = input.columns.firstIndex(of: .activity) else { return }
        table.reloadData(
            forRowIndexes: IndexSet(integersIn: 0..<input.rows.count), columnIndexes: [column])
        scheduleAge()
    }

    // MARK: - The pointer

    private func rowID(_ index: Int) -> String? {
        guard let input, input.rows.indices.contains(index) else { return nil }
        return input.rows[index].sessionId
    }

    // A primary press on the table. A press on a row claims a held hold key for the row (D8),
    // and gives the row the press tint.
    package func press(at point: NSPoint) {
        focus()
        guard let id = rowID(table.row(at: point)) else { return }
        pressedRow = id
        refreshRowLooks()
        filter()?.rowPress(id)
    }

    // The table moves no row: a drag of the pointer does nothing.
    package func dragged(to point: NSPoint, event: NSEvent) {}

    // The release of a press. On the row of the press it is a click (OverviewModel.rowClicked).
    package func release(at point: NSPoint, clicks: Int) {
        let pressed = pressedRow
        pressedRow = nil
        refreshRowLooks()
        guard let pressed, rowID(table.row(at: point)) == pressed else { return }
        model.rowClicked(pressed, clicks: clicks, filter: filter())
    }

    // A right-click on a row gives the row menu at the click point. It does not change the
    // selection (D6). A right-click outside a row does nothing.
    package func rightClick(at point: NSPoint) {
        focus()
        let index = table.row(at: point)
        guard let input, input.rows.indices.contains(index) else { return }
        model.showRowMenu(input.rows[index], convert(point, from: table), self)
    }

    // The Show Menu action of VoiceOver on the row with the ID: the row menu at the left of the
    // bottom of the row. A row that left the list gives no menu.
    func showMenu(forRow id: String) {
        guard let input, let index = input.rows.firstIndex(where: { $0.sessionId == id }) else {
            return
        }
        let rect = table.rect(ofRow: index)
        let point = NSPoint(x: rect.minX + table.intercellSpacing.width, y: rect.maxY)
        model.showRowMenu(input.rows[index], convert(point, from: table), self)
    }

    // The pointer moved to the point of the window over the table, or left the table (nil).
    func hover(at windowPoint: NSPoint?) {
        pointer = windowPoint
        updateHover()
    }

    // The row under the pointer now.
    private func pointerRow() -> String? {
        pointer.flatMap { rowID(table.row(at: table.convert($0, from: nil))) }
    }

    private func updateHover() {
        let id = pointerRow()
        guard id != hoveredRow else { return }
        hoveredRow = id
        refreshRowLooks()
    }

    // MARK: - The scroll keys

    // Scroll the rows. The clip view keeps the new place inside the rows and the header.
    private func scroll(_ move: RowsScroll) {
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let shown = clip.bounds.height - insets.top - insets.bottom
        let page = max(0, shown - scrollView.verticalPageScroll)
        let step = (input?.metrics ?? CanvasMetrics(interfaceScale: 100)).points(RowsScroll.step)
        let far: CGFloat = 1e7
        var origin = clip.bounds.origin
        switch move {
        case .pageUp: origin.y -= page
        case .pageDown: origin.y += page
        case .top: origin.y = -far
        case .bottom: origin.y = far
        case .left: origin.x -= step
        case .right: origin.x += step
        }
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
        guard target.origin != clip.bounds.origin else { return }
        clip.scroll(to: target.origin)
        scrollView.reflectScrolledClipView(clip)
        updateHover()
    }

    // MARK: - The header

    func sort(by column: OverviewColumn) {
        guard let input else { return }
        model.update(panel, .sortBy(input.tab, column))
    }

    // A drop of the dragged column on the header of target.
    func move(_ column: OverviewColumn, onto target: OverviewColumn) {
        guard let input,
            let before = ColumnDrag.dropBefore(input.columns, from: column, to: target)
        else { return }
        model.update(panel, .moveColumn(input.tab, column, before: before))
    }

    // A resize changes only its own column. The config keeps the width in its limits, in whole
    // layout units.
    func resize(_ column: OverviewColumn, to width: Double) {
        guard let input else { return }
        model.update(panel, .setWidths(input.tab, [column: width]))
    }

    // The columns of the table, in the order of the table: a drag of a header moves them live.
    package var columnOrder: [OverviewColumn] {
        table.tableColumns.compactMap { OverviewColumn(rawValue: $0.identifier.rawValue) }
    }

    // The press on the header ended. When a drag of a header moved its column, the config gets
    // the one move from the order before the press to the order of now.
    package func headerDragEnded(_ before: [OverviewColumn]) {
        let after = columnOrder
        guard after != before, let (column, target) = Self.move(from: before, to: after) else {
            return
        }
        move(column, onto: target)
    }

    // The column that moved and the header that it went onto, for the order before and after one
    // move of one column.
    static func move(
        from before: [OverviewColumn], to after: [OverviewColumn]
    ) -> (OverviewColumn, OverviewColumn)? {
        guard before.count == after.count, Set(before) == Set(after) else { return nil }
        for column in before {
            var rest = before
            rest.removeAll { $0 == column }
            guard let place = after.firstIndex(of: column) else { continue }
            var placed = rest
            placed.insert(column, at: place)
            if placed == after, let from = before.firstIndex(of: column), from != place {
                return (column, before[place])
            }
        }
        return nil
    }

    // MARK: - The row looks

    private func rowLook(_ row: SessionRow, _ input: TableInput) -> RowLook {
        RowLook(
            watch: row.watch?.colour.token, selected: row.sessionId == input.selected,
            openChat: SessionID(row.sessionId).map(input.openChats.contains) ?? false,
            hovered: row.sessionId == hoveredRow, pressed: row.sessionId == pressedRow)
    }

    private func refreshRowLooks() {
        table.enumerateAvailableRowViews { view, index in
            self.showLook(view, index)
        }
    }

    private func showLook(_ view: NSTableRowView, _ index: Int) {
        guard let view = view as? OverviewRowView, let input else { return }
        view.stripe = input.metrics.points(OverviewSizes.watchStripe)
        // A reused row view of a Starting row loses the look and the menu of its last row.
        guard input.rows.indices.contains(index) else {
            view.look = RowLook()
            view.showMenu = nil
            return
        }
        view.look = rowLook(input.rows[index], input)
        let id = input.rows[index].sessionId
        view.showMenu = { [weak self] in self?.showMenu(forRow: id) }
    }

    // MARK: - The data source and the delegate

    package func numberOfRows(in tableView: NSTableView) -> Int {
        (input?.rows.count ?? 0) + (input?.starting.count ?? 0)
    }

    package func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int
    ) -> NSView? {
        guard let input, let id = tableColumn?.identifier,
            let column = OverviewColumn(rawValue: id.rawValue)
        else { return nil }
        // A Starting row has no icon.
        if let start = input.start(at: index) {
            guard column != .kind else { return nil }
            let cell = reused(id, OverviewTextCell.init)
            cell.show(CellContent.of(start, column), parked: false, metrics: input.metrics)
            return cell
        }
        guard input.rows.indices.contains(index) else { return nil }
        let row = input.rows[index]
        if column == .kind {
            let cell = reused(id, OverviewKindCell.init)
            let look = SessionIconLook(
                row: row, appIcon: input.appIcons[row.sessionId], rowFlash: input.rowFlash)
            cell.show(look, metrics: input.metrics)
            return cell
        }
        let cell = reused(id, OverviewTextCell.init)
        cell.show(
            CellContent.of(row, column, now: model.nowMilliseconds), parked: row.state == .parked,
            metrics: input.metrics)
        return cell
    }

    // A cell view of the table to reuse, or a new one.
    private func reused<Cell: NSView>(
        _ id: NSUserInterfaceItemIdentifier, _ make: (NSRect) -> Cell
    ) -> Cell {
        if let cell = table.makeView(withIdentifier: id, owner: nil) as? Cell { return cell }
        let cell = make(.zero)
        cell.identifier = id
        return cell
    }

    package func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        reused(Self.rowViewID) { OverviewRowView(frame: $0) }
    }

    package func tableView(
        _ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int
    ) {
        showLook(rowView, row)
    }

    // MARK: - The column APIs of the table

    // A click on a header sorts by its column. A press that became a drag or a resize is no
    // click.
    package func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let column = OverviewColumn(rawValue: tableColumn.identifier.rawValue) else {
            return
        }
        sort(by: column)
    }

    // The kind column never moves, and no column moves before it. newColumnIndex is -1 when the
    // drag starts.
    package func tableView(
        _ tableView: NSTableView, shouldReorderColumn columnIndex: Int,
        toColumn newColumnIndex: Int
    ) -> Bool {
        guard tableView.tableColumns.indices.contains(columnIndex),
            tableView.tableColumns[columnIndex].identifier.rawValue != OverviewColumn.kind.rawValue
        else { return false }
        return newColumnIndex != 0
    }

    // A width that the user gives a column goes to the config. A width that the table shows
    // from the config is no change.
    package func tableViewColumnDidResize(_ notification: Notification) {
        guard let input,
            let tableColumn = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
            let column = OverviewColumn(rawValue: tableColumn.identifier.rawValue),
            let index = input.columns.firstIndex(of: column)
        else { return }
        let width = OverviewColumn.clamp(width: tableColumn.width / input.metrics.scale)
        guard width != OverviewColumn.clamp(width: input.widths[index]) else { return }
        resize(column, to: width)
    }

    // The user never selects a row of the table: SelectionModel owns the selection.
    package func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    package func selectionShouldChange(in tableView: NSTableView) -> Bool { false }
}

// A key that scrolls the rows, as the keys scrolled the list of the Electron app. The window
// filter takes each Bifrost key first, so only a key that no binding took comes here. A key with
// Command, Control or Option does not scroll.
package enum RowsScroll: Equatable {
    case pageUp, pageDown, top, bottom, left, right

    // The scroll of an arrow key, in layout units.
    package static let step = 40.0

    // Page Up and Page Down scroll a page, Home and End go to the top and the bottom, Space and
    // Shift+Space scroll a page down and up, and Left and Right scroll the columns.
    package init?(_ key: KeyEvent) {
        guard key.isDown, key.modifiers.isDisjoint(with: [.command, .control, .option]),
            case .named(let name) = key.key
        else { return nil }
        switch name {
        case .pageUp: self = .pageUp
        case .pageDown: self = .pageDown
        case .home: self = .top
        case .end: self = .bottom
        case .space: self = key.modifiers.contains(.shift) ? .pageUp : .pageDown
        case .arrowLeft: self = .left
        case .arrowRight: self = .right
        default: return nil
        }
    }
}

// A label that a click goes through, so a click on the empty text focuses the rows.
@MainActor
package final class PassiveLabel: NSTextField {
    override package func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// The table of the rows: a table of session rows (SessionRowsTable) whose rows view handles the
// pointer. The table also tells the rows view where the pointer is, for the hover.
@MainActor
package final class OverviewTable: SessionRowsTable {
    weak var rows: OverviewRowsView?
    private var hoverArea: NSTrackingArea?

    override package init() {
        super.init()
        columnAutoresizingStyle = .noColumnAutoresizing
        allowsColumnReordering = true
        allowsColumnResizing = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override package func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override package func mouseMoved(with event: NSEvent) {
        rows?.hover(at: event.locationInWindow)
    }

    override package func mouseEntered(with event: NSEvent) {
        rows?.hover(at: event.locationInWindow)
    }

    override package func mouseExited(with event: NSEvent) { rows?.hover(at: nil) }

    // A scroll moves the rows under the pointer.
    override package func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        rows?.hover(at: event.locationInWindow)
    }
}

// The header of the table. The table does the pointer work of the header (a click sorts, a drag
// moves a column, a drag of an edge resizes a column). The header draws each column header
// itself, with the panel colour behind it: the label in the dim text colour, then the sort mark
// of the sort column (▲ ascending, ▼ descending), and the cyan tint on the header of a press. A
// header that the user drags draws at its live place. A press on the header focuses the rows.
@MainActor
package final class OverviewHeaderView: NSTableHeaderView {
    weak var rows: OverviewRowsView?
    // The column of the press on its header, or nil.
    private var pressed: OverviewColumn?

    override package var acceptsFirstResponder: Bool { false }

    private var metrics: CanvasMetrics {
        rows?.input?.metrics ?? CanvasMetrics(interfaceScale: 100)
    }

    // The columns, the widths or the sort changed.
    func columnsChanged() {
        needsDisplay = true
    }

    // The sort mark of the column: ▲ or ▼ for the sort column, else nil.
    package func sortMark(_ column: OverviewColumn) -> String? {
        guard let sort = rows?.input?.sort, sort.column == column else { return nil }
        return sort.descending ? "▼" : "▲"
    }

    private func overviewColumn(_ index: Int) -> OverviewColumn? {
        guard let table = tableView, table.tableColumns.indices.contains(index) else { return nil }
        return OverviewColumn(rawValue: table.tableColumns[index].identifier.rawValue)
    }

    // MARK: - The pointer

    // The table tracks the press until its release: a click, a move or a resize. The press tint
    // shows on its header until then, and the end of the press commits a move.
    override package func mouseDown(with event: NSEvent) {
        let before = pressBegan(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        pressEnded(before)
    }

    // A press at the point of the header: the rows get the focus, and the header of the press
    // gets the tint. The result is the order of the columns before the press.
    func pressBegan(at point: NSPoint) -> [OverviewColumn] {
        rows?.focus()
        pressed = overviewColumn(column(at: point))
        needsDisplay = true
        return rows?.columnOrder ?? []
    }

    // The table ended the press: the tint goes, and a move of a column goes to the config.
    func pressEnded(_ before: [OverviewColumn]) {
        pressed = nil
        needsDisplay = true
        rows?.headerDragEnded(before)
    }

    // The column whose header has the press tint, or nil.
    var pressedColumn: OverviewColumn? { pressed }

    override package func rightMouseDown(with event: NSEvent) {}

    // The table is in no window: the press tint goes.
    func stop() {
        guard pressed != nil else { return }
        pressed = nil
        needsDisplay = true
    }

    // MARK: - The drawing

    // The header has the panel colour, as the sticky header of the Electron app had, so the rows
    // that scroll under it do not show through. The header that the user drags draws last, at
    // its live place.
    override package func draw(_ dirtyRect: NSRect) {
        guard let table = tableView else { return }
        let transparency = rows?.input?.transparency ?? ThemeTokens.defaultTransparency
        ThemeTokens.panel(transparency: transparency).nsColor.setFill()
        dirtyRect.fill(using: .copy)
        let dragged = draggedColumn
        for index in table.tableColumns.indices where index != dragged {
            draw(index, offset: 0, dirtyRect)
        }
        if table.tableColumns.indices.contains(dragged) {
            draw(dragged, offset: draggedDistance, dirtyRect)
        }
    }

    private func draw(_ index: Int, offset: CGFloat, _ dirtyRect: NSRect) {
        guard let column = overviewColumn(index) else { return }
        let rect = headerRect(ofColumn: index).offsetBy(dx: offset, dy: 0)
        guard rect.intersects(dirtyRect) else { return }
        NSGraphicsContext.saveGraphicsState()
        rect.clip()
        if offset != 0 {
            let transparency = rows?.input?.transparency ?? ThemeTokens.defaultTransparency
            ThemeTokens.panel(transparency: transparency).nsColor.setFill()
            rect.fill(using: .copy)
        }
        drawHeader(column, in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHeader(_ column: OverviewColumn, in rect: NSRect) {
        let metrics = metrics
        if pressed == column {
            ThemeTokens.accent.opacity(0.12).nsColor.setFill()
            rect.fill(using: .sourceOver)
        }
        let colour = ThemeTokens.textDim.nsColor
        var x = rect.minX + metrics.points(OverviewSizes.cellPadding)
        if !column.label.isEmpty {
            let font = Fonts.ui(metrics.points(OverviewSizes.headerTextSize), weight: .regular)
            let label = NSAttributedString(
                string: column.label, attributes: [.font: font, .foregroundColor: colour])
            let size = label.size()
            label.draw(at: NSPoint(x: x, y: rect.midY - size.height / 2))
            x += size.width + metrics.points(4)
        }
        if let mark = sortMark(column) {
            let font = Fonts.ui(metrics.points(OverviewSizes.sortMarkSize), weight: .regular)
            let text = NSAttributedString(
                string: mark, attributes: [.font: font, .foregroundColor: colour])
            let size = text.size()
            text.draw(at: NSPoint(x: x, y: rect.midY - size.height / 2))
        }
    }
}
