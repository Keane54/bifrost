import BifrostLayout
import BifrostTestSupport
import Testing

// The overlap of frames (docs/behaviour/windows.md, "Dragging, snapping and stacking").

// A frame in the z-order list. The first frame is at the bottom.
private func frame(_ number: Int, _ r: LayoutRect, minimised: Bool = false) -> LayoutFrame {
    LayoutFrame(
        id: frameID(number), panels: [panel("overview:1")], active: panel("overview:1"), rect: r,
        minimised: minimised, locked: false)
}

private let a = rect(h: 200, w: 300, x: 0, y: 0)
// To the right of A, with a gap.
private let apart = rect(h: 200, w: 300, x: 400, y: 0)
// To the right of A, with the left edge on the right edge of A (a snap).
private let touch = rect(h: 200, w: 300, x: 300, y: 0)
// Over the bottom-right corner of A.
private let over = rect(h: 200, w: 300, x: 200, y: 100)

private func with(_ r: LayoutRect, x: Double? = nil, y: Double? = nil) -> LayoutRect {
    LayoutRect(x: x ?? r.x, y: y ?? r.y, w: r.w, h: r.h)
}

@Suite("overlapping rects")
struct RectsOverlapTests {
    @Test
    func shareAnArea() {
        #expect(rectsOverlap(a, over))
        #expect(rectsOverlap(over, a))
    }

    @Test("an overlap of 1 pixel counts")
    func onePixel() {
        #expect(rectsOverlap(a, with(touch, x: 299)))
        #expect(rectsOverlap(a, with(a, y: 199)))
    }

    @Test("a rect inside another counts as overlap")
    func inside() {
        #expect(rectsOverlap(a, rect(h: 10, w: 10, x: 50, y: 50)))
    }

    @Test("rects that only touch do not overlap")
    func touchOnly() {
        #expect(!rectsOverlap(a, touch))
        #expect(!rectsOverlap(a, with(a, y: 200)))
        #expect(!rectsOverlap(a, with(a, x: 300, y: 200)))
    }

    @Test("rects with a gap do not overlap")
    func gap() {
        #expect(!rectsOverlap(a, apart))
    }
}

// User decision, 2026-11-10: a frame keeps its backdrop blur only while it overlaps a lower frame
// that shows. A frame over the background only has no blur.
@Suite("which frames blur")
struct BlurredFramesTests {
    @Test("one visible frame is not blurred")
    func oneFrame() {
        #expect(blurredFrames([frame(1, a)]).isEmpty)
    }

    @Test("frames that do not overlap are not blurred")
    func noOverlap() {
        #expect(blurredFrames([frame(1, a), frame(2, apart)]).isEmpty)
    }

    @Test
    func touchAtAnEdge() {
        #expect(blurredFrames([frame(1, a), frame(2, touch)]).isEmpty)
    }

    @Test("the upper of two overlapping frames blurs and the lower does not")
    func upperFrame() {
        #expect(blurredFrames([frame(1, a), frame(2, over)]) == [frameID(2)])
        // The z-order and not the ID sets which frame is upper.
        #expect(blurredFrames([frame(2, over), frame(1, a)]) == [frameID(1)])
    }

    @Test
    func minimisedLowerFrame() {
        #expect(blurredFrames([frame(1, a, minimised: true), frame(2, over)]).isEmpty)
    }

    @Test("a minimised frame is not blurred")
    func minimisedFrame() {
        #expect(blurredFrames([frame(1, a), frame(2, over, minimised: true)]).isEmpty)
    }

    @Test
    func eachLowerFrame() {
        let frames = [frame(1, a), frame(2, apart), frame(3, with(over, x: 100))]
        #expect(blurredFrames(frames) == [frameID(3)])
    }

    @Test
    func notForAFrameAbove() {
        let frames = [frame(1, a), frame(2, apart), frame(3, with(apart, y: 100))]
        #expect(blurredFrames(frames) == [frameID(3)])
    }

    @Test("a frame uses its live rect during a drag")
    func liveRect() {
        let frames = [frame(1, a), frame(2, apart)]
        // The drag moves f2 over f1.
        let moved = LiveRect(frame: frameID(2), rect: over)
        #expect(blurredFrames(frames, live: moved) == [frameID(2)])
        // The drag moves f2 away from f1.
        let overlapping = [frame(1, a), frame(2, over)]
        #expect(
            blurredFrames(overlapping, live: LiveRect(frame: frameID(2), rect: apart)).isEmpty)
    }

    @Test
    func liveRectOfALowerFrame() {
        let frames = [frame(1, apart), frame(2, a)]
        let moved = LiveRect(frame: frameID(1), rect: over)
        #expect(blurredFrames(frames, live: moved) == [frameID(2)])
    }

    @Test
    func liveRectOfAnUnknownFrame() {
        let frames = [frame(1, a), frame(2, apart)]
        #expect(blurredFrames(frames, live: LiveRect(frame: frameID(9), rect: over)).isEmpty)
        #expect(blurredFrames(frames, live: nil).isEmpty)
    }
}
