import BifrostSessions
import Foundation
import Testing

@testable import BifrostReviews

// The settings of Reviews in the types of the rules.

@Suite("the Reviews config", .timeLimit(.minutes(1)))
struct ReviewsConfigTests {
    // The defaults of Settings > Reviews: watch off, automatic fixes on, team requests on, three
    // PR sessions, a pause of one hour and a poll each two minutes.
    @Test func theDefaultsAreTheDefaultsOfTheSettings() {
        let config = ReviewsConfig()
        #expect(!config.watch && config.autoFix && config.teamRequests && !config.signedCommits)
        #expect(config.rowFlash && config.notifications)
        #expect(config.maxSessions == 3)
        #expect(config.pause == .seconds(3600) && config.pollInterval == .seconds(120))
        #expect(config.requestModel == .standard && config.reviewModel == .standard)
        #expect(config.ignore.isEmpty)
    }
}
