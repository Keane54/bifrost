import Foundation
import Testing

@testable import BifrostReviews

// The PRs, the authors and the times of the row tests. Each test uses the fixed now and builds
// its PRs here. No row text uses a time zone, so the tests need no zone.

enum Rows {
    static let viewer = "viewer-a"
    // 2026-11-10 12:00:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_794_312_000)
    // The head commit of each PR of the tests.
    static let head = String(repeating: "a", count: 40)

    // The time that is the count of minutes after now (before now for a negative count).
    static func at(_ minutes: Double) -> Date {
        now.addingTimeInterval(minutes * 60)
    }

    static func key(_ text: String) throws -> PRKey {
        try #require(PRKey(text: text))
    }

    static func node(_ text: String) throws -> NodeID {
        try #require(NodeID(text))
    }

    static func commit(_ character: Character) throws -> CommitID {
        try #require(CommitID(String(repeating: character, count: 40)))
    }

    static func person(_ login: String, _ association: AuthorAssociation = .member) -> Author {
        Author(login: login, isBot: false, association: association)
    }

    static let copilot = Author(
        login: Authors.copilotLogin, isBot: true, association: AuthorAssociation.none)

    static func comment(
        _ id: String, by author: Author, at time: Date = Rows.at(-120), body: String = "A note."
    ) throws -> PRComment {
        PRComment(
            id: try node(id), databaseID: 1, author: author, body: body, createdAt: time, url: nil)
    }

    static func thread(
        _ id: String, by author: Author, at time: Date = Rows.at(-120), resolved: Bool = false,
        review: String? = nil, replies: [PRComment] = []
    ) throws -> PRThread {
        PRThread(
            id: try node(id), isResolved: resolved, path: "src/a.swift", line: 4,
            reviewID: try review.map(node),
            comments: [try comment("\(id)c", by: author, at: time)] + replies)
    }

    static func review(
        _ id: String, by author: Author, _ state: ReviewState, at time: Date? = Rows.at(-120),
        body: String = ""
    ) throws -> PRReview {
        PRReview(
            id: try node(id), databaseID: 1, author: author, state: state, body: body,
            submittedAt: time, commit: head, url: nil)
    }

    // A PR of the To review tab or of the My PRs tab. A direct request names the viewer, and a
    // team request names only a team.
    static func pull(
        _ text: String, title: String = "A change", author: String = "user-a",
        direct: Bool = true, requestedAt: Date = Rows.at(-60), updatedAt: Date = Rows.at(-30),
        decision: ReviewDecision? = nil, ci: CIState? = nil, pending: String? = nil,
        viewerReviews: [ViewerOpinion] = [], approvals: Int = 0, reviewers: [String] = [],
        reviews: [PRReview] = [], decisions: [PRReview] = [], threads: [PRThread] = [],
        comments: [PRComment] = [], failedChecks: Int = 0, fork: Bool = false,
        cutThreads: Bool = false
    ) throws -> PullRequest {
        PullRequest(
            key: try key(text), title: title, author: author, isDraft: false, additions: 12,
            deletions: 3, createdAt: at(-600), updatedAt: updatedAt, reviewDecision: decision,
            requestedUsers: (direct ? [viewer] : []) + reviewers,
            requestedTeams: direct ? [] : ["team-a"], isDirectRequest: direct,
            requestedAt: requestedAt, reviews: reviews, decisions: decisions, threads: threads,
            comments: comments, failedChecks: failedChecks, ci: ci, headRef: "feature",
            headSHA: head, baseRef: "main", isCrossRepository: fork,
            viewerPendingReviewID: try pending.map(node), viewerReviews: viewerReviews,
            approvals: approvals, truncatedThreads: cutThreads, truncatedReviews: false,
            truncatedComments: false, truncatedChecks: false)
    }

    // A state after the first turn-on one day ago, with no request seen yet.
    static func turnedOn() -> ReviewsState {
        var state = ReviewsState()
        state.turnedOnAt = at(-60 * 24)
        return state
    }

    static func answer(
        toReview: [PullRequest] = [], mine: [PullRequest] = [], cut: Bool = false,
        errors: [String] = []
    ) -> PollAnswer {
        PollAnswer(
            viewer: viewer, toReview: toReview, mine: mine, toReviewCut: cut, errors: errors)
    }

    static func toReview(
        _ answer: PollAnswer, _ state: ReviewsState, _ config: ReviewsConfig = ReviewsConfig(),
        clones: CloneStates = CloneStates()
    ) -> [ReviewRow] {
        ReviewRows.toReview(answer, state, config, clones: clones, now: now)
    }

    static func mine(
        _ answer: PollAnswer, _ state: ReviewsState, _ config: ReviewsConfig = ReviewsConfig(),
        clones: CloneStates = CloneStates()
    ) -> [ReviewRow] {
        ReviewRows.mine(answer, state, config, clones: clones, now: now)
    }
}

extension ReviewRow {
    // The state of a To review row, or nil for a My PRs row.
    var toReviewState: ToReviewState? {
        if case .toReview(let state) = state { return state }
        return nil
    }

    // The status and the Claude state of a My PRs row, or nil for a To review row.
    var mineState: (status: ReviewStatus, claude: ClaudeState)? {
        if case .mine(let status, let claude) = state { return (status, claude) }
        return nil
    }
}
