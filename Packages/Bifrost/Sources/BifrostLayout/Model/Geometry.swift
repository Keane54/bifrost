// The geometry of the frames on the canvas. The values are layout units: one unit is
// interfaceScale / 100 points. ui-state.json keeps the rects in these units, as the files of the
// Electron app do. Each result of a rule is a whole number: rounded() gives the nearest one, and
// a half goes away from zero.
//
// The rules get finite values. The layout refuses a rect or a size that is not finite where it
// comes in (WindowLayout, the load of a file), and a pointer delta that is not finite counts as
// 0. So the rules use Swift.min and Swift.max with no NaN case.

public struct LayoutRect: Codable, Sendable, Equatable {
    public var x, y, w, h: Double

    package init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    // True when the four values are finite.
    package var isFinite: Bool { x.isFinite && y.isFinite && w.isFinite && h.isFinite }
}

public struct LayoutSize: Sendable, Equatable {
    package var w, h: Double

    public init(w: Double, h: Double) {
        self.w = w
        self.h = h
    }
}

package struct LayoutPoint: Sendable, Equatable {
    package var x, y: Double

    package init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

// The edge or the corner of a frame that a resize moves.
package enum FrameEdge: Sendable {
    case n, s, e, w, ne, nw, se, sw

    // The sides of a frame.
    struct Sides: OptionSet {
        let rawValue: Int
        static let left = Sides(rawValue: 1 << 0)
        static let right = Sides(rawValue: 1 << 1)
        static let top = Sides(rawValue: 1 << 2)
        static let bottom = Sides(rawValue: 1 << 3)
    }

    // The sides that the resize moves.
    var sides: Sides {
        switch self {
        case .n: .top
        case .s: .bottom
        case .e: .right
        case .w: .left
        case .ne: [.top, .right]
        case .nw: [.top, .left]
        case .se: [.bottom, .right]
        case .sw: [.bottom, .left]
        }
    }
}

// An arrow mark for one snap: a point on the snap line, and the direction in which the snap moves
// the frame edge.
package struct SnapMark: Sendable, Equatable {
    package enum Direction: String, Sendable { case left, right, up, down }
    package var x: Double
    package var y: Double
    package var direction: Direction

    package init(x: Double, y: Double, direction: Direction) {
        self.x = x
        self.y = y
        self.direction = direction
    }
}

package enum Geometry {
    package static let snapDistance = 8.0, titleHeight = 28.0, cornerGap = 8.0
    package static let minSize = LayoutSize(w: 200, h: 120)

    private enum Axis { case x, y }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }

    // A pointer delta that is not a finite number counts as 0.
    private static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }

    private static func roundRect(_ r: LayoutRect) -> LayoutRect {
        LayoutRect(x: r.x.rounded(), y: r.y.rounded(), w: r.w.rounded(), h: r.h.rounded())
    }

    // Two ranges overlap when they touch or come within snap units.
    private static func overlaps(
        _ aStart: Double, _ aLength: Double, _ bStart: Double, _ bLength: Double, _ snap: Double
    ) -> Bool {
        bStart <= aStart + aLength + snap && aStart <= bStart + bLength + snap
    }

    // The lines on one axis: the bounds first, then the edges of each other rect that overlaps
    // the moving rect on the other axis.
    private static func snapLines(
        _ axis: Axis, _ r: LayoutRect, _ others: [LayoutRect], _ bounds: LayoutSize,
        _ snap: Double
    ) -> [Double] {
        var lines = [0, axis == .x ? bounds.w : bounds.h]
        for o in others {
            let near =
                axis == .x
                ? overlaps(r.y, r.h, o.y, o.h, snap) : overlaps(r.x, r.w, o.x, o.w, snap)
            if !near { continue }
            if axis == .x { lines += [o.x, o.x + o.w] } else { lines += [o.y, o.y + o.h] }
        }
        return lines
    }

    // The closest line for the edge positions. The first edge wins an equal distance. The first
    // line wins an equal distance.
    private static func closest(_ edges: [Double], _ lines: [Double], _ snap: Double)
        -> (edge: Int, line: Double)?
    {
        var best: (edge: Int, line: Double, distance: Double)?
        for (edge, value) in edges.enumerated() {
            for line in lines {
                let distance = abs(value - line)
                guard distance <= snap else { continue }
                if let current = best, distance >= current.distance { continue }
                best = (edge, line, distance)
            }
        }
        return best.map { ($0.edge, $0.line) }
    }

    // The rect in whole units inside the bounds, and at least the minimum size when the bounds
    // allow it. The size rounds first, and it stays in the whole units of the bounds. Then the
    // place rounds and moves into the room that the whole size leaves. So the rect never passes
    // the bounds, also with half units (row W16).
    package static func clampRect(
        _ r: LayoutRect, bounds: LayoutSize, min: LayoutSize = minSize
    ) -> LayoutRect {
        let width = bounds.w.rounded(.down)
        let height = bounds.h.rounded(.down)
        let w = Swift.min(width, max(r.w, min.w).rounded())
        let h = Swift.min(height, max(r.h, min.h).rounded())
        let x = clamp(r.x.rounded(), 0, width - w)
        let y = clamp(r.y.rounded(), 0, height - h)
        return LayoutRect(x: x, y: y, w: w, h: h)
    }

    // The rect that the screen shows for a saved rect in the current area. The saved rect does
    // not change. So a frame goes back to its saved rect when the area grows again.
    package static func shownRect(_ r: LayoutRect, bounds: LayoutSize) -> LayoutRect {
        clampRect(r, bounds: bounds, min: minSize)
    }

    package static func centreRect(_ size: LayoutSize, bounds: LayoutSize) -> LayoutRect {
        roundRect(
            LayoutRect(
                x: (bounds.w - size.w) / 2, y: (bounds.h - size.h) / 2, w: size.w, h: size.h))
    }

    package static func moveRect(
        _ start: LayoutRect, dx: Double, dy: Double, others: [LayoutRect], bounds: LayoutSize,
        snap: Double = snapDistance
    ) -> LayoutRect {
        let raw = LayoutRect(
            x: start.x + finite(dx), y: start.y + finite(dy), w: start.w, h: start.h)
        var x = raw.x
        var y = raw.y
        let xLines = snapLines(.x, raw, others, bounds, snap)
        if let hit = closest([raw.x, raw.x + raw.w], xLines, snap) {
            x = hit.edge == 0 ? hit.line : hit.line - raw.w
        }
        let yLines = snapLines(.y, raw, others, bounds, snap)
        if let hit = closest([raw.y, raw.y + raw.h], yLines, snap) {
            y = hit.edge == 0 ? hit.line : hit.line - raw.h
        }
        return roundRect(
            LayoutRect(
                x: clamp(x, 0, max(0, bounds.w - raw.w)),
                y: clamp(y, 0, max(0, bounds.h - raw.h)), w: raw.w, h: raw.h))
    }

    package static func resizeRect(
        _ start: LayoutRect, edge: FrameEdge, dx: Double, dy: Double, others: [LayoutRect],
        bounds: LayoutSize, snap: Double = snapDistance, min: LayoutSize = minSize
    ) -> LayoutRect {
        var left = start.x
        var right = start.x + start.w
        var top = start.y
        var bottom = start.y + start.h
        let sides = edge.sides
        if sides.contains(.left) { left += finite(dx) }
        if sides.contains(.right) { right += finite(dx) }
        if sides.contains(.top) { top += finite(dy) }
        if sides.contains(.bottom) { bottom += finite(dy) }
        // Round the four edges first. Then w and h come from whole edges, so a fixed edge never
        // moves.
        left.round()
        right.round()
        top.round()
        bottom.round()

        // The moved rect. It finds the other rects that overlap it.
        let raw = LayoutRect(
            x: Swift.min(left, right), y: Swift.min(top, bottom), w: abs(right - left),
            h: abs(bottom - top))
        let xLines = snapLines(.x, raw, others, bounds, snap)
        let yLines = snapLines(.y, raw, others, bounds, snap)

        // Snap one moving edge, then apply the limits. For a start rect closer than min to the
        // bounds, the low limit wins over the high limit: the minimum size holds and the edge can
        // pass the bounds. The input is a clamped rect, so this does not occur in normal use.
        func place(_ value: Double, _ lines: [Double], _ low: Double, _ high: Double) -> Double {
            clamp(closest([value], lines, snap)?.line ?? value, low, max(low, high))
        }
        if sides.contains(.left) { left = place(left, xLines, 0, right - min.w) }
        if sides.contains(.right) { right = place(right, xLines, left + min.w, bounds.w) }
        if sides.contains(.top) { top = place(top, yLines, 0, bottom - min.h) }
        if sides.contains(.bottom) { bottom = place(bottom, yLines, top + min.h, bounds.h) }

        return LayoutRect(
            x: left.rounded(), y: top.rounded(), w: right.rounded() - left.rounded(),
            h: bottom.rounded() - top.rounded())
    }

    // The start and the end of a rect on one axis.
    private static func extent(_ r: LayoutRect, _ axis: Axis) -> (start: Double, end: Double) {
        axis == .x ? (r.x, r.x + r.w) : (r.y, r.y + r.h)
    }

    // True when the two rects overlap on the axis, or come within snapDistance on it.
    private static func near(_ a: LayoutRect, _ b: LayoutRect, _ axis: Axis) -> Bool {
        let (aStart, aEnd) = extent(a, axis)
        let (bStart, bEnd) = extent(b, axis)
        return overlaps(aStart, aEnd - aStart, bStart, bEnd - bStart, snapDistance)
    }

    // The mark for one axis, or nil when no edge snaps on that axis. An edge snaps when the
    // snapped rect puts it on a line and the raw rect does not. The start edge comes first. A
    // window edge comes before the edge of another frame.
    private static func axisMark(
        _ axis: Axis, _ raw: LayoutRect, _ snapped: LayoutRect, _ others: [LayoutRect],
        _ bounds: LayoutSize
    ) -> SnapMark? {
        let cross: Axis = axis == .x ? .y : .x
        let rawEdges = extent(raw, axis)
        let snappedEdges = extent(snapped, axis)
        let (low, high) = extent(snapped, cross)
        let limit = axis == .x ? bounds.w : bounds.h
        let pairs = [(rawEdges.start, snappedEdges.start), (rawEdges.end, snappedEdges.end)]
        for (from, line) in pairs where line != from {
            var along: Double?
            if line == 0 || line == limit {
                // For a window edge, the mark is at the middle of the frame edge.
                along = (low + high) / 2
            } else if let other = others.first(where: { o in
                let edges = extent(o, axis)
                return (edges.start.rounded() == line || edges.end.rounded() == line)
                    && near(raw, o, cross)
            }) {
                // For another frame, the mark is at the middle of the overlap of the two edges.
                // If the two edges have a gap, the mark is at the middle of the gap. The snap
                // found that frame from the raw rect, so this search uses the raw rect too. The
                // overlap uses the snapped rect.
                let (otherLow, otherHigh) = extent(other, cross)
                along = (max(low, otherLow) + min(high, otherHigh)) / 2
            }
            guard let along else { continue }
            let at = along.rounded()
            let forward = line > from
            if axis == .x { return SnapMark(x: line, y: at, direction: forward ? .right : .left) }
            return SnapMark(x: at, y: line, direction: forward ? .down : .up)
        }
        return nil
    }

    // The arrow marks of the snap that a release applies. The raw rect follows the pointer with
    // no snap. The snapped rect is the same drag with the snap. Each axis that snaps gives one
    // mark. The x mark comes first. Two marks less than cornerGap apart on both axes are at one
    // corner, and their arrows would cover each other. Then each mark moves cornerGap along its
    // own frame edge, to the middle of that edge.
    package static func snapMarks(
        raw: LayoutRect, snapped: LayoutRect, others: [LayoutRect], bounds: LayoutSize
    ) -> [SnapMark] {
        var x = axisMark(.x, raw, snapped, others, bounds)
        var y = axisMark(.y, raw, snapped, others, bounds)
        if var xMark = x, var yMark = y, abs(xMark.x - yMark.x) < cornerGap,
            abs(xMark.y - yMark.y) < cornerGap
        {
            xMark.y += xMark.y < snapped.y + snapped.h / 2 ? cornerGap : -cornerGap
            yMark.x += yMark.x < snapped.x + snapped.w / 2 ? cornerGap : -cornerGap
            x = xMark
            y = yMark
        }
        return [x, y].compactMap { $0 }
    }

    package static func contains(_ r: LayoutRect, _ p: LayoutPoint) -> Bool {
        p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
    }

    package static func titleBar(_ r: LayoutRect) -> LayoutRect {
        LayoutRect(x: r.x, y: r.y, w: r.w, h: min(titleHeight, r.h))
    }
}
