// The Review panel (docs/behaviour/reviews.md, "The Review panel"): Claude's draft review as
// GitHub gives it (DraftRead), its comments in the panel (DraftCommentEdit), the checks of an
// action of the panel, and the writes of Send review, Discard draft and Approve instead with
// their guard. Only a click of the user starts a write. Just before the writes, Bifrost reads the
// PR and the draft again and refuses when they changed: Bifrost never writes over a change that
// the user made on GitHub, and changes only Claude's own pending draft.
import BifrostFoundation
import Foundation

// The draft review as GitHub gives it (DraftQueries.draft).
package struct DraftRead: Sendable, Equatable {
    package struct Comment: Sendable, Equatable {
        package var id: NodeID
        package var path: String
        // The line, or the original line for a comment on an outdated diff.
        package var line: Int?
        package var startLine: Int?
        // The diff hunk of the comment, as GitHub gives it.
        package var hunk: String
        package var body: String

        package init(
            id: NodeID, path: String, line: Int?, startLine: Int? = nil, hunk: String = "",
            body: String
        ) {
            self.id = id
            self.path = path
            self.line = line
            self.startLine = startLine
            self.hunk = hunk
            self.body = body
        }
    }

    package var id: NodeID
    package var state: ReviewState?
    package var body: String
    package var commit: CommitID?
    // True when the viewer wrote the review.
    package var mine: Bool
    package var comments: [Comment]
    // True when the review has more comments than the read gets (DraftEdits.maxComments).
    package var truncated: Bool

    package init(
        id: NodeID, state: ReviewState?, body: String, commit: CommitID?, mine: Bool,
        comments: [Comment], truncated: Bool = false
    ) {
        self.id = id
        self.state = state
        self.body = body
        self.commit = commit
        self.mine = mine
        self.comments = comments
        self.truncated = truncated
    }

    // One page of the read: the review with the comments of the page, and the cursor of the next
    // page. An answer with errors fails, also next to data, and a node that is not a review is a
    // bad answer. A comment with no ID is left out.
    package static func page(_ data: Data) -> Result<(draft: DraftRead, next: String?), GitHubError>
    {
        ReviewAnswer.fields(of: data).flatMap { fields in
            guard let node = fields["node"]?.object,
                let id = node["id"]?.string.flatMap(NodeID.init)
            else { return .failure(.badAnswer) }
            let comments = node["comments"].nodes.compactMap { item -> Comment? in
                guard let comment = item["id"]?.string.flatMap(NodeID.init) else { return nil }
                return Comment(
                    id: comment, path: item["path"]?.string ?? "",
                    line: item["line"]?.wholeNumber ?? item["originalLine"]?.wholeNumber,
                    startLine: item["startLine"]?.wholeNumber
                        ?? item["originalStartLine"]?.wholeNumber,
                    hunk: item["diffHunk"]?.string ?? "", body: item["body"]?.string ?? "")
            }
            let draft = DraftRead(
                id: id, state: node["state"]?.string.flatMap(ReviewState.init(rawValue:)),
                body: node["body"]?.string ?? "",
                commit: node["commit"]?.object?["oid"]?.string.flatMap(CommitID.init),
                mine: node["viewerDidAuthor"] == .bool(true), comments: comments)
            return .success((draft, ReviewAnswer.cursor(node["comments"])))
        }
    }
}

// The draft that the panel showed when it opened: the review, the summary and the text of each
// comment. Each send compares the fresh read with it, and a good edit write updates it, so a
// second Send after a partial failure does not take Bifrost's own write for a change on GitHub.
package struct OpenedDraft: Sendable, Equatable {
    package var review: NodeID
    package var body: String
    package var comments: [NodeID: String]

    package init(_ draft: DraftRead) {
        review = draft.id
        body = draft.body
        comments = Dictionary(
            draft.comments.map { ($0.id, $0.body) }, uniquingKeysWith: { first, _ in first })
    }
}

// One comment of the draft in the panel, with its new text or its removal.
package struct DraftCommentEdit: Sendable, Equatable, Identifiable {
    package let id: NodeID
    package let path: String
    package let line: Int?
    package let startLine: Int?
    // The last lines of the diff hunk of the comment (DraftEdits.lastLines).
    package let hunk: [String]
    // True when the user added the comment on GitHub: Claude didn't draft it.
    package let yours: Bool
    // The text of the comment in the panel.
    package var text: String
    // True when the user removed the comment in the panel.
    package var removed: Bool

    package init(
        id: NodeID, path: String, line: Int?, startLine: Int? = nil, hunk: [String] = [],
        yours: Bool = false, text: String, removed: Bool = false
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.startLine = startLine
        self.hunk = hunk
        self.yours = yours
        self.text = text
        self.removed = removed
    }

    // The place of the comment: "src/a.swift line 12", "src/a.swift lines 10-12", or the path.
    package var place: String {
        guard let line else { return path }
        if let startLine, startLine != line { return "\(path) lines \(startLine)-\(line)" }
        return "\(path) line \(line)"
    }
}

