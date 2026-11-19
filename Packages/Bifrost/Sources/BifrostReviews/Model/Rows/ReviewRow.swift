// The rows of the Reviews panel (docs/behaviour/reviews.md, "The rows"). A pure function of the
// last poll answer, the Reviews state, the settings and the time makes the rows of each tab:
// ToReviewRules and MyPRRules hold the rules, and RowText holds the texts.
import Foundation

package enum ReviewsTab: Sendable {
    case toReview, mine
}

// The state of a To review row. ToReviewRules.order gives the order of the groups of the tab.
package enum ToReviewState: Sendable, Equatable {
    // A direct request that came after the first turn-on, with no session, no pause and no act of
    // the user. Only this state flashes.
    case newRequest
    // The user has a pending review on the PR: Claude's draft or the user's own.
    case draftReady
    // Claude suggests Approve and posted nothing: its mark has no draft and is for the head
    // commit. A mark whose draft the user deleted has this state too.
    case reviewed
    // The last review round failed, with its reason.
    case failed(String)
    // A direct request that was open at the first turn-on, or that the user acted on.
    case waitingForYou
    // A review waits in the queue for the trust of the clone of its repository.
    case trustNeeded
    case reviewing
    case queued
    // The flash waits until the end of the pause.
    case paused(until: Date)
    // The latest opinion of the user approves the head commit.
    case youApproved
    // GitHub's review decision is APPROVED, so the approval of the user changes nothing.
    case approvedByOthers
    // A request for a team of the user only.
    case teamRequest
}

// The review status of a My PRs row.
package enum ReviewStatus: Sendable {
    case changesRequested, comments, approved, pending
}

// What Claude does on a PR of the user.
package enum ClaudeState: Sendable, Equatable {
    // Claude has open questions for the user: their count.
    case needsYou(Int)
    // A request round works on the count of items.
    case fixing(Int)
    // A request round waits in the queue for a free session slot.
    case queued
    // A request round waits in the queue for the trust of the clone of its repository.
    case trustNeeded
    // A request round waits in the queue for the clone of its repository.
    case cloning
    case waiting
    // The last round failed, with its reason.
    case error(String)
    // The PR comes from a fork: Bifrost starts no round for it.
    case fork
}

// The colour of a text, a dot or a name of a row. The panel gives each one a colour of the look.
package enum RowTone: Sendable, Equatable {
    // The soft green of an approval.
    case green
    // The amber of a comment.
    case amber
    // The red of a change request, a failure, failing CI or Needs you.
    case red
    // The blue of the Comments status.
    case blue
    case plain
    case dim
}

// A text of a row with its colour and its tip.
package struct RowLabel: Sendable, Equatable {
    package var text: String
    package var tone: RowTone
    package var tip: String?

    package init(text: String, tone: RowTone, tip: String?) {
        self.text = text
        self.tone = tone
        self.tip = tip
    }
}

// A reviewer of a My PRs row, with the colour of the latest opinion.
package struct Reviewer: Sendable, Equatable {
    package var name: String
    package var tone: RowTone

    package init(name: String, tone: RowTone) {
        self.name = name
        self.tone = tone
    }
}

// The Approve button of a To review row: it approves now, or it waits until CI has passed.
package enum ApproveOffer: Sendable, Equatable {
    case ready, waitsForCI
}

// The progress of an approval on its To review row (ApproveFlow.progress). The row shows it in
// the place of its buttons, and a poll does not remove the row while it has a progress.
package enum ApproveProgress: Sendable, Equatable {
    // The fresh read and the write run.
    case approving
    // GitHub confirmed the approval. The row shows this for ApproveFlow.hold.
    case approved
}

// The state of a row in its tab.
package enum RowState: Sendable, Equatable {
    case toReview(ToReviewState)
    case mine(ReviewStatus, ClaudeState)
}

