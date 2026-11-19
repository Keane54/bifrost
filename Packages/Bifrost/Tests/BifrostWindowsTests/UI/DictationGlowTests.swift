import AppKit
import BifrostTestSupport
import Testing

@testable import BifrostDictation
@testable import BifrostLayout
@testable import BifrostLook
@testable import BifrostWindows

// The glow layer of the green look: the values of the approved mock
// (docs/behaviour/dictation.md).
@Suite("dictation glow", .timeLimit(.minutes(1)), .tags(.window))
@MainActor
struct DictationGlowTests {
    private let metrics = CanvasMetrics(interfaceScale: 100)

    private func frame(width: Double = 600) -> FrameView {
        let view = FrameView(
            id: FrameID(number: 1), blur: .backdrop, metrics: metrics, transparency: 15)
        view.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        return view
    }

    @Test("the glow never takes pointer input")
    func noPointerInput() {
        let view = frame()
        view.setDictation(0.8)
        for part in view.dictationParts {
            #expect(part.hitTest(NSPoint(x: part.frame.midX, y: part.frame.midY)) == nil)
        }
        #expect(view.titleBar.meter.hitTest(NSPoint(x: 10, y: 10)) == nil)
        view.setDictation(nil)
    }

    @Test("the glow paints down from the top border with the look values")
    func glowGeometry() {
        let look = DictationLook.of(level: 1)
        let rect = DictationGlow.glowRect(width: 602, border: 1, look: look, metrics: metrics)
        // 3 % in from each side of the inner width, and 1 unit below the top border.
        #expect(abs(rect.minX - (1 + 600 * 0.03)) < 1e-9)
        #expect(abs(rect.width - 600 * 0.94) < 1e-9)
        #expect(rect.minY == 2)
        #expect(abs(rect.height - look.glowHeight) < 1e-9)
        let layer = DictationGlow.makeGlowLayer()
        DictationGlow.apply(
            look, glow: layer, shadow: DictationGlow.makeShadow(), metrics: metrics)
        let radius = layer.value(forKeyPath: DictationGlow.blurRadius)
        #expect((radius as? Double).map { abs($0 - look.glowBlur) < 1e-9 } == true)
        // The ellipse is at the middle of the top, as high as the glow and as wide as the glow
        // width of the look: 72 % at level 1, and 55 % at level 0.
        #expect(layer.type == .radial)
        #expect(layer.startPoint == CGPoint(x: 0.5, y: 0))
        #expect(abs(layer.endPoint.x - 1.22) < 1e-9)
        #expect(layer.endPoint.y == 1)
        DictationGlow.apply(
            .of(level: 0), glow: layer, shadow: DictationGlow.makeShadow(), metrics: metrics)
        #expect(abs(layer.endPoint.x - 1.05) < 1e-9)
    }

    @Test("the green values mix the green token with an alpha")
    func greenAlpha() {
        var half = ThemeTokens.watchGreen
        half.a = 0.5
        #expect(DictationGlow.green(0.5) == half.cgColor)
        #expect(DictationGlow.green(2).alpha == 1)
        #expect(DictationGlow.green(-1).alpha == 0)
    }

    @Test
    func edgeAndShadow() {
        let view = frame(width: 602)
        view.setDictation(1)
        for _ in 0..<120 { view.smoothDictation(seconds: 1.0 / 60) }
        let look = DictationLook.of(level: view.dictationLevel)
        #expect(view.dictationEdgeLayer.frame == CGRect(x: 1, y: 1, width: 600, height: 1))
        #expect(view.look.topLine == DictationGlow.green(look.borderAlpha))
        // The shadow is the green with the shadow alpha, and its softness is half the blur.
        #expect(abs(view.dictationShadowGlow.strength - look.borderShadowAlpha) < 1e-6)
        #expect(abs(view.dictationShadowGlow.softness - look.borderShadowBlur / 2) < 1e-6)
        // The values of the mock at level 1: a blur of 12 and 85 %.
        #expect(abs(look.borderShadowBlur - 12) < 1e-6)
        #expect(abs(look.borderShadowAlpha - 0.85) < 1e-6)
        view.setDictation(nil)
    }

