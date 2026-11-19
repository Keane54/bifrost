// The hit tests on the frames. The frames are in z-order, so the last frame is on top.
import Foundation

package enum Hit {
    // A tab leaves its stack when the pointer goes more than this distance from the title bar.
    package static let tearDistance = 12.0
    // A move can stack its frame only after the pointer went this distance from the drag start.
    // So a small move of a frame whose title bar is on another title bar does not stack the
    // frames.
    package static let stackDistance = 4.0
    // When a tab leaves its stack, the top left corner of the new frame is 60 units left of the
    // pointer and 14 units above it.
    package static let tearOffset = LayoutPoint(x: 60, y: 14)

    // True when p is stackDistance or more from the start point of the drag.
    package static func movedToStack(from start: LayoutPoint, to p: LayoutPoint) -> Bool {
        hypot(p.x - start.x, p.y - start.y) >= stackDistance
    }

    // The top frame that shows and contains p. The excluded frame does not count.
    package static func frameAt(
        _ frames: [LayoutFrame], _ p: LayoutPoint, excluding: FrameID? = nil
    ) -> LayoutFrame? {
        frames.last { frame in
            !frame.minimised && frame.id != excluding && Geometry.contains(frame.rect, p)
        }
    }

    // The top frame that shows and whose title bar contains p. If the body of a higher frame
    // covers p, the result is nil.
    package static func titleBarAt(
        _ frames: [LayoutFrame], _ p: LayoutPoint, excluding: FrameID
    ) -> LayoutFrame? {
        guard let frame = frameAt(frames, p, excluding: excluding),
            Geometry.contains(Geometry.titleBar(frame.rect), p)
        else { return nil }
        return frame
    }

    // True when p is more than tearDistance above, below, left or right of the title bar. The
    // distance counts from the edges of the rect: x, x + w, y and y + h.
    package static func tornOut(bar: LayoutRect, _ p: LayoutPoint) -> Bool {
        p.y < bar.y - tearDistance || p.y > bar.y + bar.h + tearDistance
            || p.x < bar.x - tearDistance || p.x > bar.x + bar.w + tearDistance
    }

    // The rect of a tab that leaves its stack, at the pointer p. It has the saved size of the
    // panel, or else the size of the stack. The size fits in the area. The layout moves the rect
    // into the area.
    package static func tearOutRect(
        at p: LayoutPoint, saved: LayoutRect?, stack: LayoutRect, bounds: LayoutSize
    ) -> LayoutRect {
        let size = saved.flatMap { $0.w.isFinite && $0.h.isFinite ? $0 : nil } ?? stack
        let fit = Geometry.clampRect(LayoutRect(x: 0, y: 0, w: size.w, h: size.h), bounds: bounds)
        return LayoutRect(x: p.x - tearOffset.x, y: p.y - tearOffset.y, w: fit.w, h: fit.h)
    }
}
