// The rules of the Review panel (docs/behaviour/reviews.md, "The Review panel"): the read of a
// draft page, the comments of the panel, the plan of Send review, the checks, the guard of each
// write and the result of each write.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

struct DraftEditsTests {
    private func node(_ text: String) throws -> NodeID { try ReviewData.node(text) }

    private func draft(_ body: String = "Summary.", comments: [(String, String)]) throws
        -> DraftRead
    {
        DraftRead(
            id: try node("PRR_claude"), state: .pending, body: body,
            commit: try ReviewData.commit(), mine: true,
            comments: try comments.map {
                DraftRead.Comment(id: try node($0.0), path: "src/a.swift", line: 1, body: $0.1)
            })
    }

    private func edits(_ read: DraftRead) -> [DraftCommentEdit] {
        read.comments.map {
            DraftCommentEdit(id: $0.id, path: $0.path, line: $0.line, text: $0.body)
        }
    }

    private func mark() throws -> RecommendationMark {
        RecommendationMark(
            value: .comment, why: "", headSHA: try ReviewData.commit(),
            reviewID: try node("PRR_claude"), at: Rows.now)
    }

    // A page keeps each comment with its ID, takes the original line of an outdated comment,
    // and gives the cursor of the next page. Errors fail.
    @Test func aPageOfTheDraftDecodes() throws {
        let data = DraftAnswers.json([
            "data": [
                "node": [
                    "id": "PRR_claude", "state": "PENDING", "body": "Sum.",
                    "viewerDidAuthor": true, "commit": ["oid": .string(ReviewData.headHex)],
                    "comments": [
                        "pageInfo": ["hasNextPage": true, "endCursor": "c2"],
                        "nodes": [
                            [
                                "id": "PRRC_1", "path": "a", "line": .null, "originalLine": 9,
                                "startLine": .null, "originalStartLine": 7, "diffHunk": "@@",
                                "body": "One.",
                            ],
                            ["path": "b", "line": 2, "body": "No ID."],
                        ],
                    ],
                ]
            ]
        ])
        let page = try DraftRead.page(data).get()
        #expect(page.next == "c2")
        #expect(page.draft.state == .pending && page.draft.mine && page.draft.body == "Sum.")
        #expect(
            page.draft.comments
                == [
                    DraftRead.Comment(
                        id: try node("PRRC_1"), path: "a", line: 9, startLine: 7, hunk: "@@",
                        body: "One.")
                ])
        let errors = DraftAnswers.json(["errors": [["message": "Gone."]], "data": ["node": .null]])
        #expect(throws: GitHubError.refused("Gone.")) { try DraftRead.page(errors).get() }
    }

    // Each comment of the panel has its place and the end of its hunk. A saved draft text of
    // Claude with the same path and line makes a comment Claude's, once; each other comment is
    // the user's.
    @Test func theCommentsOfThePanel() throws {
        let review = try node("PRR_claude")
        let read = DraftRead(
            id: review, state: .pending, body: "", commit: nil, mine: true,
            comments: [
                .init(
                    id: try node("C1"), path: "a", line: 4, startLine: 2,
                    hunk: "@@\r\n1\r\n2\n3\r4\n5", body: "One."),
                .init(id: try node("C2"), path: "a", line: 4, body: "Two."),
                .init(id: try node("C3"), path: "b", line: nil, body: "Three."),
            ])
        let saved = DraftRecord(
            reviewID: review, pr: try ReviewData.pr(), path: "a", line: 4, body: "", at: Rows.now)
        let comments = DraftEdits.comments(read, drafts: [saved])
        #expect(comments.map(\.yours) == [false, true, true])
        #expect(comments.map(\.place) == ["a lines 2-4", "a line 4", "b"])
        #expect(comments.first?.hunk == ["2", "3", "4", "5"])
        let long = DraftEdits.lastLines(String(repeating: "x", count: 400))
        #expect(long == [String(repeating: "x", count: 300)])
    }

    // The writes of a send: the summary, each changed comment, each removed comment, then the
    // submit. A text that is already the text of GitHub needs no write, so a second send after a
    // partial failure writes only the rest.
    @Test func theSendPlansItsWritesInOrder() throws {
        let read = try draft(comments: [("C1", "One."), ("C2", "Two."), ("C3", "Three.")])
        let opened = OpenedDraft(read)
        var comments = edits(read)
        comments[0].text = "One!"
        comments[2].removed = true
        let plan = DraftEdits.plan(
            read, opened: opened, summary: "New.", comments: comments, event: .comment)
        #expect(
            plan == .success([
                .body("New."), .comment(try node("C1"), "One!"), .remove(try node("C3")),
                .submit(.comment),
            ]))
        // After the summary and the first comment went, GitHub has them: only the rest goes.
        var after = try draft("New.", comments: [("C1", "One!"), ("C2", "Two."), ("C3", "Three.")])
        var remembered = opened
        remembered.body = "New."
        remembered.comments[try node("C1")] = "One!"
        func again(_ read: DraftRead) -> Result<[DraftStep], DraftRefusal> {
            DraftEdits.plan(
                read, opened: remembered, summary: "New.", comments: comments, event: .comment)
        }
        #expect(again(after) == .success([.remove(try node("C3")), .submit(.comment)]))
        // A removed comment that is gone from GitHub needs no write.
        after.comments.removeLast()
        #expect(again(after) == .success([.submit(.comment)]))
    }

    // The checks of a send, before any write.
    @Test func theSendChecks() throws {
        let read = try draft(comments: [("C1", "One.")])
        let opened = OpenedDraft(read)
        let comments = edits(read)
        func plan(
            _ read: DraftRead, _ summary: String, _ comments: [DraftCommentEdit],
            _ event: DraftEvent = .comment
        ) -> DraftRefusal? {
            if case .failure(let refusal) = DraftEdits.plan(
                read, opened: opened, summary: summary, comments: comments, event: event)
            {
                return refusal
            }
            return nil
        }
        // The summary changed on GitHub, and is not the edit of the user.
        let theirs = try draft("Theirs.", comments: [("C1", "One.")])
        #expect(plan(theirs, "Summary.", comments) == .edited)
        // The same text as the edit is no change.
        #expect(plan(try draft("Mine.", comments: [("C1", "One.")]), "Mine.", comments) == nil)
        // A comment that GitHub has and the panel didn't show.
        let added = try draft(comments: [("C1", "One."), ("C9", "New.")])
        #expect(plan(added, "Summary.", comments) == .edited)
        // A kept comment that is gone from GitHub.
        #expect(plan(try draft(comments: []), "Summary.", comments) == .edited)
        var blank = comments
        blank[0].text = "  "
        #expect(plan(read, "Summary.", blank) == .blankComment)
        #expect(plan(read, " ", comments, .requestChanges) == .needsSummary)
        var none = comments
        none[0].removed = true
        #expect(plan(read, "", none) == .empty)
        #expect(plan(read, String(repeating: "a", count: 65_537), comments) == .tooLong)
    }

    // The fresh checks of the PR and of the draft.
    @Test func theFreshChecks() throws {
        let commit = try ReviewData.commit()
        let claude = PendingDraft(id: try node("PRR_claude"), body: "", commit: commit)
        var fresh = FreshPR(
            id: try node("PR_1"), url: "", author: "user-a", headSHA: commit, pending: claude)
        let mark = try mark()
        func refusal(_ fresh: FreshPR, needsHead: Bool) -> DraftRefusal? {
            DraftEdits.refusal(fresh, viewer: Rows.viewer, mark: mark, needsHead: needsHead)
        }
        #expect(refusal(fresh, needsHead: true) == nil)
        fresh.headSHA = try ReviewData.commit(ReviewData.oldHex)
        #expect(refusal(fresh, needsHead: true) == .headMoved)
        #expect(refusal(fresh, needsHead: false) == nil)
        fresh.pending = PendingDraft(id: try node("PRR_mine"), body: "", commit: commit)
        #expect(refusal(fresh, needsHead: false) == .gone)
        fresh.author = Rows.viewer
        #expect(refusal(fresh, needsHead: false) == .ownPR)
        var read = try draft(comments: [])
        #expect(DraftEdits.problem(read, mark: mark) == nil)
        read.truncated = true
        #expect(DraftEdits.problem(read, mark: mark) == .tooMany)
        read.state = .commented
        #expect(DraftEdits.problem(read, mark: mark) == .gone)
    }

    // The guard: only the PR of the row, only Claude's draft on the reviewed commit, and a comment
    // only when the fresh read gave it.
    @Test func theGuardOfEachWrite() throws {
        let commit = try ReviewData.commit()
        let pr = try ReviewData.pr()
        let review = try node("PRR_claude")
        let fresh = FreshPR(
            id: try node("PR_1"), url: pr.webURL.absoluteString, author: "user-a",
            headSHA: commit, pending: PendingDraft(id: review, body: "", commit: commit))
        let read = try draft(comments: [("C1", "One.")])
        let click = UserClick()
        func write(_ step: DraftStep, _ fresh: FreshPR) throws -> GitHubWrite? {
            DraftEdits.write(
                step, pr: pr, mark: try mark(), fresh: fresh, draft: read, click: click)
        }
        #expect(
            try write(.body("B"), fresh) == .editDraftBody(review: review, body: "B", click: click))
        #expect(
            try write(.comment(try node("C1"), "T"), fresh)
                == .editDraftComment(comment: try node("C1"), body: "T", click: click))
        #expect(try write(.comment(try node("C9"), "T"), fresh) == nil)
        #expect(try write(.remove(try node("C9")), fresh) == nil)
        #expect(
            try write(.submit(.requestChanges), fresh)
                == .submitDraft(review: review, event: .requestChanges, click: click))
        #expect(try write(.discard, fresh) == .discardDraft(review: review, click: click))
        var other = fresh
        other.url = "https://github.com/Owner-A/Repo-A/pull/8"
        #expect(try write(.discard, other) == nil)
        other = fresh
        other.pending = PendingDraft(id: try node("PRR_mine"), body: "", commit: commit)
        #expect(try write(.discard, other) == nil)
    }

    // The result of each write, and the refusal of each failure: a write that GitHub can have
    // made is unknown, and a refusal of GitHub with its text says so.
    @Test func theResultOfEachWrite() throws {
        let review = try node("PRR_claude")
        let click = UserClick()
        let body = GitHubWrite.editDraftBody(review: review, body: "B", click: click)
        func outcome(_ write: GitHubWrite, _ step: DraftStep, _ state: String) -> DraftRefusal? {
            DraftEdits.outcome(DraftAnswers.written(write, state: state), of: step, write: write)
        }
        #expect(outcome(body, .body("B"), "PENDING") == nil)
        #expect(outcome(body, .body("B"), "COMMENTED") == .notPending)
        let submit = GitHubWrite.submitDraft(review: review, event: .comment, click: click)
        #expect(outcome(submit, .submit(.comment), "COMMENTED") == nil)
        #expect(outcome(submit, .submit(.comment), "APPROVED") == .notAsSent)
        #expect(DraftEdits.outcome(Data("{}".utf8), of: .discard, write: submit) == .discardUnknown)
        #expect(DraftEdits.failure(.timedOut, of: .submit(.comment)) == .sendUnknown)
        #expect(DraftEdits.failure(.refused("No."), of: .body("B")) == .editFailed)
        #expect(DraftEdits.failure(.refused(""), of: .discard) == .notChanged(.refused("")))
        #expect(DraftEdits.failure(.notLoggedIn, of: .discard) == .notChanged(.notLoggedIn))
        #expect(DraftRefusal.sendUnknown.mayHaveChanged && !DraftRefusal.sendFailed.mayHaveChanged)
        // An answer that isn't pending proves a change on GitHub, so it asks for a poll too.
        #expect(DraftRefusal.notPending.mayHaveChanged && !DraftRefusal.busy.mayHaveChanged)
    }
}
