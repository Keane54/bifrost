import BifrostLayout

// The rules of the tooltips (docs/behaviour/look.md, "Tooltips"). The tooltips share one delay
// group: a tooltip opens after the pointer rests 300 ms on its view, and while another tooltip
// shows, or up to 400 ms after it closed, the next one opens at once. A tooltip closes at once. The
// place: the side of the view (top or right) at 6 units, centred on the view, flipped to the other
// side when it has no room in the window, and moved along its side to stay 5 units inside the
// window.

package enum TooltipSide: Sendable {
    case top, right
}

// The area that holds a tooltip: the window of its view (it wraps at the width of the window and
// flips or moves at its edges), or the visible frame of the screen of the window. A view in a
// small panel, for example a row of a menu, uses the screen.
package enum TooltipArea: Sendable {
    case window, screen
}

// The delay group of the tooltips.
package struct TooltipTiming: Sendable, Equatable {
    // The delay of a tooltip and the timeout of the group.
    package static let delay = Duration.milliseconds(300)
    package static let groupTimeout = Duration.milliseconds(400)

    private var open = false
    private var closedAt: Duration?

    package init() {}

    // The time from now until a tooltip opens, for a pointer that comes to its view now. The
    // times are on one clock that never goes back.
    package func openDelay(now: Duration) -> Duration {
        if open { return .zero }
        if let closedAt, now - closedAt < Self.groupTimeout { return .zero }
        return Self.delay
    }

    package mutating func opened() {
        open = true
        closedAt = nil
    }

    // A close of a tooltip that was open starts the group timeout.
    package mutating func closed(at now: Duration) {
        if open { closedAt = now }
        open = false
    }
}

// The place of a tooltip, in the coordinates of the window content (y down), in points.
package enum TooltipPlacement {
    // The space between the view and the tooltip (sideOffset) and the space to the edge of the
    // window (collisionPadding).
    package static let offset = 6.0
    package static let padding = 5.0

    package static func frame(
        tip: LayoutSize, anchor: LayoutRect, side: TooltipSide, in bounds: LayoutRect,
        scale: Double = 1
    ) -> LayoutRect {
        let offset = offset * scale
        let padding = padding * scale
        switch side {
        case .top:
            let above = anchor.y - offset - tip.h
            let below = anchor.y + anchor.h + offset
            let fitsAbove = above >= bounds.y + padding
            let fitsBelow = below + tip.h <= bounds.y + bounds.h - padding
            let y = !fitsAbove && fitsBelow ? below : above
            let x = shifted(
                anchor.x + anchor.w / 2 - tip.w / 2, size: tip.w, start: anchor.x,
                length: anchor.w, low: bounds.x + padding, high: bounds.x + bounds.w - padding)
            return LayoutRect(x: x, y: y, w: tip.w, h: tip.h)
        case .right:
            let after = anchor.x + anchor.w + offset
            let before = anchor.x - offset - tip.w
            let fitsAfter = after + tip.w <= bounds.x + bounds.w - padding
            let fitsBefore = before >= bounds.x + padding
            let x = !fitsAfter && fitsBefore ? before : after
            let y = shifted(
                anchor.y + anchor.h / 2 - tip.h / 2, size: tip.h, start: anchor.y,
                length: anchor.h, low: bounds.y + padding, high: bounds.y + bounds.h - padding)
            return LayoutRect(x: x, y: y, w: tip.w, h: tip.h)
        }
    }

    // Move a start along one axis into low to high. The tooltip stays at the view: its start is
    // never after the end of the view, and its end never before the start of the view.
    private static func shifted(
        _ value: Double, size: Double, start: Double, length: Double, low: Double, high: Double
    ) -> Double {
        var result = value
        if result + size > high { result = high - size }
        if result < low { result = low }
        return min(max(result, start - size), start + length)
    }
}
