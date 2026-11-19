// The Watchlist panel (docs/behaviour/panels.md, "The Watchlist"): the watched sessions in watch
// order. Each row shows the watch colour, the stripe of the full colour, the row icon, the name
// and the state. The rows are an NSTableView of one column, as for the Overview: the table reuses
// the views of its rows, and the row icon is an AppKit view (SessionIconView).
//
// - The panel and its table never take the first responder, and the table is not in the Tab loop
//   of the window: the rows are not focusable (the section "The UI" of the architecture design).
// - A click selects the row. A click while a hold key is down runs the hold command on the row,
//   and the selection stays (D8). A double-click also opens the session (OverviewModel.open),
//   except during a hold. A right-click or a Control-click shows the row menu
//   (OverviewModel.showRowMenu), and so does the Show Menu action of VoiceOver on a row. The
//   selection of the table only follows SelectionModel, so VoiceOver tells the selected row.
//   Each action reads the row by its ID at the time of the action, so a row that left the
//   session list gets no click and no menu.
// - A press that moves Hit.stackDistance starts a drag: a drag session of AppKit with the session
//   ID of the row on a private pasteboard type. The dragged row is at 40 % opacity, and the drag
//   image of AppKit follows the pointer. The table is the drop place (validateDrop and acceptDrop
//   of its data source). A line shows the drop place while the drop would move the row, and the
//   drop moves the row with RegistryService.watchMove. The drag session ends the drag: Esc, a
//   drop outside the table and a drop that moves nothing move nothing. A drag is never a click.
// - The press ends with no click and no move when the panel leaves the window, and a new press
//   replaces it.
// - A failed move shows its reason in the error line until the user closes it.
// - While the panel is in a window, it follows the rows, the selection, the Row flash setting,
//   the icons of the terminal apps, the Interface scale and the label set with Observations.
import AppKit
import BifrostFoundation
import BifrostKeyboard
import BifrostLayout
import BifrostLook
import BifrostSessions
import Observation

// The values that the Watchlist shows.
package struct WatchlistInput: Equatable, Sendable {
    // The watched rows, in watch order.
    package var rows: [SessionRow]
    package var selected: String?
    package var rowFlash: Bool
    // The icon of the app that shows each row that has one, by row ID.
    package var appIcons: [String: AppIcon]
    package var metrics: CanvasMetrics
    package var emptyText: String

    @MainActor
    package init(model: OverviewModel, labels: LabelSet, look: PanelLook) {
        rows = WatchOrder.watched(model.sessions.rows)
        selected = model.selection.selectedId
        rowFlash = model.rowFlash
        appIcons = model.appIcons(rows)
        metrics = look.metrics
        emptyText = WatchOrder.emptyText(labels)
    }
}

