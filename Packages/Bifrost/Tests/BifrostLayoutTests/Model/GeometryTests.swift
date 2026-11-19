import BifrostTestSupport
import Testing

@testable import BifrostLayout

// The geometry of the frames: the rects, the clamp and the snap (docs/behaviour/windows.md).

private let bounds = size(h: 800, w: 1200)

@Suite("moving a rect")
struct MoveRectTests {
    @Test
    func movesByTheDelta() {
        let start = rect(h: 200, w: 300, x: 100, y: 100)
        #expect(
            Geometry.moveRect(start, dx: 10, dy: 5, others: [], bounds: bounds)
                == rect(h: 200, w: 300, x: 110, y: 105))
    }

    @Test("the left edge snaps to the bounds at 8 pixels")
    func snapsAt8() {
        let start = rect(h: 200, w: 300, x: 20, y: 100)
        #expect(Geometry.moveRect(start, dx: -12, dy: 0, others: [], bounds: bounds).x == 0)
    }

    @Test
    func doesNotSnapAt9() {
        let start = rect(h: 200, w: 300, x: 21, y: 100)
        #expect(Geometry.moveRect(start, dx: -12, dy: 0, others: [], bounds: bounds).x == 9)
    }

    @Test
    func snapsTheRightEdge() {
        let start = rect(h: 200, w: 300, x: 895, y: 100)
        #expect(Geometry.moveRect(start, dx: 0, dy: 0, others: [], bounds: bounds).x == 900)
    }

    @Test
    func snapsToAnotherRect() {
        let other = rect(h: 300, w: 400, x: 0, y: 100)
        let start = rect(h: 200, w: 300, x: 405, y: 150)
        #expect(Geometry.moveRect(start, dx: 0, dy: 0, others: [other], bounds: bounds).x == 400)
    }

    @Test
    func noSnapWithoutAnOverlap() {
        let other = rect(h: 100, w: 400, x: 0, y: 600)
        let start = rect(h: 200, w: 300, x: 405, y: 100)
        #expect(Geometry.moveRect(start, dx: 0, dy: 0, others: [other], bounds: bounds).x == 405)
    }

    @Test
    func alignsLeftEdges() {
        let other = rect(h: 200, w: 200, x: 300, y: 400)
        let start = rect(h: 250, w: 300, x: 306, y: 150)
        #expect(Geometry.moveRect(start, dx: 0, dy: 0, others: [other], bounds: bounds).x == 300)
    }

    @Test
    func prefersTheBounds() {
        // The left edge is 4 from the bounds line at 0 and 4 from the other right edge at 8.
        let other = rect(h: 200, w: 8, x: 0, y: 100)
        let start = rect(h: 200, w: 300, x: 4, y: 150)
        #expect(Geometry.moveRect(start, dx: 0, dy: 0, others: [other], bounds: bounds).x == 0)
    }

    @Test
    func prefersTheLeftEdge() {
        let start = rect(h: 200, w: 1192, x: 4, y: 100)
        #expect(Geometry.moveRect(start, dx: 0, dy: 0, others: [], bounds: bounds).x == 0)
    }

    @Test
    func snapsTheTopEdge() {
        let start = rect(h: 200, w: 300, x: 100, y: 20)
        #expect(Geometry.moveRect(start, dx: 0, dy: -12, others: [], bounds: bounds).y == 0)
    }

    @Test
    func rawWithASnapOf0() {
        let start = rect(h: 200, w: 300, x: 20, y: 100)
        #expect(
            Geometry.moveRect(start, dx: -12, dy: 0, others: [], bounds: bounds, snap: 0).x == 8)
    }

    @Test
    func clampsInsideTheBounds() {
        let start = rect(h: 200, w: 300, x: 100, y: 100)
        let result = Geometry.moveRect(start, dx: 5000, dy: 5000, others: [], bounds: bounds)
        #expect(result.x == bounds.w - 300)
        #expect(result.y == bounds.h - 200)
    }
}

