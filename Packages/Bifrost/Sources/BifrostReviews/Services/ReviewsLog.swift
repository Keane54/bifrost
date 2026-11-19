import BifrostFoundation
import OSLog

// What the Reviews watcher and the repo store log. Each case is one line of the log.
package enum ReviewsLogEvent: Sendable, Equatable {
    // The watcher starts to poll. interval is the wait between two polls.
    case started(interval: Duration)
    // The watcher stopped: Watch GitHub is off, or the app quits.
    case stopped
    // A poll failed. The watcher logs only a change of the failure, so a failure that lasts does
    // not fill the log.
    case pollFailed(GitHubError)
    // Reviews does not start, because the store did not open.
    case notStarted(ReviewsStoreError)
    // The clone of the repository failed. The repo store logs only the first failure of a row
    // of failures, so a clone that fails at each poll does not fill the log.
    case cloneFailed(RepoName, RepoError)
    // The reset of the worktree of the PR after a round removed this count of changes.
    case worktreeReset(PRKey, changes: Int)
}

// Where the Reviews watcher sends its events. The app uses SystemReviewsLog. A test records the
// events.
package protocol ReviewsLog: Sendable {
    func record(_ event: ReviewsLogEvent)
}

// The log of Reviews in the unified log of macOS. The text of a GitHub failure is private.
package struct SystemReviewsLog: ReviewsLog {
    private static let logger = Logger(bifrost: "reviews")

    package init() {}

    package func record(_ event: ReviewsLogEvent) {
        let logger = Self.logger
        switch event {
        case .started(let interval):
            logger.info(
                "Bifrost watches GitHub. It polls each \(interval.description, privacy: .public).")
        case .stopped:
            logger.info("Bifrost stopped to watch GitHub.")
        case .pollFailed(let failure):
            logger.error("A poll of GitHub failed. \(failure.message, privacy: .private)")
        case .notStarted(let failure):
            logger.error("Reviews did not start. \(failure.message, privacy: .private)")
        case .cloneFailed(let repo, let failure):
            logger.error(
                """
                The clone of \(repo.description, privacy: .private) failed. \
                \(failure.message, privacy: .private)
                """)
        case .worktreeReset(let pr, let changes):
            logger.info(
                """
                The reset of the worktree of \(pr.text, privacy: .private) removed \
                \(changes, privacy: .public) changes.
                """)
        }
    }
}
