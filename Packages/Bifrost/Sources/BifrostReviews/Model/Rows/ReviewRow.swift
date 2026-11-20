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
    // the user. Only this state flashes, and only while the CI of the PR does not fail.
    case newRequest
    // The user has a pending review on the PR: Claude's draft or the user's own.
    case draftReady
    // Claude suggests Approve and posted nothing: its mark has no draft and is for the head
    // commit. A mark whose draft the user deleted has this state too.
    case reviewed
    // Claude reviewed an older commit than the head: the author pushed new commits after the
    // review. The row shows no verdict and no Approve button, and offers Review.
    case newCommits
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
    // The latest opinion of the user requests changes on the head commit.
    case youRequestedChanges
    // The user commented on the head commit, with no approval or change request on it.
    case youCommented
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
    // Claude has questions for the user: the count of the open questions on comments, and true
    // when the CI question shows (CIRule.visibleQuestion).
    case needsYou(comments: Int, ci: Bool)
    // The work on the PR waits for the user, with the reason (PRState.waitsForYou): an own
    // request that Bifrost did not commit or push, or changes in the worktree that no round made.
    case waitsForYou(String)
    // Like waitsForYou, with a short text and a tip of its own (RowText): the safety net stopped
    // a conflict round for changes that are not on GitHub (Unpushed changes), or the user asked
    // for a change while Claude resolved conflicts (Ask again).
    case unpushedChanges
    // The same for a request round: the tip names new comments, not the base branch.
    case unpushedComments
    case askAgain
    // A request round works on the count of items.
    case fixing(Int)
    // A conflict round works on the merge conflicts.
    case resolvingConflicts
    // A CI round works on the failed checks.
    case fixingCI
    // A round waits in the queue for a free session slot.
    case queued
    // A round waits in the queue for the trust of the clone of its repository.
    case trustNeeded
    // A round waits in the queue for the clone of its repository.
    case cloning
    case waiting
    // The last round failed, with its reason.
    case error(String)
    // Bifrost re-ran the failed jobs of the head and waits for their result
    // (CIRule.isRetrying).
    case retryingCI
    // The PR comes from a fork: Bifrost starts no round for it.
    case fork
    // GitHub says that the PR has conflicts with its base branch. The reason of the failed
    // conflict attempt on this head and base, or nil when no attempt on this pair failed.
    case conflicts(String?)

    // True when the work waits for the user with a reason (PRState.waitsForYou).
    package var waitsForUser: Bool {
        switch self {
        case .waitsForYou, .unpushedChanges, .unpushedComments, .askAgain: true
        default: false
        }
    }

    // True when the row needs the user: open questions, or work that waits for the user. The
    // row then comes first, shows the red box, and makes the tab count red.
    package var needsTheUser: Bool {
        switch self {
        case .needsYou, .waitsForYou, .unpushedChanges, .unpushedComments, .askAgain: true
        case .fixing, .resolvingConflicts, .fixingCI, .queued, .trustNeeded, .cloning, .waiting,
            .error, .retryingCI, .fork, .conflicts:
            false
        }
    }
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

// The kind of a review that the user gives on GitHub: an approval, a comment or a request for
// changes. The progress of a write (ReviewWriteProgress), a review that GitHub confirmed
// (ConfirmedReview) and the review of the user on the head in a poll answer
// (ToReviewRules.reviewOnHead) each have one.
package enum ReviewVerdict: Sendable, Equatable {
    case approve, comment, requestChanges

    // The kind of a send of Claude's draft review with the event.
    package init(_ event: DraftEvent) {
        self = event == .comment ? .comment : .requestChanges
    }
}

// The progress of a review write on its To review row (ReviewWrites.progress): an approval of the
// Approve button, or a send of Claude's draft review in the Review panel. The row shows it in the
// place of its state text and its buttons, and a poll does not remove the row while it has a
// progress.
package enum ReviewWriteProgress: Sendable, Equatable {
    // The fresh reads and the writes run.
    case running(ReviewVerdict)
    // GitHub confirmed the write. The row shows this for ReviewWrites.hold.
    case confirmed(ReviewVerdict)
}

// A review of the user that Bifrost wrote and GitHub confirmed, with the head commit that it is
// on (ReviewWrites.reviewedHere).
package struct ConfirmedReview: Sendable, Equatable {
    package var verdict: ReviewVerdict
    package var head: String

    package init(_ verdict: ReviewVerdict, head: String) {
        self.verdict = verdict
        self.head = head
    }
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
    // To review: the CI state of the PR, or nil when the PR has no checks. Failing CI stops the
    // flash of a new request (flash).
    package var ci: CIState?
    // My PRs: the items that wait for Handle now, the threads of the later Copilot reviews, and
    // the open questions of Claude. A CI question that the row shows counts as one question. The
    // row menu reads them.
    package var waiting: Int
    package var laterCopilot: Int
    package var questions: Int
    // My PRs: true when the writes of an earlier round that stopped wait for Try again (a kept
    // outbox) and no round runs. The row menu can drop them.
    package var unsentUpdates: Bool
    // My PRs: the count of the files that Bifrost found in the copy of the PR, not on GitHub,
    // when the work started to wait for the user (WaitsForYou.files). The row menu offers
    // Discard these changes for them.
    package var unsavedFiles: Int
    // My PRs: true when a click can start a conflict round (Resolve now): GitHub says that the PR
    // has conflicts, the PR does not come from a fork, and no round runs or waits and no writes
    // wait for the PR. The setting of the conflict rounds does not change it.
    package var resolvable: Bool

    package init(
        id: PRKey, state: RowState, repo: String, title: String, dot: RowTone? = nil,
        tag: RowLabel? = nil, review: RowLabel? = nil, reviewers: [Reviewer] = [],
        notes: [String] = [], status: RowLabel, reviewable: Bool = false,
        approve: ApproveOffer? = nil, draft: DraftEvent? = nil, ci: CIState? = nil,
        waiting: Int = 0, laterCopilot: Int = 0, questions: Int = 0, unsentUpdates: Bool = false,
        unsavedFiles: Int = 0, resolvable: Bool = false
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
        self.ci = ci
        self.waiting = waiting
        self.laterCopilot = laterCopilot
        self.questions = questions
        self.unsentUpdates = unsentUpdates
        self.unsavedFiles = unsavedFiles
        self.resolvable = resolvable
    }

    package var tab: ReviewsTab {
        switch state {
        case .toReview: .toReview
        case .mine: .mine
        }
    }

    // Only a new request flashes, and only while its CI does not fail (user decision,
    // 2026-11-19): the user cannot review a PR with failing CI, so it does not need the user now.
    // The flash also makes the To review count red and the attention dot, and the notice of the
    // request waits for it (ReviewsState.recordNotices). The panel stops the flash when the Row
    // flash setting is off.
    package var flash: Bool { state == .toReview(.newRequest) && ci != .failing }

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
        clones: CloneStates = CloneStates(), reviewedHere: [PRKey: ConfirmedReview] = [:],
        now: Date
    ) -> [ReviewRow] {
        ToReviewRules.rows(
            answer, state, config, clones: clones, reviewedHere: reviewedHere, now: now)
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
    // old place or at the end. A held PR has the progress of a review write (ReviewWrites.held),
    // so a poll that drops its PR does not remove the row while the row shows the progress.
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