// One row of the panel: two lines. Line 1 has the repository, the number and the title. Line 2
// has the notes on the left and the status on the right.
package struct ReviewRow: Sendable, Equatable, Identifiable {
    package var id: PRKey
    package var state: RowState
    // Line 1. repo is the name of the repository, without the owner. dot is the colour of
    // Claude's result before the repository (To review). tag follows the title: "team" for a team
    // request (To review), or the cross of failed checks (My PRs).
    package var repo: String
    package var title: String
    package var dot: RowTone?
    package var tag: RowLabel?
    // Line 2, from the left. review is the review status (My PRs), and the reviewers follow it.
    // notes are the other texts: the author, the size and the age, or the line of Claude's
    // result (To review); the later Copilot comments and the older comments (My PRs). status is
    // the text on the right, with its colour and its tip. A new request has no text there: the
    // panel shows its buttons.
    package var review: RowLabel?
    package var reviewers: [Reviewer]
    package var notes: [String]
    package var status: RowLabel
    // True when a review round can start on the row (To review): no round runs or waits, CI does
    // not fail, and the pending review of the user is not Claude's draft, which a new round would
    // fill a second time.
    package var reviewable: Bool
    // To review: the Approve button, or nil (ToReviewRules.approveOffer). draft is the event of
    // Claude's draft review when the row offers the Review panel for it (Comment or Request
    // changes), or nil.
    package var approve: ApproveOffer?
    package var draft: DraftEvent?
    // My PRs: the items that wait for Handle now, the threads of the later Copilot reviews, and
    // the open questions of Claude. The row menu reads them.
    package var waiting: Int
    package var laterCopilot: Int
    package var questions: Int
    // My PRs: true when the writes of an earlier round that stopped wait for Try again (a kept
    // outbox) and no round runs. The row menu can drop them.
    package var unsentUpdates: Bool

    package init(
        id: PRKey, state: RowState, repo: String, title: String, dot: RowTone? = nil,
        tag: RowLabel? = nil, review: RowLabel? = nil, reviewers: [Reviewer] = [],
        notes: [String] = [], status: RowLabel, reviewable: Bool = false,
        approve: ApproveOffer? = nil, draft: DraftEvent? = nil, waiting: Int = 0,
        laterCopilot: Int = 0, questions: Int = 0, unsentUpdates: Bool = false
    ) {
        self.id = id
        self.state = state
        self.repo = repo
        self.title = title
        self.dot = dot
        self.tag = tag
        self.review = review
        self.reviewers = reviewers
        self.notes = notes
        self.status = status
        self.reviewable = reviewable
        self.approve = approve
        self.draft = draft
        self.waiting = waiting
        self.laterCopilot = laterCopilot
        self.questions = questions
        self.unsentUpdates = unsentUpdates
    }

    package var tab: ReviewsTab {
        switch state {
        case .toReview: .toReview
        case .mine: .mine
        }
    }

    // Only a new request flashes. The panel stops the flash when the Row flash setting is off.
    package var flash: Bool { state == .toReview(.newRequest) }

    // Remove hides only a row that others approved (ReviewsState.hide).
    package var isRemovable: Bool { state == .toReview(.approvedByOthers) }
}

// What Reviews knows of the clones of the repositories, for the rows (docs/behaviour/reviews.md,
// "Clones and trust"): the clones that run now, and the clones that wait for the trust of the
// user. A queued round of such a repository waits, and its row says why.
package struct CloneStates: Sendable, Equatable {
    package var cloning: Set<RepoName>
    package var needsTrust: Set<RepoName>

    package init(cloning: Set<RepoName> = [], needsTrust: Set<RepoName> = []) {
        self.cloning = cloning
        self.needsTrust = needsTrust
    }
}

package enum ReviewRows {
    // The To review rows: the requests of the answer that are not ignored, removed or hidden by
    // the team filter, in the order of the groups, then the oldest request first. Paused rows
    // sort by the end of the pause.
    package static func toReview(
        _ answer: PollAnswer, _ state: ReviewsState, _ config: ReviewsConfig,
        clones: CloneStates = CloneStates(), now: Date
    ) -> [ReviewRow] {
        ToReviewRules.rows(answer, state, config, clones: clones, now: now)
    }

    // The My PRs rows: the PRs of the user that are not ignored. A row that needs the user comes
    // first, then the groups of the review status, then the last update first.
    package static func mine(
        _ answer: PollAnswer, _ state: ReviewsState, _ config: ReviewsConfig,
        clones: CloneStates = CloneStates(), now: Date
    ) -> [ReviewRow] {
        MyPRRules.rows(answer, state, config, clones: clones)
    }

    // The new To review rows, with each old row of a held PR that the new rows do not have, at its
    // old place or at the end. A held PR has an approval progress (ApproveFlow.held), so a poll
    // that drops its PR does not remove the row while the row shows the progress.
    package static func holding(
        _ held: Set<PRKey>, old: [ReviewRow], new: [ReviewRow]
    ) -> [ReviewRow] {
        guard !held.isEmpty else { return new }
        let present = Set(new.map(\.id))
        var rows = new
        for (index, row) in old.enumerated()
        where held.contains(row.id) && !present.contains(row.id) {
            rows.insert(row, at: min(index, rows.count))
        }
        return rows
    }

    // True when the poll brings the request as new, so its row flashes: a request that Bifrost
    // has not seen and that came after the first turn-on, or a direct request that came again
    // after Bifrost first saw it. Before the first turn-on, no request is new.
    package static func isNewRequest(_ pr: PullRequest, _ state: ReviewsState) -> Bool {
        guard let turnedOnAt = state.turnedOnAt else { return false }
        guard let mark = state.requests[pr.key] else { return pr.requestedAt >= turnedOnAt }
        return pr.isDirectRequest && pr.requestedAt > mark.firstSeen
    }
}