@MainActor
package final class WatchlistPanel: NSView, NSTableViewDataSource, NSTableViewDelegate,
    NSDraggingSource, SessionRowsPointer
{
    // The private pasteboard type of a dragged row: its session ID.
    package static let rowType = NSPasteboard.PasteboardType("dev.bifrost.watchlist-row")
    // The sizes in layout units.
    package static let rowHeight = 26.0
    static let textSize = 12.0
    static let emptyTextSize = 13.0
    // The opacity of the dragged row.
    static let draggedOpacity = 0.4
    private static let rowViewID = NSUserInterfaceItemIdentifier("watch-row")
    private static let cellID = NSUserInterfaceItemIdentifier("watch-cell")

    package let scrollView = NSScrollView()
    package let table = WatchlistTable()
    package let emptyText = PassiveLabel(wrappingLabelWithString: "")
    package let errorLine = PanelErrorLine()
    package private(set) var input: WatchlistInput?
    // The reason of the last failed move, until the user closes it or the next move.
    package private(set) var error: String?

    private let model: OverviewModel
    private let registry: () -> RegistryService?
    private let labels: () -> LabelSet
    private let look: PanelLook
    private let filter: () -> WindowKeyFilter?
    private var press: RowPress?
    private var following: Task<Void, Never>?
    // Start the drag session of AppKit for the row with the ID, from the drag event. A test gives
    // its own start: a test window is never on the screen, so it has no drag session.
    package var startDrag: (_ id: String, _ event: NSEvent) -> Void = { _, _ in }

    // model: the model that the session lists share (the rows, the selection, the Row flash
    // setting, the icons and the Open and row menu actions). registry gives the registry of the
    // move, or nil before the start of the services made it. labels gives the label set of the
    // settings; it can read observed values. filter gives the key filter of the window, for the
    // hold keys of a row click (D8).
    package init(
        model: OverviewModel, registry: @escaping () -> RegistryService?,
        labels: @escaping () -> LabelSet, look: PanelLook,
        filter: @escaping () -> WindowKeyFilter?
    ) {
        self.model = model
        self.registry = registry
        self.labels = labels
        self.look = look
        self.filter = filter
        super.init(frame: .zero)
        table.panel = self
        table.pointer = self
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.rowType])
        table.draggingDestinationFeedbackStyle = .none
        startDrag = { [weak self] id, event in self?.beginDragSession(id, event) }
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        emptyText.textColor = ThemeTokens.textDim.nsColor
        emptyText.isSelectable = false
        emptyText.isHidden = true
        addSubview(emptyText)
        errorLine.isHidden = true
        errorLine.onClose = { [weak self] in self?.closeError() }
        addSubview(errorLine)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        following?.cancel()
    }

    override package var isFlipped: Bool { true }
    override package var acceptsFirstResponder: Bool { false }
    override package var canBecomeKeyView: Bool { false }

    override package func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            following?.cancel()
            following = nil
            endPress()
        } else {
            follow()
        }
    }

    private func follow() {
        guard following == nil else { return }
        let changes = Observations { [weak self] in self?.currentInput }
        following = Task { [weak self] in
            for await input in changes {
                if let input { self?.apply(input) }
            }
        }
    }

    // The values of now.
    private var currentInput: WatchlistInput {
        WatchlistInput(model: model, labels: labels(), look: look)
    }

    override package func layout() {
        super.layout()
        let metrics = input?.metrics ?? look.metrics
        var bottom = bounds.height
        if !errorLine.isHidden {
            let height = errorLine.height(for: bounds.width)
            bottom -= height
            errorLine.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: height)
        }
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bottom))
        table.sizeLastColumnToFit()
        let padding = metrics.points(12)
        let width = max(0, bounds.width - 2 * padding)
        emptyText.preferredMaxLayoutWidth = width
        let size = emptyText.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        emptyText.frame = NSRect(
            x: padding, y: padding, width: width, height: size.height.rounded(.up))
    }

    // MARK: - The values

    package func apply(_ new: WatchlistInput) {
        guard new != input else { return }
        let old = input
        input = new
        let scaleChanged = old?.metrics != new.metrics
        if scaleChanged { applyMetrics(new.metrics) }
        table.reloadChanged(
            old: scaleChanged ? nil : old?.rows, new: new.rows, oldIcons: old?.appIcons ?? [:],
            newIcons: new.appIcons, all: old?.rowFlash != new.rowFlash, columns: [0])
        table.showSelection(new.selected, in: new.rows)
        refreshLooks()
        emptyText.stringValue = new.emptyText
        emptyText.isHidden = !new.rows.isEmpty
        errorLine.show(error, metrics: new.metrics)
        needsLayout = true
    }

    private func applyMetrics(_ metrics: CanvasMetrics) {
        table.rowHeight = metrics.points(Self.rowHeight)
        emptyText.font = Fonts.ui(metrics.points(Self.emptyTextSize), weight: .regular)
    }


    // MARK: - The error line

    package func closeError() {
        error = nil
        showError()
    }

    private func showError() {
        errorLine.show(error, metrics: input?.metrics ?? look.metrics)
        needsLayout = true
    }

    // MARK: - The pointer

    private func rowID(_ index: Int) -> String? {
        guard let input, input.rows.indices.contains(index) else { return nil }
        return input.rows[index].sessionId
    }

    // A primary press on the table. A press on a row claims a held hold key for the row (D8), and
    // can start a drag.
    package func press(at point: NSPoint) {
        endPress()
        guard let id = rowID(table.row(at: point)) else { return }
        filter()?.rowPress(id)
        press = RowPress(id: id, start: point)
    }

    // The pointer moved with the button down. After Hit.stackDistance from the press, the press
    // starts the drag session. From then on, the session has the pointer.
    package func dragged(to point: NSPoint, event: NSEvent) {
        guard var press, press.phase == .pressed, let input else { return }
        let scale = input.metrics.scale
        let start = LayoutPoint(x: press.start.x / scale, y: press.start.y / scale)
        let now = LayoutPoint(x: point.x / scale, y: point.y / scale)
        guard Hit.movedToStack(from: start, to: now) else { return }
        press.phase = .dragging(before: nil)
        self.press = press
        refreshLooks()
        startDrag(press.id, event)
    }

    // The release of a press that did not start a drag. On the row of the press it is a click
    // (OverviewModel.rowClicked).
    package func release(at point: NSPoint, clicks: Int) {
        guard let press, press.phase == .pressed else { return }
        self.press = nil
        if rowID(table.row(at: point)) == press.id {
            model.rowClicked(press.id, clicks: clicks, filter: filter())
        }
        refreshLooks()
    }

    // A right-click on a row gives the row menu at the click point. It does not change the
    // selection (D6). A right-click outside a row, or on a row that is gone, does nothing.
    package func rightClick(at point: NSPoint) {
        guard let id = rowID(table.row(at: point)),
            let row = model.sessions.rows.first(where: { $0.sessionId == id })
        else { return }
        model.showRowMenu(row, convert(point, from: table), self)
    }

    // The Show Menu action of VoiceOver on the row with the ID: the row menu at the left of the
    // bottom of the row. A row that left the list gives no menu.
    func showMenu(forRow id: String) {
        guard let input, let index = input.rows.firstIndex(where: { $0.sessionId == id }),
            let row = model.sessions.rows.first(where: { $0.sessionId == id })
        else { return }
        let rect = table.rect(ofRow: index)
        model.showRowMenu(row, convert(NSPoint(x: rect.minX, y: rect.maxY), from: table), self)
    }

    // The press ends with no click and no move: a new press, or the panel left the window.
    private func endPress() {
        guard press != nil else { return }
        press = nil
        refreshLooks()
    }

    // MARK: - The drag

    // The drag session of AppKit for the row: the session ID on the pasteboard, and the image of
    // the row as the drag image at the place of the row.
    private func beginDragSession(_ id: String, _ event: NSEvent) {
        guard let input, let index = input.rows.firstIndex(where: { $0.sessionId == id }) else {
            return
        }
        let item = NSPasteboardItem()
        item.setString(id, forType: Self.rowType)
        let drag = NSDraggingItem(pasteboardWriter: item)
        let rect = table.rect(ofRow: index)
        drag.setDraggingFrame(rect, contents: rowImage(index))
        table.beginDraggingSession(with: [drag], event: event, source: self)
    }

    // The image of the row view, for the drag.
    private func rowImage(_ index: Int) -> NSImage? {
        guard let view = table.rowView(atRow: index, makeIfNecessary: false),
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    // The session that the dragged row goes before for a drop above the row at the index (the
    // number of rows for the end), or nil for the end. A drop at the place of the dragged row is
    // the place that it has now.
    private func target(_ id: String, aboveRow row: Int) -> String? {
        let shown = input?.rows.map(\.sessionId) ?? []
        guard !shown.isEmpty else { return nil }
        let end = row >= shown.count
        return WatchOrder.dropTarget(
            shown, dragged: id, over: end ? shown.count - 1 : max(row, 0), upperHalf: !end)
    }

    // The drag of the row is over the table, above the row at the index. True when a drop there
    // would move the row: the line then shows the drop place.
    func dropProposed(_ id: String, aboveRow row: Int) -> Bool {
        guard let press, press.id == id, case .dragging = press.phase else { return false }
        let before = target(id, aboveRow: row)
        let shown = input?.rows.map(\.sessionId) ?? []
        let moves = WatchOrder.isMove(shown, dragged: id, before: before)
        showDropPlace(moves ? .dragging(before: before) : .dragging(before: nil), moves: moves)
        return moves
    }

    // The drag left the table: no line.
    func dropLeft() {
        guard press != nil else { return }
        showDropPlace(.dragging(before: nil), moves: false)
    }

    // The drop of the row above the row at the index. The move check reads the watched rows of
    // now, so a row that left the list does not move. True when the drop moved the row.
    @discardableResult
    func drop(_ id: String, aboveRow row: Int) -> Bool {
        let before = target(id, aboveRow: row)
        let order = WatchOrder.watched(model.sessions.rows).map(\.sessionId)
        guard WatchOrder.shouldMove(order, dragged: id, before: before, cancelled: false) else {
            return false
        }
        error = nil
        if registry()?.watchMove(id, before: before) != true {
            error = ActionRefusal.unknownSession.message
        }
        showError()
        return error == nil
    }

    // The drag session ended: with a drop, Esc, or a drop outside the table. The row and the line
    // go back.
    func dragEnded() {
        guard let press, case .dragging = press.phase else { return }
        self.press = nil
        refreshLooks()
    }

    private func showDropPlace(_ phase: RowPress.Phase, moves: Bool) {
        guard var press else { return }
        press.phase = phase
        press.lineShows = moves
        guard press != self.press else { return }
        self.press = press
        refreshLooks()
    }

    // The drag session of AppKit asks what the drag may do: move inside the app, nothing outside.
    package func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    package func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        dragEnded()
    }

    // MARK: - The row looks

    private func rowLook(_ index: Int, _ input: WatchlistInput) -> WatchRowLook {
        let row = input.rows[index]
        var look = WatchRowLook(
            watch: row.watch?.colour.token, selected: row.sessionId == input.selected)
        guard let press, case .dragging(let before) = press.phase else { return look }
        look.dragged = row.sessionId == press.id
        let shown = input.rows.map(\.sessionId)
        // A drop that keeps the place shows no line, and so does a drag outside the table.
        guard press.lineShows else { return look }
        if before == row.sessionId {
            look.line = .above
        } else if before == nil && index == shown.count - 1 {
            look.line = .below
        }
        return look
    }

    private func refreshLooks() {
        table.enumerateAvailableRowViews { view, index in
            self.showLook(view, index)
        }
    }

    private func showLook(_ view: NSTableRowView, _ index: Int) {
        guard let view = view as? WatchRowView, let input, input.rows.indices.contains(index)
        else { return }
        view.look = rowLook(index, input)
        view.metrics = input.metrics
        let id = input.rows[index].sessionId
        view.showMenu = { [weak self] in self?.showMenu(forRow: id) }
    }

    // MARK: - The data source and the delegate

    package func numberOfRows(in tableView: NSTableView) -> Int {
        input?.rows.count ?? 0
    }

    package func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int
    ) -> NSView? {
        guard let input, input.rows.indices.contains(index) else { return nil }
        let cell =
            table.makeView(withIdentifier: Self.cellID, owner: nil) as? WatchRowCell
            ?? WatchRowCell(frame: .zero)
        cell.identifier = Self.cellID
        let row = input.rows[index]
        let icon = SessionIconLook(
            row: row, appIcon: input.appIcons[row.sessionId], rowFlash: input.rowFlash)
        cell.show(row, icon: icon, metrics: input.metrics)
        return cell
    }

    package func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let view = table.makeView(withIdentifier: Self.rowViewID, owner: nil) as? WatchRowView {
            return view
        }
        let view = WatchRowView(frame: .zero)
        view.identifier = Self.rowViewID
        return view
    }

    package func tableView(
        _ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int
    ) {
        showLook(rowView, row)
    }

    // The user never selects a row of the table: SelectionModel owns the selection.
    package func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    package func selectionShouldChange(in tableView: NSTableView) -> Bool { false }

    // A drag of a row over the table: always a drop above a row, as a move.
    package func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let id = info.draggingPasteboard.string(forType: Self.rowType) else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return dropProposed(id, aboveRow: row) ? .move : []
    }

    package func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: Self.rowType) else { return false }
        return drop(id, aboveRow: row)
    }
}

