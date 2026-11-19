// The body of the Event log panel (docs/behaviour/panels.md, The Event log panel): the bar with
// the Session filter and the count of the events on top, then the rows (EventLogRowsView), or
// the empty texts when no entry shows.
//
// - The Session filter is a native menu: "All sessions", then each session of the log
//   (LogView.sessionOptions), with a tick at the choice. A session that the filter shows stays
//   in the menu after its last entry leaves the log, so the menu always shows the filter. Each
//   item holds the ID of its session, so a choice never depends on the place of the item. While
//   the menu is open, its list does not change: AppKit asks for the items of now just before
//   each open (menuNeedsUpdate(_:)), and a change while the menu is closed shows at once.
// - With no entry to show, the body says "No events yet.". While Live details is off, it also
//   says where the events come from.
// - While the body is in a window, it follows the log, the names of the session rows, the state
//   of Live details and the Interface scale with Observations. The log changes at most once each
//   250 ms (EventBatcher), and a change of a row that does not change its name gives an equal
//   value, so a flood of events gives at most one update each 250 ms. Out of a window the body
//   follows nothing.
import AppKit
import BifrostLayout
import BifrostLook
import Observation

// The values of the body that come from outside it.
package struct EventLogState: Equatable, Sendable {
    // The entries of the log, the oldest first.
    package var entries: [LogEntry]
    // The safe name of each session row by row ID (LogView.names).
    package var names: [String: String]
    // True while Live details is on.
    package var liveOn: Bool
    package var metrics: CanvasMetrics

    package init(
        entries: [LogEntry], names: [String: String], liveOn: Bool, metrics: CanvasMetrics
    ) {
        self.entries = entries
        self.names = names
        self.liveOn = liveOn
        self.metrics = metrics
    }
}

// The sizes of the bar and of the empty texts in layout units.
package enum EventLogBarSizes {
    package static let height = 34.0
    package static let menuHeight = 22.0
    // The space between the box of the Session filter and its text.
    package static let menuInset = 4.0
    package static let padding = 8.0
    // The space between the Session filter and the count.
    package static let gap = 12.0
    // The widest Session filter, as a part of the width of the bar.
    package static let menuMaxPart = 0.6
    package static let emptyPadding = 12.0
    package static let emptyTextSize = 13.0
    // The space between the two empty texts.
    package static let hintGap = 4.0
}