    // The shadow lights only the area above the top edge. Its strip starts b in from each end
    // of the edge, and the light goes 3 softness lengths (1.5 b) past the strip.
    @Test
    func shadowAboveOnly() {
        let look = DictationLook.of(level: 0.5)
        let b = look.borderShadowBlur
        let shadow = DictationGlow.makeShadow()
        let area = DictationGlow.layoutShadow(shadow, width: 600, look: look, metrics: metrics)
        #expect(area.maxY == 0)
        #expect(abs(area.minX - (b - 1.5 * b)) < 1e-9)
        #expect(abs(area.width - (600 - 2 * b + 3 * b)) < 1e-9)
        #expect(abs(area.height - 1.5 * b) < 1e-9)
        #expect(abs(shadow.stripFrame.minX + area.minX - b) < 1e-9)
        #expect(abs(shadow.stripFrame.width - (600 - 2 * b)) < 1e-9)
        #expect(abs(shadow.stripFrame.minY - area.height) < 1e-9)
    }

    // The display link keeps only a weak target, so a frame view that shows the green look can
    // go, and its deinit stops the link.
    @Test func aFrameWithTheGreenLookCanGo() {
        weak var plain: FrameView?
        weak var gone: FrameView?
        autoreleasepool {
            let a = frame()
            plain = a
            let view = frame()
            view.setDictation(0.5)
            #expect(view.displayLinkRuns)
            gone = view
        }
        #expect(plain == nil)
        #expect(gone == nil)
    }

    // The glow has one named blur filter. A new look changes only the radius of that filter.
    @Test func theGlowKeepsOneBlurFilterAndChangesItsRadius() throws {
        let view = frame()
        view.setDictation(0.3)
        view.smoothDictation(seconds: 1.0 / 60)
        let filters = try #require(view.dictationGlowLayer.filters as? [CIFilter])
        #expect(filters.map(\.name) == ["blur"])
        view.setDictation(0.9)
        for _ in 0..<10 { view.smoothDictation(seconds: 1.0 / 60) }
        let after = try #require(view.dictationGlowLayer.filters as? [CIFilter])
        #expect(after.map(\.name) == ["blur"])
        let look = DictationLook.of(level: view.dictationLevel)
        let radius = view.dictationGlowLayer.value(forKeyPath: DictationGlow.blurRadius)
        #expect((radius as? Double).map { abs($0 - look.glowBlur) < 1e-9 } == true)
        view.setDictation(nil)
    }

    // The display link stops at each frame when the level reaches its target, and starts again
    // when the target changes. A look that did not change sets no layer.
    @Test func theSmoothingStopsAtTheTarget() {
        let view = frame()
        view.setDictation(0.5)
        #expect(view.displayLinkRuns)
        for _ in 0..<120 { view.smoothDictation(seconds: 1.0 / 60) }
        #expect(view.dictationLevel == 0.5)
        #expect(!view.displayLinkRuns)
        // The same target keeps the link stopped.
        view.setDictation(0.5)
        #expect(!view.displayLinkRuns)
        // A frame at the target changes no layer.
        view.dictationEdgeLayer.backgroundColor = nil
        view.smoothDictation(seconds: 1.0 / 60)
        #expect(view.dictationEdgeLayer.backgroundColor == nil)
        // A new target starts the link again, and the look follows the level.
        view.setDictation(0.1)
        #expect(view.displayLinkRuns)
        view.smoothDictation(seconds: 1.0 / 60)
        let look = DictationLook.of(level: view.dictationLevel)
        #expect(view.dictationEdgeLayer.backgroundColor == DictationGlow.green(look.borderAlpha))
        view.setDictation(nil)
        #expect(!view.displayLinkRuns)
    }

    // A new paint of the frame (here a new transparency) keeps the green look on top of it,
    // also when the level is at its target.
    @Test func aNewPaintKeepsTheGreenLook() {
        let view = frame()
        view.setDictation(0.6)
        for _ in 0..<120 { view.smoothDictation(seconds: 1.0 / 60) }
        let green = view.look.topLine
        view.apply(metrics: metrics, transparency: 30, blur: .backdrop)
        #expect(view.look.topLine == green)
        #expect(view.look.glow == 0)
        view.setDictation(nil)
    }

    @Test("the glow stops follow the mock")
    func glowStops() {
        let look = DictationLook.of(level: 0.6)
        let layer = DictationGlow.makeGlowLayer()
        DictationGlow.apply(
            look, glow: layer, shadow: DictationGlow.makeShadow(), metrics: metrics)
        #expect(layer.locations?.map(\.doubleValue) == [0, 0.45, 0.75])
        let alphas = (layer.colors as? [CGColor])?.map(\.alpha) ?? []
        #expect(alphas.count == 3)
        #expect(zip(alphas, [look.glowAlpha, look.glowAlpha * 0.35, 0]).allSatisfy {
            abs(Double($0) - $1) < 1e-6
        })
        // 1 unit from the top border.
        #expect(DictationGlow.top == 1)
    }
}
