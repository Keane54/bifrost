// The labels of the rows of Settings > Reviews (docs/behaviour/reviews.md, "Settings > Reviews").
// This list is the one source of the labels: each row shows its label, and the search finds a
// row only by its label.

// The rows of Settings > Reviews, in the order of the rows in the section. The raw value is the
// label of the row.
package enum ReviewsSettingsRow: String, Sendable, CaseIterable {
    case watch = "Watch GitHub"
    case autoFix = "Handle comments on my PRs automatically"
    case resolveConflicts = "Resolve merge conflicts automatically"
    case fixCI = "Fix failing CI automatically"
    case signedCommits = "Sign commits through GitHub"
    case teamRequests = "Show team requests"
    case maxSessions = "Maximum PR sessions"
    case pauseTime = "Pause time"
    case pollInterval = "GitHub poll interval"
    case requestModel = "Model for request sessions"
    case reviewModel = "Model for review sessions"
    case ignore = "Repositories to ignore"
    case removeClones = "Remove all clones"

    // The rows that the section shows and the search finds. The Fix CI row stays hidden until the
    // CI watcher exists.
    package static var shown: [ReviewsSettingsRow] { allCases.filter { $0 != .fixCI } }

    // The row of the save tracker. The search finds the row by its label.
    package var row: SettingsRowID { SettingsRowID(.reviews, .found(rawValue)) }
}
