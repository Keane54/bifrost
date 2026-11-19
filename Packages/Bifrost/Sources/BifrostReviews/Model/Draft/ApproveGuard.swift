// The Approve button (docs/behaviour/reviews.md, "Approve"): the fresh read of the PR before a
// write of the Approve button or of the Review panel (FreshPR), the checks of an approval and the
// guard that makes its one write. Only a click of the user starts an approval, and Bifrost reads
// the PR again just before the write: the write goes only to the PR that GitHub gives for the
// row, only on the commit that Claude reviewed, and only with the draft review of Claude's mark.
import BifrostFoundation
import Foundation

// The PR as GitHub gives it just before a write of the Approve button or of the Review panel
// (DraftQueries.fresh).
package struct FreshPR: Sendable, Equatable {
    // The node ID of the PR, for an approval with no draft.
    package var id: NodeID
    // The address of the PR that GitHub gives. The guard takes the PR key from it.
    package var url: String
    package var state: PRLifecycle
    package var author: String
    package var headSHA: CommitID
    package var ci: CIState?
    // The pending review of the viewer, or nil.
    package var pending: PendingDraft?
    // The newest opinions of the viewer (approvals, change requests and dismissals).
    package var opinions: [ViewerOpinion]

    package init(
        id: NodeID, url: String, state: PRLifecycle = .open, author: String, headSHA: CommitID,
        ci: CIState? = nil, pending: PendingDraft? = nil, opinions: [ViewerOpinion] = []
    ) {
        self.id = id
        self.url = url
        self.state = state
        self.author = author
        self.headSHA = headSHA
        self.ci = ci
        self.pending = pending
        self.opinions = opinions
    }

    // The PR key of the address that GitHub gave, or nil.
    package var key: PRKey? { PRKey(url: url) }

    // The answer of the read. An answer with errors fails, also next to data, so a part of the
    // data never looks whole. A PR with no ID, no known state or no head commit is a bad answer.
    package static func decode(_ data: Data) -> Result<FreshPR, GitHubError> {
        ReviewAnswer.pullRequest(data).flatMap { node in
            guard let id = node["id"]?.string.flatMap(NodeID.init),
                let state = node["state"]?.string.flatMap(PRLifecycle.init(rawValue:)),
                let head = node["headRefOid"]?.string.flatMap(CommitID.init)
            else { return .failure(.badAnswer) }
            let commit = node["commits"].nodes.last?["commit"]?.object
            let pending = node["pending"].nodes.lazy.compactMap { item -> PendingDraft? in
                guard item["viewerDidAuthor"] == .bool(true),
                    let review = item["id"]?.string.flatMap(NodeID.init)
                else { return nil }
                return PendingDraft(
                    id: review, body: item["body"]?.string ?? "",
                    commit: item["commit"]?.object?["oid"]?.string.flatMap(CommitID.init))
            }.first
            let opinions = node["opinions"].nodes.compactMap { item -> ViewerOpinion? in
                guard let state = item["state"]?.string.flatMap(ReviewState.init(rawValue:))
                else { return nil }
                return ViewerOpinion(
                    state: state, commit: item["commit"]?.object?["oid"]?.string,
                    submittedAt: item["submittedAt"]?.string.flatMap {
                        try? Date($0, strategy: .iso8601)
                    })
            }
            return .success(
                FreshPR(
                    id: id, url: node["url"]?.string ?? "", state: state,
                    author: node["author"]?.object?["login"]?.string ?? "", headSHA: head,
                    ci: CIState(
                        rollup: commit?["statusCheckRollup"]?.object?["state"]?.string,
                        commit: commit?["oid"]?.string, head: head.hex),
                    pending: pending, opinions: opinions))
        }
    }
}

