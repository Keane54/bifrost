import BifrostLayout
import BifrostTestSupport
import Testing

// The drag rules of a frame (docs/behaviour/windows.md, "Dragging, snapping and stacking").

private let bounds = size(h: 800, w: 1200)

private func run(
    _ actions: [WindowAction], from start: WindowLayout = WindowLayout(bounds: bounds)
) -> WindowLayout {
    var layout = start
    for action in actions { layout.apply(action) }
    return layout
}

private func view(
    _ frame: Int, live: LayoutRect? = nil, marks: [SnapMark] = [], target: Int? = nil
) -> DragView {
    DragView(frame: frameID(frame), live: live, marks: marks, dropTarget: target.map(frameID))
}

// One frame f1 (Settings) at x 20, y 100, w 300, h 200.
private func oneFrame() -> WindowLayout {
    run([.open(panel("settings")), .setRect(frameID(1), rect(h: 200, w: 300, x: 20, y: 100))])
}

// f1 holds the tabs overview:1 and overview:2 at x 220, y 220, w 760, h 360. Its title bar is
// y 220 to 248. The memory has the rect of overview:2 before the stack: x 244, y 244.
private func stackOfTwo() -> WindowLayout {
    run([
        .open(panel("overview:1")), .open(panel("overview:2")),
        .stack(frameID(2), onto: frameID(1)),
    ])
}