@Suite("resizing a rect")
struct ResizeRectTests {
    private let start = rect(h: 200, w: 300, x: 100, y: 100)

    @Test("the south-east corner snaps the right and bottom edges")
    func seSnaps() {
        let result = Geometry.resizeRect(
            start, edge: .se, dx: 797, dy: 497, others: [], bounds: bounds)
        #expect(result == rect(h: 700, w: 1100, x: 100, y: 100))
    }

    @Test
    func rawWithASnapOf0() {
        let result = Geometry.resizeRect(
            start, edge: .se, dx: 797, dy: 497, others: [], bounds: bounds, snap: 0)
        #expect(result == rect(h: 697, w: 1097, x: 100, y: 100))
    }

    // A pointer step of 10 right and 10 down moves only the sides of the edge or the corner.
    @Test(
        "each edge and corner moves only its own sides",
        arguments: [
            (FrameEdge.n, rect(h: 190, w: 300, x: 100, y: 110)),
            (.s, rect(h: 210, w: 300, x: 100, y: 100)),
            (.e, rect(h: 200, w: 310, x: 100, y: 100)),
            (.w, rect(h: 200, w: 290, x: 110, y: 100)),
            (.ne, rect(h: 190, w: 310, x: 100, y: 110)),
            (.nw, rect(h: 190, w: 290, x: 110, y: 110)),
            (.se, rect(h: 210, w: 310, x: 100, y: 100)),
            (.sw, rect(h: 210, w: 290, x: 110, y: 100)),
        ])
    func eachEdgeMovesItsSides(edge: FrameEdge, result: LayoutRect) {
        #expect(
            Geometry.resizeRect(start, edge: edge, dx: 10, dy: 10, others: [], bounds: bounds)
                == result)
    }

    @Test
    func keepsTheMinimumSize() {
        let result = Geometry.resizeRect(
            start, edge: .se, dx: -1000, dy: -1000, others: [], bounds: bounds)
        #expect(result == rect(h: 120, w: 200, x: 100, y: 100))
    }

    @Test
    func nwKeepsTheFixedEdges() {
        let result = Geometry.resizeRect(
            start, edge: .nw, dx: 500, dy: 500, others: [], bounds: bounds)
        #expect(result == rect(h: 120, w: 200, x: 200, y: 180))
    }

    @Test
    func stopsAnEdge() {
        let result = Geometry.resizeRect(
            start, edge: .e, dx: 5000, dy: 0, others: [], bounds: bounds)
        #expect(result.x + result.w == bounds.w)
        #expect(result.y == 100)
        #expect(result.h == 200)
    }

    @Test
    func stopsTheLeftEdge() {
        let result = Geometry.resizeRect(
            start, edge: .w, dx: -5000, dy: 0, others: [], bounds: bounds)
        #expect(result == rect(h: 200, w: 400, x: 0, y: 100))
    }

    @Test
    func snapsAMovingEdge() {
        let other = rect(h: 200, w: 200, x: 600, y: 100)
        let result = Geometry.resizeRect(
            start, edge: .e, dx: 195, dy: 0, others: [other], bounds: bounds)
        #expect(result.w == 500)
    }

    @Test
    func minimumOverASnapLine() {
        // The raw right edge is 300, 5 from the other left edge at 295. The minimum stops it at
        // 300.
        let other = rect(h: 200, w: 200, x: 295, y: 100)
        let result = Geometry.resizeRect(
            start, edge: .e, dx: -100, dy: 0, others: [other], bounds: bounds)
        #expect(result.w == 200)
    }
}

@Suite("the edge cases of a move or a resize")
struct MoveResizeEdgeTests {
    private let start = rect(h: 200, w: 300, x: 100, y: 100)

