// The findings form of the Review panel (docs/behaviour/reviews.md, "The Review panel"): what a
// review of Claude's findings posts, its checks, the fresh check of the PR and the guard of its
// one write. The post holds only the summary that the user typed and the findings that the user
// ticked. The guard refuses a line comment that is not the comment of a finding of the mark. The
// private note of the mark is never a part of a post.
import BifrostFoundation
import Foundation

// What the Review panel posts with a review of Claude's findings: the review text and the line
// comments. The private note of the mark is never a part of it.
package struct ReviewPost: Sendable, Equatable {
    package var body: String
    package var threads: [DraftComment]

    package init(body: String, threads: [DraftComment]) {
        self.body = body
        self.threads = threads
    }

    // True when the post has no review text and no line comment: an approval with no text.
    package var isEmpty: Bool { body.trimmed().isEmpty && threads.isEmpty }
}

// An approval from the Review panel: the mark that the panel showed, and its post.
package struct PanelApproval: Sendable, Equatable {
    package var mark: RecommendationMark
    package var post: ReviewPost

    package init(mark: RecommendationMark, post: ReviewPost) {
        self.mark = mark
        self.post = post
    }
}

// Why the findings form sent no review, or why Bifrost does not know whether GitHub saved it.
// Each text is friendly and plain, for the error line of the form.
package enum FindingsRefusal: Error, Sendable, Equatable {
    // The row does not offer the findings now (a round runs, the mark changed, Reviews is off),
    // or the form did not open this mark.
    case notOffered
    // Another action of the form, or another write of the PR, runs now. This one sent nothing.
    case busy
    case closed
    case ownPR
    // The head of the PR is not the commit that Claude reviewed.
    case headMoved
    // The user has a pending review of their own: a review can't go next to it.
    case pendingReview
    case needsSummary
    case empty
    case tooLong
    // The guard refused the write: it didn't match Claude's findings. Nothing was sent.
    case guardRefused
    // The fresh read failed. Nothing was sent.
    case readFailed(GitHubError)
    // GitHub refused the write; the Event log has its line.
    case refusedByGitHub
    // GitHub can have saved the review. Bifrost never sends it again by itself.
    case unknown
    // GitHub saved a review, but not in the state of the event.
    case notAsSent
    // The write didn't go, for a reason of gh (not installed, not logged in, ...).
    case notSent(GitHubError)
    // The approval of Approve didn't go through, for this reason.
    case approveRefused(ApproveRefusal)

    // True when GitHub can have saved the review, so a poll shows the true state.
    package var mayHaveChanged: Bool {
        switch self {
        case .unknown, .notAsSent: true
        case .approveRefused(let refusal): refusal.mayHaveApproved
        default: false
        }
    }

    package var message: String {
        switch self {
        case .notOffered:
            "You can't send this review right now, its row in the Reviews panel shows why."
        case .busy: "A review of this pull request is still sending, so try again once it's done."
        case .closed: "This pull request has been closed or merged, so the review wasn't sent."
        case .ownPR: "You can't review your own pull request, so the review wasn't sent."
        case .headMoved:
            "This pull request has changed since Claude reviewed it, so you'll need a new review "
                + "before sending."
        case .pendingReview: ApproveRefusal.pendingReview.message
        case .needsSummary: DraftRefusal.needsSummary.message
        case .empty: "Add a summary or tick a finding before you comment."
        case .tooLong:
            "This review is too long for GitHub, so untick some findings or shorten the summary."
        case .guardRefused:
            "This review didn't match Claude's findings, so Bifrost stopped it and nothing was "
                + "posted."
        case .readFailed(let error):
            "Bifrost couldn't load this pull request from GitHub, so the review wasn't sent. "
                + error.message
        case .refusedByGitHub: "GitHub rejected the review, check the Event log for details."
        case .unknown:
            "Bifrost can't tell whether GitHub saved your review, so click Refresh to check."
        case .notAsSent:
            "GitHub saved the review, but it doesn't match what you sent, so check it on GitHub."
        case .notSent(let error): "Bifrost couldn't send this review. \(error.message)"
        case .approveRefused(let refusal): refusal.message
        }
    }
}

