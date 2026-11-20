// The rules of the To review tab (docs/behaviour/reviews.md, "The rows"): the state of each row,
// its texts and the order of the tab. The row gets the CI state of its PR, and ReviewRow.flash
// gives the flash from the state and the CI. The marks that each poll leaves in the state (the
// first sight of each request, the pauses and the removed rows) are in ReviewsState.recordPoll.
import Foundation

enum ToReviewRules {
    // The order of the groups of the tab.
    static func group(_ state: ToReviewState) -> Int {
        switch state {
        case .newRequest: 0
        case .draftReady: 1
        case .reviewed, .newCommits: 2
        case .failed: 3
        case .waitingForYou: 4
        case .trustNeeded: 5
        case .reviewing: 6
        case .queued: 7
        case .paused: 8
        case .youApproved: 9
        case .youRequestedChanges: 10
        case .youCommented: 11
        case .approvedByOthers: 12
        case .teamRequest: 13
        }
    }

    static func rows(
        _ answer: PollAnswer, _ state: ReviewsState, _ config: ReviewsConfig,
        clones: CloneStates = CloneStates(), reviewedHere: [PRKey: ConfirmedReview] = [:],
        now: Date
    ) -> [ReviewRow] {
        let shown = answer.toReview.compactMap { pr -> (PullRequest, ToReviewState)? in
            guard !IgnoreRule.matches(config.ignore, pr.key.repo), state.hidden[pr.key] == nil,
                let rowState = Self.state(
                    pr, state, teamRequests: config.teamRequests, clones: clones,
                    reviewedHere: reviewedHere[pr.key], now: now)
            else { return nil }
            return (pr, rowState)
        }
        return shown.sorted(by: inOrder).map { pr, rowState in
            row(pr, rowState, state, now: now)
        }
    }

    // The state of the row of the PR, or nil when the team filter hides it. The first rule that
    // holds wins. A session shows in each case. A queued review of a repository whose clone
    // needs the trust of the user waits for it. A queued review of a repository with no clone
    // yet stays queued: its start makes the clone. reviewedHere is the review that the user gave
    // in Bifrost, after GitHub confirmed the write (ReviewWrites.reviewedHere): the answer can be
    // from before that review, and the row must not offer the same write again.
    static func state(
        _ pr: PullRequest, _ state: ReviewsState, teamRequests: Bool,
        clones: CloneStates = CloneStates(), reviewedHere: ConfirmedReview? = nil, now: Date
    ) -> ToReviewState? {
        let prState = state.prs[pr.key]
        if prState?.round != nil { return .reviewing }
        if state.queue.contains(where: { $0.pr == pr.key }) {
            return clones.needsTrust.contains(pr.key.repo) ? .trustNeeded : .queued
        }
        let direct = pr.isDirectRequest
        guard direct || teamRequests else { return nil }
        if let reviewedHere, reviewedHere.head == pr.headSHA { return you(reviewedHere.verdict) }
        // The draft of Claude is on an older commit than the head: the author pushed new commits.
        if let pending = pr.viewerPendingReviewID {
            if let mark = prState?.recommendation, mark.reviewID == pending,
                mark.headSHA.hex != pr.headSHA
            {
                return .newCommits
            }
            return .draftReady
        }
        let mark = state.requests[pr.key]
        // The user acted on the request (a Review click or the posts of a round) after its first
        // sight.
        let acted =
            if let actedAt = prState?.actedAt, let mark { actedAt >= mark.firstSeen } else { false }
        let isNew = direct && mark?.baseline != true && !acted
        // A new request on the same commit stays new, so it flashes as before.
        if !isNew, let review = reviewOnHead(pr.viewerReviews, head: pr.headSHA) {
            return you(review)
        }
        if let reason = prState?.lastError { return .failed(reason) }
        // A review of Claude with no draft: on the head it is Looks good, on an older commit it
        // is New commits.
        if let mark = prState?.recommendation, mark.reviewID == nil {
            return mark.headSHA.hex == pr.headSHA ? .reviewed : .newCommits
        }
        if let until = state.pauses[pr.key], now < until { return .paused(until: until) }
        if pr.reviewDecision == .approved { return .approvedByOthers }
        if !direct { return .teamRequest }
        return isNew ? .newRequest : .waitingForYou
    }

