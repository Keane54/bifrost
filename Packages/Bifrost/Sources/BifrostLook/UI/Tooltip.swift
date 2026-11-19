// The tooltips of the frames and the side bar (docs/behaviour/look.md, "Tooltips"): the title
// colour, a border of the panel edge colour, the text colour, the UI font at 12 with a line
// height of 16, and a space of 8 by 4 around the text, all in layout units. A line break in the
// text starts a new line. The pointer goes through the tooltip, so a tooltip that covers the next
// view does not stop the tooltip of that view. The rules of the delay and the place are in
// TooltipRules.swift (the model of the look). A tooltip of a view in a small panel, such as a
// row of a menu, takes the screen as its area (TooltipArea).
import AppKit
import BifrostFoundation
import BifrostLayout

@MainActor
public final class TooltipController {
    public static let shared = TooltipController()

    // The scale of the tooltips. The app sets it at each change of the Interface scale setting.
    public var metrics = CanvasMetrics(interfaceScale: 100)

    // The views with a tooltip, and their text and side.
    private var trackers: [ObjectIdentifier: Tracker] = [:]
    private var timing = TooltipTiming()
    // The show after the delay. Each move of the pointer moves the show to the end of a new
    // delay, so a pointer that moves makes one wait.
    private let pending: Debouncer
    private var panel: NSPanel?
    private var shown: ObjectIdentifier?
    private var monitor: Any?
    // The time since the start, on the clock of the owner.
    private let elapsed: @Sendable () -> Duration

    package convenience init() {
        self.init(clock: ContinuousClock())
    }

    // A test gives a manual clock.
    init<C: Clock>(clock: C) where C.Duration == Duration {
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
        pending = Debouncer(clock: clock)
    }

