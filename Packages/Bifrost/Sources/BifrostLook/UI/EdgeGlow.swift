// A soft light above the top edge of a frame: the cyan glow of the top frame, and the green
// shadow of the top border while a chat listens. The light is strongest at the edge. It falls off
// upwards, and it falls off at the two ends of the edge, so it has no hard side.
//
// Core Animation makes the light. A strip lies along the edge, just below the area of the light,
// and only the shadow of the strip shows. The shadow is a Gaussian blur of the strip, so the light
// at the edge is half the alpha of the colour, and the softness is the standard deviation of the
// blur. The layer of the glow is the area above the edge, and it clips the shadow, so no light
// falls on the frame itself. The shadow has a path, so Core Animation draws it with no
// offscreen pass. The alpha of the colour is the shadow opacity, so a new strength makes no colour.
import QuartzCore

@MainActor
package final class EdgeGlow {
    // The light goes this many times the softness past the strip. Past that distance it is less
    // than 0.2 % of the alpha of the colour.
    package static let reach: CGFloat = 3

    // The area of the light. Put it in a view or a layer above the edge, at the rect that
    // layout(edgeWidth:inset:softness:) gives.
    package let layer = CALayer()
    private let strip = CALayer()

    package init(colour: TokenColour) {
        layer.masksToBounds = true
        // The y axis goes down, as in the frame, so the edge is the bottom of the layer.
        layer.isGeometryFlipped = true
        strip.shadowColor = colour.opacity(1).cgColor
        strip.shadowOpacity = Float(colour.a)
        strip.shadowOffset = .zero
        strip.shadowRadius = 0
        layer.addSublayer(strip)
    }

    // The alpha of the colour, from 0 to 1. The light at the middle of the edge is half of it.
    package var strength: Double {
        get { Double(strip.shadowOpacity) }
        set {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            strip.shadowOpacity = Float(min(1, max(0, newValue)))
            CATransaction.commit()
        }
    }

    // The standard deviation of the blur, in points.
    package var softness: CGFloat { strip.shadowRadius }

    // The rect of the strip in the layer, in points.
    package var stripFrame: CGRect { strip.frame }

    // Put the light on an edge of this width, in points. The strip starts inset from each end of
    // the edge, and softness is the standard deviation of the blur. The result is the area of the
    // light in the coordinates of the edge: x is 0 at the left end of the edge, y is 0 at the
    // edge, and y goes down. The caller puts the layer there.
    @discardableResult
    package func layout(edgeWidth: CGFloat, inset: CGFloat, softness: CGFloat) -> CGRect {
        let soft = max(0, softness)
        let reach = soft * Self.reach
        let length = max(0, edgeWidth - inset * 2)
        let area = CGRect(
            x: inset - reach, y: -reach, width: length + reach * 2, height: reach)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The strip lies below the area, from the edge down. Its far side is out of reach, so
        // only its near side lights the area.
        strip.frame = CGRect(x: reach, y: reach, width: length, height: max(reach, 1))
        strip.shadowPath = CGPath(rect: strip.bounds, transform: nil)
        strip.shadowRadius = soft
        CATransaction.commit()
        return area
    }
}
