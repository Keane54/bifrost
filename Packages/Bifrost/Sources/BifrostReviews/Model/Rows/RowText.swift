// The texts, the tips and the colours of the rows (docs/behaviour/reviews.md, "The rows"). The
// texts are in-app texts: friendly, plain English.
import Foundation

package enum RowText {
    // MARK: - Line 2

    // How long ago a time was: under one minute is "just now", then "5m ago", "3h ago", "2d ago".
    package static func age(_ span: Duration) -> String {
        let seconds = span.components.seconds
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    // The size of a PR: "+12 −3", with the minus sign U+2212.
    package static func size(additions: Int, deletions: Int) -> String {
        "+\(additions) \u{2212}\(deletions)"
    }

    // The span from the time to now.
    static func span(since time: Date, now: Date) -> Duration {
        .seconds(now.timeIntervalSince(time))
    }

    // MARK: - To review

    static let team = RowLabel(text: "team", tone: .dim, tip: nil)

    // The text on the right of a To review row in its state. A new request shows its buttons
    // instead, so it has no text. A pause shows the minutes left, at least 1.
    package static func toReview(_ state: ToReviewState, now: Date) -> String {
        switch state {
        case .newRequest: ""
        case .draftReady: "Draft ready"
        case .reviewed: "Looks good"
        case .failed: "Review failed"
        case .waitingForYou: "Waiting for you"
        case .trustNeeded: "Trust needed"
        case .reviewing: "Reviewing"
        case .queued: "Queued"
        case .paused(let until):
            "Paused \(max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up))))m"
        case .youApproved: "You approved"
        case .approvedByOthers: "Approved by others"
        case .teamRequest: "Team request"
        }
    }

    // The tip of the text of a state, or nil.
    static func tip(_ state: ToReviewState) -> String? {
        switch state {
        case .failed(let reason): reason
        case .queued: "Waiting for a free review slot."
        case .reviewing: "Claude is reviewing this pull request."
        case .youApproved: "You approved this pull request on GitHub."
        case .trustNeeded: trustTip
        case .newRequest, .draftReady, .reviewed, .waitingForYou, .paused, .approvedByOthers,
            .teamRequest:
            nil
        }
    }

    // The tip of a row whose work waits for the trust of its repository.
    static let trustTip =
        "Bifrost needs you to trust this repository first. Click Trust at the top of the panel."

    static let ciFailing = "CI failing"
    static let ciRunning = "CI running"
    static let ciFailingTip =
        "CI is failing on this pull request, so Bifrost won't review or approve it. It can be "
        + "reviewed again when CI passes."
    static let ciRunningTip =
        "CI is still running. Claude can review now, but you can approve only when it has passed."

    // The text of Claude's result on the right of a row, and the colour of the text and of the
    // dot.
    static func text(_ result: ClaudeResult) -> RowLabel {
        switch result {
        case .approve: RowLabel(text: "Approval recommended", tone: .green, tip: nil)
        case .comment: RowLabel(text: "Draft ready", tone: .amber, tip: nil)
        case .changes: RowLabel(text: "Changes required", tone: .red, tip: nil)
        case .deleted:
            RowLabel(
                text: "Draft deleted", tone: .dim,
                tip: "You deleted Claude's draft. Click Approve to approve this pull request.")
        case .others: RowLabel(text: "Approved by others", tone: .dim, tip: nil)
        }
    }

    // The tip of a mark of Claude: what Claude suggests and why, and what to do next.
    static func suggestion(_ mark: RecommendationMark, _ state: ToReviewState) -> String? {
        let why = mark.why.isEmpty ? "" : " \(mark.why)"
        switch state {
        case .reviewed:
            return "Claude suggests: Approve.\(why) Nothing was posted."
        case .draftReady:
            let name = recommendation(mark.value)
            let next =
                mark.value == .approve
                ? "Click Approve to submit Claude's draft as an approval."
                : "Click \(name) to check the draft and send it."
            return "Claude suggests: \(name).\(why) \(next)"
        case .newRequest, .failed, .waitingForYou, .trustNeeded, .reviewing, .queued, .paused,
            .youApproved, .approvedByOthers, .teamRequest:
            return nil
        }
    }

    package static func recommendation(_ value: Recommendation) -> String {
        switch value {
        case .approve: "Approve"
        case .comment: "Comment"
        case .requestChanges: "Request changes"
        }
    }

    // The line of Claude's result in place of the author, the size and the age.
    static func line(_ result: ClaudeResult, drafted: Drafted?, approvals: Int) -> String {
        switch result {
        case .deleted:
            return "You deleted Claude's draft. Approve when you're ready."
        case .others:
            let who = approvals == 0 ? "Others" : count(approvals, "person", "people")
            return "\(who) approved it, so you don't need to review it."
        case .approve, .comment, .changes:
            guard let drafted else { return "Claude drafted a review." }
            let comments = count(drafted.comments, "comment", "comments")
            if drafted.summary && drafted.comments > 0 {
                return "Claude drafted a summary and \(comments)."
            }
            if drafted.summary { return "Claude drafted a summary." }
            return drafted.comments > 0
                ? "Claude drafted \(comments)." : "Claude found nothing to change."
        }
    }

    // MARK: - My PRs

    // The review status, with the tip of a PR whose lists GitHub cut.
    package static func status(_ status: ReviewStatus, cut: Bool) -> RowLabel {
        let tip = cut ? "Bifrost read only the newest items of this PR." : nil
        return switch status {
        case .changesRequested: RowLabel(text: "Changes requested", tone: .red, tip: tip)
        case .comments: RowLabel(text: "Comments", tone: .blue, tip: tip)
        case .approved: RowLabel(text: "Approved", tone: .green, tip: tip)
        case .pending: RowLabel(text: "Pending", tone: .dim, tip: tip)
        }
    }

    static let forkReason =
        "This pull request comes from a fork. Bifrost can't push there, so Claude leaves its "
        + "comments to you."

    // The Claude state on the right of a My PRs row.
    package static func claude(_ state: ClaudeState) -> RowLabel {
        switch state {
        case .needsYou(let questions):
            RowLabel(
                text: "Needs you", tone: .red,
                tip: "Claude needs your answer on \(count(questions, "comment", "comments")). "
                    + "Click to answer.")
        case .fixing(let items):
            RowLabel(
                text: "Fixing \(items)", tone: .plain,
                tip: "Claude is working on \(count(items, "comment", "comments")).")
        case .queued:
            RowLabel(text: "Queued", tone: .dim, tip: "Waiting for a free session slot.")
        case .trustNeeded:
            RowLabel(text: "Trust needed", tone: .dim, tip: trustTip)
        case .cloning:
            RowLabel(text: "Cloning", tone: .dim, tip: "Bifrost is copying this repository.")
        case .waiting:
            RowLabel(text: "Waiting", tone: .dim, tip: nil)
        case .error(let reason):
            RowLabel(text: "Error", tone: .red, tip: reason)
        case .fork:
            RowLabel(text: "Fork", tone: .dim, tip: forkReason)
        }
    }

    // The cross after the title of a PR with failed checks.
    static func failedChecks(_ count: Int) -> RowLabel {
        RowLabel(
            text: "\u{2715}", tone: .red, tip: "\(Self.count(count, "check", "checks")) failed")
    }

    static func laterCopilot(_ count: Int) -> String {
        "Copilot: \(count) more"
    }

    static func older(_ count: Int) -> String {
        "\(Self.count(count, "older comment", "older comments"))"
    }

    // "1 comment", "2 comments".
    private static func count(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }
}

// The kind of a result of Claude on a To review row: Claude suggests Approve, Claude drafted a
// comment or a request for changes, the user deleted Claude's draft, or others approved the PR.
enum ClaudeResult: Sendable, Equatable {
    case approve, comment, changes, deleted, others

    // The colour of the dot before the repository.
    var dot: RowTone { RowText.text(self).tone }
}

// What Claude drafted for a mark: a summary or not, and the count of comments on lines.
struct Drafted: Sendable, Equatable {
    var summary: Bool
    var comments: Int
}