// A primary press on a row, from the mouse down to the release or to the end of its drag.
private struct RowPress: Equatable {
    enum Phase: Equatable {
        // The pointer has not moved Hit.stackDistance yet, so the release is a click.
        case pressed
        // A drag session. A drop goes before this session, or to the end for nil.
        case dragging(before: String?)
    }

    let id: String
    // The press point in the coordinates of the table.
    let start: NSPoint
    var phase = Phase.pressed
    // True while the drag is over a drop place that moves the row: the line shows.
    var lineShows = false
}

// The table of the rows: a table of session rows (SessionRowsTable) whose panel handles the
// pointer, and the drop place of a drag of a row.
@MainActor
package final class WatchlistTable: SessionRowsTable {
    weak var panel: WatchlistPanel?

    override package init() {
        super.init()
        headerView = nil
        columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.title = "Session"
        column.resizingMask = .autoresizingMask
        addTableColumn(column)
        setAccessibilityLabel("Watchlist")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // The drag left the table: the line goes.
    override package func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        panel?.dropLeft()
    }

}

// The drop line of a row: above the row that the drop goes before, or below the last row.
package enum WatchDropLine: Equatable, Sendable {
    case above, below
}

// The colours of a row. The panel gives them from the watchlist, SelectionModel and the drag.
package struct WatchRowLook: Equatable {
    package var watch: TokenColour?
    package var selected = false
    package var dragged = false
    package var line: WatchDropLine?

    package init(
        watch: TokenColour? = nil, selected: Bool = false, dragged: Bool = false,
        line: WatchDropLine? = nil
    ) {
        self.watch = watch
        self.selected = selected
        self.dragged = dragged
        self.line = line
    }
}