    // The review of the user on the head commit, or nil. The newest opinion of the user (an
    // approval, a change request or a dismissal) counts when it is on the head and is not a
    // dismissal. Else a comment of the user on the head counts. A comment does not change an
    // opinion, so a comment after an approval of the head leaves the approval.
    static func reviewOnHead(_ opinions: [ViewerOpinion], head: String) -> ReviewVerdict? {
        guard !head.isEmpty else { return nil }
        let kinds: [ReviewState] = [.approved, .changesRequested, .dismissed]
        var newest: ViewerOpinion?
        for opinion in opinions where kinds.contains(opinion.state) {
            let time = opinion.submittedAt ?? .distantPast
            if newest == nil || time >= newest?.submittedAt ?? .distantPast { newest = opinion }
        }
        if let newest, newest.commit == head {
            switch newest.state {
            case .approved: return .approve
            case .changesRequested: return .requestChanges
            case .commented, .dismissed, .pending: break
            }
        }
        let commented = opinions.contains { $0.state == .commented && $0.commit == head }
        return commented ? .comment : nil
    }

    // True when the newest opinion of the user is an approval of the head commit.
    static func approvedOnHead(_ opinions: [ViewerOpinion], head: String) -> Bool {
        reviewOnHead(opinions, head: head) == .approve
    }

    // The state of a row whose head commit has the review of the user.
    private static func you(_ review: ReviewVerdict) -> ToReviewState {
        switch review {
        case .approve: .youApproved
        case .comment: .youCommented
        case .requestChanges: .youRequestedChanges
        }
    }

    // The order of the tab: the group, then the end of the pause of a paused row, then the oldest
    // request, then the key.
    private static func inOrder(
        _ left: (PullRequest, ToReviewState), _ right: (PullRequest, ToReviewState)
    ) -> Bool {
        let (leftPR, leftState) = left
        let (rightPR, rightState) = right
        if group(leftState) != group(rightState) { return group(leftState) < group(rightState) }
        if case .paused(let leftEnd) = leftState, case .paused(let rightEnd) = rightState,
            leftEnd != rightEnd
        {
            return leftEnd < rightEnd
        }
        if leftPR.requestedAt != rightPR.requestedAt {
            return leftPR.requestedAt < rightPR.requestedAt
        }
        return leftPR.key < rightPR.key
    }

    // MARK: - The row

    // True for a state whose text failing or running CI replaces: a state that waits for the
    // user. A session, a review of the user and approved by others keep their own text.
    private static func showsCI(_ state: ToReviewState) -> Bool {
        switch state {
        case .newRequest, .waitingForYou, .teamRequest, .failed, .reviewed, .draftReady, .paused,
            .newCommits:
            true
        case .trustNeeded, .reviewing, .queued, .youApproved, .youRequestedChanges, .youCommented,
            .approvedByOthers:
            false
        }
    }

    private static func row(
        _ pr: PullRequest, _ rowState: ToReviewState, _ state: ReviewsState, now: Date
    ) -> ReviewRow {
        let mark = shownMark(pr, rowState, state.prs[pr.key])
        let result = result(rowState, mark)
        var notes = [
            pr.author, RowText.size(additions: pr.additions, deletions: pr.deletions),
            RowText.age(RowText.span(since: pr.requestedAt, now: now)),
        ]
        if let result {
            notes = [
                RowText.line(
                    result, drafted: mark.flatMap { drafted($0, state.drafts) },
                    approvals: pr.approvals)
            ]
        }
        return ReviewRow(
            id: pr.key, state: .toReview(rowState), repo: pr.key.repo.name, title: pr.title,
            dot: result?.dot, tag: pr.isDirectRequest ? nil : RowText.team, review: nil,
            reviewers: [], notes: notes, status: status(pr, rowState, mark, result, now: now),
            reviewable: reviewable(
                rowState, ownDraft: rowState == .draftReady && mark != nil, pr.ci),
            approve: approveOffer(pr, rowState, mark), draft: draftOffer(rowState, mark),
            ci: pr.ci)
    }

    // The Approve button (user decision, 2026-11-13): a Looks good or a Draft ready row that
    // shows a mark that lets the user approve (ApproveGuard.isApprovable) for the head commit,
    // while the latest opinion of the user is not an approval of that commit. Failing CI gives no
    // button, and running CI gives a button that waits.
    static func approveOffer(
        _ pr: PullRequest, _ rowState: ToReviewState, _ mark: RecommendationMark?
    ) -> ApproveOffer? {
        guard rowState == .reviewed || rowState == .draftReady, let mark,
            ApproveGuard.isApprovable(mark), mark.headSHA.hex == pr.headSHA,
            !approvedOnHead(pr.viewerReviews, head: pr.headSHA), pr.ci != .failing
        else { return nil }
        return pr.ci == .running ? .waitsForCI : .ready
    }