@MainActor
package final class EventLogPanel: NSView, NSMenuDelegate {
    package static let allSessions = "All sessions"
    package static let empty = "No events yet."
    package static let liveHint =
        "Events come from Live details. Turn it on in Settings to see them here."

    package let rows = EventLogRowsView()
    package let sessionMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    package let countLabel = NSTextField(labelWithString: "")
    package let emptyText = NSTextField(wrappingLabelWithString: EventLogPanel.empty)
    package let hintText = NSTextField(wrappingLabelWithString: EventLogPanel.liveHint)
    // The session of the filter, or nil for all sessions.
    package private(set) var session: String?
    // The sessions of the menu after "All sessions", in their order.
    package private(set) var choices: [SessionOption] = []
    // True while the menu of the Session filter is open.
    private var menuOpen = false
    package private(set) var state: EventLogState?
    private let source: @MainActor @Sendable () -> EventLogState
    private var following: Task<Void, Never>?

    // source gives the values of now. It reads observable values, so the body follows them.
    package init(source: @escaping @MainActor @Sendable () -> EventLogState) {
        self.source = source
        super.init(frame: .zero)
        sessionMenu.isBordered = false
        sessionMenu.setAccessibilityLabel("Session")
        (sessionMenu.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        sessionMenu.target = self
        sessionMenu.action = #selector(menuChose(_:))
        sessionMenu.addItem(withTitle: Self.allSessions)
        sessionMenu.menu?.delegate = self
        countLabel.textColor = ThemeTokens.textDim.nsColor
        for text in [emptyText, hintText] {
            text.textColor = ThemeTokens.textDim.nsColor
            text.isSelectable = false
            text.refusesFirstResponder = true
        }
        for view in [sessionMenu, countLabel, rows, emptyText, hintText] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        following?.cancel()
    }

    override package var isFlipped: Bool { true }

    override package func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            following?.cancel()
            following = nil
        } else {
            follow()
        }
    }

    private func follow() {
        guard following == nil else { return }
        let source = source
        let changes = Observations { source() }
        following = Task { [weak self] in
            for await state in changes { self?.apply(state) }
        }
    }

    // Show only the entries of the session, or all entries for nil.
    package func choose(session: String?) {
        guard session != self.session else { return }
        self.session = session
        show()
    }

    // The item of "All sessions" holds no session ID.
    @objc private func menuChose(_ sender: NSPopUpButton) {
        choose(session: sender.selectedItem?.representedObject as? String)
    }

    // AppKit asks for the items just before the menu opens: the menu gets the list of now.
    package func menuNeedsUpdate(_ menu: NSMenu) {
        guard let state else { return }
        showMenu(choiceList(state))
    }

    package func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
    }

    // The action of a choice can come after the close, in the same turn of the main actor, so the
    // close changes no item. The next change or the next open gives the list of now.
    package func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
    }

    // A state equal to the last one does nothing: a change of a row that keeps its name gives an
    // equal state.
    private func apply(_ new: EventLogState) {
        guard new != state else { return }
        let old = state
        state = new
        if old?.metrics != new.metrics { applyMetrics(new.metrics) }
        show()
    }

    private func show() {
        guard let state else { return }
        let old = rows.input
        rows.apply(
            EventLogInput(
                entries: state.entries, names: state.names, session: session,
                metrics: state.metrics))
        if old?.entries != state.entries || old?.names != state.names || old?.session != session {
            showChoices(state)
        }
        let shown = rows.shown.count
        countLabel.stringValue = shown == 1 ? "1 event" : "\(shown) events"
        rows.isHidden = shown == 0
        emptyText.isHidden = shown != 0
        hintText.isHidden = shown != 0 || state.liveOn
        needsLayout = true
    }

    // The list of the menu while it is closed. While the menu is open, it keeps its items.
    private func showChoices(_ state: EventLogState) {
        guard !menuOpen else { return }
        showMenu(choiceList(state))
    }

    // The list of the menu: the sessions of the log, then the session of the filter when the log
    // has no entry of it now.
    private func choiceList(_ state: EventLogState) -> [SessionOption] {
        var list = LogView.sessionOptions(state.entries, names: state.names)
        if let session, !list.contains(where: { $0.id == session }) {
            let label = LogView.sessionLabel(session, names: state.names)
            list.append(SessionOption(id: session, label: label))
        }
        return list
    }

    // The menu: "All sessions", then the list. The menu changes only when its list changes. The
    // item of the session of the filter has the tick.
    private func showMenu(_ list: [SessionOption]) {
        if list != choices, let menu = sessionMenu.menu {
            choices = list
            // The items go into the menu of the button through NSMenu, not through the add of a
            // title to the button: that add removes an item with the same title, and two sessions
            // can have the same label. The menu stays the same object, so a call from
            // menuNeedsUpdate(_:) changes the menu that opens.
            menu.removeAllItems()
            menu.addItem(withTitle: Self.allSessions, action: nil, keyEquivalent: "")
            for choice in list {
                let item = menu.addItem(withTitle: choice.label, action: nil, keyEquivalent: "")
                item.representedObject = choice.id
            }
        }
        let items = sessionMenu.itemArray
        let index = items.firstIndex { ($0.representedObject as? String) == session } ?? 0
        sessionMenu.selectItem(at: index)
    }

    private func applyMetrics(_ metrics: CanvasMetrics) {
        let font = Fonts.ui(metrics.points(EventLogSizes.textSize), weight: .regular)
        sessionMenu.font = font
        sessionMenu.menu?.font = font
        countLabel.font = font
        let emptyFont = Fonts.ui(metrics.points(EventLogBarSizes.emptyTextSize), weight: .regular)
        emptyText.font = emptyFont
        hintText.font = emptyFont
        needsDisplay = true
    }

    override package func layout() {
        super.layout()
        let metrics = state?.metrics ?? CanvasMetrics(interfaceScale: 100)
        let padding = metrics.points(EventLogBarSizes.padding)
        let bar = metrics.points(EventLogBarSizes.height)
        let menuHeight = metrics.points(EventLogBarSizes.menuHeight)
        let inset = metrics.points(EventLogBarSizes.menuInset)
        let maxWidth = max(0, (bounds.width - 2 * padding) * EventLogBarSizes.menuMaxPart)
        let menuWidth = max(0, min(sessionMenu.intrinsicContentSize.width, maxWidth - 2 * inset))
        sessionMenu.frame = NSRect(
            x: padding + inset, y: ((bar - menuHeight) / 2).rounded(), width: menuWidth,
            height: menuHeight)
        let countHeight = countLabel.intrinsicContentSize.height
        let countX = menuBox.maxX + metrics.points(EventLogBarSizes.gap)
        countLabel.frame = NSRect(
            x: countX, y: ((bar - countHeight) / 2).rounded(),
            width: max(0, bounds.width - padding - countX), height: countHeight)
        let top = bar + metrics.points(1)
        rows.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        let space = metrics.points(EventLogBarSizes.emptyPadding)
        let textWidth = max(0, bounds.width - 2 * space)
        emptyText.frame = wrapped(emptyText, x: space, y: top + space, width: textWidth)
        let hintY = emptyText.frame.maxY + metrics.points(EventLogBarSizes.hintGap)
        hintText.frame = wrapped(hintText, x: space, y: hintY, width: textWidth)
        needsDisplay = true
    }

    // The box of the Session filter: the menu with its inset at the left and the right.
    private var menuBox: NSRect {
        let metrics = state?.metrics ?? CanvasMetrics(interfaceScale: 100)
        return sessionMenu.frame.insetBy(dx: -metrics.points(EventLogBarSizes.menuInset), dy: 0)
    }

    private func wrapped(_ text: NSTextField, x: CGFloat, y: CGFloat, width: CGFloat) -> NSRect {
        text.preferredMaxLayoutWidth = width
        let size = text.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        return NSRect(x: x, y: y, width: width, height: size.height.rounded(.up))
    }

    // The box of the Session filter and the line under the bar, in the panel edge colour.
    override package func draw(_ dirtyRect: NSRect) {
        let metrics = state?.metrics ?? CanvasMetrics(interfaceScale: 100)
        let line = metrics.points(1)
        ThemeTokens.panelEdge.nsColor.set()
        let bar = metrics.points(EventLogBarSizes.height)
        NSRect(x: 0, y: bar, width: bounds.width, height: line).fill(using: .sourceOver)
        let box = NSBezierPath(rect: menuBox.insetBy(dx: line / 2, dy: line / 2))
        box.lineWidth = line
        box.stroke()
    }
}

