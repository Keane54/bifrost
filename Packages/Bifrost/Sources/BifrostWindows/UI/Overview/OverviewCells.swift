// The cells and the rows of the Overview table (docs/behaviour/overview.md, Cells and the icon):
// the content of each cell (CellContent), the views of the cells, and the row view, which draws
// the colours of a row.
import AppKit
import BifrostLook
import BifrostSessions

// The content of one cell: the text, its colour and its tooltip. The kind cell shows the row icon
// (SessionIconView), so its content has no text.
package struct CellContent: Equatable {
    package enum Colour: Equatable {
        // The text colour of the row: the parked colour for a parked row, else the text colour.
        case row
        // The colour of a state label.
        case tone(Tone)
        case priority(SessionPriority)
    }

    package var text: String
    package var colour: Colour
    package var tooltip: String?

    package init(_ text: String, _ colour: Colour = .row, tooltip: String? = nil) {
        self.text = text
        self.colour = colour
        self.tooltip = tooltip
    }

    // The content of the cell of the row in the column. now is the wall time in milliseconds
    // since 1970, for the age of the Activity cell.
    package static func of(_ row: SessionRow, _ column: OverviewColumn, now: Int) -> CellContent {
        switch column {
        case .kind: CellContent("")
        case .name: CellContent(row.name)
        case .priority: row.priority.map { CellContent("\($0.rawValue)", .priority($0)) }
            ?? CellContent("")
        case .state:
            CellContent(
                OverviewFormat.stateLabel(row.state), .tone(OverviewFormat.stateTone(row)))
        // The tooltip of the project cell is the folder.
        case .project:
            CellContent(
                OverviewFormat.projectLabel(row.cwd), tooltip: row.cwd.isEmpty ? nil : row.cwd)
        case .branch: CellContent(row.branch ?? "")
        case .model: CellContent(row.model ?? "")
        case .context: CellContent(OverviewFormat.percent(row.usage?.contextPercent))
        case .cost: CellContent(OverviewFormat.cost(row.usage?.costUsd))
        case .activity: CellContent(TimeText.age(since: row.lastActivity, now: now))
        }
    }

    // The state text of a Starting row.
    package static let startingText = "Starting…"

    // The content of the cell of a Starting row in the column: the name, the state text in the
    // dim colour and the project. The other cells are empty.
    package static func of(_ start: StartingSession, _ column: OverviewColumn) -> CellContent {
        switch column {
        case .name: CellContent(start.name)
        case .state: CellContent(startingText, .tone(.dim))
        case .project: CellContent(OverviewFormat.projectLabel(start.cwd), tooltip: start.cwd)
        case .kind, .priority, .branch, .model, .context, .cost, .activity: CellContent("")
        }
    }

    // The colour of the text in a row that is parked or not.
    package func textColour(parked: Bool) -> TokenColour {
        switch colour {
        case .row: parked ? ThemeTokens.parked : ThemeTokens.text
        case .tone(let tone): Self.toneColour(tone)
        case .priority(let priority): ThemeTokens.priority(priority.rawValue)
        }
    }

    private static func toneColour(_ tone: Tone) -> TokenColour {
        switch tone {
        case .active: ThemeTokens.textStrong
        case .yellow: ThemeTokens.boxYellow
        case .red: ThemeTokens.boxRed
        case .dim: ThemeTokens.textDim
        case .parked: ThemeTokens.parked
        }
    }
}

// The sizes of the table in layout units.
package enum OverviewSizes {
    package static let rowHeight = 22.0
    package static let headerHeight = 18.0
    // The space at the left and the right of a cell.
    package static let cellPadding = 4.0
    package static let textSize = 12.0
    package static let headerTextSize = 11.0
    package static let sortMarkSize = 8.0
    // The side of the row icon.
    package static let iconSide = 18.0
    // The width of the stripe at the left edge of a watched row.
    package static let watchStripe = 3.0
}

// A text cell. A long text ends with an ellipsis, so it never touches the next column.
@MainActor
package final class OverviewTextCell: NSTableCellView {
    package let label = NSTextField(labelWithString: "")
    private var padding: CGFloat = 4
    private var tooltip: String?

    override package init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.drawsBackground = false
        label.isBordered = false
        label.isSelectable = false
        label.refusesFirstResponder = true
        addSubview(label)
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // The text of the cell.
    package var text: String { label.stringValue }

    package func show(_ content: CellContent, parked: Bool, metrics: CanvasMetrics) {
        let font = Fonts.ui(metrics.points(OverviewSizes.textSize), weight: .regular)
        if label.font != font { label.font = font }
        if label.stringValue != content.text { label.stringValue = content.text }
        let colour = content.textColour(parked: parked).nsColor
        if label.textColor != colour { label.textColor = colour }
        padding = metrics.points(OverviewSizes.cellPadding)
        if content.tooltip != tooltip {
            tooltip = content.tooltip
            if let text = content.tooltip {
                TooltipController.shared.attach(text, to: self, side: .top)
            } else {
                TooltipController.shared.detach(from: self)
            }
        }
        needsLayout = true
    }

    override package func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(
            x: padding, y: ((bounds.height - height) / 2).rounded(),
            width: max(0, bounds.width - 2 * padding), height: height)
    }
}