    // Give a view a tooltip. A second call for the same view changes its text, its side and its
    // area.
    package func attach(
        _ text: String, to view: NSView, side: TooltipSide, area: TooltipArea = .window
    ) {
        // A view that is gone without a detach leaves its tracker. A new view can get the same
        // identifier, so the trackers of the views that are gone go first.
        trackers = trackers.filter { $0.value.view != nil }
        let id = ObjectIdentifier(view)
        if let tracker = trackers[id] {
            tracker.text = text
            tracker.side = side
            tracker.tipArea = area
            return
        }
        let tracker = Tracker(controller: self, view: view, text: text, side: side)
        tracker.tipArea = area
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: tracker, userInfo: nil)
        tracker.area = area
        trackers[id] = tracker
        view.addTrackingArea(area)
    }

    // Remove the tooltip of a view.
    package func detach(from view: NSView) {
        let id = ObjectIdentifier(view)
        guard let tracker = trackers.removeValue(forKey: id) else { return }
        if let area = tracker.area { view.removeTrackingArea(area) }
        if tracker.waiting && shown != id { pending.cancel() }
        if shown == id { hide() }
        stopWatchingIfIdle()
    }

    // The text of the tooltip of a view, or nil.
    func text(of view: NSView) -> String? { trackers[ObjectIdentifier(view)]?.text }

    // The area of the tooltip of a view, or nil.
    func area(of view: NSView) -> TooltipArea? { trackers[ObjectIdentifier(view)]?.tipArea }

    // True while the monitor of the presses and the Esc key is on.
    var watchesPresses: Bool { monitor != nil }

    // A keyboard focus on the view shows its tooltip at once, with no delay. A control with a
    // tooltip calls this from becomeFirstResponder. AppKit gives
    // a button the focus only from the keyboard (Full Keyboard Access).
    package func focused(_ view: NSView) {
        guard let tracker = trackers[ObjectIdentifier(view)] else { return }
        tracker.waiting = true
        tracker.pressed = false
        pending.cancel()
        watchPresses()
        show(tracker)
    }

    // The view lost the focus: its tooltip closes. A control calls this from
    // resignFirstResponder.
    package func unfocused(_ view: NSView) {
        guard let tracker = trackers[ObjectIdentifier(view)] else { return }
        exited(tracker)
    }

    private var now: Duration { elapsed() }

    fileprivate func entered(_ tracker: Tracker) {
        guard !tracker.pressed else { return }
        tracker.waiting = true
        watchPresses()
        wait(for: tracker)
    }

    // The pointer must rest on the view for the delay. Each move of the pointer before the
    // tooltip shows starts the delay again.
    fileprivate func moved(_ tracker: Tracker) {
        guard tracker.waiting, shown != tracker.id else { return }
        wait(for: tracker)
    }

    private func wait(for tracker: Tracker) {
        let delay = timing.openDelay(now: now)
        if delay == .zero {
            pending.cancel()
            show(tracker)
            return
        }
        pending.schedule(after: delay) { [weak self, weak tracker] in
            guard let self, let tracker, tracker.waiting else { return }
            self.show(tracker)
        }
    }

    fileprivate func exited(_ tracker: Tracker) {
        tracker.waiting = false
        tracker.pressed = false
        pending.cancel()
        if shown == tracker.id { hide() }
        stopWatchingIfIdle()
    }

    // A press on the view closes its tooltip until the pointer leaves the view. The Esc key also
    // closes it.
    private func watchPresses() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown,
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.pressed(event)
            return event
        }
    }

    // The monitor stays while a tooltip shows (also one of a keyboard focus) or waits.
    private func stopWatchingIfIdle() {
        let waits = trackers.values.contains(where: \.waiting)
        guard shown == nil, !waits else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // The key code of the Esc key.
    private static let escape: UInt16 = 53

    private func pressed(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode != Self.escape { return }
        for tracker in trackers.values where tracker.waiting {
            tracker.waiting = false
            tracker.pressed = event.type != .keyDown
        }
        pending.cancel()
        hide()
        stopWatchingIfIdle()
    }

    // A window that does not show gets no tooltip.
    private func show(_ tracker: Tracker) {
        guard let view = tracker.view, let window = view.window, window.isVisible,
            let content = window.contentView
        else { return }
        hide()
        let scale = metrics.scale
        let screenRect: CGRect
        let tip: NSView
        switch tracker.tipArea {
        case .screen:
            // A long line wraps at the width of the screen, inside its padding.
            let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
            tip = makeTip(
                tracker.text, maxWidth: screen.width - 2 * TooltipPlacement.padding * scale)
            let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
            screenRect = Self.screenFrame(
                tip: tip.frame.size, anchor: anchor, side: tracker.side, screen: screen,
                scale: scale)
        case .window:
            // A long line wraps at the edge of the window. A line break in the text starts a line.
            tip = makeTip(tracker.text, maxWidth: content.bounds.width)
            let anchor = content.convert(view.bounds, from: view)
            let flippedAnchor = content.isFlipped ? anchor : flip(anchor, in: content.bounds)
            let frame = TooltipPlacement.frame(
                tip: LayoutSize(w: tip.frame.width, h: tip.frame.height),
                anchor: LayoutRect(
                    x: flippedAnchor.minX, y: flippedAnchor.minY, w: flippedAnchor.width,
                    h: flippedAnchor.height),
                side: tracker.side,
                in: LayoutRect(x: 0, y: 0, w: content.bounds.width, h: content.bounds.height),
                scale: scale)
            var rect = CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h)
            if !content.isFlipped { rect = flip(rect, in: content.bounds) }
            screenRect = window.convertToScreen(content.convert(rect, to: nil))
        }
        let panel = NSPanel(
            contentRect: screenRect, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = tip
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        shown = tracker.id
        timing.opened()
    }

    private func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        shown = nil
        timing.closed(at: now)
    }

    private func flip(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    // The frame of a tip in the visible frame of a screen, for an anchor in screen coordinates
    // (y up). The rules of TooltipPlacement apply with the screen as the area: the tip flips at
    // the edge of the screen and stays inside it.
    static func screenFrame(
        tip: CGSize, anchor: CGRect, side: TooltipSide, screen: CGRect, scale: Double
    ) -> CGRect {
        let frame = TooltipPlacement.frame(
            tip: LayoutSize(w: tip.width, h: tip.height),
            anchor: LayoutRect(
                x: anchor.minX - screen.minX, y: screen.maxY - anchor.maxY, w: anchor.width,
                h: anchor.height),
            side: side, in: LayoutRect(x: 0, y: 0, w: screen.width, h: screen.height),
            scale: scale)
        return CGRect(
            x: screen.minX + frame.x, y: screen.maxY - frame.y - frame.h, width: frame.w,
            height: frame.h)
    }

    // The sizes of a tooltip in layout units: the size of the text, the height of a line, the
    // width of the border, and the space between the border and the text at the sides and at
    // the top and the bottom.
    static let textSize = 12.0, lineHeight = 16.0, border = 1.0, textInsetX = 8.0, textInsetY = 4.0

    // The view of a tooltip with the text, at the scale of the metrics. The tooltip, with its
    // border and its text insets, is at most maxWidth wide, so a long line wraps.
    func makeTip(_ text: String, maxWidth: CGFloat = .greatestFiniteMagnitude) -> NSView {
        let font = Fonts.ui(metrics.points(Self.textSize), weight: .regular)
        let line = metrics.points(Self.lineHeight)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = line
        style.maximumLineHeight = line
        style.lineBreakMode = .byWordWrapping
        let label = NSTextField(wrappingLabelWithString: text)
        label.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: font, .foregroundColor: ThemeTokens.text.nsColor, .paragraphStyle: style,
            ])
        label.font = font
        label.textColor = ThemeTokens.text.nsColor
        label.maximumNumberOfLines = 0
        let border = metrics.points(Self.border)
        let insetX = metrics.points(Self.textInsetX)
        let insetY = metrics.points(Self.textInsetY)
        let textWidth = max(1, maxWidth - (insetX + border) * 2)
        label.preferredMaxLayoutWidth = textWidth
        let bounds = NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)
        let fitted = label.cell?.cellSize(forBounds: bounds) ?? label.intrinsicContentSize
        label.frame = NSRect(
            x: border + insetX, y: border + insetY,
            width: min(textWidth, fitted.width.rounded(.up)), height: fitted.height.rounded(.up))
        let tip = NSView(
            frame: NSRect(
                x: 0, y: 0, width: label.frame.width + (insetX + border) * 2,
                height: label.frame.height + (insetY + border) * 2))
        tip.wantsLayer = true
        tip.layer?.backgroundColor = ThemeTokens.title.cgColor
        tip.layer?.borderColor = ThemeTokens.panelEdge.cgColor
        tip.layer?.borderWidth = border
        tip.layer?.cornerRadius = 0
        tip.addSubview(label)
        return tip
    }
}

// The tracking area of one view with a tooltip. AppKit sends the events of the area to its owner
// through the responder methods.
private final class Tracker: NSResponder {
    weak var controller: TooltipController?
    weak var view: NSView?
    var text: String
    var side: TooltipSide
    // The area that holds the tooltip.
    var tipArea = TooltipArea.window
    let id: ObjectIdentifier
    // The pointer is on the view, and its tooltip waits or shows.
    var waiting = false
    // A press closed the tooltip, until the pointer leaves the view.
    var pressed = false
    // The tracking area on the view. Its owner is this tracker.
    var area: NSTrackingArea?

    init(controller: TooltipController, view: NSView, text: String, side: TooltipSide) {
        self.controller = controller
        self.view = view
        self.text = text
        self.side = side
        id = ObjectIdentifier(view)
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func mouseEntered(with event: NSEvent) { controller?.entered(self) }
    override func mouseMoved(with event: NSEvent) { controller?.moved(self) }
    override func mouseExited(with event: NSEvent) { controller?.exited(self) }
}
