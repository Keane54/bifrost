// The look of a chat window while it dictates (docs/behaviour/dictation.md, "The look"). The
// level goes from 0 to 1, and e = level^0.8. The glow layer, the top edge and the shadow of the
// frame use these values. The glow grows more with the voice than in the approved mock, and it
// falls back faster (user decision, 2026-11-18). At level 0 it looks as in the mock.
import Foundation

package struct DictationLook: Sendable, Equatable {
    // The width of the level bar in the title bar, in points.
    package static let barWidth = 44.0
    // The time constants of the smoothing, in seconds. The level rises fast and falls slower.
    package static let attack = 0.06
    package static let release = 0.15

    // The width of the level bar for this level.
    package var barWidth: Double
    // The alpha of the green top border.
    package var borderAlpha: Double
    // The alpha and the blur radius of the shadow of the top border.
    package var borderShadowAlpha: Double
    package var borderShadowBlur: Double
    // The alpha, the blur radius and the height of the glow below the top border.
    package var glowAlpha: Double
    package var glowBlur: Double
    package var glowHeight: Double
    // The width of the ellipse of the glow, as a part of the width of the glow. The glow gets
    // wider with the voice. At its widest, the light at 2 % and 98 % of the frame stays near 0.
    package var glowWidth: Double

    // The look for a level. A level out of the range 0 to 1 gets the nearest end, and a level
    // that is not a number is 0.
    package static func of(level: Double) -> DictationLook {
        let l = level.isFinite ? min(1, max(0, level)) : 0
        let e = pow(l, 0.8)
        return DictationLook(
            barWidth: barWidth * l,
            borderAlpha: 0.35 + 0.65 * e,
            borderShadowAlpha: 0.25 + 0.6 * e,
            borderShadowBlur: 2 + 10 * e,
            glowAlpha: 0.05 + 0.72 * e,
            glowBlur: 3.5 + 8.8 * e,
            glowHeight: 3.5 + 76.5 * e,
            glowWidth: 0.55 + 0.17 * e)
    }

    // One step of the smoothing over the time of one display frame. A time that is not more than
    // 0 (or not a number) moves nothing.
    package static func smooth(
        _ current: Double, toward target: Double, seconds: Double
    ) -> Double {
        guard seconds > 0 else { return current }
        let tau = target > current ? attack : release
        return current + (target - current) * (1 - exp(-seconds / tau))
    }

    // The green look shows only while the microphone is open. A model download shows no green
    // look.
    package static func shows(_ phase: DictationPhase) -> Bool {
        phase == .listening
    }
}