    // The Review panel: a Draft ready row whose mark is Claude's Comment or Request changes draft.
    static func draftOffer(_ rowState: ToReviewState, _ mark: RecommendationMark?) -> DraftEvent? {
        guard rowState == .draftReady, let mark, mark.reviewID != nil,
            !ApproveGuard.isApprovable(mark)
        else { return nil }
        return mark.value == .requestChanges ? .requestChanges : .comment
    }

    // True when a review round can start: no round runs or waits, the pending review of the user
    // is not Claude's draft, and CI does not fail (user decision, 2026-11-13).
    private static func reviewable(_ state: ToReviewState, ownDraft: Bool, _ ci: CIState?) -> Bool {
        guard ci != .failing, !ownDraft else { return false }
        switch state {
        case .reviewing, .queued, .trustNeeded: return false
        case .newRequest, .draftReady, .reviewed, .newCommits, .failed, .waitingForYou, .paused,
            .youApproved, .youRequestedChanges, .youCommented, .approvedByOthers, .teamRequest:
            return true
        }
    }

    // The text on the right, its colour and its tip. Failing or running CI replaces the text of
    // a state that waits for the user, and the result of Claude replaces the text of its state.
    private static func status(
        _ pr: PullRequest, _ rowState: ToReviewState, _ mark: RecommendationMark?,
        _ result: ClaudeResult?, now: Date
    ) -> RowLabel {
        // The tip of the state. With CI, a failed row keeps the reason of its failure as the tip.
        let stateTip = RowText.tip(rowState)
        if showsCI(rowState) {
            switch pr.ci {
            case .failing?:
                return RowLabel(
                    text: RowText.ciFailing, tone: .red, tip: stateTip ?? RowText.ciFailingTip)
            case .running?:
                return RowLabel(
                    text: RowText.ciRunning, tone: .dim, tip: stateTip ?? RowText.ciRunningTip)
            case .passed?, nil:
                break
            }
        }
        if let result {
            var label = RowText.text(result)
            label.tip = label.tip ?? mark.flatMap { RowText.suggestion($0, rowState) }
            return label
        }
        let tone: RowTone =
            switch rowState {
            case .failed: .red
            case .youApproved: ReviewVerdict.approve.tone
            case .youRequestedChanges: ReviewVerdict.requestChanges.tone
            case .youCommented: ReviewVerdict.comment.tone
            case .newCommits: .amber
            case .newRequest, .draftReady, .reviewed, .waitingForYou, .trustNeeded, .reviewing,
                .queued, .paused, .approvedByOthers, .teamRequest:
                .plain
            }
        return RowLabel(text: RowText.toReview(rowState, now: now), tone: tone, tip: stateTip)
    }

    // The mark of Claude that the row shows. Only a draft-ready or a reviewed row shows one, and
    // only while the mark is for the pending review of the user (or, with no draft, while the
    // user has no pending review). An older mark is stale.
    private static func shownMark(
        _ pr: PullRequest, _ rowState: ToReviewState, _ prState: PRState?
    ) -> RecommendationMark? {
        guard rowState == .draftReady || rowState == .reviewed,
            let mark = prState?.recommendation, mark.reviewID == pr.viewerPendingReviewID
        else { return nil }
        return mark
    }

    private static func result(_ rowState: ToReviewState, _ mark: RecommendationMark?)
        -> ClaudeResult?
    {
        switch rowState {
        case .approvedByOthers:
            return .others
        case .reviewed:
            if mark?.deleted == true { return .deleted }
            return mark?.value == .approve ? .approve : nil
        case .draftReady:
            return switch mark?.value {
            case .approve?: .approve
            case .comment?: .comment
            case .requestChanges?: .changes
            case nil: nil
            }
        case .newRequest, .newCommits, .failed, .waitingForYou, .trustNeeded, .reviewing, .queued,
            .paused, .youApproved, .youRequestedChanges, .youCommented, .teamRequest:
            return nil
        }
    }

    // What Claude drafted for the mark, from the saved draft comments of its review. A mark with
    // no draft drafted nothing. nil when Bifrost kept no draft comment of the review, or when the
    // user deleted the draft.
    private static func drafted(_ mark: RecommendationMark, _ drafts: [DraftRecord]) -> Drafted? {
        guard !mark.deleted else { return nil }
        guard let review = mark.reviewID else { return Drafted(summary: false, comments: 0) }
        let own = drafts.filter { $0.reviewID == review }
        guard !own.isEmpty else { return nil }
        return Drafted(
            summary: own.contains { $0.path.isEmpty },
            comments: own.count(where: { !$0.path.isEmpty }))
    }
}
