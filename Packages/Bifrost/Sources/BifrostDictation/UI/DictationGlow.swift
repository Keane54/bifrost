// The green look of a frame while the chat of its active panel listens ("The look" in
// docs/behaviour/dictation.md, option B of the approved mock: the user decision of the green
// glow). The values come from DictationLook.of(level:), with the level smoothed at each display
// frame. Each size is in layout units.
// - The top line of the frame is one 2 unit bar: the 1 unit top border of the frame and a 1 unit
//   edge inside it, both in the green with the border alpha.
// - The shadow of the top border is a soft green light above the top edge only (EdgeGlow). The
//   light starts b in from each end of the edge, and its softness is b / 2, where b is the shadow
//   blur of the look. It is strongest at the edge, and it falls off upwards and at the two ends.
// - The glow falls down from the top line into the window as a central hump: a layer 3 % in
//   from each side and 1 unit below the top border, with the height and the blur of the look.
//   Its fill is a radial ellipse at the middle of its top, as wide as the glow width of the look
//   (a part of the width of the layer) and as high as the layer, with the stops at 0, 45 and
//   75 %: the glow alpha, 0.35 of it, then nothing.
// No part takes pointer input.
import AppKit
import BifrostLook
import CoreImage
import QuartzCore

@MainActor
package enum DictationGlow {
    // The height of the ellipse of the glow, as a part of the height of the glow. The look gives
    // its width.
    static let ellipseHeight = 1.0
    // The inset of the glow at each side, as a part of the inner width of the frame.
    static let sideInset = 0.03
    // The glow starts this many units below the top border (top: 1px).
    static let top = 1.0
    // The stops of the glow and the alpha of each one as a part of the glow alpha.
    static let stops: [Double] = [0, 0.45, 0.75]
    static let stopAlphas: [Double] = [1, 0.35, 0]
    // The edge inside the top border.
    static let edgeHeight = 1.0

    // The green token with an alpha.
    package static func green(_ alpha: Double) -> CGColor {
        var colour = ThemeTokens.watchGreen
        colour.a = min(1, max(0, alpha))
        return colour.cgColor
    }

    // The rect of the glow in the frame, in points. border and the width are in points.
    package static func glowRect(
        width: CGFloat, border: CGFloat, look: DictationLook, metrics: CanvasMetrics
    ) -> CGRect {
        let inner = max(0, width - border * 2)
        let inset = inner * CGFloat(sideInset)
        return CGRect(
            x: border + inset, y: border + metrics.points(top), width: max(0, inner - inset * 2),
            height: metrics.points(look.glowHeight))
    }

    // Put the shadow of the top border on the top edge of a frame of this width, in points. The
    // result is the area of the shadow in the frame, above its top edge.
    @discardableResult
    package static func layoutShadow(
        _ shadow: EdgeGlow, width: CGFloat, look: DictationLook, metrics: CanvasMetrics
    ) -> CGRect {
        let blur = metrics.points(look.borderShadowBlur)
        return shadow.layout(edgeWidth: width, inset: blur, softness: blur / 2)
    }

    // The rect of the edge inside the top border, in points.
    package static func edgeRect(
        width: CGFloat, border: CGFloat, metrics: CanvasMetrics
    ) -> CGRect {
        CGRect(
            x: border, y: border, width: max(0, width - border * 2),
            height: metrics.points(edgeHeight))
    }

    // The key path of the radius of the blur of the glow layer.
    package static let blurRadius = "filters.blur.inputRadius"

    // The layer of the glow: a radial gradient, with one blur filter for its life. A new look
    // changes only the radius of the filter, so Core Animation keeps the state of the filter.
    package static func makeGlowLayer() -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.type = .radial
        // The centre is the middle of the top. The end point gives the radii of the ellipse.
        layer.startPoint = CGPoint(x: 0.5, y: 0)
        layer.endPoint = endPoint(DictationLook.of(level: 0))
        layer.locations = stops.map { NSNumber(value: $0) }
        layer.filters = [blur()]
        return layer
    }

    // The shadow of the top border: a green light above the top edge.
    package static func makeShadow() -> EdgeGlow {
        EdgeGlow(colour: ThemeTokens.watchGreen)
    }

    // Give the layers the values of the look. layoutShadow(_:width:look:metrics:) gives the shadow
    // its size.
    package static func apply(
        _ look: DictationLook, glow: CAGradientLayer, shadow: EdgeGlow, metrics: CanvasMetrics
    ) {
        glow.colors = stopAlphas.map { green(look.glowAlpha * $0) }
        glow.endPoint = endPoint(look)
        glow.setValue(Double(metrics.points(look.glowBlur)), forKeyPath: blurRadius)
        shadow.strength = look.borderShadowAlpha
    }

    // The end point of the radial gradient for the look: the radii of the ellipse in the unit
    // space of the layer.
    package static func endPoint(_ look: DictationLook) -> CGPoint {
        CGPoint(x: 0.5 + look.glowWidth, y: ellipseHeight)
    }

    // The blur of the glow, named for its key path. The radius of CIGaussianBlur is its standard
    // deviation, as in the approved mock.
    private static func blur() -> CIFilter {
        let filter = CIFilter(name: "CIGaussianBlur") ?? CIFilter()
        filter.name = "blur"
        return filter
    }
}
