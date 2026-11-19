import BifrostApp
import BifrostFoundation
import Foundation
import Testing

@Test func developmentNeverStartsTheUpdater() {
    #expect(!UpdatePolicy.startsUpdater(variant: .development, feedURL: "https://x/appcast.xml",
                                        publicKey: "key"))
}

@Test func releaseNeedsAFeedAndAKey() {
    #expect(UpdatePolicy.startsUpdater(variant: .release, feedURL: "https://x/appcast.xml",
                                       publicKey: "key"))
    #expect(!UpdatePolicy.startsUpdater(variant: .release, feedURL: nil, publicKey: "key"))
    #expect(!UpdatePolicy.startsUpdater(variant: .release, feedURL: "", publicKey: "key"))
    #expect(!UpdatePolicy.startsUpdater(variant: .release, feedURL: "https://x/appcast.xml",
                                        publicKey: nil))
    #expect(!UpdatePolicy.startsUpdater(variant: .release, feedURL: "https://x/appcast.xml",
                                        publicKey: ""))
}

// The health log counts an update cycle as failed only for a real error: no error, no new update
// and a cancelled or later install are good ends.
@Test func anUpdateCycleFailsOnlyForARealError() {
    #expect(UpdatePolicy.cycleSucceeded(nil))
    for code in [1001, 4007, 4008] {
        #expect(UpdatePolicy.cycleSucceeded(("SUSparkleErrorDomain", code)))
    }
    #expect(!UpdatePolicy.cycleSucceeded(("SUSparkleErrorDomain", 2001)))
    #expect(!UpdatePolicy.cycleSucceeded(("SUSparkleErrorDomain", 1002)))
    #expect(!UpdatePolicy.cycleSucceeded((NSURLErrorDomain, 1001)))
}
