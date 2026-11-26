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
        case .newCommits: "New commits"
        case .failed: "Review failed"
        case .waitingForYou: "Waiting for you"
        case .trustNeeded: "Trust needed"
        case .reviewing: "Reviewing"
        case .queued: "Queued"
        case .paused(let until):
            "Paused \(max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up))))m"
        case .youApproved: "You approved"
        case .youRequestedChanges: "You requested changes"
        case .youCommented: "You commented"
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
        case .youRequestedChanges: "You requested changes on this pull request on GitHub."
        case .youCommented: "You commented on this pull request on GitHub."
        case .trustNeeded: trustTip
        case .newCommits: newCommitsTip
        case .newRequest, .draftReady, .reviewed, .waitingForYou, .paused, .approvedByOthers,
            .teamRequest:
            nil
        }
    }

    // The tip of a row whose Claude review is on an older commit than the head.
    static let newCommitsTip =
        "Claude reviewed an older commit. Review again to check the new changes."

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

    // The tip of a mark of Claude: what Claude suggests and why, and what to do next, in one flow
    // of text. On a Looks good row, the next step follows the findings: nothing, only nits (which
    // Approve does not post), or a finding above a nit (Approve opens the Review panel).
    static func suggestion(_ mark: RecommendationMark, _ state: ToReviewState) -> String? {
        let name = recommendation(mark.value)
        switch state {
        case .reviewed:
            if mark.findings.isEmpty { return sentence(name, mark.why) }
            guard mark.findings.aboveNits else {
                return "\(clause(name, mark.why)), so approving won't post nits. To read them, "
                    + "check Claude's review from the menu."
            }
            return "\(sentence(name, mark.why)) Click Approve to check Claude's findings."
        case .draftReady:
            let next =
                mark.value == .approve
                ? "Click Approve to check Claude's draft."
                : "Click \(name) to check the draft and send it."
            return "\(sentence(name, mark.why)) \(next)"
        case .newRequest, .newCommits, .failed, .waitingForYou, .trustNeeded, .reviewing, .queued,
            .paused, .youApproved, .youRequestedChanges, .youCommented, .approvedByOthers,
            .teamRequest:
            return nil
        }
    }

    // "Claude suggests: <name> - <why>", or "Claude suggests: <name>" with no why. The review
    // skill asks for a why in lower case with no full stop at the end (bifrost-mode.md), so this
    // text adds the punctuation. A why of an old result keeps its capital letter.
    private static func clause(_ name: String, _ why: String) -> String {
        guard !why.isEmpty else { return "Claude suggests: \(name)" }
        // A comma follows the clause, so a full stop at the end of the why goes.
        let reason = why.hasSuffix(".") ? String(why.dropLast()) : why
        return "Claude suggests: \(name) - \(reason)"
    }

    // The recommendation line as a sentence. A why that ends a sentence gets no second full stop.
    private static func sentence(_ name: String, _ why: String) -> String {
        "Claude suggests: \(name)\(sentenceEnd(why))"
    }

    // The end of the recommendation line after the name: " - <why>." or "." with no why. A why
    // that ends a sentence gets no second full stop. The Review panel shows the line with the
    // name in its colour.
    package static func sentenceEnd(_ why: String) -> String {
        guard !why.isEmpty else { return "." }
        let ends = why.hasSuffix(".") || why.hasSuffix("!") || why.hasSuffix("?")
        return " - \(why)\(ends ? "" : ".")"
    }

    package static func recommendation(_ value: Recommendation) -> String {
        switch value {
        case .approve: "Approve"
        case .comment: "Comment"
        case .requestChanges: "Request changes"
        }
    }

    // The progress of a review write on its row, in the place of the state text and the buttons:
    // "Approving…", "Commenting…" or "Requesting changes…" in the text colour while the write
    // runs, then "Approved", "Commented" or "Changes requested" in the colour of the review.
    package static func progress(_ progress: ReviewWriteProgress) -> RowLabel {
        switch progress {
        case .running(let review):
            let text =
                switch review {
                case .approve: "Approving"
                case .comment: "Commenting"
                case .requestChanges: "Requesting changes"
                }
            return RowLabel(text: text + "\u{2026}", tone: .plain, tip: nil)
        case .confirmed(let review):
            let text =
                switch review {
                case .approve: "Approved"
                case .comment: "Commented"
                case .requestChanges: "Changes requested"
                }
            return RowLabel(text: text, tone: review.tone, tip: nil)
        }
    }

    // The line of an Approve of Claude with no draft: the count of the findings of each kind
    // that is not 0, in the order bugs, minor points, nits. "Claude found nothing to change." for
    // no findings, and "Claude found only 2 nits." for nits alone.
    package static func found(_ findings: [Finding]) -> String {
        guard !findings.isEmpty else { return "Claude found nothing to change." }
        guard findings.aboveNits else { return "Claude found only \(findingsList(findings))." }
        return "Claude found \(findingsList(findings))."
    }

    // The count of the findings of each kind that is not 0, in the order bugs, minor points,
    // nits, joined "a and b" or "a, b and c": "2 minor points and 1 nit". The line of a row and
    // the notification of a Looks good round use it.
    package static func findingsList(_ findings: [Finding]) -> String {
        let kinds: [(FindingKind, String, String)] = [
            (.bug, "bug", "bugs"), (.minor, "minor point", "minor points"), (.nit, "nit", "nits"),
        ]
        let parts = kinds.compactMap { kind, one, many -> String? in
            let found = findings.count(kind)
            return found == 0 ? nil : count(found, one, many)
        }
        return parts.count < 2
            ? parts.joined()
            : parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
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

    static let unpushedTip =
        "Bifrost won't merge the base branch over changes that aren't on GitHub. Ask Claude to "
        + "commit them, or discard them."
    static let unpushedCommentsTip =
        "Bifrost won't handle new comments over changes that aren't on GitHub. Ask Claude to "
        + "commit them, or discard them."
    static let unpushedCITip =
        "Bifrost won't fix failing CI over changes that aren't on GitHub. Ask Claude to commit "
        + "them, or discard them."
    static let askAgainTip =
        "Bifrost didn't apply your change, because Claude was busy resolving conflicts. Discard "
        + "the edits Claude made for your request so the merge can be resolved first, then ask "
        + "again."

    // The Claude state on the right of a My PRs row.
    package static func claude(_ state: ClaudeState) -> RowLabel {
        switch state {
        case .needsYou(let comments, let ci):
            RowLabel(text: "Needs you", tone: .red, tip: needsYouTip(comments: comments, ci: ci))
        case .waitsForYou(let reason):
            RowLabel(text: "Needs you", tone: .red, tip: reason)
        case .unpushedChanges:
            RowLabel(text: "Unpushed changes", tone: .amber, tip: unpushedTip)
        case .unpushedComments:
            RowLabel(text: "Unpushed changes", tone: .amber, tip: unpushedCommentsTip)
        case .askAgain:
            RowLabel(text: "Ask again", tone: .amber, tip: askAgainTip)
        case .unpushedCI:
            RowLabel(text: "Unpushed changes", tone: .amber, tip: unpushedCITip)
        case .fixing(let items):
            RowLabel(
                text: "Fixing \(items)", tone: .plain,
                tip: "Claude is working on \(count(items, "comment", "comments")).")
        case .resolvingConflicts:
            RowLabel(
                text: "Resolving conflicts", tone: .plain,
                tip: "Claude is resolving the merge conflicts with the base branch.")
        case .fixingCI:
            RowLabel(
                text: "Fixing CI", tone: .plain, tip: "Claude is looking at the failed checks.")
        case .retryingCI:
            RowLabel(
                text: "Retrying CI", tone: .dim,
                tip: "Bifrost re-ran the failed jobs and is waiting for the result.")
        case .conflicts(let reason?):
            RowLabel(text: "Has conflicts", tone: .red, tip: reason)
        case .conflicts(nil):
            RowLabel(
                text: "Has conflicts", tone: .amber,
                tip: "This branch has conflicts with its base branch. Choose Resolve now to let "
                    + "Claude resolve them.")
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

    // The tip of Needs you: the questions on comments, the CI question, or both.
    private static func needsYouTip(comments: Int, ci: Bool) -> String {
        let questions = count(comments, "comment", "comments")
        if !ci { return "Claude needs your answer on \(questions). Click to answer." }
        if comments == 0 {
            return "Claude needs your help with the failed checks. Click to answer."
        }
        return "Claude needs your answer on \(questions) and on the failed checks. Click to answer."
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

extension ReviewVerdict {
    // The colour of a review of the user: the soft green of an approval, the amber of a comment
    // and the red of a change request.
    package var tone: RowTone {
        switch self {
        case .approve: .green
        case .comment: .amber
        case .requestChanges: .red
        }
    }
}

// What Claude drafted for a mark: a summary or not, and the count of comments on lines.
struct Drafted: Sendable, Equatable {
    var summary: Bool
    var comments: Int
}
