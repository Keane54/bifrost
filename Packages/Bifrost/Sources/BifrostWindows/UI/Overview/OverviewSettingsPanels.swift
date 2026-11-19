// The bodies of the Overview Settings panels, and the AppKit parts of a body: its host and the
// radio group of the tab colours.
//
// The radio group is an AppKit control in the SwiftUI body (TabColourGroup), because its arrow
// keys need the key focus, and a SwiftUI control that moves with a frame is never focusable (the
// section "The UI" of the architecture design). A click on a swatch chooses its colour and gives
// the group the focus. Then Left and Right choose the previous and the next colour, and wrap at
// the ends (OverviewSettingsRules.nextColour). The group has the control mark, so the Bifrost keys
// leave its arrow keys to it.
import AppKit
import BifrostKeyboard
import BifrostLayout
import BifrostLook
import SwiftUI

// The bodies of the Overview Settings panels: one host for each overview-settings:<n> panel in a
// frame. All bodies share the model of the Overviews.
@MainActor
package final class OverviewSettingsPanels: PanelBodiesPart {
    private let model: OverviewModel
    private let look: PanelLook
    private var hosts: [PanelID: OverviewSettingsHost] = [:]

    package init(model: OverviewModel, look: PanelLook) {
        self.model = model
        self.look = look
    }

    // overview-settings:<n> edits overview:<n>.
    package func body(for panel: PanelID) -> NSView? {
        guard case .overviewSettings(let number) = panel else { return nil }
        if let host = hosts[panel] { return host }
        let view = OverviewSettingsPanel(model: model, overview: .overview(number), look: look)
        let host = OverviewSettingsHost(rootView: view)
        host.sizingOptions = []
        hosts[panel] = host
        return host
    }

    package func releaseBody(for panel: PanelID) {
        hosts[panel] = nil
    }
}

// The host of an Overview Settings panel. It never takes the first responder, and it is not in
// the Tab loop of the window. The colour group in it takes the focus itself.
package typealias OverviewSettingsHost = PassiveHostingView<OverviewSettingsPanel>

// The radio group of the tab colours in the SwiftUI body. The swatches wrap to the next line when
// the width is too small for one line.
struct TabColourGroup: NSViewRepresentable {
    let selected: Int
    let metrics: CanvasMetrics
    let choose: (Int) -> Void

    func makeNSView(context: Context) -> TabColourPicker {
        TabColourPicker(selected: selected, metrics: metrics, choose: choose)
    }

    func updateNSView(_ view: TabColourPicker, context: Context) {
        view.show(selected: selected, metrics: metrics, choose: choose)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: TabColourPicker, context: Context
    ) -> CGSize? {
        nsView.size(forWidth: proposal.width)
    }
}