// The row view: it draws the colours of a row under its cell.
// - The row has its watch colour at 12 %, and the selection on top of it.
// - A stripe of the full watch colour, 3 units wide, is at the left edge, on top of the selection.
// - The drop line is 1 unit of the strong text colour, 4 units in from each side, at the top or
//   the bottom of the row.
// - The dragged row is at 40 % opacity, with its cell.
@MainActor
package final class WatchRowView: NSTableRowView {
    package var look = WatchRowLook() {
        didSet {
            guard look != oldValue else { return }
            alphaValue = look.dragged ? WatchlistPanel.draggedOpacity : 1
            needsDisplay = true
        }
    }
    var metrics = CanvasMetrics(interfaceScale: 100) {
        didSet { if metrics != oldValue { needsDisplay = true } }
    }
    // The Show Menu action of VoiceOver: the row menu of the row.
    var showMenu: (() -> Void)?

    override package var isFlipped: Bool { true }

    // The selection of the table changes no colour of a cell: the row view draws the selection.
    override package var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override package func accessibilityPerformShowMenu() -> Bool {
        guard let showMenu else { return false }
        showMenu()
        return true
    }

    override package func drawBackground(in dirtyRect: NSRect) {
        if let watch = look.watch {
            fill(watch.opacity(ThemeTokens.watchRowOpacity), bounds)
        }
        if look.selected { fill(ThemeTokens.select, bounds) }
        if let watch = look.watch {
            let stripe = metrics.points(OverviewSizes.watchStripe)
            fill(watch, NSRect(x: 0, y: 0, width: stripe, height: bounds.height))
        }
        guard let line = look.line else { return }
        let inset = metrics.points(4)
        let height = metrics.points(1)
        let y = line == .above ? 0 : bounds.height - height
        fill(
            ThemeTokens.textStrong,
            NSRect(x: inset, y: y, width: max(0, bounds.width - 2 * inset), height: height))
    }

    // The table draws no selection: SelectionModel owns it.
    override package func drawSelection(in dirtyRect: NSRect) {}

    private func fill(_ colour: TokenColour, _ rect: NSRect) {
        colour.nsColor.setFill()
        rect.fill(using: .sourceOver)
    }
}

