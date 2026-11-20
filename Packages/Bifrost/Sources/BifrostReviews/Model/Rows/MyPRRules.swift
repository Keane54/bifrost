// The rules of the My PRs tab (docs/behaviour/reviews.md, "The rows"): the open items of a PR,
// its review status, its reviewers with their colours, the Claude state and the order of the tab.
import BifrostFoundation
import Foundation

// The kind of an open item of a PR of the user.
package enum WorkItemKind: String, Sendable, Codable {
    case thread, comment
    case reviewBody = "review-body"
}

// The open items of a PR of the user, each in one list. Only a trusted human author gives an
// item: a thread that is not resolved, the body of a review that requests changes or comments,
// or a top-level comment. Of Copilot, only the threads count: the threads of the first Copilot
// review are like the threads of a person, and the threads of a later review wait for Handle
// Copilot comments. Another bot, an outsider and the user never give an item.
package struct OpenItems: Sendable, Equatable {
    package struct Item: Sendable, Equatable {
        package var id: NodeID
        package var kind: WorkItemKind
    }

    // New work for a request round.
    package var work: [Item] = []
    // Items from before the start of new work, the held items of a failed round, and the known
    // items with a newer trusted comment from before the start of new work. They wait for Handle
    // now.
    package var older: [Item] = []
    // The threads of a later Copilot review. They wait for Handle Copilot comments.
    package var laterCopilot: [Item] = []
    // The items with an open question. They wait for the answer of the user.
    package var questions: [Item] = []
    // The items that a write of the outbox names. The outbox sends or drops their writes first.
    package var posting: [Item] = []

    // The items of the lists of a PR. baseline holds the items that were open at the first
    // turn-on, and since is the start of new work: an item from before it is older. The first
    // Copilot review is the one that the state saved, so a deleted first review never makes a
    // later review the first.
    package init(
        threads: [PRThread], reviews: [PRReview], comments: [PRComment], viewer: String,
        state: PRState, baseline: Set<NodeID>, since: Date?
    ) {
        let posting = Set(state.outbox?.posts.compactMap(\.item) ?? [])
        let held = Set(state.held)
        let firstCopilot = state.firstCopilotReview ?? Self.firstCopilotReview(reviews)
        func trustedAfter(_ comments: [PRComment], _ time: Date) -> Bool {
            comments.contains { Self.isTrustedHuman($0.author, viewer) && $0.createdAt > time }
        }
        // True when a trusted comment after the time is also new work: it is from the start of
        // new work on. So a comment from before the take-over or the confirm of the automatic
        // rounds never makes work by itself.
        func newWorkAfter(_ comments: [PRComment], _ time: Date) -> Bool {
            comments.contains { comment in
                Self.isTrustedHuman(comment.author, viewer) && comment.createdAt > time
                    && (since.map { comment.createdAt >= $0 } ?? true)
            }
        }
        // The place of an item that Bifrost knows from an earlier round. The first rule that
        // holds wins:
        // 1. A write of the outbox names the item.
        // 2. An open question with no trusted comment after it waits for the answer.
        // 3. A held item is older. An answered question that is held waits too.
        // 4. An answered question is work.
        // 5. An open question with a newer trusted comment is older.
        // 6. A handled item stays handled, until a trusted comment after the last reply. Then it
        //    is older.
        // 7. Each older item of rules 3, 5 and 6 is work after Handle now, or after a trusted
        //    comment from the start of new work on that is after its mark: the full read of the
        //    failed round, the question or the last reply.
        func known(_ id: NodeID, _ comments: [PRComment]) -> Place {
            if posting.contains(id) { return .posting }
            let question = state.questions[id]
            if let question, question.answer == nil, !trustedAfter(comments, question.seenUntil) {
                return .questions
            }
            // The time that a trusted comment must come after.
            let mark: Date?
            if held.contains(id) {
                mark = state.checkedAt
            } else if let question {
                if question.answer != nil { return .work }
                mark = question.seenUntil
            } else if let handled = state.handled[id] {
                // A handled item of the first release has no reply time: it stays handled.
                guard let reply = handled.lastReplyAt, trustedAfter(comments, reply) else {
                    return .handled
                }
                mark = reply
            } else {
                return .new
            }
            let reopened = mark.map { newWorkAfter(comments, $0) } ?? false
            return state.handleOlder || reopened ? .work : .older
        }
        // The place of a new item: older when it was open at the first turn-on or is from before
        // the start of new work, unless the user clicked Handle now.
        func fresh(_ id: NodeID, _ time: Date?) -> Place {
            let before = if let since, let time { time < since } else { false }
            return !state.handleOlder && (baseline.contains(id) || before) ? .older : .work
        }

        for thread in threads {
            guard !thread.isResolved, let opener = thread.comments.first else { continue }
            let human = Self.isTrustedHuman(opener.author, viewer)
            guard human || Authors.isCopilot(opener.author) else { continue }
            let item = Item(id: thread.id, kind: .thread)
            var place = known(item.id, thread.comments)
            if place == .new {
                if human || (thread.reviewID != nil && thread.reviewID == firstCopilot) {
                    place = fresh(item.id, opener.createdAt)
                } else {
                    place = state.handleCopilot ? .work : .laterCopilot
                }
            }
            add(item, place)
        }
        for review in reviews where Self.isTrustedHuman(review.author, viewer) {
            // An approval, a dismissed review and an empty body need no act.
            guard review.state == .changesRequested || review.state == .commented,
                !review.body.trimmed().isEmpty
            else { continue }
            let item = Item(id: review.id, kind: .reviewBody)
            let place = known(item.id, [])
            add(item, place == .new ? fresh(item.id, review.submittedAt) : place)
        }
        for comment in comments where Self.isTrustedHuman(comment.author, viewer) {
            let item = Item(id: comment.id, kind: .comment)
            let place = known(item.id, [])
            add(item, place == .new ? fresh(item.id, comment.createdAt) : place)
        }
    }

    // The list of an item, the mark of a handled item, or no record yet.
    private enum Place {
        case work, older, laterCopilot, questions, posting, handled, new
    }

    private mutating func add(_ item: Item, _ place: Place) {
        switch place {
        case .work: work.append(item)
        case .older: older.append(item)
        case .laterCopilot: laterCopilot.append(item)
        case .questions: questions.append(item)
        case .posting: posting.append(item)
        case .handled, .new: break
        }
    }

    // A trusted author who is not a bot: Copilot gives only threads.
    private static func isTrustedHuman(_ author: Author, _ viewer: String) -> Bool {
        !author.isBot && Authors.isTrusted(author, viewer: viewer)
    }

    // The Copilot review with the earliest submit time. A review that is not submitted does not
    // count. Of two reviews at one time, the first in the list wins.
    package static func firstCopilotReview(_ reviews: [PRReview]) -> NodeID? {
        var first: PRReview?
        for review in reviews where Authors.isCopilot(review.author) {
            guard let time = review.submittedAt else { continue }
            if let earlier = first?.submittedAt, earlier <= time { continue }
            first = review
        }
        return first?.id
    }
}

