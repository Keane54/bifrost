// The settings of Reviews in the types of the rules and the services (docs/behaviour/reviews.md,
// "The rows"). The app makes it from the settings. The defaults are the defaults of the settings.
import BifrostSessions

package struct ReviewsConfig: Sendable, Equatable {
    package var watch: Bool
    // "Handle comments on my PRs automatically".
    package var autoFix: Bool
    package var teamRequests: Bool
    package var signedCommits: Bool
    // The Row flash setting of the look. The panel applies it to the flash of a row.
    package var rowFlash: Bool
    package var notifications: Bool
    package var maxSessions: Int
    package var pause: Duration
    package var pollInterval: Duration
    package var requestModel: ModelChoice
    package var reviewModel: ModelChoice
    package var ignore: [IgnoreEntry]

    package init(
        watch: Bool = false, autoFix: Bool = true, teamRequests: Bool = true,
        signedCommits: Bool = false, rowFlash: Bool = true, notifications: Bool = true,
        maxSessions: Int = 3, pause: Duration = .seconds(3600),
        pollInterval: Duration = .seconds(120), requestModel: ModelChoice = .standard,
        reviewModel: ModelChoice = .standard, ignore: [IgnoreEntry] = []
    ) {
        self.watch = watch
        self.autoFix = autoFix
        self.teamRequests = teamRequests
        self.signedCommits = signedCommits
        self.rowFlash = rowFlash
        self.notifications = notifications
        self.maxSessions = maxSessions
        self.pause = pause
        self.pollInterval = pollInterval
        self.requestModel = requestModel
        self.reviewModel = reviewModel
        self.ignore = ignore
    }
}