// The cell of a row: the row icon of 16 units, the name and the state, 8 units apart and 8 units
// in from each side. A long name ends with an ellipsis. The name has the parked colour on a parked
// row, and the state has the colour of its tone, as in the Overview (CellContent).
@MainActor
package final class WatchRowCell: NSTableCellView {
    package let icon = SessionIconView(frame: .zero)
    package let name = NSTextField(labelWithString: "")
    package let state = NSTextField(labelWithString: "")
    private var metrics = CanvasMetrics(interfaceScale: 100)

    override package init(frame: NSRect) {
        super.init(frame: frame)
        for label in [name, state] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
            label.drawsBackground = false
            label.isBordered = false
            label.isSelectable = false
            label.refusesFirstResponder = true
            addSubview(label)
        }
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(icon)
        textField = name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    package func show(_ row: SessionRow, icon look: SessionIconLook, metrics: CanvasMetrics) {
        self.metrics = metrics
        let font = Fonts.ui(metrics.points(WatchlistPanel.textSize), weight: .regular)
        let parked = row.state == .parked
        for (label, column) in [(name, OverviewColumn.name), (state, .state)] {
            // The name and the state read no time, so the time 0 changes nothing.
            let content = CellContent.of(row, column, now: 0)
            if label.font != font { label.font = font }
            if label.stringValue != content.text { label.stringValue = content.text }
            let colour = content.textColour(parked: parked).nsColor
            if label.textColor != colour { label.textColor = colour }
        }
        icon.show(look, unit: metrics.points(1))
        needsLayout = true
    }

    override package func layout() {
        super.layout()
        let padding = metrics.points(8)
        let gap = metrics.points(8)
        let side = metrics.points(16)
        icon.frame = NSRect(
            x: padding, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
        let stateWidth = min(
            state.intrinsicContentSize.width, max(0, bounds.width - 2 * padding - side - gap))
        let height = name.intrinsicContentSize.height
        let y = ((bounds.height - height) / 2).rounded()
        state.frame = NSRect(
            x: bounds.width - padding - stateWidth, y: y, width: stateWidth, height: height)
        let nameX = padding + side + gap
        name.frame = NSRect(
            x: nameX, y: y, width: max(0, state.frame.minX - gap - nameX), height: height)
    }
}