enum MyPRRules {
    static func rows(
        _ answer: PollAnswer, _ state: ReviewsState, _ config: ReviewsConfig,
        clones: CloneStates = CloneStates()
    ) -> [ReviewRow] {
        let baseline = Set(state.baseline)
        let since = state.fixFrom ?? state.turnedOnAt
        // With automatic rounds off, or with no consent yet, new work waits for Handle now too.
        let autoFix = state.allowsAutoFix(config.autoFix)
        // With the CI work off, or with no consent, the CI question is hidden.
        let showsCI = state.allowsCIFix(config.fixCI)
        let rows = answer.mine.filter { !IgnoreRule.matches(config.ignore, $0.key.repo) }.map {
            pr -> (pr: PullRequest, row: ReviewRow, rank: Int) in
            let prState = state.prs[pr.key] ?? PRState()
            let items = OpenItems(
                threads: pr.threads, reviews: pr.reviews, comments: pr.comments,
                viewer: answer.viewer, state: prState, baseline: baseline, since: since)
            let status = Self.status(pr, viewer: answer.viewer, items: items)
            let ciQuestion = CIRule.visibleQuestion(pr, prState.ci, allowed: showsCI)
            let claude = Self.claude(
                pr, prState, queue: state.queue, clones: clones, ciQuestion: ciQuestion)
            let later = items.laterCopilot.count
            let waiting = items.older.count + (autoFix ? 0 : items.work.count)
            let row = ReviewRow(
                id: pr.key, state: .mine(status, claude), repo: pr.key.repo.name, title: pr.title,
                dot: nil, tag: pr.failedChecks > 0 ? RowText.failedChecks(pr.failedChecks) : nil,
                review: RowText.status(status, cut: isCut(pr)),
                reviewers: reviewers(pr, viewer: answer.viewer),
                notes: [
                    later == 0 ? nil : RowText.laterCopilot(later),
                    waiting == 0 ? nil : RowText.older(waiting),
                ].compactMap { $0 },
                status: RowText.claude(claude), waiting: waiting, laterCopilot: later,
                questions: Self.openQuestions(prState) + (ciQuestion == nil ? 0 : 1),
                unsentUpdates: Self.hasUnsentUpdates(prState),
                unsavedFiles: prState.waiting?.files.count ?? 0,
                resolvable: Self.isResolvable(pr, prState, queue: state.queue))
            return (pr, row, rank(status, claude))
        }
        // A row that needs the user first, then the groups of the status, then the last update
        // first, then the key.
        return rows.sorted { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            if left.pr.updatedAt != right.pr.updatedAt {
                return left.pr.updatedAt > right.pr.updatedAt
            }
            return left.pr.key < right.pr.key
        }.map(\.row)
    }