    @Test("a fractional delta keeps the fixed edges")
    func fractionalDelta() {
        let w = Geometry.resizeRect(start, edge: .w, dx: 0.5, dy: 0, others: [], bounds: bounds)
        #expect(w.x + w.w == 400)
        let n = Geometry.resizeRect(start, edge: .n, dx: 0, dy: 0.5, others: [], bounds: bounds)
        #expect(n.y + n.h == 300)
        let nw = Geometry.resizeRect(
            start, edge: .nw, dx: 0.5, dy: 0.5, others: [], bounds: bounds)
        #expect(nw.x + nw.w == 400)
        #expect(nw.y + nw.h == 300)
    }

    @Test
    func clampAfterASnap() {
        // The right edge snaps to the other left edge at 1207. The clamp then moves it to 1200.
        let other = rect(h: 200, w: 100, x: 1207, y: 100)
        let wide = rect(h: 200, w: 300, x: 910, y: 100)
        #expect(Geometry.moveRect(wide, dx: 0, dy: 0, others: [other], bounds: bounds).x == 900)
    }

    @Test
    func nonFiniteDelta() {
        #expect(
            Geometry.moveRect(start, dx: .nan, dy: .infinity, others: [], bounds: bounds)
                == start)
        #expect(
            Geometry.resizeRect(
                start, edge: .se, dx: .nan, dy: -.infinity, others: [], bounds: bounds) == start)
    }

    @Test
    func snapsTheYAxis() {
        let other = rect(h: 100, w: 200, x: 100, y: 600)
        let result = Geometry.resizeRect(
            start, edge: .s, dx: 0, dy: 297, others: [other], bounds: bounds)
        #expect(result.h == 500)
    }

    @Test
    func nwSnapsBothEdges() {
        let other = rect(h: 100, w: 50, x: 40, y: 40)
        let result = Geometry.resizeRect(
            start, edge: .nw, dx: -56, dy: -56, others: [other], bounds: bounds)
        #expect(result == rect(h: 260, w: 360, x: 40, y: 40))
    }

    @Test
    func neSnapsBothEdges() {
        let other = rect(h: 100, w: 100, x: 500, y: 40)
        let result = Geometry.resizeRect(
            start, edge: .ne, dx: 97, dy: -57, others: [other], bounds: bounds)
        #expect(result == rect(h: 260, w: 400, x: 100, y: 40))
    }

    @Test
    func snapsAtExactlySnapPixels() {
        // The moved rect ends at y 300. The other starts at y 308, exactly 8 away.
        // The left edge goes to 403, 2 from the other left edge at 405.
        let other = rect(h: 100, w: 100, x: 405, y: 308)
        let base = rect(h: 200, w: 300, x: 100, y: 100)
        let result = Geometry.moveRect(base, dx: 303, dy: 0, others: [other], bounds: bounds)
        #expect(result.x == 405)
        var farther = other
        farther.y = 309
        let far = Geometry.moveRect(base, dx: 303, dy: 0, others: [farther], bounds: bounds)
        #expect(far.x == 403)
    }

    @Test
    func roundsAfterAFractionalSnap() {
        let other = rect(h: 200, w: 100.4, x: 0, y: 100)
        let moved = rect(h: 200, w: 300, x: 105, y: 100)
        #expect(Geometry.moveRect(moved, dx: 0, dy: 0, others: [other], bounds: bounds).x == 100)
    }
}

// The panel follows the pointer with no snap. The snapped rect gives the marks only.
private struct Snap {
    var marks: [SnapMark]
    var raw: LayoutRect
    var snapped: LayoutRect
}

private func move(
    _ start: LayoutRect, _ dx: Double, _ dy: Double, _ others: [LayoutRect] = []
) -> Snap {
    let raw = Geometry.moveRect(start, dx: dx, dy: dy, others: others, bounds: bounds, snap: 0)
    let snapped = Geometry.moveRect(
        start, dx: dx, dy: dy, others: others, bounds: bounds, snap: Geometry.snapDistance)
    let marks = Geometry.snapMarks(raw: raw, snapped: snapped, others: others, bounds: bounds)
    return Snap(marks: marks, raw: raw, snapped: snapped)
}

