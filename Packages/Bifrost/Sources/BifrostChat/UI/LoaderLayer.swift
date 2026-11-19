// The Take control loader of a chat window (docs/behaviour/chat.md, "The Take control loader"): a
// layer over the whole chat body with the line of the loader, and a soft band in the colours of
// the window background in the bottom two fifths. The band has the stops of the base gradient of
// the background (Motion.baseColours), from the left to the right, so it follows a change of the
// background colours. It fades in from transparent at its top edge, and it shifts slowly from side
// to side. With reduced motion it does not move. The layer takes no pointer input. The chat body
// hides the terminal and the note while the layer shows.
import AppKit
import BifrostLook
import QuartzCore

// The values of the loader look.
package struct LoaderLook: Sendable, Equatable {
    // One step of the fade of the band: the place from the top edge (0) to the bottom edge
    // (1), and the alpha of the mask there.
    package struct FadeStep: Sendable, Equatable {
        package var at: Double
        package var alpha: Double

        package init(_ at: Double, _ alpha: Double) {
            self.at = at
            self.alpha = alpha
        }
    }

    // The colours of the band from its start to its end: the stops of the base gradient of the
    // window background (Motion.baseColours). The loader has no colour of its own.
    package var colours: [TokenColour]
    // The angle of the gradient: 0 degrees points up, 90 to the right.
    package var angle: Double
    // The gradient is this many times the width of the band, so the motion can shift it.
    package var widthFactor: Double
    // The height of the band: this part of the chat body, at the bottom.
    package var heightPart: Double
    // The fade of the band from its top edge to its bottom edge, on an eased curve: the upper
    // half stays faint, and the colour has its full strength only at the bottom edge.
    package var fade: [FadeStep]
    // The opacity of the band.
    package var opacity: Double
    // The time of one shift from one end of the gradient to the other. Then the shift goes back,
    // on the ease-in-out curve, with no end.
    package var shiftTime: Duration
    // The line: its top at this part of the height, its text size and the inset at its sides,
    // in layout units.
    package var textTop: Double
    package var textSize: Double
    package var textInset: Double

    package static let standard = LoaderLook(
        colours: Motion.baseColours, angle: 100, widthFactor: 2, heightPart: 0.4,
        fade: [
            FadeStep(0, 0), FadeStep(0.15, 0.03), FadeStep(0.30, 0.1), FadeStep(0.45, 0.2),
            FadeStep(0.60, 0.38), FadeStep(0.75, 0.6), FadeStep(0.90, 0.85), FadeStep(1, 1),
        ], opacity: 0.25, shiftTime: .seconds(12), textTop: 0.4, textSize: 13, textInset: 16)
}

