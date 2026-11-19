// The mic icon and the level bar in the title bar of a frame while the chat of its active panel
// listens: a space of 8 at the left, the mic of 13 by 13 in the green, a space of 8, then the
// level bar of 44 by 3 on white/8 with the green part of the level. The sizes are in layout
// units. The meter is a row (a stack view) with its own size, so the title bar can put it first
// in its row. It takes no pointer input.
import AppKit
import BifrostLook

package final class DictationMeter: NSStackView {
    // The space before the mic, the side of the mic, the space between the mic and the bar, and
    // the height of the bar.
    static let leadingSpace = 8.0, micSize = 13.0, spacingAfterMic = 8.0, barHeight = 3.0
    // The width of the meter in layout units.
    package static let width = leadingSpace + micSize + spacingAfterMic + DictationLook.barWidth

    let mic = NSImageView()
    package let bar = MeterBar()
    // The fixed sizes of the mic and the bar.
    private var sizes: [ScaledLength] = []
    private var metrics = CanvasMetrics(interfaceScale: 100)

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal
        alignment = .centerY
        isHidden = true
        mic.image = Icons.image(.mic)
        mic.imageScaling = .scaleProportionallyUpOrDown
        mic.contentTintColor = ThemeTokens.watchGreen.nsColor
        // VoiceOver skips the mic: only the bar is an element.
        mic.setAccessibilityElement(false)
        addArrangedSubview(mic)
        addArrangedSubview(bar)
        sizes =
            mic.scaledSize(width: Self.micSize, height: Self.micSize)
            + bar.scaledSize(width: DictationLook.barWidth, height: Self.barHeight)
        apply(metrics: metrics)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    package override var isFlipped: Bool { true }
    package override func hitTest(_ point: NSPoint) -> NSView? { nil }
    package override func isAccessibilityElement() -> Bool { false }

    // The level of the bar, 0 to 1 (the smoothed level of the frame).
    package func show(level: Double) {
        bar.fill = DictationLook.of(level: level).barWidth / DictationLook.barWidth
    }

    // The size of the meter: the whole row, as high as the mic.
    package override var intrinsicContentSize: NSSize {
        NSSize(width: metrics.points(Self.width), height: metrics.points(Self.micSize))
    }

    package func apply(metrics: CanvasMetrics) {
        self.metrics = metrics
        edgeInsets = NSEdgeInsets(
            top: 0, left: metrics.points(Self.leadingSpace), bottom: 0, right: 0)
        spacing = metrics.points(Self.spacingAfterMic)
        sizes.apply(metrics)
        invalidateIntrinsicContentSize()
    }
}

// The level bar: white/8, and the green part of the level from the left. VoiceOver reads it as a
// level indicator from 0 to 1. It reads the value when it asks, so a change of the level posts no
// notification.
package final class MeterBar: NSView {
    // The part of the bar in the green, 0 to 1. A new level changes only the green layer, with
    // no layout pass.
    var fill = 0.0 {
        didSet { layoutFill() }
    }
    private let level = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = TokenColour.rgb(255, 255, 255, alpha: 0.08).cgColor
        level.backgroundColor = ThemeTokens.watchGreen.cgColor
        layer?.addSublayer(level)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("Voice level")
        setAccessibilityMinValue(NSNumber(value: 0))
        setAccessibilityMaxValue(NSNumber(value: 1))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    package override var isFlipped: Bool { true }
    package override func hitTest(_ point: NSPoint) -> NSView? { nil }
    package override func accessibilityValue() -> Any? { NSNumber(value: fill) }

    package override func layout() {
        super.layout()
        layoutFill()
    }

    private func layoutFill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        level.frame = CGRect(
            x: 0, y: 0, width: bounds.width * CGFloat(min(1, max(0, fill))),
            height: bounds.height)
        CATransaction.commit()
    }
}