@Suite("frame drag")
struct FrameDragTests {
    @Test func aMoveDrawsTheRawRectAndAReleaseSnaps() throws {
        var layout = oneFrame()
        var drag = try #require(
            FrameDrag(layout: layout, frame: frameID(1), mode: .move, at: point(x: 100, y: 110),
                snap: 8))
        // The raw rect is 6 from the left edge. The release snaps it to 0.
        let step = drag.move(to: point(x: 86, y: 110), layout: &layout)
        #expect(
            step
                == view(
                    1, live: rect(h: 200, w: 300, x: 6, y: 100),
                    marks: [SnapMark(x: 0, y: 200, direction: .left)]))
        // A move does not change the layout. Only the end does.
        #expect(layout == oneFrame())
        let end = drag.end(at: point(x: 86, y: 110), layout: layout)
        #expect(end == .setRect(frameID(1), rect(h: 200, w: 300, x: 0, y: 100)))
    }

    @Test func aCancelKeepsTheLastDrawnRectWithNoSnap() throws {
        var layout = oneFrame()
        var drag = try #require(
            FrameDrag(layout: layout, frame: frameID(1), mode: .move, at: point(x: 100, y: 110),
                snap: 8))
        // A cancel before the first step changes nothing.
        #expect(drag.end(at: nil, layout: layout) == .nothing)
        // A step to the press point draws nothing.
        _ = drag.move(to: point(x: 100, y: 110), layout: &layout)
        #expect(drag.end(at: nil, layout: layout) == .nothing)
        _ = drag.move(to: point(x: 86, y: 110), layout: &layout)
        #expect(
            drag.end(at: nil, layout: layout)
                == .setRect(frameID(1), rect(h: 200, w: 300, x: 6, y: 100)))
    }

    @Test func aDropOnATitleBarStacksAndShowsNoMarks() throws {
        // f1 at x 100, y 100 (its title bar is y 100 to 128). f2 on top at x 600, y 500.
        var layout = run([
            .open(panel("overview:1")), .open(panel("settings")),
            .setRect(frameID(1), rect(h: 300, w: 400, x: 100, y: 100)),
            .setRect(frameID(2), rect(h: 200, w: 300, x: 600, y: 500)),
        ])
        var drag = try #require(
            FrameDrag(layout: layout, frame: frameID(2), mode: .move, at: point(x: 650, y: 510),
                snap: 8))
        // The pointer goes into the title bar of f1. The raw rect is 5 and 2 from the edges of
        // f1, so the snap would show marks without the drop target.
        let step = drag.move(to: point(x: 155, y: 112), layout: &layout)
        let raw = rect(h: 200, w: 300, x: 105, y: 102)
        let snapped = rect(h: 200, w: 300, x: 100, y: 100)
        let others = [rect(h: 300, w: 400, x: 100, y: 100)]
        let marks = Geometry.snapMarks(raw: raw, snapped: snapped, others: others, bounds: bounds)
        #expect(!marks.isEmpty)
        #expect(step == view(2, live: raw, target: 1))
        let end = drag.end(at: point(x: 155, y: 112), layout: layout)
        #expect(end == .stack(frameID(2), onto: frameID(1)))
        let stacked = layout.apply(.stack(frameID(2), onto: frameID(1)))
        #expect(stacked)
        #expect(layout.frames.map(\.panels) == [[panel("overview:1"), panel("settings")]])
    }

    @Test func aMoveOfLessThan4OnATitleBarDoesNotStack() throws {
        // f1 at x 0, y 0 and f2 on top at x 10, y 5. The point (20, 10) is in both title bars.
        var layout = run([
            .open(panel("overview:1")), .open(panel("settings")),
            .setRect(frameID(1), rect(h: 300, w: 300, x: 0, y: 0)),
            .setRect(frameID(2), rect(h: 200, w: 200, x: 10, y: 5)),
        ])
        var short = try #require(
            FrameDrag(layout: layout, frame: frameID(2), mode: .move, at: point(x: 20, y: 10),
                snap: 8))
        // 2.24 from the press point.
        let step = short.move(to: point(x: 22, y: 11), layout: &layout)
        #expect(step.dropTarget == nil)
        #expect(
            short.end(at: point(x: 22, y: 11), layout: layout)
                == .setRect(frameID(2), rect(h: 200, w: 200, x: 12, y: 0)))

        var far = try #require(
            FrameDrag(layout: layout, frame: frameID(2), mode: .move, at: point(x: 20, y: 10),
                snap: 8))
        // 4 from the press point.
        #expect(far.move(to: point(x: 24, y: 10), layout: &layout).dropTarget == frameID(1))
        #expect(
            far.end(at: point(x: 24, y: 10), layout: layout)
                == .stack(frameID(2), onto: frameID(1)))
    }

    @Test func aTabPressThatEndsBeforeATearOutDoesNothing() throws {
        var layout = stackOfTwo()
        let before = layout
        var drag = try #require(
            FrameDrag(
                layout: layout, frame: frameID(1), mode: .tab(panel("overview:1")),
                at: point(x: 300, y: 230), snap: 8))
        // 12 below the title bar: 12 or less is not a tear-out.
        let step = drag.move(to: point(x: 300, y: 260), layout: &layout)
        #expect(step == view(1))
        #expect(layout == before)
        #expect(drag.end(at: point(x: 300, y: 260), layout: layout) == .nothing)
    }

    @Test func aTabTearsOutPast12AndTheDragMovesTheNewFrame() throws {
        var layout = stackOfTwo()
        var drag = try #require(
            FrameDrag(
                layout: layout, frame: frameID(1), mode: .tab(panel("overview:2")),
                at: point(x: 300, y: 230), snap: 8))
        // 13 below the title bar. The new frame is f3 at the pointer less the tear offset, with
        // the saved size of overview:2.
        let tear = drag.move(to: point(x: 300, y: 261), layout: &layout)
        #expect(tear == view(3))
        #expect(drag.frame == frameID(3))
        #expect(layout.frames.map(\.id) == [frameID(1), frameID(3)])
        #expect(layout.frame(of: panel("overview:2"))?.rect == rect(h: 360, w: 760, x: 240, y: 247))
        // The drag moves f3 from the pointer. f1 is one of the others: the left edge snaps to
        // the left edge of f1 at 220.
        let step = drag.move(to: point(x: 285, y: 271), layout: &layout)
        #expect(
            step
                == view(
                    3, live: rect(h: 360, w: 760, x: 225, y: 257),
                    marks: [SnapMark(x: 220, y: 419, direction: .left)]))
        #expect(
            drag.end(at: point(x: 285, y: 271), layout: layout)
                == .setRect(frameID(3), rect(h: 360, w: 760, x: 220, y: 257)))
    }

    // After a tear-out, the new frame has its rect in the layout and the drag has drawn nothing.
    // A cancel then gives nothing. A release snaps the new frame from its rect.
    @Test func aTearOutThatEndsBeforeTheNextStepKeepsOrSnapsTheNewFrame() throws {
        var layout = stackOfTwo()
        var drag = try #require(
            FrameDrag(
                layout: layout, frame: frameID(1), mode: .tab(panel("overview:2")),
                at: point(x: 300, y: 230), snap: 8))
        _ = drag.move(to: point(x: 300, y: 261), layout: &layout)
        #expect(drag.frame == frameID(3))
        #expect(drag.end(at: nil, layout: layout) == .nothing)
        #expect(
            drag.end(at: point(x: 300, y: 261), layout: layout)
                == .setRect(frameID(3), rect(h: 360, w: 760, x: 240, y: 247)))
        // A release 15 to the left snaps the left edge to the left edge of f1 at 220.
        #expect(
            drag.end(at: point(x: 285, y: 261), layout: layout)
                == .setRect(frameID(3), rect(h: 360, w: 760, x: 220, y: 247)))
    }

    // A drag that stopped stays stopped, also when its frame can move again.
    @Test func aStoppedDragStaysStoppedAfterAnUnlock() throws {
        var layout = oneFrame()
        var drag = try #require(
            FrameDrag(layout: layout, frame: frameID(1), mode: .move, at: point(x: 100, y: 110),
                snap: 8))
        _ = drag.move(to: point(x: 86, y: 110), layout: &layout)
        layout.apply(.lock(frameID(1), true))
        #expect(drag.move(to: point(x: 80, y: 110), layout: &layout) == view(1))
        layout.apply(.lock(frameID(1), false))
        #expect(drag.move(to: point(x: 70, y: 110), layout: &layout) == view(1))
        #expect(drag.end(at: point(x: 70, y: 110), layout: layout) == .nothing)
        #expect(drag.end(at: nil, layout: layout) == .nothing)
    }

    @Test func aTornOutFrameGetsTheSavedSizeOfItsPanel() throws {
        // Settings has its own size when it goes into the stack. The stack keeps that rect in
        // the memory.
        let stacked = run([
            .open(panel("overview:1")), .open(panel("settings")),
            .setRect(frameID(2), rect(h: 356, w: 420, x: 700, y: 40)),
            .stack(frameID(2), onto: frameID(1)),
        ])
        var layout = stacked
        var drag = try #require(
            FrameDrag(
                layout: layout, frame: frameID(1), mode: .tab(panel("settings")),
                at: point(x: 300, y: 230), snap: 8))
        _ = drag.move(to: point(x: 300, y: 300), layout: &layout)
        #expect(layout.frame(of: panel("settings"))?.rect == rect(h: 356, w: 420, x: 240, y: 286))
        // overview:1 has no saved size, so it gets the size of the stack.
        layout = stacked
        var other = try #require(
            FrameDrag(
                layout: layout, frame: frameID(1), mode: .tab(panel("overview:1")),
                at: point(x: 300, y: 230), snap: 8))
        _ = other.move(to: point(x: 300, y: 300), layout: &layout)
        #expect(layout.frame(of: panel("overview:1"))?.rect == rect(h: 360, w: 760, x: 240, y: 286))
    }

    @Test func aDragOfTheOnlyTabIsAMove() throws {
        var layout = oneFrame()
        var drag = try #require(
            FrameDrag(
                layout: layout, frame: frameID(1), mode: .tab(panel("settings")),
                at: point(x: 100, y: 110), snap: 8))
        // The first step draws: no tear-out wait.
        let step = drag.move(to: point(x: 86, y: 110), layout: &layout)
        #expect(step.live == rect(h: 200, w: 300, x: 6, y: 100))
        #expect(layout == oneFrame())
        #expect(
            drag.end(at: point(x: 86, y: 110), layout: layout)
                == .setRect(frameID(1), rect(h: 200, w: 300, x: 0, y: 100)))
    }

    @Test func aLockedOrMinimisedFrameStartsNoDrag() {
        let layout = run([
            .open(panel("overview:1")), .open(panel("overview:2")), .lock(frameID(1), true),
            .minimise(frameID(2)),
        ])
        let p = point(x: 300, y: 230)
        #expect(FrameDrag(layout: layout, frame: frameID(1), mode: .move, at: p, snap: 8) == nil)
        #expect(
            FrameDrag(layout: layout, frame: frameID(2), mode: .resize(.se), at: p, snap: 8) == nil)
        #expect(FrameDrag(layout: layout, frame: frameID(9), mode: .move, at: p, snap: 8) == nil)
        let open = run([.lock(frameID(1), false)], from: layout)
        #expect(FrameDrag(layout: open, frame: frameID(1), mode: .move, at: p, snap: 8) != nil)
    }

    @Test func aSnapOf0GivesNoSnap() throws {
        var layout = oneFrame()
        var drag = try #require(
            FrameDrag(layout: layout, frame: frameID(1), mode: .move, at: point(x: 100, y: 110),
                snap: 0))
        let raw = rect(h: 200, w: 300, x: 6, y: 100)
        #expect(drag.move(to: point(x: 86, y: 110), layout: &layout) == view(1, live: raw))
        #expect(drag.end(at: point(x: 86, y: 110), layout: layout) == .setRect(frameID(1), raw))
    }

    @Test func aResizeDrawsTheRawEdgesAndNeverStacks() throws {
        // f1 at x 0, y 0 (its title bar is y 0 to 28). f2 on top at x 400, y 400.
        var layout = run([
            .open(panel("overview:1")), .open(panel("settings")),
            .setRect(frameID(1), rect(h: 300, w: 300, x: 0, y: 0)),
            .setRect(frameID(2), rect(h: 200, w: 300, x: 400, y: 400)),
        ])
        var drag = try #require(
            FrameDrag(
                layout: layout, frame: frameID(2), mode: .resize(.se), at: point(x: 700, y: 600),
                snap: 8))
        // The right edge goes to 1195, 5 from the window edge.
        let step = drag.move(to: point(x: 1195, y: 600), layout: &layout)
        #expect(
            step
                == view(
                    2, live: rect(h: 200, w: 795, x: 400, y: 400),
                    marks: [SnapMark(x: 1200, y: 500, direction: .right)]))
        // A resize that ends on a title bar does not stack. The minimum size stops the edges.
        #expect(drag.move(to: point(x: 100, y: 10), layout: &layout).dropTarget == nil)
        #expect(
            drag.end(at: point(x: 100, y: 10), layout: layout)
                == .setRect(frameID(2), rect(h: 120, w: 200, x: 400, y: 400)))
    }

    // A drag ends when its frame closes, goes to the side bar or becomes
    // locked. The end then changes nothing.
    @Test func aDragEndsWhenItsFrameIsLockedOrClosed() throws {
        let changes: [WindowAction] = [
            .lock(frameID(1), true), .close(panel("settings")), .minimise(frameID(1)),
        ]
        for change in changes {
            var layout = oneFrame()
            var drag = try #require(
                FrameDrag(layout: layout, frame: frameID(1), mode: .move, at: point(x: 100, y: 110),
                    snap: 8))
            #expect(drag.move(to: point(x: 86, y: 110), layout: &layout).live != nil)
            let changed = layout.apply(change)
            #expect(changed)
            #expect(drag.move(to: point(x: 80, y: 110), layout: &layout) == view(1))
            #expect(drag.end(at: point(x: 80, y: 110), layout: layout) == .nothing)
            #expect(drag.end(at: nil, layout: layout) == .nothing)
        }
    }
}