private func resize(
    _ start: LayoutRect, _ edge: FrameEdge, _ dx: Double, _ dy: Double,
    _ others: [LayoutRect] = []
) -> Snap {
    let raw = Geometry.resizeRect(
        start, edge: edge, dx: dx, dy: dy, others: others, bounds: bounds, snap: 0)
    let snapped = Geometry.resizeRect(
        start, edge: edge, dx: dx, dy: dy, others: others, bounds: bounds,
        snap: Geometry.snapDistance)
    let marks = Geometry.snapMarks(raw: raw, snapped: snapped, others: others, bounds: bounds)
    return Snap(marks: marks, raw: raw, snapped: snapped)
}

private func mark(_ direction: SnapMark.Direction, x: Double, y: Double) -> SnapMark {
    SnapMark(x: x, y: y, direction: direction)
}

@Suite("snap marks")
struct SnapMarksTests {
    @Test
    func snapToAnotherPanel() {
        // The right edge goes to 595, 5 from the other left edge at 600. The y overlap is 200 to
        // 300.
        let other = rect(h: 200, w: 300, x: 600, y: 100)
        let result = move(rect(h: 300, w: 300, x: 100, y: 200), 195, 0, [other])
        #expect(result.raw.x == 295)
        #expect(result.snapped.x == 300)
        #expect(result.marks == [mark(.right, x: 600, y: 250)])
    }

    @Test
    func snapToTheWindowLeftEdge() {
        let result = move(rect(h: 200, w: 300, x: 20, y: 100), -14, 0)
        #expect(result.raw.x == 6)
        #expect(result.snapped.x == 0)
        #expect(result.marks == [mark(.left, x: 0, y: 200)])
    }

    @Test
    func twoMarksForACorner() {
        let result = move(rect(h: 200, w: 300, x: 20, y: 20), -15, -14)
        #expect(result.marks == [mark(.left, x: 0, y: 100), mark(.up, x: 150, y: 0)])
    }

    @Test
    func twoMarksAtOneCorner() {
        // The right edge snaps to 600 and the bottom edge snaps to 305, at the corner of the
        // other. Both marks start at x 600, y 305. Each moves 8 along its edge, to the middle of
        // the edge.
        let other = rect(h: 100, w: 300, x: 600, y: 305)
        let result = move(rect(h: 200, w: 300, x: 100, y: 100), 195, 0, [other])
        #expect(result.snapped == rect(h: 200, w: 300, x: 300, y: 105))
        #expect(result.marks == [mark(.right, x: 600, y: 297), mark(.down, x: 592, y: 305)])
    }

    @Test
    func snapAcrossAGap() {
        // A resize of the right edge only. The bottom edge at 300 stays 4 from the other at 304.
        let other = rect(h: 100, w: 300, x: 600, y: 304)
        let result = resize(rect(h: 200, w: 300, x: 100, y: 100), .e, 195, 0, [other])
        #expect(result.marks == [mark(.right, x: 600, y: 302)])
    }

    @Test
    func noMarkFarFromLines() {
        #expect(move(rect(h: 200, w: 300, x: 100, y: 100), 10, 5).marks == [])
    }

    @Test
    func noMarkOnTheLine() {
        // The release does not change the rect. So no edge snaps.
        #expect(move(rect(h: 200, w: 300, x: 0, y: 100), 0, 50).marks == [])
    }

    @Test
    func pointsInTheDirection() {
        // The left edge goes to 395, 5 past the other right edge at 400. The snap moves it right.
        let other = rect(h: 300, w: 400, x: 0, y: 100)
        let result = move(rect(h: 200, w: 300, x: 500, y: 150), -105, 0, [other])
        #expect(result.marks == [mark(.right, x: 400, y: 250)])
    }

