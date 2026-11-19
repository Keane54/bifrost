// The arrow marks of the snap that a release applies (docs/behaviour/windows.md, "Dragging,
// snapping and stacking"). The x mark has a left or a right arrow, and the y mark has an up or a
// down arrow. Each arrow is a chevron of lucide, 10 units square, with the stroke width 3 of the 24
// unit icon box (absoluteStrokeWidth is off, so the line is 3 * 10 / 24 units wide), round ends and
// the colour of the snap token. The arrow is centred on its mark point and stays inside the area.
// Each mark is one shape layer, the change of a mark has no implicit animation, and the view takes
// no pointer input.
import AppKit
import BifrostLayout
import BifrostLook
import QuartzCore

final class SnapMarksView: NSView {
    // The size of an arrow, in layout units.
    static let markSize = 10.0
    // The stroke of an arrow, in layout units.
    static let lineWidth = 3 * markSize / 24

    private var shapes: [CAShapeLayer] = []
    // The marks that show now.
    private(set) var shown: [SnapMark] = []
    private var metrics = CanvasMetrics(interfaceScale: 100)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.isGeometryFlipped = true
        layer = root
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    // The marks are hidden from accessibility (aria-hidden).
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    // The frames of the arrows that show, in points.
    var arrowFrames: [CGRect] { shapes.prefix(shown.count).map(\.frame) }

    // Show the marks in an area of the bounds (layout units) at the scale.
    func show(_ marks: [SnapMark], bounds: LayoutSize, metrics: CanvasMetrics) {
        guard marks != shown || metrics != self.metrics else { return }
        shown = marks
        self.metrics = metrics
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while shapes.count < marks.count {
            let shape = CAShapeLayer()
            shape.strokeColor = ThemeTokens.snap.cgColor
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            layer?.addSublayer(shape)
            shapes.append(shape)
        }
        for (index, shape) in shapes.enumerated() {
            guard index < marks.count else {
                shape.isHidden = true
                continue
            }
            let mark = marks[index]
            let size = Self.markSize
            let x = Self.start(mark.x, area: bounds.w)
            let y = Self.start(mark.y, area: bounds.h)
            shape.isHidden = false
            shape.frame = metrics.points(LayoutRect(x: x, y: y, w: size, h: size))
            shape.lineWidth = metrics.points(Self.lineWidth)
            shape.path = Self.arrow(mark.direction, scale: metrics.scale)
        }
        CATransaction.commit()
    }

    // The left or top of an arrow: centred on the mark point, and inside the area (markStart).
    private static func start(_ at: Double, area: Double) -> Double {
        min(max(at - markSize / 2, 0), area - markSize)
    }

    // The chevron of lucide for the direction, in its box of 24, drawn in a box of 10 units.
    private static func arrow(_ direction: SnapMark.Direction, scale: Double) -> CGPath {
        let points: [(Double, Double)] =
            switch direction {
            case .left: [(15, 18), (9, 12), (15, 6)]
            case .right: [(9, 18), (15, 12), (9, 6)]
            case .up: [(18, 15), (12, 9), (6, 15)]
            case .down: [(6, 9), (12, 15), (18, 9)]
            }
        let factor = markSize / 24 * scale
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.0 * factor, y: $0.1 * factor) })
        return path
    }
}
