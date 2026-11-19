import BifrostLayout
import CoreGraphics

// The scale between layout units and points (plan decision). One layout unit is
// interfaceScale / 100 points. So the rects of ui-state.json keep the meaning that the shared
// file format gives them: pixels of a page at the zoom of the Interface scale setting.
nonisolated public struct CanvasMetrics: Sendable, Equatable {
    // The choices of the Interface scale setting, in percent: 80 to 150 in steps of 10. The
    // settings check the setting with them.
    package static let scaleChoices = Array(stride(from: 80, through: 150, by: 10))

    // The scale in percent, from 80 to 150 (scaleChoices).
    package let interfaceScale: Int

    // A value outside the range of the setting goes to the nearest end.
    public init(interfaceScale: Int) {
        let choices = Self.scaleChoices
        let low = choices.first ?? 100
        let high = choices.last ?? 100
        self.interfaceScale = min(max(interfaceScale, low), high)
    }

    // The points of one layout unit.
    package var scale: Double { Double(interfaceScale) / 100 }

    // The sums multiply by the percent and then divide by 100. A binary scale such as 1.1 is
    // not exact, so 880 / 1.1 gives 799.99... and the floor gives 799. 880 * 100 / 110 gives 800.
    private var percent: Double { Double(interfaceScale) }

    // A value in layout units as a value in points.
    private func toPoints(_ value: Double) -> Double { value * percent / 100 }

    // A rect in layout units as a rect in points.
    package func points(_ r: LayoutRect) -> CGRect {
        CGRect(x: toPoints(r.x), y: toPoints(r.y), width: toPoints(r.w), height: toPoints(r.h))
    }

    // A size in points as a size in whole layout units, as the size of a page at a zoom.
    package func units(_ size: CGSize) -> LayoutSize {
        LayoutSize(
            w: (Double(size.width) * 100 / percent).rounded(.down),
            h: (Double(size.height) * 100 / percent).rounded(.down))
    }

    // A length in layout units as a length in points: a font size, a padding, a border or a
    // width.
    public func points(_ length: Double) -> CGFloat { CGFloat(toPoints(length)) }
}
