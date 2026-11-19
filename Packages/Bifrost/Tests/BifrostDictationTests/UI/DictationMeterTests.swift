// The level bar of the dictation meter, for VoiceOver. The test makes the views with no window.
import AppKit
import BifrostTestSupport
import Testing

@testable import BifrostDictation

@Suite("dictation meter", .tags(.window))
@MainActor
struct DictationMeterTests {
    // VoiceOver reads the bar as a level indicator from 0 to 1, with the level that it shows.
    @Test func theLevelBarGivesItsValueToVoiceOver() throws {
        let meter = DictationMeter(frame: CGRect(x: 0, y: 0, width: 80, height: 20))
        let bar = meter.bar
        #expect(bar.isAccessibilityElement())
        #expect(bar.accessibilityRole() == .levelIndicator)
        #expect(bar.accessibilityLabel() == "Voice level")
        #expect((bar.accessibilityMinValue() as? NSNumber)?.doubleValue == 0)
        #expect((bar.accessibilityMaxValue() as? NSNumber)?.doubleValue == 1)
        for level in [0, 0.25, 1] {
            meter.show(level: level)
            let value = try #require(bar.accessibilityValue() as? NSNumber)
            #expect(value.doubleValue == bar.fill)
        }
        #expect((bar.accessibilityValue() as? NSNumber)?.doubleValue == 1)
    }
}
