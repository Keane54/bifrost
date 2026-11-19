import Foundation
import Testing

@testable import BifrostWindows

// What's new at the start (docs/behaviour/updates.md, "What's new").
@Suite("what's new rule")
struct WhatsNewRuleTests {
    @Test func aFreshInstallHasNoNewsButStoresTheVersion() {
        let decision = WhatsNewRule.decide(current: "1.0.0", lastSeen: nil, setupDone: false)
        #expect(decision.open == nil)
        #expect(decision.store)
    }

    @Test func theFirstVersionWithWhatsNewShowsOnlyThatVersion() {
        let decision = WhatsNewRule.decide(current: "1.0.0", lastSeen: nil, setupDone: true)
        #expect(decision.open == WhatsNewRange(since: nil, version: version("1.0.0")))
        #expect(decision.store)
    }

    @Test func anUpdateShowsTheVersionsSinceTheLastSeenVersion() {
        let decision = WhatsNewRule.decide(current: "1.3.0", lastSeen: "1.1.0", setupDone: true)
        #expect(decision.open == WhatsNewRange(since: version("1.1.0"), version: version("1.3.0")))
        #expect(decision.store)
        // The setup choice does not matter once a version is stored.
        let again = WhatsNewRule.decide(current: "1.3.0", lastSeen: "1.1.0", setupDone: false)
        #expect(again.open == decision.open)
    }

    @Test func theSameVersionOrAnOlderAppOpensNothingAndStoresNothing() {
        for seen in ["1.3.0", "v1.3.0", "1.4.0"] {
            let decision = WhatsNewRule.decide(current: "1.3.0", lastSeen: seen, setupDone: true)
            #expect(decision.open == nil, "\(seen)")
            #expect(!decision.store, "\(seen)")
        }
    }

    @Test func aStoredTextThatIsNotAVersionCountsAsNone() {
        let decision = WhatsNewRule.decide(current: "1.0.0", lastSeen: "soon", setupDone: true)
        #expect(decision.open == WhatsNewRange(since: nil, version: version("1.0.0")))
        #expect(decision.store)
    }

    @Test func aCurrentVersionThatIsNotAVersionDoesNothing() {
        let decision = WhatsNewRule.decide(current: "dev", lastSeen: nil, setupDone: true)
        #expect(decision.open == nil)
        #expect(!decision.store)
    }

    @Test func theRangeKeepsTheReleasesAfterSinceUpToTheVersion() {
        let list = ["1.4.0", "1.3.0", "1.2.0", "1.1.0", "1.0.0"].map { release($0) }
        let since = WhatsNewRange(since: version("1.1.0"), version: version("1.3.0"))
        #expect(since.releases(in: list).map(\.version.description) == ["1.3.0", "1.2.0"])
        let first = WhatsNewRange(since: nil, version: version("1.3.0"))
        #expect(first.releases(in: list).map(\.version.description) == ["1.3.0"])
        let future = WhatsNewRange(since: nil, version: version("9.0.0"))
        #expect(future.releases(in: list).isEmpty)
    }
}