// The kind cell: the row icon, 4 units from the left edge, in the middle of the row.
@MainActor
package final class OverviewKindCell: NSTableCellView {
    package let icon = SessionIconView(frame: .zero)
    private var padding: CGFloat = 4
    private var side: CGFloat = 18

    override package init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    package func show(_ look: SessionIconLook, metrics: CanvasMetrics) {
        padding = metrics.points(OverviewSizes.cellPadding)
        side = metrics.points(OverviewSizes.iconSide)
        icon.show(look, unit: metrics.points(1))
        needsLayout = true
    }

    override package func layout() {
        super.layout()
        icon.frame = NSRect(
            x: padding, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
    }
}

// The colours of a row. The table gives them from SelectionModel, the open chats, the pointer and
// the watchlist, never from the selection of the table.
package struct RowLook: Equatable {
    // The watch colour of a watched row.
    package var watch: TokenColour?
    package var selected = false
    // A row with an open chat has the hover colour, as a hovered row does.
    package var openChat = false
    package var hovered = false
    // The primary button is down on the row.
    package var pressed = false

    package init(
        watch: TokenColour? = nil, selected: Bool = false, openChat: Bool = false,
        hovered: Bool = false, pressed: Bool = false
    ) {
        self.watch = watch
        self.selected = selected
        self.openChat = openChat
        self.hovered = hovered
        self.pressed = pressed
    }

    // The colour on top of the row background: the selection, else the hover of an open chat or
    // of the pointer.
    package var overlay: TokenColour? {
        if selected { return ThemeTokens.select }
        return openChat || hovered ? ThemeTokens.hover : nil
    }
}

// The row view: it draws the colours of a row under its cells.
// - A watched row has its watch colour at 12 %, and the selection or the hover on top of it.
// - A press gives a short cyan tint: the accent at 12 %. On a watched row it takes the place of
//   the watch colour, and on another row the place of the selection and the hover.
// - A watched row has a stripe of the full watch colour at its left edge, on top of the other
//   colours.
@MainActor
package final class OverviewRowView: NSTableRowView {
    package var look = RowLook() {
        didSet { if look != oldValue { needsDisplay = true } }
    }
    // The width of the watch stripe in points.
    var stripe: CGFloat = 3 {
        didSet { if stripe != oldValue { needsDisplay = true } }
    }
    // The Show Menu action of VoiceOver: the row menu of the row.
    var showMenu: (() -> Void)?

    // The selection of the table changes no colour of a cell: the row view draws the selection.
    override package var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override package func accessibilityPerformShowMenu() -> Bool {
        guard let showMenu else { return false }
        showMenu()
        return true
    }

    override package func drawBackground(in dirtyRect: NSRect) {
        let press = ThemeTokens.accent.opacity(0.12)
        if let watch = look.watch {
            fill(look.pressed ? press : watch.opacity(ThemeTokens.watchRowOpacity), bounds)
            if let overlay = look.overlay { fill(overlay, bounds) }
            fill(watch, NSRect(x: 0, y: 0, width: stripe, height: bounds.height))
        } else if look.pressed {
            fill(press, bounds)
        } else if let overlay = look.overlay {
            fill(overlay, bounds)
        }
    }

    // The table draws no selection: drawBackground draws the selection of SelectionModel.
    override package func drawSelection(in dirtyRect: NSRect) {}

    private func fill(_ colour: TokenColour, _ rect: NSRect) {
        colour.nsColor.setFill()
        rect.fill(using: .sourceOver)
    }
}

extension WatchColour {
    // The colour of the watch colour.
    package var token: TokenColour {
        switch self {
        case .darkRed: ThemeTokens.watchDarkRed
        case .red: ThemeTokens.watchRed
        case .amber: ThemeTokens.watchAmber
        case .yellow: ThemeTokens.watchYellow
        case .green: ThemeTokens.watchGreen
        case .lightBlue: ThemeTokens.watchLightBlue
        case .darkBlue: ThemeTokens.watchDarkBlue
        case .white: ThemeTokens.watchWhite
        }
    }
}