    // The questions of Claude on comments that wait for an answer.
    private static func openQuestions(_ prState: PRState) -> Int {
        prState.questions.values.count(where: { $0.answer == nil })
    }

    // True when Resolve now can start a conflict round: GitHub says that the PR has conflicts,
    // the PR does not come from a fork, no round runs, no round of the user's side waits in the
    // queue, and no writes wait (an outbox).
    static func isResolvable(_ pr: PullRequest, _ prState: PRState, queue: [QueueEntry]) -> Bool {
        pr.mergeable == .conflicting && !pr.isCrossRepository && prState.round == nil
            && !queue.contains { $0.pr == pr.key && $0.kind.isMine } && prState.outbox == nil
    }

    // True when the writes of a stopped round wait for Try again (a kept outbox), with no round.
    // An own outbox counts only when it waits for the user (a reason on the row): with no reason
    // its writes run now, or go on by themselves after a quit.
    static func hasUnsentUpdates(_ prState: PRState) -> Bool {
        guard prState.round == nil, let outbox = prState.outbox else { return false }
        return !outbox.own || prState.waitsForYou != nil
    }

    private static func rank(_ status: ReviewStatus, _ claude: ClaudeState) -> Int {
        if claude.needsTheUser { return 0 }
        return switch status {
        case .changesRequested: 1
        case .comments: 2
        case .pending: 3
        case .approved: 4
        }
    }

    // The review status. The first rule that holds wins:
    // 1. Changes requested: the latest decision of a human reviewer requests changes.
    // 2. Comments: a thread is open in the work, the older items, the questions or the outbox.
    //    Only a thread counts: a review body or a top-level comment stays work, but does not
    //    change the status, so a "Thanks" never hides an approval.
    // 3. Approved: a human reviewer approved, and no thread is open.
    // 4. Pending: each other case, also with no reviewer.
    // Copilot is never a reviewer here: its threads can give Comments, but never Approved.
    static func status(_ pr: PullRequest, viewer: String, items: OpenItems) -> ReviewStatus {
        let decisions = humanDecisions(pr.decisions, viewer: viewer)
        if decisions.contains(.changesRequested) { return .changesRequested }
        let lists = [items.work, items.older, items.questions, items.posting]
        if lists.joined().contains(where: { $0.kind == .thread }) { return .comments }
        return decisions.contains(.approved) ? .approved : .pending
    }

    // The latest decision of each human reviewer: an approval, a change request or a dismissal.
    // A comment does not change a decision, as on GitHub. The user and the bots are not
    // reviewers.
    private static func humanDecisions(_ decisions: [PRReview], viewer: String) -> [ReviewState] {
        var latest: [String: PRReview] = [:]
        for review in decisions {
            let login = review.author.login.lowercased()
            guard !review.author.isBot, login != viewer.lowercased(),
                review.state != .commented, review.state != .pending,
                let time = review.submittedAt
            else { continue }
            if let before = latest[login]?.submittedAt, before > time { continue }
            latest[login] = review
        }
        return latest.values.map(\.state)
    }

