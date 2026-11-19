// A length of a view in layout units, as a layout constraint. The constant of the constraint is
// the length in points at the Interface scale, so a change of the scale changes only the
// constants. The chrome of the frames and the dictation parts use it for their fixed sizes.
import AppKit

@MainActor
package struct ScaledLength {
    package let constraint: NSLayoutConstraint
    package let units: Double

    // Set the points of the length for the scale.
    package func apply(_ metrics: CanvasMetrics) {
        let points = metrics.points(units)
        if constraint.constant != points { constraint.constant = points }
    }
}

extension NSView {
    // A fixed width and height of the view in layout units. The constraints are active. The view
    // must be in a stack view or have no autoresizing constraints.
    package func scaledSize(width: Double, height: Double) -> [ScaledLength] {
        let lengths = [
            ScaledLength(constraint: widthAnchor.constraint(equalToConstant: width), units: width),
            ScaledLength(
                constraint: heightAnchor.constraint(equalToConstant: height), units: height),
        ]
        for length in lengths { length.constraint.isActive = true }
        return lengths
    }
}

extension [ScaledLength] {
    // Set the points of each length for the scale.
    @MainActor
    package func apply(_ metrics: CanvasMetrics) {
        for length in self { length.apply(metrics) }
    }
}