// Why Bifrost did not approve, or does not know whether GitHub saved the approval. Each text is
// friendly and plain, for the error line of the panel.
package enum ApproveRefusal: Error, Sendable, Equatable {
    // Reviews does not run, or has no good poll yet.
    case notReady
    case closed
    case ownPR
    // The mark of the PR does not let the user approve (any more), or a round runs or waits.
    case notSuggested
    // The head of the PR is not the commit that Claude reviewed.
    case headMoved
    case alreadyApproved
    case ciFailing
    case ciRunning
    // The user has a pending review of their own: an approval with no draft can't go next to it.
    case pendingReview
    // Claude's draft review is not the pending review on GitHub any more.
    case draftMissing
    case draftOtherCommit
    // The guard refused the write: it didn't match Claude's review. Nothing was sent.
    case guardRefused
    // The fresh read failed. Nothing was sent.
    case readFailed(GitHubError)
    // GitHub refused the write; the Event log has its line.
    case refusedByGitHub
    // The write didn't go, for a reason of gh (not installed, not logged in, ...).
    case notSent(GitHubError)
    // GitHub can have saved the approval. Bifrost never sends it again by itself.
    case unknown
    // GitHub saved a review, but not as an approval.
    case notApproved

    // True when GitHub can have saved the approval, so a poll shows the true state.
    package var mayHaveApproved: Bool {
        switch self {
        case .unknown, .notApproved: true
        default: false
        }
    }

    package var message: String {
        switch self {
        case .notReady:
            "Reviews isn't running right now, so Bifrost didn't approve this pull request."
        case .closed: "This pull request is closed or merged, so Bifrost didn't approve it."
        case .ownPR: "You can't approve your own pull request."
        case .notSuggested:
            "Claude doesn't suggest Approve for this pull request any more, so Bifrost didn't "
                + "approve it."
        case .headMoved:
            "This pull request changed after Claude's review, so Bifrost didn't approve it. It "
                + "needs a new review."
        case .alreadyApproved: "You already approved this commit on GitHub."
        case .ciFailing: "CI is failing on this pull request, so Bifrost didn't approve it."
        case .ciRunning: "CI is still running. Approve when it has passed."
        case .pendingReview:
            "You have a draft review on this pull request. Submit or delete it on GitHub first, "
                + "then try again."
        case .draftMissing:
            "Bifrost couldn't find Claude's draft review on GitHub, so it didn't approve. The "
                + "draft may have been submitted or deleted."
        case .draftOtherCommit:
            "Claude's draft review is on another commit, so Bifrost didn't submit it."
        case .guardRefused:
            "Bifrost stopped this approval because it didn't match Claude's review. Nothing was "
                + "posted."
        case .readFailed(let error):
            "Bifrost couldn't load this pull request from GitHub, so it didn't approve it. "
                + error.message
        case .refusedByGitHub:
            "GitHub didn't accept the approval. The Event log has the details."
        case .notSent(let error): "Bifrost couldn't approve this pull request. \(error.message)"
        case .unknown:
            "Bifrost couldn't tell if GitHub saved your approval. Click Refresh to check."
        case .notApproved:
            "GitHub saved the review, but not as an approval. Check the pull request on GitHub."
        }
    }
}

package enum ApproveGuard {
    // True when the mark lets the user approve: Claude suggests Approve, or the user deleted
    // Claude's draft with Approve instead (user decision, 2026-11-13).
    package static func isApprovable(_ mark: RecommendationMark) -> Bool {
        mark.value == .approve || mark.deleted
    }

    // The fresh check of an approval: the reason not to write, or nil. The first rule that holds
    // wins.
    package static func refusal(
        _ fresh: FreshPR, viewer: String, mark: RecommendationMark
    ) -> ApproveRefusal? {
        if fresh.state != .open { return .closed }
        if fresh.author.lowercased() == viewer.lowercased() { return .ownPR }
        if !isApprovable(mark) { return .notSuggested }
        if fresh.headSHA != mark.headSHA { return .headMoved }
        switch fresh.ci {
        case .failing?: return .ciFailing
        case .running?: return .ciRunning
        case .passed?, nil: break
        }
        if ToReviewRules.approvedOnHead(fresh.opinions, head: fresh.headSHA.hex) {
            return .alreadyApproved
        }
        // GitHub keeps one pending review for each user: an approval with no draft can't go
        // next to one.
        guard let review = mark.reviewID else { return fresh.pending == nil ? nil : .pendingReview }
        guard let pending = fresh.pending, pending.id == review else { return .draftMissing }
        return pending.commit == mark.headSHA ? nil : .draftOtherCommit
    }

    // The one write of the approval, or nil when the guard refuses it. The write goes only to the
    // PR of the row (the key of the address that GitHub gave), only on the reviewed commit, and
    // only with the draft of the mark: a mark with no draft approves the head commit with no
    // text, and a mark with a draft submits that draft as an approval, with its body as it is.
    package static func write(
        _ fresh: FreshPR, pr: PRKey, mark: RecommendationMark, click: UserClick
    ) -> GitHubWrite? {
        guard fresh.key == pr, isApprovable(mark) else { return nil }
        guard let review = mark.reviewID else {
            guard fresh.headSHA == mark.headSHA else { return nil }
            return .approveCommit(pr: fresh.id, commit: fresh.headSHA, click: click)
        }
        guard let pending = fresh.pending, pending.id == review, pending.commit == mark.headSHA
        else { return nil }
        return .approveDraft(review: pending.id, click: click)
    }

    // The result of the write from the answer of GitHub: nil when GitHub approved. An answer with
    // no review is unknown, and a review in another state is not an approval.
    package static func outcome(_ answer: Data, of write: GitHubWrite) -> ApproveRefusal? {
        guard let node = write.answerNode(answer), node["id"]?.string?.isEmpty == false else {
            return .unknown
        }
        return node["state"] == .string(ReviewState.approved.rawValue) ? nil : .notApproved
    }
}
