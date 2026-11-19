import BifrostLayout
import BifrostTestSupport
import Testing

// The hit test of the frames and the snap targets (docs/behaviour/windows.md).

private func frame(_ number: Int, _ r: LayoutRect, minimised: Bool = false) -> LayoutFrame {
    LayoutFrame(
        id: frameID(number), panels: [panel("overview:1")], active: panel("overview:1"), rect: r,
        minimised: minimised, locked: false)
}

private func minimised(_ value: LayoutFrame) -> LayoutFrame {
    var copy = value
    copy.minimised = true
    return copy
}

private func moved(_ value: LayoutFrame, to r: LayoutRect) -> LayoutFrame {
    var copy = value
    copy.rect = r
    return copy
}

// In z-order: f1 at the bottom, f3 on top. All three cover the point (150, 150).
private let low = frame(1, rect(h: 300, w: 300, x: 0, y: 0))
private let mid = frame(2, rect(h: 300, w: 300, x: 100, y: 100))
private let high = frame(3, rect(h: 300, w: 300, x: 120, y: 120))

// The title bar of a frame at x 100, y 50. Its edges are x 100 and 400, y 50 and 78.
private let bar = rect(h: 28, w: 300, x: 100, y: 50)

@Suite("what the pointer hits")
struct HitTests {
    @Test
    func frameAtTheTop() {
        let p = point(x: 150, y: 150)
        #expect(Hit.frameAt([low, mid, high], p)?.id == frameID(3))
        #expect(Hit.frameAt([low, mid], p)?.id == frameID(2))
        #expect(Hit.frameAt([low, mid, minimised(high)], p)?.id == frameID(2))
        #expect(Hit.frameAt([low, mid, high], point(x: 50, y: 50))?.id == frameID(1))
        #expect(Hit.frameAt([low, mid, high], point(x: 500, y: 500)) == nil)
        #expect(Hit.frameAt([minimised(low)], point(x: 50, y: 50)) == nil)
    }

    @Test
    func frameAtSkipsTheExcluded() {
        let p = point(x: 150, y: 150)
        #expect(Hit.frameAt([low, mid, high], p, excluding: frameID(3))?.id == frameID(2))
        #expect(Hit.frameAt([low, mid, high], p, excluding: frameID(2))?.id == frameID(3))
        #expect(Hit.frameAt([low], point(x: 50, y: 50), excluding: frameID(1)) == nil)
    }