// The body of the Event log panel in a frame: one part of the panel bodies.
@MainActor
package final class EventLogPanels: PanelBodiesPart {
    private let source: @MainActor @Sendable () -> EventLogState
    // The body while the panel is in a frame.
    private var body: EventLogPanel?

    // The body reads the entries of the log, the names of the rows of the session list (their
    // one place), the state of Live details and the Interface scale. liveOn and metrics read
    // observable values, so the body follows their changes.
    package init(
        model: EventLogModel, sessions: SessionListModel,
        liveOn: @escaping @MainActor @Sendable () -> Bool,
        metrics: @escaping @MainActor @Sendable () -> CanvasMetrics
    ) {
        let known = KnownNames()
        source = {
            EventLogState(
                entries: model.entries, names: LogView.names(sessions.rows, known: &known.names),
                liveOn: liveOn(), metrics: metrics())
        }
    }

    package func body(for panel: PanelID) -> NSView? {
        guard panel == .eventLog else { return nil }
        if let body { return body }
        let made = EventLogPanel(source: source)
        body = made
        return made
    }

    package func releaseBody(for panel: PanelID) {
        guard panel == .eventLog else { return }
        body = nil
    }
}

// The safe form of each name of the last rows (LogView.names), so a change of a row that keeps its
// name does not make its safe form again.
@MainActor
private final class KnownNames {
    var names: [String: String] = [:]
}
