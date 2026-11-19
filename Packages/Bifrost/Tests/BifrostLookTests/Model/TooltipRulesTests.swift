import BifrostLayout
import BifrostLook
import Testing

// The rules of the tooltip (docs/behaviour/look.md): a delay of 300 ms, a group timeout of 400 ms,
// a side offset of 6 and a collision padding of 5 in the window.

private let bounds = LayoutRect(x: 0, y: 0, w: 1000, h: 600)
private let tip = LayoutSize(w: 120, h: 24)

@Suite("tooltip rules")
struct TooltipRulesTests {
    @Test func aTooltipOpensAfter300msAndAnAdjacentOneAtOnce() {
        var timing = TooltipTiming()
        #expect(timing.openDelay(now: .seconds(10)) == .milliseconds(300))
        timing.opened()
        // While one tooltip shows, the next one opens at once.
        #expect(timing.openDelay(now: .seconds(11)) == .zero)
        timing.closed(at: .seconds(12))
        #expect(timing.openDelay(now: .seconds(12) + .milliseconds(399)) == .zero)
        #expect(timing.openDelay(now: .seconds(12) + .milliseconds(400)) == .milliseconds(300))
        // A close with no open tooltip does not start the group time.
        var fresh = TooltipTiming()
        fresh.closed(at: .seconds(1))
        #expect(fresh.openDelay(now: .seconds(1)) == .milliseconds(300))
    }

    @Test func aTopTooltipIsCentredAboveTheViewAt6() {
        let anchor = LayoutRect(x: 400, y: 300, w: 40, h: 20)
        let frame = TooltipPlacement.frame(tip: tip, anchor: anchor, side: .top, in: bounds)
        #expect(frame == LayoutRect(x: 360, y: 270, w: 120, h: 24))
    }

    @Test func aRightTooltipIsCentredBesideTheViewAt6() {
        let anchor = LayoutRect(x: 0, y: 100, w: 40, h: 40)
        let frame = TooltipPlacement.frame(tip: tip, anchor: anchor, side: .right, in: bounds)
        #expect(frame == LayoutRect(x: 46, y: 108, w: 120, h: 24))
    }

    @Test func aTooltipWithNoRoomGoesToTheOtherSide() {
        let top = LayoutRect(x: 400, y: 10, w: 40, h: 20)
        #expect(
            TooltipPlacement.frame(tip: tip, anchor: top, side: .top, in: bounds)
                == LayoutRect(x: 360, y: 36, w: 120, h: 24))
        let right = LayoutRect(x: 900, y: 100, w: 40, h: 40)
        #expect(
            TooltipPlacement.frame(tip: tip, anchor: right, side: .right, in: bounds)
                == LayoutRect(x: 774, y: 108, w: 120, h: 24))
        // With no room on either side, the tooltip keeps its side.
        let tall = LayoutSize(w: 120, h: 590)
        let kept = TooltipPlacement.frame(tip: tall, anchor: top, side: .top, in: bounds)
        #expect(kept.y == 10 - 6 - 590)
    }

    @Test func aTooltipShiftsAlongItsSideToStayInTheWindow() {
        let left = LayoutRect(x: 2, y: 300, w: 20, h: 20)
        #expect(
            TooltipPlacement.frame(tip: tip, anchor: left, side: .top, in: bounds)
                == LayoutRect(x: 5, y: 270, w: 120, h: 24))
        let corner = LayoutRect(x: 990, y: 300, w: 8, h: 20)
        #expect(
            TooltipPlacement.frame(tip: tip, anchor: corner, side: .top, in: bounds).x
                == 1000 - 5 - 120)
        // The shift keeps the tooltip at the view: its left edge never goes past the right edge
        // of the view.
        let outside = LayoutRect(x: -50, y: 300, w: 20, h: 20)
        #expect(
            TooltipPlacement.frame(tip: tip, anchor: outside, side: .top, in: bounds).x == -30)
    }
}
