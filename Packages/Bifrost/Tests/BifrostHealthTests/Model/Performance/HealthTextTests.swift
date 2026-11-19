// The texts of the Performance monitor (docs/behaviour/health.md, "Performance").
import Foundation
import Testing

@testable import BifrostHealth

@Suite("performance health text")
struct HealthTextTests {
    @Test func theGBValueGetsTwoDecimalsWhenOneGivesTheLimit() {
        let gb = mb(1024)
        #expect(HealthText.overLimit(mb(1027), limit: gb) == "1.01 GB")
        #expect(HealthText.overLimit(mb(1024 * 1.8), limit: mb(1536)) == "1.8 GB")
        #expect(HealthText.overLimit(mb(1024 * 1.515), limit: mb(1536)) == "1.52 GB")
        #expect(HealthText.overLimit(mb(1024 * 1.06), limit: gb) == "1.1 GB")
        #expect(HealthText.limit(gb) == "1 GB")
        #expect(HealthText.limit(mb(1536)) == "1.5 GB")
    }

    // The text shows the value that the check compared. At 1.25 GB (an exact half in binary),
    // the text rounds as the check does, and an over-limit text never shows the limit itself.
    @Test func theGBTextShowsTheValueThatTheCheckUses() throws {
        #expect(HealthText.overLimit((1 << 30) + (1 << 28), limit: mb(1024)) == "1.3 GB")
        for limit in [mb(1024), mb(1536)] {
            for step in 1...2400 {
                let bytes = limit + UInt64(step) * 131_072
                let text = HealthText.overLimit(bytes, limit: limit)
                let value = try #require(Double(text.dropLast(3)))
                #expect(value * 1_073_741_824 > Double(limit), "\(bytes) bytes gave \(text)")
            }
        }
    }

    @Test func theOKTextHasTheRealValues() {
        #expect(
            HealthText.ok(Use(memory: mb(712.4), cpu: 2.4))
                == "Bifrost is using 712 MB RAM and 2% CPU.")
        // The rounded MB value decides between MB and GB.
        #expect(
            HealthText.ok(Use(memory: mb(1023.6), cpu: 0))
                == "Bifrost is using 1.0 GB RAM and 0% CPU.")
        #expect(
            HealthText.ok(Use(memory: mb(1843), cpu: 150.6))
                == "Bifrost is using 1.8 GB RAM and 151% CPU.")
    }

    @Test func theHeadlineNamesTheLevelOrSaysItIsChecking() {
        #expect(HealthText.headline(nil, use: nil) == "Checking Bifrost…")
        #expect(HealthText.headline(.warning, use: nil) == "Warning")
        #expect(HealthText.headline(.problem, use: Use(memory: mb(10), cpu: 0)) == "Problem")
        #expect(
            HealthText.headline(.ok, use: Use(memory: mb(712), cpu: 2))
                == "Bifrost is using 712 MB RAM and 2% CPU.")
    }

    @Test func aSavedPartHasAFriendlyName() {
        #expect(HealthText.saved("the settings") == "your settings")
        #expect(HealthText.saved("the UI state") == "the panel layout")
        #expect(HealthText.saved("the registry store") == "the session list")
        #expect(HealthText.saved("the window state") == "the window position")
        #expect(HealthText.saved("the Daily update state") == "the Daily update state")
    }
}
