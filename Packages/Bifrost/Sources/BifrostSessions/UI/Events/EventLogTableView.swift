// The rows of the Event log (docs/behaviour/panels.md, The Event log panel): an NSTableView with
// the newest entry first. A row has three columns: the time (HH:MM:SS.mmm), the session and the
// event. A notice has no session: its text takes the session column and the event column, in the
// strong text colour, and its tooltip holds the whole text.
//
// - The table has one table column. Each cell (EventLogCell) puts the three columns of its row in
//   place, so the text of a notice can span two of them. The table reuses the cells, and it makes
//   only the cells of the visible rows.
// - The table never takes the first responder and gives each key to the next responder. It has
//   no selection and no menu.
// - The panel gives a new EventLogInput at each change of a value that the table shows. A value
//   equal to the last one does nothing. The entries of the log change at most once each 250 ms
//   (EventBatcher), so a flood of events reloads the table at most once each 250 ms.
import AppKit
import BifrostLook

// The values that the rows show.
package struct EventLogInput: Equatable, Sendable {
    // The entries of the log, the oldest first.
    package var entries: [LogEntry]
    // The name of each session row by row ID (LogView.names).
    package var names: [String: String]
    // The session of the filter, or nil for all sessions.
    package var session: String?
    package var metrics: CanvasMetrics

    package init(
        entries: [LogEntry], names: [String: String], session: String?, metrics: CanvasMetrics
    ) {
        self.entries = entries
        self.names = names
        self.session = session
        self.metrics = metrics
    }
}

// The sizes of the rows in layout units.
package enum EventLogSizes {
    package static let rowHeight = 18.0
    package static let textSize = 12.0
    // The space at the left and the right of a row, and between two columns.
    package static let padding = 8.0
    package static let gap = 8.0
    package static let timeWidth = 96.0
    package static let sessionWidth = 150.0
}

@MainActor
package final class EventLogRowsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let cellID = NSUserInterfaceItemIdentifier("event-log-row")

    package let scrollView = NSScrollView()
    package let table = EventLogTable()
    package private(set) var input: EventLogInput?
    // The entries of the filter, the oldest first. Row 0 of the table shows the last one.
    package private(set) var shown: [LogEntry] = []
    #if DEBUG
    // The number of reloads of the table. A test counts them.
    package private(set) var reloads = 0
    #endif

    override package init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: Self.cellID)
        // The name of the column for accessibility. The table has no header.
        column.title = "Events"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override package var isFlipped: Bool { true }

    override package func layout() {
        super.layout()
        scrollView.frame = bounds
        table.sizeLastColumnToFit()
    }

    package func apply(_ new: EventLogInput) {
        guard new != input else { return }
        let old = input
        input = new
        if old?.metrics != new.metrics {
            table.rowHeight = new.metrics.points(EventLogSizes.rowHeight)
        }
        if old?.entries != new.entries || old?.session != new.session {
            shown = LogView.filter(new.entries, session: new.session)
        }
        table.reloadData()
        #if DEBUG
        reloads += 1
        #endif
        // A new filter shows its newest entries.
        if let old, old.session != new.session { scrollToTop() }
    }

    // The entry of a row of the table: the newest first.
    package func entry(atRow row: Int) -> LogEntry? {
        let index = shown.count - 1 - row
        return shown.indices.contains(index) ? shown[index] : nil
    }

    private func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - The data source and the delegate

    package func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    package func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let input, let entry = entry(atRow: row) else { return nil }
        let cell =
            table.makeView(withIdentifier: Self.cellID, owner: nil) as? EventLogCell
            ?? EventLogCell(frame: .zero)
        cell.identifier = Self.cellID
        cell.show(EventLogCellContent(entry, names: input.names), metrics: input.metrics)
        return cell
    }

    // The table never selects a row.
    package func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    package func selectionShouldChange(in tableView: NSTableView) -> Bool { false }
}

// The content of one row: the time, the texts and the kind of the row.
package struct EventLogCellContent: Equatable, Sendable {
    package var time: String
    package var row: LogRow
    package var notice: Bool

    package init(_ entry: LogEntry, names: [String: String]) {
        time = TimeText.clockMs(entry.at)
        row = LogView.row(entry, names: names)
        notice = entry.isNotice
    }
}

// The view of one row: the three columns as labels. A notice hides the session label, and its
// text starts where the session starts.
@MainActor
package final class EventLogCell: NSTableCellView {
    package let time = EventLogCell.label()
    package let session = EventLogCell.label()
    package let text = EventLogCell.label()
    private var metrics = CanvasMetrics(interfaceScale: 100)
    private var tooltip: String?

    override package init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(time)
        addSubview(session)
        addSubview(text)
        textField = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private static func label() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.drawsBackground = false
        label.isBordered = false
        label.isSelectable = false
        label.refusesFirstResponder = true
        return label
    }

    package func show(_ content: EventLogCellContent, metrics: CanvasMetrics) {
        self.metrics = metrics
        let font = Fonts.ui(metrics.points(EventLogSizes.textSize), weight: .regular)
        let textColour = content.notice ? ThemeTokens.textStrong : ThemeTokens.text
        set(time, content.time, font, ThemeTokens.textDim)
        set(session, content.row.session ?? "", font, ThemeTokens.textDim)
        set(text, content.row.text, font, textColour)
        session.isHidden = content.row.session == nil
        if content.row.title != tooltip {
            tooltip = content.row.title
            if let title = content.row.title {
                TooltipController.shared.attach(title, to: text, side: .top)
            } else {
                TooltipController.shared.detach(from: text)
            }
        }
        needsLayout = true
    }

    private func set(_ label: NSTextField, _ value: String, _ font: NSFont, _ colour: TokenColour) {
        if label.font != font { label.font = font }
        if label.stringValue != value { label.stringValue = value }
        if label.textColor != colour.nsColor { label.textColor = colour.nsColor }
    }

    override package func layout() {
        super.layout()
        let padding = metrics.points(EventLogSizes.padding)
        let gap = metrics.points(EventLogSizes.gap)
        var x = padding
        place(time, x: x, width: metrics.points(EventLogSizes.timeWidth))
        x += metrics.points(EventLogSizes.timeWidth) + gap
        if !session.isHidden {
            place(session, x: x, width: metrics.points(EventLogSizes.sessionWidth))
            x += metrics.points(EventLogSizes.sessionWidth) + gap
        }
        place(text, x: x, width: max(0, bounds.width - padding - x))
    }

    private func place(_ label: NSTextField, x: CGFloat, width: CGFloat) {
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(
            x: x, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
    }
}

// The table of the rows. It never takes the first responder, and it gives each key to the next
// responder. It has no menu.
@MainActor
package final class EventLogTable: PassiveTableView {
    override package init() {
        super.init()
        headerView = nil
        cornerView = nil
        columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        allowsColumnReordering = false
        allowsColumnResizing = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