    @Test
    func titleBarAtTheBar() {
        let target = frame(1, rect(h: 300, w: 300, x: 0, y: 0))
        let dragged = frame(2, rect(h: 200, w: 200, x: 10, y: 5))
        // The dragged frame is on top and covers the point, but it does not count.
        let p = point(x: 20, y: 10)
        #expect(Hit.titleBarAt([target, dragged], p, excluding: frameID(2))?.id == frameID(1))
        // The last row of the title bar (TITLE_H = 28) has the point. The next row does not.
        #expect(
            Hit.titleBarAt([target, dragged], point(x: 20, y: 27), excluding: frameID(2))?.id
                == frameID(1))
        #expect(
            Hit.titleBarAt([target, dragged], point(x: 20, y: 28), excluding: frameID(2)) == nil)
        // A minimised frame has no title bar on the screen.
        #expect(Hit.titleBarAt([minimised(target), dragged], p, excluding: frameID(2)) == nil)
    }

    @Test
    func titleBarAtCovered() {
        let target = frame(1, rect(h: 300, w: 300, x: 0, y: 0))
        let cover = frame(2, rect(h: 200, w: 200, x: 0, y: 0))
        let dragged = frame(3, rect(h: 200, w: 200, x: 400, y: 400))
        let p = point(x: 20, y: 10)
        // The point is in the title bar of f2, which is above f1. So f2 is the result.
        #expect(
            Hit.titleBarAt([target, cover, dragged], p, excluding: frameID(3))?.id == frameID(2))
        // The point is in the title bar of f1, but the body of f2 covers it.
        let lower = moved(cover, to: rect(h: 200, w: 200, x: 0, y: -100))
        #expect(Hit.titleBarAt([target, lower, dragged], p, excluding: frameID(3)) == nil)
        // The same frames in the other z-order: f1 is on top, so its title bar has the point.
        #expect(
            Hit.titleBarAt([lower, target, dragged], p, excluding: frameID(3))?.id == frameID(1))
    }

    @Test
    func notMovedToStack() {
        #expect(Hit.stackDistance == 4)
        let start = point(x: 200, y: 100)
        #expect(!Hit.movedToStack(from: start, to: start))
        #expect(!Hit.movedToStack(from: start, to: point(x: 201, y: 100)))
        #expect(!Hit.movedToStack(from: start, to: point(x: 197, y: 100)))
        #expect(!Hit.movedToStack(from: start, to: point(x: 202, y: 102)))
    }

    @Test
    func movedToStack() {
        let start = point(x: 200, y: 100)
        #expect(Hit.movedToStack(from: start, to: point(x: 204, y: 100)))
        #expect(Hit.movedToStack(from: start, to: point(x: 200, y: 96)))
        #expect(Hit.movedToStack(from: start, to: point(x: 197, y: 97)))
        #expect(Hit.movedToStack(from: start, to: point(x: 900, y: 600)))
    }

    @Test
    func tearOutWithTheSavedSize() {
        let area = size(h: 800, w: 1200)
        let stack = rect(h: 420, w: 800, x: 200, y: 352)
        let p = point(x: 700, y: 150)
        let saved = rect(h: 356, w: 420, x: 900, y: 40)
        #expect(Hit.tearOffset == point(x: 60, y: 14))
        #expect(
            Hit.tearOutRect(at: p, saved: saved, stack: stack, bounds: area)
                == rect(h: 356, w: 420, x: 640, y: 136))
    }

    @Test
    func tearOutWithTheStackSize() {
        let area = size(h: 800, w: 1200)
        let stack = rect(h: 420, w: 800, x: 200, y: 352)
        #expect(
            Hit.tearOutRect(at: point(x: 700, y: 150), saved: nil, stack: stack, bounds: area)
                == rect(h: 420, w: 800, x: 640, y: 136))
    }

    @Test
    func tearOutFitsTheArea() {
        let area = size(h: 500, w: 800)
        let stack = rect(h: 300, w: 400, x: 0, y: 0)
        let saved = rect(h: 900, w: 1440, x: 0, y: 0)
        let result = Hit.tearOutRect(
            at: point(x: 100, y: 100), saved: saved, stack: stack, bounds: area)
        #expect(size(h: result.h, w: result.w) == size(h: 500, w: 800))
    }

    @Test
    func notTornOut() {
        #expect(Hit.tearDistance == 12)
        #expect(!Hit.tornOut(bar: bar, point(x: 150, y: 60)))
        #expect(!Hit.tornOut(bar: bar, point(x: 100, y: 50)))
        #expect(!Hit.tornOut(bar: bar, point(x: 399, y: 77)))
        // 12 pixels above, below, left and right of the edges.
        #expect(!Hit.tornOut(bar: bar, point(x: 150, y: 38)))
        #expect(!Hit.tornOut(bar: bar, point(x: 150, y: 90)))
        #expect(!Hit.tornOut(bar: bar, point(x: 88, y: 60)))
        #expect(!Hit.tornOut(bar: bar, point(x: 412, y: 60)))
        // 12 pixels from two edges at the same time.
        #expect(!Hit.tornOut(bar: bar, point(x: 88, y: 38)))
        #expect(!Hit.tornOut(bar: bar, point(x: 412, y: 90)))
    }

    @Test("a drag out of the title bar starts at 13 pixels in any direction")
    func tornOut() {
        #expect(Hit.tornOut(bar: bar, point(x: 150, y: 37)))
        #expect(Hit.tornOut(bar: bar, point(x: 150, y: 91)))
        #expect(Hit.tornOut(bar: bar, point(x: 87, y: 60)))
        #expect(Hit.tornOut(bar: bar, point(x: 413, y: 60)))
        // Far away on one axis and inside on the other axis.
        #expect(Hit.tornOut(bar: bar, point(x: 250, y: 500)))
        #expect(Hit.tornOut(bar: bar, point(x: -300, y: 60)))
    }
}