    @Test
    func ySnapToAnotherPanel() {
        // The bottom edge goes to 597, 3 from the other top edge at 600. The x overlap is 100 to
        // 300.
        let other = rect(h: 100, w: 200, x: 100, y: 600)
        let result = resize(rect(h: 200, w: 300, x: 100, y: 100), .s, 0, 297, [other])
        #expect(result.raw.h == 497)
        #expect(result.snapped.h == 500)
        #expect(result.marks == [mark(.down, x: 200, y: 600)])
    }

    @Test
    func twoMarksForACornerResize() {
        let result = resize(rect(h: 200, w: 300, x: 100, y: 100), .se, 797, 497)
        #expect(result.marks == [mark(.right, x: 1200, y: 450), mark(.down, x: 650, y: 800)])
    }

    @Test
    func noMarkAtTheMinimum() {
        // The raw right edge is 300, 5 from the other left edge at 295. The minimum stops it at
        // 300.
        let other = rect(h: 200, w: 200, x: 295, y: 100)
        let result = resize(rect(h: 200, w: 300, x: 100, y: 100), .e, -100, 0, [other])
        #expect(result.snapped.w == 200)
        #expect(result.marks == [])
    }

    @Test
    func noMarkAfterTheClamp() {
        // The right edge snaps to the other left edge at 1207. The clamp then moves it to 1200.
        let other = rect(h: 200, w: 100, x: 1207, y: 100)
        let result = move(rect(h: 200, w: 300, x: 910, y: 100), 0, 0, [other])
        #expect(result.snapped.x == 900)
        #expect(result.marks == [])
    }

    @Test
    func roundsAFractionalEdge() {
        let other = rect(h: 200, w: 100.4, x: 0, y: 100)
        let result = move(rect(h: 200, w: 300, x: 105, y: 100), 0, 0, [other])
        #expect(result.marks == [mark(.left, x: 100, y: 200)])
    }
}

@Suite("clamping a rect")
struct ClampRectTests {
    @Test
    func growsToMin() {
        #expect(
            Geometry.clampRect(rect(h: 10, w: 10, x: 50, y: 50), bounds: bounds)
                == rect(h: 120, w: 200, x: 50, y: 50))
    }

    @Test
    func boundsBelowMin() {
        #expect(
            Geometry.clampRect(rect(h: 100, w: 300, x: 50, y: 50), bounds: size(h: 100, w: 150))
                == rect(h: 100, w: 150, x: 0, y: 0))
    }

    @Test
    func shrinksALargeRect() {
        #expect(
            Geometry.clampRect(rect(h: 1500, w: 2000, x: 0, y: 0), bounds: bounds)
                == rect(h: 800, w: 1200, x: 0, y: 0))
    }

    @Test
    func movesIntoTheBounds() {
        #expect(
            Geometry.clampRect(rect(h: 200, w: 300, x: 1500, y: -50), bounds: bounds)
                == rect(h: 200, w: 300, x: 900, y: 0))
    }

    // A rect with half units never passes the bounds. The size rounds first. Then the place
    // moves into the room that the whole size leaves.
    @Test(
        "a rect with half units stays in the bounds",
        arguments: [
            // y 513.5 + h 286.5 is 800. Each value rounds up, and 514 + 287 would give 801.
            (rect(h: 286.5, w: 300, x: 0, y: 513.5), bounds, rect(h: 287, w: 300, x: 0, y: 513)),
            (rect(h: 200, w: 300.5, x: 899.5, y: 0), bounds, rect(h: 200, w: 301, x: 899, y: 0)),
            // Bounds with a half unit hold only the whole units below them.
            (
                rect(h: 1500, w: 2000, x: 0, y: 0), size(h: 600.5, w: 800.5),
                rect(h: 600, w: 800, x: 0, y: 0)
            ),
            (
                rect(h: 100, w: 300, x: 50, y: 50), size(h: 100.5, w: 150.5),
                rect(h: 100, w: 150, x: 0, y: 0)
            ),
            // Away from the edges, each half rounds up as before.
            (
                rect(h: 200.5, w: 300.5, x: 10.5, y: 20.5), bounds,
                rect(h: 201, w: 301, x: 11, y: 21)
            ),
            (rect(h: 200, w: 300, x: -0.5, y: -0.5), bounds, rect(h: 200, w: 300, x: 0, y: 0)),
        ])
    func halfUnitsStayInTheBounds(input: LayoutRect, area: LayoutSize, expected: LayoutRect) {
        let clamped = Geometry.clampRect(input, bounds: area)
        #expect(clamped == expected)
        #expect(clamped.x + clamped.w <= area.w)
        #expect(clamped.y + clamped.h <= area.h)
    }
}