@MainActor
package final class LoaderLayer: NSView {
    // The key of the shift animation on the gradient layer.
    package static let shiftKey = "loader-shift"

    package let label = NSTextField(wrappingLabelWithString: "")
    package let rainbow = RainbowView(look: .standard)
    private let look = LoaderLook.standard
    private var metrics = CanvasMetrics(interfaceScale: 100)

    override package init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        label.alignment = .center
        label.textColor = ThemeTokens.text.nsColor
        label.isSelectable = false
        label.refusesFirstResponder = true
        label.setAccessibilityRole(.staticText)
        addSubview(rainbow)
        addSubview(label)
        setMetrics(metrics)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override package var isFlipped: Bool { true }

    // A click goes through the loader.
    override package func hitTest(_ point: NSPoint) -> NSView? { nil }

    // The line that shows, or nil while the loader is hidden.
    package var text: String? { isHidden ? nil : label.stringValue }

    // True while the band moves.
    package var isMoving: Bool { rainbow.isMoving }

    package func setMetrics(_ metrics: CanvasMetrics) {
        self.metrics = metrics
        label.font = Fonts.ui(metrics.points(look.textSize), weight: .regular)
        needsLayout = true
    }

    // Show the loader with the line. A screen reader hears the line when the loader shows or the
    // line changes.
    package func show(_ text: String, reduceMotion: Bool) {
        let changed = isHidden || label.stringValue != text
        label.stringValue = text
        isHidden = false
        rainbow.setMoving(!reduceMotion)
        needsLayout = true
        guard changed, let app = NSApp else { return }
        NSAccessibility.post(
            element: app, notification: .announcementRequested,
            userInfo: [
                .announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
    }

    package func hide() {
        isHidden = true
        rainbow.setMoving(false)
    }

    override package func layout() {
        super.layout()
        let height = (bounds.height * look.heightPart).rounded()
        rainbow.frame = NSRect(
            x: 0, y: bounds.height - height, width: bounds.width, height: height)
        // A long line wraps inside the insets, and it stops at the bottom edge.
        let inset = min(metrics.points(look.textInset), bounds.width / 2)
        let width = max(0, bounds.width - 2 * inset)
        let top = (bounds.height * look.textTop).rounded()
        label.preferredMaxLayoutWidth = width
        let fitted = label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        label.frame = NSRect(
            x: inset, y: top, width: width,
            height: min(fitted.height.rounded(.up), max(0, bounds.height - top)))
    }
}

// The band of the loader. Its layer clips a gradient layer that is widthFactor times as wide as
// the band, and the mask of the layer gives the fade. The shift moves the anchor point of the
// gradient from its left edge to its middle and back, so the shift stays right at each size of
// the band.
@MainActor
package final class RainbowView: NSView {
    package let gradient = CAGradientLayer()
    package let mask = CAGradientLayer()
    private let look: LoaderLook

    init(look: LoaderLook) {
        self.look = look
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        alphaValue = look.opacity
        gradient.colors = look.colours.map(\.nsColor.cgColor)
        gradient.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(gradient)
        // The view is not flipped: in the unit space of the mask, y = 1 is the top edge.
        mask.colors = look.fade.map { NSColor.black.withAlphaComponent($0.alpha).cgColor }
        mask.locations = look.fade.map { NSNumber(value: $0.at) }
        mask.startPoint = CGPoint(x: 0.5, y: 1)
        mask.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.mask = mask
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override package var isFlipped: Bool { false }
    override package func hitTest(_ point: NSPoint) -> NSView? { nil }
    override package func isAccessibilityElement() -> Bool { false }

    // True while the shift animation runs.
    package var isMoving: Bool { gradient.animation(forKey: LoaderLayer.shiftKey) != nil }

    // Start or stop the shift. A shift that runs keeps its phase.
    func setMoving(_ on: Bool) {
        if on && !isMoving {
            let shift = CABasicAnimation(keyPath: "anchorPoint")
            shift.fromValue = CGPoint(x: 0, y: 0.5)
            shift.toValue = CGPoint(x: 1 - 1 / look.widthFactor, y: 0.5)
            shift.duration = look.shiftTime / .seconds(1)
            shift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shift.autoreverses = true
            shift.repeatCount = .infinity
            shift.isRemovedOnCompletion = false
            gradient.add(shift, forKey: LoaderLayer.shiftKey)
        } else if !on {
            gradient.removeAnimation(forKey: LoaderLayer.shiftKey)
        }
    }

    override package func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        let width = bounds.width * look.widthFactor
        gradient.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        gradient.position = CGPoint(x: 0, y: bounds.height / 2)
        // The line of the gradient at its angle across the whole gradient (Motion.gradientLine
        // gives it from the top left corner, with y down).
        let line = Motion.gradientLine(look.angle, width, bounds.height)
        if width > 0, bounds.height > 0 {
            gradient.startPoint = CGPoint(x: line.x0 / width, y: 1 - line.y0 / bounds.height)
            gradient.endPoint = CGPoint(x: line.x1 / width, y: 1 - line.y1 / bounds.height)
        }
        CATransaction.commit()
    }
}
