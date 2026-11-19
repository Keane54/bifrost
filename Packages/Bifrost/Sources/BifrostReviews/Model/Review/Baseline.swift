// The baseline of a review (docs/behaviour/reviews.md, "Review rounds"): what the review session
// looks at when the author asks the user for a review again. The baseline is the last submitted
// review of the user on the PR (ReviewContext.lastSubmittedReview): a pending review and a review
// that holds only replies do not count.
// - No baseline: a first review of the full diff.
// - The baseline is on the head commit: the full diff, with the note "unchanged".
// - The baseline is on an ancestor of the head: a re-review of the changes since that commit,
//   with a check of the earlier threads and summaries of the user.
// - The author rewrote the history, or Bifrost cannot find the commit of the baseline: the full
//   diff, with the note "rewritten" and a check of the earlier threads and summaries.

package enum ReviewKind: String, Sendable, Equatable {
    case first
    case reReview = "re-review"
}

package enum BaselineNote: String, Sendable, Equatable {
    case unchanged, rewritten
}

package struct Baseline: Sendable, Equatable {
    package var kind: ReviewKind
    // The commit of the last review of a re-review, else nil.
    package var since: CommitID?
    package var note: BaselineNote?

    package init(kind: ReviewKind, since: CommitID? = nil, note: BaselineNote? = nil) {
        self.kind = kind
        self.since = since
        self.note = note
    }

    // The baseline of a review of the head. last is the last submitted review of the user, or
    // nil. isAncestor is true when git found that the commit of that review is an ancestor of the
    // head (GitCommand.isAncestor); false when it is not, or when git cannot find the commit.
    package static func of(last: ViewerReview?, head: CommitID, isAncestor: Bool) -> Baseline {
        guard let last else { return Baseline(kind: .first) }
        guard let commit = last.commit else { return Baseline(kind: .first, note: .rewritten) }
        if commit == head { return Baseline(kind: .first, note: .unchanged) }
        guard isAncestor else { return Baseline(kind: .first, note: .rewritten) }
        return Baseline(kind: .reReview, since: commit)
    }

    // True when the review checks the earlier threads and summaries of the user.
    package var checksEarlier: Bool { kind == .reReview || note == .rewritten }

    // The commit that git must check as an ancestor of the head: the commit of the last review,
    // when it is not the head. nil when the baseline needs no check.
    package static func ancestorToCheck(last: ViewerReview?, head: CommitID) -> CommitID? {
        guard let commit = last?.commit, commit != head else { return nil }
        return commit
    }
}