// One write of the Review panel on Claude's draft.
package enum DraftStep: Sendable, Equatable {
    case body(String)
    case comment(NodeID, String)
    case remove(NodeID)
    case submit(DraftEvent)
    case discard
}

// Why an action of the Review panel did not go through, or why Bifrost doesn't know whether
// GitHub saved it. Each text is friendly and plain, for the error line of the panel.
package enum DraftRefusal: Error, Sendable, Equatable {
    // The row doesn't offer the draft now (a round runs, the mark changed, Reviews is off), or
    // the panel didn't open this draft.
    case notOffered
    // Another action of the panel runs now. This one sent nothing.
    case busy
    // A review write of the findings form of the PR may have gone, and no poll after it has
    // shown the true state on GitHub (ReviewWrites.waitsForPoll). Nothing was sent.
    case waitsForPoll
    case closed
    case ownPR
    case gone
    case otherCommit
    // The head of the PR is not the reviewed commit: only Discard draft can go.
    case headMoved
    case tooMany
    // The draft changed on GitHub after the panel opened.
    case edited
    case empty
    case needsSummary
    case blankComment
    case tooLong
    // The guard of the writes refused one. Nothing more was sent.
    case guardRefused
    case readFailed(GitHubError)
    // A write of a summary or a comment did not work, or GitHub can have saved only a part.
    case editFailed
    case editUnknown
    // A fresh read before an edit, or the answer of an edit, says that the review isn't pending.
    case notPending
    case sendFailed
    case sendUnknown
    case notAsSent
    case discardFailed
    case discardUnknown
    // A write didn't go, for a reason of gh (not installed, not logged in, ...).
    case notChanged(GitHubError)
    // Approve instead stopped before the delete of the draft, for the reason of the approval.
    case approveRefused(ApproveRefusal)
    // Approve instead deleted the draft, and then the approval didn't go through, or GitHub can
    // have saved it.
    case insteadFailed
    case insteadUnknown

    // True when the state on GitHub can be other than the state that Bifrost knows: GitHub can
    // have made the change, or the review isn't a draft any more. A poll then shows the true
    // state.
    package var mayHaveChanged: Bool {
        switch self {
        case .editUnknown, .sendUnknown, .notAsSent, .discardUnknown, .insteadUnknown, .notPending,
            .waitsForPoll:
            true
        default: false
        }
    }

    package var message: String {
        switch self {
        case .notOffered:
            "You can't change this draft right now. The row in the Reviews panel shows why."
        case .busy: "Bifrost is still working on this draft. Wait for it to finish, then try again."
        case .waitsForPoll: FindingsRefusal.unknown.message
        case .closed:
            "This pull request is closed or merged, so Bifrost didn't change the draft."
        case .ownPR: "This is your own pull request, so Bifrost didn't change the draft."
        case .gone:
            "Bifrost couldn't find Claude's draft review on GitHub, so it didn't change anything. "
                + "The draft may have been submitted or deleted."
        case .otherCommit:
            "Claude's draft review is on another commit, so Bifrost didn't change it."
        case .headMoved:
            "This pull request changed after Claude's review, so Bifrost didn't send or approve "
                + "it. You can still discard the draft."
        case .tooMany:
            "This draft has more comments than Bifrost can show. Please finish it on GitHub."
        case .edited:
            "The draft changed on GitHub after you opened it, so Bifrost sent nothing. Close this "
                + "panel and open it again."
        case .empty: "Add a summary or keep a comment, then send the review."
        case .needsSummary: "Add a summary to request changes."
        case .blankComment: "One comment has no text. Write something, or remove the comment."
        case .tooLong:
            "The summary or a comment is longer than GitHub allows. Shorten it, then send the "
                + "review."
        case .guardRefused:
            "Bifrost stopped this because it didn't match Claude's draft. Nothing more was sent."
        case .readFailed(let error):
            "Bifrost couldn't load this draft from GitHub, so it stopped there. \(error.message)"
        case .editFailed:
            "GitHub didn't take all of your changes, so the review is still a draft. Your edits "
                + "are still here, so you can send it again. The Event log has the details."
        case .editUnknown:
            "Bifrost couldn't tell if GitHub saved all of your changes. The review is still a "
                + "draft, and your edits are still here, so you can send it again."
        case .notPending:
            "Claude's review isn't a draft on GitHub any more. Check the pull request on GitHub."
        case .sendFailed:
            "GitHub didn't send the review, so it's still a draft. Your edits are still here, so "
                + "you can try again. The Event log has the details."
        case .sendUnknown:
            "Bifrost couldn't tell if GitHub sent your review. Click Refresh to check."
        case .notAsSent:
            "GitHub saved the review, but not as you sent it. Check the pull request on GitHub."
        case .discardFailed: "GitHub didn't delete the draft. The Event log has the details."
        case .discardUnknown:
            "Bifrost couldn't tell if GitHub deleted the draft. Click Refresh to check."
        case .notChanged(let error): "Bifrost couldn't change the draft. \(error.message)"
        case .approveRefused(let refusal): refusal.message
        case .insteadFailed:
            "The draft is deleted, but the approval didn't go through. Click Approve on the row "
                + "to try again."
        case .insteadUnknown:
            "The draft is deleted, but Bifrost couldn't tell if GitHub saved your approval. "
                + "Click Refresh to check."
        }
    }
}