@Suite("shown rect")
struct ShownRectTests {
    @Test
    func keepsAFittingRect() {
        let r = rect(h: 300, w: 400, x: 700, y: 400)
        #expect(Geometry.shownRect(r, bounds: bounds) == r)
    }

    @Test
    func intoASmallerArea() {
        let area = size(h: 500, w: 800)
        #expect(
            Geometry.shownRect(rect(h: 356, w: 420, x: 1052, y: 526), bounds: area)
                == rect(h: 356, w: 420, x: 380, y: 144))
        #expect(
            Geometry.shownRect(rect(h: 900, w: 1440, x: 0, y: 0), bounds: area)
                == rect(h: 500, w: 800, x: 0, y: 0))
        #expect(
            Geometry.shownRect(rect(h: 10, w: 10, x: 5, y: 5), bounds: area)
                == rect(h: Geometry.minSize.h, w: Geometry.minSize.w, x: 5, y: 5))
    }
}

@Suite("centring a rect")
struct CentreRectTests {
    @Test
    func centresWithWholeNumbers() {
        #expect(
            Geometry.centreRect(size(h: 201, w: 301), bounds: bounds)
                == rect(h: 201, w: 301, x: 450, y: 300))
    }
}

@Suite("title bar hit test")
struct TitleBarAndContainsTests {
    @Test
    func titleBarTop28() {
        #expect(
            Geometry.titleBar(rect(h: 200, w: 300, x: 10, y: 20))
                == rect(h: 28, w: 300, x: 10, y: 20))
    }

    @Test("a rect contains its top-left edge and not its bottom-right edge")
    func containsEdges() {
        let r = rect(h: 50, w: 100, x: 10, y: 20)
        #expect(Geometry.contains(r, point(x: 10, y: 20)))
        #expect(Geometry.contains(r, point(x: 109, y: 69)))
        #expect(!Geometry.contains(r, point(x: 110, y: 40)))
        #expect(!Geometry.contains(r, point(x: 50, y: 70)))
    }
}

// Each rule gives whole numbers with rounded(): a half goes away from zero (row W17). A negative
// half comes only in a step before a clamp, for example the centre of a size that is larger than
// the area. The clamp of the layout then moves the rect to 0.
@Suite("the rounding of the rects")
struct RoundingTests {
    @Test func rectsRoundAHalfAwayFromZero() {
        #expect(
            Geometry.clampRect(rect(h: 200.5, w: 300.5, x: 10.5, y: 20.5), bounds: bounds)
                == rect(h: 201, w: 301, x: 11, y: 21))
        #expect(
            Geometry.centreRect(size(h: 201, w: 301), bounds: size(h: 800, w: 1200))
                == rect(h: 201, w: 301, x: 450, y: 300))
        #expect(
            Geometry.centreRect(size(h: 801, w: 1201), bounds: size(h: 800, w: 1200))
                == rect(h: 801, w: 1201, x: -1, y: -1))
        let start = rect(h: 200, w: 300, x: 100, y: 100)
        #expect(
            Geometry.moveRect(start, dx: -0.5, dy: 0.5, others: [], bounds: bounds, snap: 0)
                == rect(h: 200, w: 300, x: 100, y: 101))
    }
}
