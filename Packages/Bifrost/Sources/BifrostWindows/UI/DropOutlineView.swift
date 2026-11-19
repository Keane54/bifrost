// The title bar where a drop stacks the dragged frame: a fill of the strong text colour at 10 %,
// and an outline of 2 units inside the edge in the strong text colour at 30 %. The outline is above
// all frames, because the dragged frame covers the title bar. It takes no pointer input and is
// hidden from accessibility.
import AppKit
import BifrostLook
import QuartzCore

final class DropOutlineView: NSView {
    // The width of the outline, in layout units (outline-2, -outline-offset-2).
    static let width = 2.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Self.colour(alpha: 0.1)
        layer?.borderColor = Self.colour(alpha: 0.3)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    // Show the outline over a title bar (a rect in points on the device pixels), or hide it for
    // nil.
    func show(_ bar: CGRect?, metrics: CanvasMetrics) {
        guard let bar else {
            if !isHidden { isHidden = true }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = bar
        layer?.borderWidth = metrics.points(Self.width)
        isHidden = false
        CATransaction.commit()
    }

    private static func colour(alpha: Double) -> CGColor {
        var colour = ThemeTokens.textStrong
        colour.a = alpha
        return colour.cgColor
    }
}