// The radio group: 12 swatches of 14 units with 6 units between them, in the order of the
// colours. The chosen swatch has an outline of 1 unit in the strong text colour around it. While
// the group has the focus, the system focus ring is around the chosen swatch.
@MainActor
package final class TabColourPicker: NSView {
    // The side of a swatch and the space between two swatches, in layout units.
    static let side = 14.0
    static let gap = 6.0
    // The outline of the chosen swatch is outside the swatch, so each swatch view is this much
    // larger at each edge.
    static let outline = 1.0

    package private(set) var selected: Int
    private var metrics: CanvasMetrics
    private var onChoose: (Int) -> Void
    private let swatches: [TabColourSwatch]

    init(selected: Int, metrics: CanvasMetrics, choose: @escaping (Int) -> Void) {
        self.selected = selected
        self.metrics = metrics
        onChoose = choose
        swatches = OverviewSettingsPanel.colourNames.indices.map(TabColourSwatch.init)
        super.init(frame: .zero)
        identifier = FocusMark.control
        for swatch in swatches {
            swatch.picker = self
            addSubview(swatch)
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override package var isFlipped: Bool { true }
    override package var acceptsFirstResponder: Bool { true }

    func show(selected: Int, metrics: CanvasMetrics, choose: @escaping (Int) -> Void) {
        onChoose = choose
        let scaled = metrics != self.metrics
        self.metrics = metrics
        if scaled { invalidateIntrinsicContentSize() }
        guard selected != self.selected || scaled else { return }
        self.selected = selected
        refresh()
    }

    // A click on a swatch, or an arrow key.
    package func choose(_ index: Int) {
        guard OverviewSettingsPanel.colourNames.indices.contains(index) else { return }
        if index != selected {
            selected = index
            refresh()
        }
        onChoose(index)
    }

    // A swatch got a click: the group takes the focus, so the arrow keys work.
    func clicked(_ index: Int) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        choose(index)
    }

    override package func keyDown(with event: NSEvent) {
        guard case .named(let name)? = KeyEvent(event, isComposing: false)?.key else {
            super.keyDown(with: event)
            return
        }
        let next = OverviewSettingsRules.nextColour(selected, key: name)
        guard next != selected else {
            super.keyDown(with: event)
            return
        }
        choose(next)
    }

    // MARK: - The layout

    // The size for a width: as many swatches on a line as the width holds, at least one.
    func size(forWidth width: CGFloat?) -> CGSize {
        let (columns, rows) = grid(width)
        let cell = metrics.points(Self.side + 2 * Self.outline)
        let step = metrics.points(Self.side + Self.gap)
        return CGSize(
            width: CGFloat(columns - 1) * step + cell, height: CGFloat(rows - 1) * step + cell)
    }

    private func grid(_ width: CGFloat?) -> (columns: Int, rows: Int) {
        let count = swatches.count
        let step = metrics.points(Self.side + Self.gap)
        let cell = metrics.points(Self.side + 2 * Self.outline)
        var columns = count
        if let width, width.isFinite, step > 0 {
            columns = min(count, max(1, Int(((width - cell) / step).rounded(.down)) + 1))
        }
        return (columns, (count + columns - 1) / columns)
    }

    override package func layout() {
        super.layout()
        let (columns, _) = grid(bounds.width)
        let cell = metrics.points(Self.side + 2 * Self.outline)
        let step = metrics.points(Self.side + Self.gap)
        for (index, swatch) in swatches.enumerated() {
            swatch.frame = NSRect(
                x: CGFloat(index % columns) * step, y: CGFloat(index / columns) * step,
                width: cell, height: cell)
        }
    }

    private func refresh() {
        for swatch in swatches {
            swatch.show(chosen: swatch.index == selected, metrics: metrics)
        }
        noteFocusRingMaskChanged()
        needsLayout = true
    }

    // MARK: - The focus ring

    override package var focusRingMaskBounds: NSRect {
        swatches.indices.contains(selected) ? swatches[selected].frame : bounds
    }

    override package func drawFocusRingMask() {
        guard swatches.indices.contains(selected) else { return }
        NSBezierPath(rect: swatches[selected].frame).fill()
    }

    // MARK: - Accessibility: a radio group of radio buttons

    override package func isAccessibilityElement() -> Bool { true }
    override package func accessibilityRole() -> NSAccessibility.Role? { .radioGroup }
    override package func accessibilityLabel() -> String? { "Tab colour" }
    override package func accessibilityChildren() -> [Any]? { swatches }
}

// One swatch of the radio group: a square of the tab colour. A press makes it 70 % opaque. Its
// tooltip is the name of the colour.
@MainActor
final class TabColourSwatch: NSView {
    let index: Int
    weak var picker: TabColourPicker?
    private var chosen = false
    private var pressed = false
    private var metrics = CanvasMetrics(interfaceScale: 100)

    init(_ index: Int) {
        self.index = index
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    private var name: String { OverviewSettingsPanel.colourNames[index] }

    func show(chosen: Bool, metrics: CanvasMetrics) {
        guard chosen != self.chosen || metrics != self.metrics else { return }
        self.chosen = chosen
        self.metrics = metrics
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            TooltipController.shared.detach(from: self)
        } else {
            TooltipController.shared.attach(name, to: self, side: .top)
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { picker?.clicked(index) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = metrics.points(TabColourPicker.outline)
        let swatch = bounds.insetBy(dx: outline, dy: outline)
        ThemeTokens.tab(index).nsColor.withAlphaComponent(pressed ? 0.7 : 1).setFill()
        swatch.fill()
        if chosen {
            ThemeTokens.textStrong.nsColor.setFill()
            let ring = NSBezierPath(rect: bounds)
            ring.append(NSBezierPath(rect: swatch).reversed)
            ring.fill()
        }
    }

    // MARK: - Accessibility: a radio button

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityLabel() -> String? { name }
    override func accessibilityValue() -> Any? { chosen ? 1 : 0 }
    override func accessibilityParent() -> Any? { picker }

    override func accessibilityPerformPress() -> Bool {
        picker?.choose(index)
        return true
    }
}