package enum FindingsPlan {
    // The post of the ticks and the summary. The review text is the summary as the user typed it
    // (when it is not blank), then the paragraph of each ticked finding that has no line comment,
    // with a blank line between them. Each ticked finding on the diff gives its line comment.
    // The ticks go in the order of the list, and a tick that is not a finding is ignored.
    package static func post(_ findings: [Finding], ticked: Set<Int>, summary: String)
        -> ReviewPost
    {
        let chosen = ticked.sorted().filter { findings.indices.contains($0) }.map { findings[$0] }
        let summaryPart = summary.trimmed().isEmpty ? [] : [summary]
        let paragraphs = chosen.filter { $0.comment == nil }.map(\.paragraph)
        return ReviewPost(
            body: (summaryPart + paragraphs).joined(separator: "\n\n"),
            threads: chosen.compactMap(\.comment))
    }

    // The checks of a post and of the summary that the user typed before the fresh read: the
    // reason not to send it with the event, or nil. GitHub refuses a text over its limit. Request
    // changes needs a summary that the user typed: the paragraphs of the findings do not count. A
    // Comment needs a review text or a line comment. An empty Approve is a plain approval.
    package static func problem(_ post: ReviewPost, summary: String, event: ReviewEvent)
        -> FindingsRefusal?
    {
        func over(_ text: String) -> Bool { text.utf16.count > ReviewResult.maxReviewBody }
        if over(post.body) || post.threads.contains(where: { over($0.body) }) { return .tooLong }
        switch event {
        case .requestChanges where summary.trimmed().isEmpty: return .needsSummary
        case .comment where post.isEmpty: return .empty
        case .approve, .comment, .requestChanges: return nil
        }
    }

    // The fresh check of a review of the findings: the reason not to write, or nil. The first rule
    // that holds wins. Only Claude's Approve mark with no draft offers the findings, and GitHub
    // keeps one pending review for each user, so a review can't go next to one.
    package static func refusal(
        _ fresh: FreshPR, viewer: String, mark: RecommendationMark
    ) -> FindingsRefusal? {
        if fresh.state != .open { return .closed }
        if fresh.author.lowercased() == viewer.lowercased() { return .ownPR }
        guard offers(mark) else { return .notOffered }
        if fresh.headSHA != mark.headSHA { return .headMoved }
        return fresh.pending == nil ? nil : .pendingReview
    }

    // True when the mark offers its findings in the form: Claude's Approve mark with no draft,
    // and not a mark whose draft the user deleted.
    package static func offers(_ mark: RecommendationMark) -> Bool {
        mark.value == .approve && mark.reviewID == nil && !mark.deleted
    }

    // True when each line comment of the post is the comment of one finding of the mark, and no
    // finding gives two line comments.
    package static func threadsAreFindings(_ post: ReviewPost, of mark: RecommendationMark) -> Bool
    {
        var comments = mark.findings.compactMap(\.comment)
        for thread in post.threads {
            guard let index = comments.firstIndex(of: thread) else { return false }
            comments.remove(at: index)
        }
        return true
    }

    // The one write of Comment or Request changes, or nil when the guard refuses it.
    package static func write(
        _ fresh: FreshPR, pr: PRKey, mark: RecommendationMark, post: ReviewPost,
        event: DraftEvent, click: UserClick
    ) -> GitHubWrite? {
        review(fresh, pr: pr, mark: mark, post: post, event: ReviewEvent(event), click: click)
    }

    // The one review write of a post with the event, or nil when the guard refuses it. The write
    // goes only to the PR of the row (the key of the address that GitHub gave), only for a mark
    // that offers its findings in the form, only on the reviewed commit, only with no pending
    // review of the user, and only with line comments of the findings of the mark. ApproveGuard
    // uses it for an approval with a post.
    static func review(
        _ fresh: FreshPR, pr: PRKey, mark: RecommendationMark, post: ReviewPost,
        event: ReviewEvent, click: UserClick
    ) -> GitHubWrite? {
        guard fresh.key == pr, offers(mark), fresh.headSHA == mark.headSHA,
            fresh.pending == nil, threadsAreFindings(post, of: mark)
        else { return nil }
        return .reviewCommit(
            pr: fresh.id, commit: fresh.headSHA, event: event, body: post.body,
            threads: post.threads, click: click)
    }

    // The result of a write of Comment or Request changes from the answer of GitHub: nil when
    // GitHub saved the review in the state of the event. An answer with no review is unknown.
    package static func outcome(_ answer: Data, of write: GitHubWrite, event: DraftEvent)
        -> FindingsRefusal?
    {
        guard let node = write.answerNode(answer), node["id"]?.string?.isEmpty == false else {
            return .unknown
        }
        let state: ReviewState =
            switch event {
            case .comment: .commented
            case .requestChanges: .changesRequested
            }
        return node["state"] == .string(state.rawValue) ? nil : .notAsSent
    }

    // How far before the unsure result a saved review may be and still count as the one we
    // sent: gh gives up on a write after 30 seconds, GitHub's times have whole seconds and the
    // Mac's clock can be a little off. Taking an older review of yours on the same head for this
    // one only locks a review you'd already given, so erring early is the safe side.
    package static let savedSlack = Duration.seconds(120)

    // The review of yours on the head that GitHub saved at or after the time, as what it did, or
    // nil. Comments, approvals and requests for changes count, the newest first; a pending or
    // dismissed review doesn't. The check of an unsure Comment uses it.
    package static func savedReview(_ reviews: [ViewerOpinion], head: String, since: Date)
        -> ReviewVerdict?
    {
        func verdict(_ state: ReviewState) -> ReviewVerdict? {
            switch state {
            case .commented: .comment
            case .approved: .approve
            case .changesRequested: .requestChanges
            case .dismissed, .pending: nil
            }
        }
        let saved = reviews.compactMap { review -> (Date, ReviewVerdict)? in
            guard review.commit == head, let at = review.submittedAt, at >= since,
                let done = verdict(review.state)
            else { return nil }
            return (at, done)
        }
        return saved.max { $0.0 < $1.0 }?.1
    }

    // The answer of the read of your own reviews on a PR (DraftQueries.ownReviews). An answer
    // with errors fails, so a part of it never looks like the whole list.
    package static func ownReviews(_ data: Data) -> Result<[ViewerOpinion], GitHubError> {
        ReviewAnswer.pullRequest(data).map { ViewerOpinion.list($0["reviews"].nodes) }
    }

    // The refusal of a write that failed. A write that GitHub can have made is unknown, and
    // Bifrost never sends it again by itself.
    package static func failure(_ error: GitHubError) -> FindingsRefusal {
        if error.writeMayHaveHappened { return .unknown }
        if case .refused(let line) = error, !line.isEmpty { return .refusedByGitHub }
        return .notSent(error)
    }
}