package enum DraftEdits {
    // The most comments that the panel reads, in pages of pageSize.
    package static let maxComments = 300
    package static let pageSize = 100
    // The last lines of a diff hunk that the panel shows, and the longest line in characters.
    static let hunkLines = 4
    static let hunkWidth = 300

    // The fresh check of the PR before an action of the panel: the reason not to write, or nil.
    // needsHead: the action needs the reviewed commit as the head of the PR (Send review and
    // Approve instead); Discard draft can go on a PR that changed.
    package static func refusal(
        _ fresh: FreshPR, viewer: String, mark: RecommendationMark, needsHead: Bool
    ) -> DraftRefusal? {
        if fresh.state != .open { return .closed }
        if fresh.author.lowercased() == viewer.lowercased() { return .ownPR }
        // The read gives only pending reviews, so a draft that isn't pending is missing.
        guard let pending = fresh.pending, pending.id == mark.reviewID else { return .gone }
        if pending.commit != mark.headSHA { return .otherCommit }
        return needsHead && fresh.headSHA != mark.headSHA ? .headMoved : nil
    }

    // The check of the read of the draft: the review of the mark, pending, by the viewer, on the
    // reviewed commit, with all its comments.
    package static func problem(_ draft: DraftRead, mark: RecommendationMark) -> DraftRefusal? {
        guard draft.id == mark.reviewID, draft.state == .pending, draft.mine else { return .gone }
        if draft.commit != mark.headSHA { return .otherCommit }
        return draft.truncated ? .tooMany : nil
    }

    // The comments of the panel, in the order of GitHub. A saved draft text of Claude for the
    // review (DraftRecord) with the same path and line makes one comment Claude's; each other
    // comment is one that the user added on GitHub.
    package static func comments(_ draft: DraftRead, drafts: [DraftRecord]) -> [DraftCommentEdit] {
        var claude = drafts.filter { $0.reviewID == draft.id && !$0.path.isEmpty }
        return draft.comments.map { comment in
            let index = claude.firstIndex { $0.path == comment.path && $0.line == comment.line }
            if let index { claude.remove(at: index) }
            return DraftCommentEdit(
                id: comment.id, path: comment.path, line: comment.line,
                startLine: comment.startLine, hunk: lastLines(comment.hunk), yours: index == nil,
                text: comment.body)
        }
    }

    // The last hunkLines lines of a diff hunk, each one cut to hunkWidth characters.
    static func lastLines(_ hunk: String) -> [String] {
        guard !hunk.isEmpty else { return [] }
        let lines = hunk.replacing("\r\n", with: "\n").replacing("\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(hunkLines).map { String($0.prefix(hunkWidth)) }
    }

    // The writes of Send review, in order: the summary, each changed comment, each removed
    // comment, then the submit. Each check comes before the first write. Bifrost writes a text
    // only where the edit is not the text of the fresh read, so a second Send after a partial
    // failure writes only the rest. A comment that the user removed and that is gone from GitHub
    // needs no write.
    package static func plan(
        _ draft: DraftRead, opened: OpenedDraft, summary: String, comments: [DraftCommentEdit],
        event: DraftEvent
    ) -> Result<[DraftStep], DraftRefusal> {
        let read = Dictionary(
            draft.comments.map { ($0.id, $0.body) }, uniquingKeysWith: { first, _ in first })
        let edited = Dictionary(
            comments.map { ($0.id, $0.removed ? nil : $0.text) },
            uniquingKeysWith: { first, _ in first })
        // A text of the fresh read changed on GitHub after the open: it is neither the text that
        // the panel showed nor the edit of the user, so the edit must not go over it.
        func newer(_ fresh: String, shown: String?, edit: String?) -> Bool {
            fresh != shown && fresh != edit
        }
        if newer(draft.body, shown: opened.body, edit: summary) { return .failure(.edited) }
        for comment in draft.comments {
            // The user added or changed a comment on GitHub after the open.
            guard let shown = opened.comments[comment.id], let edit = edited[comment.id],
                !newer(comment.body, shown: shown, edit: edit)
            else { return .failure(.edited) }
        }
        // A comment that the user keeps is gone from GitHub.
        if comments.contains(where: { !$0.removed && read[$0.id] == nil }) {
            return .failure(.edited)
        }
        let kept = comments.filter { !$0.removed }
        if kept.contains(where: { $0.text.trimmed().isEmpty }) { return .failure(.blankComment) }
        let limit = ReviewResult.maxReviewBody
        if summary.utf16.count > limit || kept.contains(where: { $0.text.utf16.count > limit }) {
            return .failure(.tooLong)
        }
        let hasSummary = !summary.trimmed().isEmpty
        // GitHub needs a text for each event, and Request changes needs a summary.
        if event == .requestChanges && !hasSummary { return .failure(.needsSummary) }
        if !hasSummary && kept.isEmpty { return .failure(.empty) }
        var steps: [DraftStep] = []
        if summary != draft.body { steps.append(.body(summary)) }
        for comment in kept where comment.text != read[comment.id] {
            steps.append(.comment(comment.id, comment.text))
        }
        for comment in comments where comment.removed && read[comment.id] != nil {
            steps.append(.remove(comment.id))
        }
        steps.append(.submit(event))
        return .success(steps)
    }

    // The one write of a step, or nil when the guard refuses it. The write goes only to the PR of
    // the row (the key of the address that GitHub gave), only to the draft review of the mark on
    // the reviewed commit, and a comment write only to a comment that the fresh read of the draft
    // gave.
    package static func write(
        _ step: DraftStep, pr: PRKey, mark: RecommendationMark, fresh: FreshPR,
        draft: DraftRead?, click: UserClick
    ) -> GitHubWrite? {
        guard fresh.key == pr, let review = mark.reviewID, let pending = fresh.pending,
            pending.id == review, pending.commit == mark.headSHA
        else { return nil }
        func known(_ comment: NodeID) -> Bool {
            draft?.id == review && draft?.comments.contains { $0.id == comment } == true
        }
        switch step {
        case .body(let text):
            return .editDraftBody(review: review, body: text, click: click)
        case .comment(let comment, let text):
            guard known(comment) else { return nil }
            return .editDraftComment(comment: comment, body: text, click: click)
        case .remove(let comment):
            guard known(comment) else { return nil }
            return .removeDraftComment(comment: comment, click: click)
        case .submit(let event):
            return .submitDraft(review: review, event: event, click: click)
        case .discard:
            return .discardDraft(review: review, click: click)
        }
    }

    // The result of a write from the answer of GitHub: nil when GitHub made the change. An answer
    // with no object is unknown. A summary write must leave the review pending, and a submit must
    // give the state of its event.
    package static func outcome(_ answer: Data, of step: DraftStep, write: GitHubWrite)
        -> DraftRefusal?
    {
        let node = write.answerNode(answer)
        let saved = node?["id"]?.string?.isEmpty == false
        switch step {
        case .comment, .remove:
            return saved ? nil : .editUnknown
        case .discard:
            return saved ? nil : .discardUnknown
        case .body:
            guard saved else { return .editUnknown }
            return node?["state"] == .string(ReviewState.pending.rawValue) ? nil : .notPending
        case .submit(let event):
            guard saved else { return .sendUnknown }
            let state: ReviewState = event == .comment ? .commented : .changesRequested
            return node?["state"] == .string(state.rawValue) ? nil : .notAsSent
        }
    }

    // The refusal of a write that failed. A write that GitHub can have made is unknown, and
    // Bifrost never sends it again by itself. A refusal of GitHub with its text goes to the Event
    // log.
    package static func failure(_ error: GitHubError, of step: DraftStep) -> DraftRefusal {
        let refusedWithText = if case .refused(let line) = error { !line.isEmpty } else { false }
        switch step {
        case .body, .comment, .remove:
            if error.writeMayHaveHappened { return .editUnknown }
            return refusedWithText ? .editFailed : .notChanged(error)
        case .submit:
            if error.writeMayHaveHappened { return .sendUnknown }
            return refusedWithText ? .sendFailed : .notChanged(error)
        case .discard:
            if error.writeMayHaveHappened { return .discardUnknown }
            return refusedWithText ? .discardFailed : .notChanged(error)
        }
    }
}
