import CoreGraphics
import Testing

@testable import BifrostLayout
@testable import BifrostLook

// One layout unit is interfaceScale / 100 points (plan decision). The rects of ui-state.json
// keep the meaning that the file has: CSS pixels at the page zoom.
@MainActor
@Suite("canvas metrics")
struct CanvasMetricsTests {
    @Test func canvasMetricsScaleRectsAndFloorTheArea() {
        let large = CanvasMetrics(interfaceScale: 150)
        #expect(large.scale == 1.5)
        #expect(
            large.points(LayoutRect(x: 10, y: 20, w: 300, h: 200))
                == CGRect(x: 15, y: 30, width: 450, height: 300))
        // The area in layout units is floored, as the CSS size of a page at a zoom.
        #expect(large.units(CGSize(width: 1001, height: 601)) == LayoutSize(w: 667, h: 400))
        #expect(large.points(12) == 18)
        let normal = CanvasMetrics(interfaceScale: 100)
        #expect(normal.scale == 1)
        #expect(normal.units(CGSize(width: 1440.75, height: 899.5)) == LayoutSize(w: 1440, h: 899))
        #expect(
            normal.points(LayoutRect(x: 16, y: 16, w: 760, h: 360))
                == CGRect(x: 16, y: 16, width: 760, height: 360))
        // At 110 a binary scale of 1.1 gives 799.99... for 880 points. The sum is exact.
        let medium = CanvasMetrics(interfaceScale: 110)
        #expect(medium.units(CGSize(width: 880, height: 550)) == LayoutSize(w: 800, h: 500))
        #expect(
            medium.points(LayoutRect(x: 0, y: 0, w: 800, h: 500))
                == CGRect(x: 0, y: 0, width: 880, height: 550))
        #expect(medium.units(CGSize(width: 879.9, height: 549.9)) == LayoutSize(w: 799, h: 499))
        #expect(medium.points(10) == 11)
        let small = CanvasMetrics(interfaceScale: 80)
        #expect(small.scale == 0.8)
        #expect(small.units(CGSize(width: 800, height: 500)) == LayoutSize(w: 1000, h: 625))
        #expect(small.points(13) == CGFloat(13 * 80) / 100)
        // A rect and back: the points of the units of a size are at most one unit smaller.
        let area = small.units(CGSize(width: 1234.5, height: 777.25))
        let back = small.points(LayoutRect(x: 0, y: 0, w: area.w, h: area.h))
        #expect(back.width <= 1234.5)
        #expect(back.width > 1234.5 - 0.8)
        #expect(back.height <= 777.25)
        #expect(back.height > 777.25 - 0.8)
    }

    @Test func aScaleOutsideTheSettingStaysInTheRange() {
        #expect(CanvasMetrics(interfaceScale: 10).scale == 0.8)
        #expect(CanvasMetrics(interfaceScale: 400).scale == 1.5)
        #expect(CanvasMetrics(interfaceScale: 110) == CanvasMetrics(interfaceScale: 110))
        #expect(CanvasMetrics(interfaceScale: 110) != CanvasMetrics(interfaceScale: 120))
    }
}
