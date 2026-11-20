// One pull request as a poll reads it from GitHub (docs/behaviour/reviews.md, "The GitHub data").
// A To review PR carries no reviews, decisions, threads or comments: those lists are empty.
import Foundation

package enum ReviewState: String, Sendable, Equatable {
    case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED", commented = "COMMENTED"
    case dismissed = "DISMISSED", pending = "PENDING"
}

package enum ReviewDecision: String, Sendable, Equatable {
    case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

// Whether the PR merges into its base branch with no conflict, as GitHub tells it. GitHub works
// this out in the background, so a new head or base gives UNKNOWN for a short time.
package enum Mergeable: String, Sendable {
    case mergeable = "MERGEABLE", conflicting = "CONFLICTING", unknown = "UNKNOWN"
}

// The combined result of the checks of the latest commit. A PR with no checks has no value.
package enum CIState: Sendable, Equatable {
    // FAILURE or ERROR, also for an optional check.
    case failing
    // PENDING or EXPECTED, or a result for another commit than the head.
    case running
    case passed

    // The state of the head from the combined result of the checks of the latest commit (state)
    // and the ID of that commit. A result of another commit than the head says nothing about the
    // head, so it counts as running. A missing result or an unknown state gives no value, as for
    // a PR with no checks.
    package init?(rollup state: String?, commit: String?, head: String) {
        switch state {
        case "FAILURE", "ERROR": self = .failing
        case "PENDING", "EXPECTED": self = .running
        case "SUCCESS": self = .passed
        default: return nil
        }
        if !head.isEmpty && commit != head { self = .running }
    }
}

package struct PRComment: Sendable, Equatable {
    package var id: NodeID
    package var databaseID: Int
    package var author: Author
    package var body: String
    package var createdAt: Date
    package var url: URL?
}

package struct PRThread: Sendable, Equatable {
    package var id: NodeID
    package var isResolved: Bool
    package var path: String
    package var line: Int?
    // The review of the first comment of the thread.
    package var reviewID: NodeID?
    package var comments: [PRComment]
}

package struct PRReview: Sendable, Equatable {
    package var id: NodeID
    package var databaseID: Int
    package var author: Author
    package var state: ReviewState
    package var body: String
    package var submittedAt: Date?
    package var commit: String?
    package var url: URL?
}

// A review of the viewer, for the Approve button: its state, its commit and its time.
package struct ViewerOpinion: Sendable, Equatable {
    package var state: ReviewState
    package var commit: String?
    package var submittedAt: Date?
}

package struct PullRequest: Sendable, Equatable {
    package var key: PRKey
    package var title: String
    package var author: String
    package var isDraft: Bool
    package var additions: Int
    package var deletions: Int
    package var createdAt: Date
    package var updatedAt: Date
    package var reviewDecision: ReviewDecision?
    // The logins of the users and the slugs of the teams with an open review request.
    package var requestedUsers: [String]
    package var requestedTeams: [String]
    // True when the viewer is one of the requested users, so the request is not only a team one.
    package var isDirectRequest: Bool
    // The newest request event for the viewer (a direct request) or for any team (a team request),
    // or the creation time when GitHub gave no event.
    package var requestedAt: Date
    // The first 30 reviews.
    package var reviews: [PRReview]
    // The latest opinionated review of each reviewer, so a busy PR keeps its newest decisions.
    package var decisions: [PRReview]
    // The newest 20 threads.
    package var threads: [PRThread]
    package var comments: [PRComment]
    package var failedChecks: Int
    package var ci: CIState?
    // The checks of the newest commit: the first 20 on To review, the first 50 on My PRs.
    package var checks: HeadChecks
    package var headRef: String
    package var headSHA: String
    package var baseRef: String
    // The commit of the base branch, or empty when GitHub gave none. Only a PR of the user reads
    // it.
    package var baseSHA: String
    // The merge state. Only a PR of the user reads it; it is nil on To review and when GitHub gave
    // no known state.
    package var mergeable: Mergeable?
    package var isCrossRepository: Bool
    package var viewerPendingReviewID: NodeID?
    // The latest opinion of the viewer: 0 or 1 review. Only a To review PR reads it.
    package var viewerReviews: [ViewerOpinion]
    // The count of the other reviewers whose latest opinion approves the PR. Only a To review PR
    // reads it.
    package var approvals: Int
    // Each flag is true when the list can lack items: GitHub has more items than the query reads,
    // or Bifrost can't read the list (its nodes or its page info). The threads flag also covers
    // the comments of each thread, and the reviews flag covers the decisions. The checks flag is
    // HeadChecks.cut, so it also covers a rollup or a check node that Bifrost can't read.
    package var truncatedThreads: Bool
    package var truncatedReviews: Bool
    package var truncatedComments: Bool
    package var truncatedChecks: Bool

    package var url: URL { key.webURL }
}
