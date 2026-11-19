// The frames that get the backdrop blur (docs/behaviour/look.md, "Blur and scale").
//
// User decision, 2026-11-10: a frame keeps its backdrop blur only while it overlaps a lower frame
// that shows. A frame over the background only has no blur. The GPU must blur the area behind each
// blurred frame again at each new frame of the background. So fewer blurred frames cost less.

// The rect of the dragged frame during a drag. The layout gets it only when the drag ends.
package struct LiveRect: Sendable, Equatable {
    package var frame: FrameID
    package var rect: LayoutRect

    package init(frame: FrameID, rect: LayoutRect) {
        self.frame = frame
        self.rect = rect
    }
}

// True when the two rects share an area. Rects that only touch at an edge or a corner do not
// overlap. Frames that snap together touch at an edge.
package func rectsOverlap(_ a: LayoutRect, _ b: LayoutRect) -> Bool {
    a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

// The IDs of the frames (in z-order, the first at the bottom) that overlap a lower frame that
// shows. A minimised frame does not show, so it gets no blur and does not count as a lower frame.
// During a drag, the live rect replaces the rect of the dragged frame.
package func blurredFrames(_ frames: [LayoutFrame], live: LiveRect? = nil) -> Set<FrameID> {
    func rect(of frame: LayoutFrame) -> LayoutRect {
        live.flatMap { $0.frame == frame.id ? $0.rect : nil } ?? frame.rect
    }
    var result = Set<FrameID>()
    for (z, frame) in frames.enumerated() where !frame.minimised {
        let r = rect(of: frame)
        let over = frames[..<z].contains { lower in
            !lower.minimised && rectsOverlap(r, rect(of: lower))
        }
        if over { result.insert(frame.id) }
    }
    return result
}
