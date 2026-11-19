// The pending review of a review round (docs/behaviour/reviews.md, "Review rounds"): what Bifrost
// writes on GitHub for a good result. Only the user submits the review.
// - GitHub refuses a whole review when one comment is on a line that the diff does not show, so
//   such a comment moves into the summary, with its path and its line, after the summary of the
//   session (user decision, 2026-11-11).
// - With no pending review of the user, Bifrost creates one on the reviewed commit, with the
//   summary and the comments.
// - With a pending review of the user, Bifrost adds each comment to it as a new thread, and puts
//   its summary below the text of the user after a blank line (user decision, 2026-11-11). A
//   thread goes on the commit of that review, so a review on another commit fails the round and
//   nothing is posted.
// - An Approve with no summary and no comments posts nothing.
import BifrostFoundation

// The result with each comment in its place: the comments on lines of the diff, and the summary
// with the moved comments.
package struct PlacedReview: Sendable, Equatable {
    package var summary: String
    package var comments: [DraftComment]
    // The count of the comments that moved into the summary.
    package var moved: Int
}

package enum PendingReviewPlan: Sendable, Equatable {
    // An Approve with nothing to say: no write.
    case nothing
    // A new pending review on the reviewed commit.
    case create(body: String, comments: [DraftComment])
    // New threads on the pending review of the user, then its new body. body is nil when there
    // is no summary to add.
    case add(review: NodeID, comments: [DraftComment], body: String?)

    // Move each comment that the diff does not show into the summary. The summary of the
    // session stays first, and each moved comment is a paragraph: its path as code, its line and
    // its body.
    package static func place(_ outcome: ReviewOutcome, diff: [DiffFile]) -> PlacedReview {
        var kept: [DraftComment] = []
        var parts = outcome.summary.trimmed().isEmpty ? [] : [outcome.summary]
        for comment in outcome.comments {
            if DiffLines.shows(diff, comment) {
                kept.append(comment)
            } else {
                parts.append("\(codeSpan(comment.path)) line \(comment.line): \(comment.body)")
            }
        }
        return PlacedReview(
            summary: parts.joined(separator: "\n\n"), comments: kept,
            moved: outcome.comments.count - kept.count)
    }

    // The writes for the result on the reviewed head, with the pending review of the user from a
    // read after the session ended.
    package static func plan(
        _ outcome: ReviewOutcome, diff: [DiffFile], head: CommitID, pending: PendingDraft?
    ) throws(RoundFailure) -> PendingReviewPlan {
        let placed = place(outcome, diff: diff)
        let hasSummary = !placed.summary.trimmed().isEmpty
        guard hasSummary || !placed.comments.isEmpty else { return .nothing }
        guard let pending else {
            if placed.summary.utf16.count > ReviewResult.maxReviewBody { throw .summaryTooLong }
            return .create(body: hasSummary ? placed.summary : "", comments: placed.comments)
        }
        guard pending.commit == head else { throw .otherCommit }
        guard hasSummary else {
            return .add(review: pending.id, comments: placed.comments, body: nil)
        }
        let draft = !pending.body.trimmed().isEmpty
        let body = draft ? "\(pending.body)\n\n\(placed.summary)" : placed.summary
        if body.utf16.count > ReviewResult.maxReviewBody {
            throw draft ? .draftTooLong : .summaryTooLong
        }
        return .add(review: pending.id, comments: placed.comments, body: body)
    }

    // A code span for a path, which the author of the PR chose. The fence is one backtick longer
    // than the longest run of backticks in the path, so the path cannot end the span. A line
    // break becomes a space.
    static func codeSpan(_ path: String) -> String {
        let flat = path.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .joined(separator: " ")
        var longest = 0
        var run = 0
        for character in flat {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let pad = flat.hasPrefix("`") || flat.hasSuffix("`") ? " " : ""
        return fence + pad + flat + pad + fence
    }
}