    // The requested reviewers, then the authors of the reviews, each one time and without the
    // user. Copilot shows as "Copilot".
    static func reviewers(_ pr: PullRequest, viewer: String) -> [Reviewer] {
        var names: [Reviewer] = []
        let logins =
            pr.requestedUsers + pr.reviews.map(\.author.login) + pr.decisions.map(\.author.login)
        for login in logins where login.lowercased() != viewer.lowercased() {
            let name = login == Authors.copilotLogin ? "Copilot" : login
            guard !names.contains(where: { $0.name == name }) else { continue }
            names.append(Reviewer(name: name, tone: tone(of: login, in: pr)))
        }
        return names
    }

    // The colour of a reviewer. The latest opinion decides: an approval is soft green and a
    // change request is red. A later comment does not change it. With no opinion, a comment is
    // amber. A dismissed opinion, a request with no review and Copilot are grey.
    private static func tone(of login: String, in pr: PullRequest) -> RowTone {
        guard login != Authors.copilotLogin else { return .dim }
        var latest: PRReview?
        var commented = false
        for review in pr.reviews + pr.decisions where review.author.login == login {
            if review.state == .commented { commented = true }
            guard review.state != .commented, review.state != .pending else { continue }
            let time = review.submittedAt ?? .distantPast
            if latest == nil || time >= latest?.submittedAt ?? .distantPast { latest = review }
        }
        switch latest?.state {
        case .approved?: return .green
        case .changesRequested?: return .red
        case nil: return commented ? .amber : .dim
        case .dismissed?, .commented?, .pending?: return .dim
        }
    }

    // What Claude does on the PR. The first rule that holds wins:
    // 1. A round runs: a request round works on its items, a conflict round resolves the
    //    conflicts and a CI round works on the failed checks.
    // 2. A round of the user's side waits in the queue. It waits for the clone of its repository
    //    while the clone runs, and for the trust of the user while the clone needs it.
    // 3. Claude has open questions on comments, or the row shows the CI question (ciQuestion).
    // 4. The work waits for the user: an own request that did not go, or changes that no round
    //    made.
    // 5. The last round failed.
    // 6. A re-run of the failed jobs of the head waits for its result.
    // 7. The PR comes from a fork.
    // 8. GitHub says that the PR has conflicts. The row gives the reason of the failed attempt
    //    only when that attempt was on this head and this base.
    // 9. Else Claude waits.
    static func claude(
        _ pr: PullRequest, _ prState: PRState, queue: [QueueEntry],
        clones: CloneStates = CloneStates(), ciQuestion: CIQuestion? = nil
    ) -> ClaudeState {
        if let round = prState.round {
            switch round.kind {
            case .review, .request: return .fixing(round.items.count)
            case .conflict: return .resolvingConflicts
            case .ci: return .fixingCI
            }
        }
        if queue.contains(where: { $0.pr == pr.key && $0.kind.isMine }) {
            let repo = pr.key.repo
            if clones.cloning.contains(repo) { return .cloning }
            return clones.needsTrust.contains(repo) ? .trustNeeded : .queued
        }
        let questions = openQuestions(prState)
        if questions > 0 || ciQuestion != nil {
            return .needsYou(comments: questions, ci: ciQuestion != nil)
        }
        if let waiting = prState.waiting {
            switch waiting.kind {
            case .unpushed: return .unpushedChanges
            case .unpushedRequest: return .unpushedComments
            case .askAgain: return .askAgain
            case .other: return .waitsForYou(waiting.reason)
            }
        }
        if let reason = prState.lastError { return .error(reason) }
        if CIRule.isRetrying(pr, prState.ci) { return .retryingCI }
        if pr.isCrossRepository { return .fork }
        if pr.mergeable == .conflicting { return .conflicts(conflictFailure(pr, prState.conflict)) }
        return .waiting
    }

    // The reason of a failed conflict attempt on the head and the base of the PR, or nil. A
    // failure with no reason (a mark that Bifrost could not read in full) gives nil, so the row
    // shows the tip of Resolve now.
    private static func conflictFailure(_ pr: PullRequest, _ mark: ConflictMark?) -> String? {
        guard let mark, mark.matches(pr), case .failed(let reason) = mark.outcome,
            !reason.isEmpty
        else { return nil }
        return reason
    }

    // True when a list of the PR can lack items: GitHub has more than the poll reads, or Bifrost
    // can't read the list.
    private static func isCut(_ pr: PullRequest) -> Bool {
        pr.truncatedThreads || pr.truncatedReviews || pr.truncatedComments || pr.truncatedChecks
    }
}
