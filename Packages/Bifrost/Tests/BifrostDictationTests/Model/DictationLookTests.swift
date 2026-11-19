// The values of the green look: the level, the smoothing and the phase that shows the look. The
// glow layer, the edge and the frame shadow have their tests in DictationGlowTests
// (docs/behaviour/dictation.md).
import Foundation
import Testing

@testable import BifrostDictation

// True when the value is less than the tolerance away from the expected value.
private func near(_ value: Double, _ expected: Double, within tolerance: Double = 0.005) -> Bool {
    abs(value - expected) < tolerance
}

@Suite("dictation look")
struct LookOfTests {
    // A quiet room looks as in the design. The glow is narrower than the 67 % of the design, but
    // at an alpha of 0.05 the change is at most 1 of 255 in a render.
    @Test("level 0 gives the values of the design")
    func levelZero() {
        let look = DictationLook.of(level: 0)
        #expect(near(look.borderAlpha, 0.35))
        #expect(near(look.glowHeight, 3.5))
        #expect(near(look.glowAlpha, 0.05))
        #expect(near(look.glowBlur, 3.5))
        #expect(near(look.glowWidth, 0.55))
        #expect(look.barWidth == 0)
    }

    // A loud voice gives a higher, brighter and wider glow than the design (user decision,
    // 2026-11-18): 80 high in place of 65, an alpha of 0.77 in place of 0.65, and 72 % wide in
    // place of 67 %.
    @Test("level 1 gives the values of the look with more motion")
    func levelOne() {
        let look = DictationLook.of(level: 1)
        #expect(near(look.borderAlpha, 1))
        #expect(near(look.glowHeight, 80))
        #expect(near(look.glowAlpha, 0.77))
        #expect(near(look.glowBlur, 12.3))
        #expect(near(look.glowWidth, 0.72))
        #expect(look.barWidth == DictationLook.barWidth)
        #expect(DictationLook.barWidth == 44)
    }

    @Test("the look rises smoothly with the level")
    func rises() {
        var last = DictationLook.of(level: 0)
        for i in 1...100 {
            let next = DictationLook.of(level: Double(i) / 100)
            #expect(next.glowHeight >= last.glowHeight)
            #expect(next.glowAlpha >= last.glowAlpha)
            #expect(next.glowBlur >= last.glowBlur)
            #expect(next.glowWidth >= last.glowWidth)
            #expect(next.borderAlpha >= last.borderAlpha)
            #expect(next.glowHeight - last.glowHeight < 5)
            #expect(next.glowAlpha - last.glowAlpha < 0.06)
            #expect(next.glowBlur - last.glowBlur < 0.8)
            #expect(next.glowWidth - last.glowWidth < 0.02)
            #expect(next.borderAlpha - last.borderAlpha < 0.06)
            last = next
        }
    }

    @Test
    func outOfRange() {
        #expect(DictationLook.of(level: -3) == DictationLook.of(level: 0))
        #expect(DictationLook.of(level: 7) == DictationLook.of(level: 1))
        #expect(DictationLook.of(level: .nan) == DictationLook.of(level: 0))
    }
}

@Suite("level smoothing")
struct SmoothLevelTests {
    @Test("the level rises faster than it falls")
    func fasterUp() {
        let up = DictationLook.smooth(0, toward: 1, seconds: 0.03)
        let down = 1 - DictationLook.smooth(1, toward: 0, seconds: 0.03)
        #expect(up > down)
    }

    // The level rises in 60 ms and falls in 150 ms, so the glow falls back fast and moves more.
    @Test("a step reaches 63% after the time constant")
    func timeConstant() {
        #expect(DictationLook.attack == 0.06)
        #expect(DictationLook.release == 0.15)
        let rise = DictationLook.smooth(0, toward: 1, seconds: 0.06)
        let fall = 1 - DictationLook.smooth(1, toward: 0, seconds: 0.15)
        #expect(near(rise, 1 - exp(-1), within: 0.000_005))
        #expect(near(fall, 1 - exp(-1), within: 0.000_005))
    }

    @Test
    func stillAndBounded() {
        #expect(DictationLook.smooth(0.4, toward: 0.9, seconds: 0) == 0.4)
        #expect(DictationLook.smooth(0.4, toward: 0.9, seconds: 100) <= 0.9)
        #expect(DictationLook.smooth(0.9, toward: 0.4, seconds: 100) >= 0.4)
    }
}

@Suite("what shows")
struct LookShowsTests {
    @Test("the green look shows only while the microphone listens")
    func onlyListening() {
        #expect(DictationLook.shows(.listening))
        for phase: DictationPhase in [
            .off, .starting, .downloading(progress: 0.5), .downloaded, .stopping,
        ] {
            #expect(!DictationLook.shows(phase))
        }
    }
}

// New tests of the values that the CSS tests read.
struct DictationLookTests {
    // The shadow of the top border: 2 px and 25 % at level 0, 12 px and 85 % at level 1.
    @Test func theShadowOfTheTopBorderHasTheValuesOfTheMock() {
        let low = DictationLook.of(level: 0)
        let high = DictationLook.of(level: 1)
        #expect(near(low.borderShadowBlur, 2))
        #expect(near(low.borderShadowAlpha, 0.25))
        #expect(near(high.borderShadowBlur, 12))
        #expect(near(high.borderShadowAlpha, 0.85))
    }

    // The look uses e = level^0.8, and the bar uses the level itself.
    @Test func theLookUsesTheLevelToThePowerOf0Point8() {
        let look = DictationLook.of(level: 0.5)
        let e = pow(0.5, 0.8)
        #expect(near(look.borderAlpha, 0.35 + 0.65 * e, within: 0.000_000_000_5))
        #expect(near(look.glowHeight, 3.5 + 76.5 * e, within: 0.000_000_000_5))
        #expect(near(look.glowAlpha, 0.05 + 0.72 * e, within: 0.000_000_000_5))
        #expect(near(look.glowWidth, 0.55 + 0.17 * e, within: 0.000_000_000_5))
        #expect(near(look.barWidth, 22, within: 0.000_000_000_5))
    }

    // A time that is not a number moves nothing, as !(dt > 0) does.
    @Test func aTimeThatIsNotANumberMovesNothing() {
        #expect(DictationLook.smooth(0.4, toward: 0.9, seconds: .nan) == 0.4)
        #expect(DictationLook.smooth(0.4, toward: 0.9, seconds: -1) == 0.4)
    }
}
