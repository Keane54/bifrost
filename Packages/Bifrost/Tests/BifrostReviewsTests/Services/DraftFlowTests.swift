// The Review panel (docs/behaviour/reviews.md, "The Review panel") on FakeGitHub: the open, Send
// review with its checks and its writes, Discard draft and Approve instead. No test reaches
// GitHub.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@MainActor
@Suite("the Review panel flow", .timeLimit(.minutes(1)))
struct DraftFlowTests {
    private static let claudeComment = "PRRC_claude"
    private static let userComment = "PRRC_user"

    // Claude's Comment draft on the head with a summary, Claude's comment on src/a.swift line 11
    // and a comment that the user added on src/b.swift line 3. The panel opened it.
    private func opened() async throws -> (FlowFixture, DraftFlow) {
        let f = try await FlowFixture()
        let mark = try f.mark(.comment)
        await f.setMark(mark)
        let pr = f.pr
        let review = try ReviewData.node(FlowFixture.claudeReview)
        await f.store.update { state in
            state.drafts = [
                DraftRecord(
                    reviewID: review, pr: pr, path: "src/a.swift", line: 11, body: "Use <.",
                    at: Rows.at(-30)),
                DraftRecord(
                    reviewID: review, pr: pr, path: "", line: 0, body: "Summary.",
                    at: Rows.at(-30)),
            ]
        }
        f.answerFresh()
        f.answerDraft(body: "Summary.", comments: try comments())
        f.github.answers[ReviewQueries.reviewName] = .success(
            DraftAnswers.reviewNow(commit: f.head))
        let flow = f.draftFlow()
        try await flow.open(f.pr)
        return (f, flow)
    }

    private func comments(_ userText: String = "Mine.") throws -> [DraftRead.Comment] {
        [
            DraftRead.Comment(
                id: try ReviewData.node(Self.claudeComment), path: "src/a.swift", line: 11,
                hunk: "@@ -1,2 +1,2 @@\n a\n-b\n+c", body: "Use <."),
            DraftRead.Comment(
                id: try ReviewData.node(Self.userComment), path: "src/b.swift", line: 3,
                startLine: 1, body: userText),
        ]
    }

    private func refusal(_ work: () async throws(DraftRefusal) -> Void) async -> DraftRefusal? {
        do throws(DraftRefusal) {
            try await work()
            return nil
        } catch {
            return error
        }
    }

    // The open shows Claude's suggestion and the draft: each comment with its place and the end
    // of its hunk, and "yours" for the comment that the user added on GitHub. It writes nothing.
    // The draft is current until the mark changes, for example to a newer draft of Claude.
    @Test func theOpenShowsTheDraft() async throws {
        let (f, flow) = try await opened()
        #expect(flow.isCurrent && !f.draftFlow().isCurrent)
        #expect(
            flow.shown
                == DraftFlow.Shown(recommendation: .comment, why: "The reason.", headMoved: false))
        #expect(flow.summary == "Summary.")
        #expect(flow.comments.map(\.place) == ["src/a.swift line 11", "src/b.swift lines 1-3"])
        #expect(flow.comments.map(\.yours) == [false, true])
        #expect(flow.comments.first?.hunk == ["@@ -1,2 +1,2 @@", " a", "-b", "+c"])
        #expect(f.written.isEmpty)
        await f.setMark(try f.mark(.requestChanges))
        #expect(!flow.isCurrent)
        await f.end()
    }

    // Send review writes the changed summary, each changed comment and each removed comment, each
    // after a fresh read of the review, then submits it with the event. The mark goes, and a poll
    // follows.
    @Test func aSendWritesTheEditsThenSubmits() async throws {
        let (f, flow) = try await opened()
        let review = try ReviewData.node(FlowFixture.claudeReview)
        let (claude, user) = (
            try ReviewData.node(Self.claudeComment), try ReviewData.node(Self.userComment)
        )
        let writes: [GitHubWrite] = [
            .editDraftBody(review: review, body: "New summary.", click: UserClick()),
            .editDraftComment(comment: claude, body: "Better.", click: UserClick()),
            .removeDraftComment(comment: user, click: UserClick()),
            .submitDraft(review: review, event: .requestChanges, click: UserClick()),
        ]
        f.answerWrite(writes[0], state: "PENDING")
        f.answerWrite(writes[1])
        f.answerWrite(writes[2])
        f.answerWrite(writes[3], state: "CHANGES_REQUESTED")
        flow.summary = "New summary."
        flow.comments[0].text = "Better."
        flow.comments[1].removed = true
        try await flow.send(.requestChanges, click: UserClick())
        #expect(f.written == writes)
        #expect(f.reads.filter { $0 == ReviewQueries.reviewName }.count == 3)
        #expect(f.savedMark == nil)
        #expect(f.polls.values.count == 1)
        await f.end()
    }

    // A summary or a comment that changed on GitHub after the open, or a comment that the user
    // added there, refuses the send: Bifrost writes nothing over it.
    @Test func aChangedDraftOnGitHubRefusesTheSend() async throws {
        let (f, flow) = try await opened()
        f.answerDraft(body: "Changed on GitHub.", comments: try comments())
        #expect(await refusal { () async throws(DraftRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .edited)
        f.answerDraft(body: "Summary.", comments: try comments("Changed there."))
        #expect(await refusal { () async throws(DraftRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .edited)
        var more = try comments()
        more.append(
            DraftRead.Comment(id: try ReviewData.node("PRRC_new"), path: "c", line: 1, body: "+"))
        f.answerDraft(body: "Summary.", comments: more)
        #expect(await refusal { () async throws(DraftRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .edited)
        #expect(f.written.isEmpty && f.savedMark != nil)
        #expect(
            DraftRefusal.edited.message
                == "The draft changed on GitHub after you opened it, so Bifrost sent nothing. "
                + "Close this panel and open it again.")
        await f.end()
    }

    // Request changes needs a summary; a send with no summary and no comment needs one or the
    // other. Neither writes.
    @Test func requestChangesNeedsASummary() async throws {
        let (f, flow) = try await opened()
        flow.summary = "  "
        #expect(await refusal { () async throws(DraftRefusal) in
            try await flow.send(.requestChanges, click: UserClick())
        } == .needsSummary)
        flow.comments[0].removed = true
        flow.comments[1].removed = true
        #expect(await refusal { () async throws(DraftRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .empty)
        #expect(f.written.isEmpty)
        #expect(DraftRefusal.needsSummary.message == "Add a summary to request changes.")
        await f.end()
    }

    @Test func aBlankCommentRefusesTheSend() async throws {
        let (f, flow) = try await opened()
        flow.comments[1].text = " \n "
        #expect(await refusal { () async throws(DraftRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .blankComment)
        #expect(f.written.isEmpty)
        #expect(
            DraftRefusal.blankComment.message
                == "One comment has no text. Write something, or remove the comment.")
        await f.end()
    }

    // Discard draft deletes only Claude's draft of the mark: a pending review that is the user's
    // own, or a draft with a comment that the panel didn't show, writes nothing. The delete goes
    // to Claude's review, and the mark goes.
    @Test func discardDeletesOnlyClaudesDraft() async throws {
        let (f, flow) = try await opened()
        f.answerFresh(pending: DraftAnswers.Pending(id: "PRR_mine", commit: f.head))
        #expect(await refusal { () async throws(DraftRefusal) in
            try await flow.discard(click: UserClick())
        } == .gone)
        f.answerFresh()
        var more = try comments()
        more.append(
            DraftRead.Comment(id: try ReviewData.node("PRRC_new"), path: "c", line: 1, body: "+"))
        f.answerDraft(body: "Summary.", comments: more)
        #expect(await refusal { () async throws(DraftRefusal) in
            try await flow.discard(click: UserClick())
        } == .edited)
        #expect(f.written.isEmpty)
        f.answerDraft(body: "Summary.", comments: try comments())
        let write = GitHubWrite.discardDraft(
            review: try ReviewData.node(FlowFixture.claudeReview), click: UserClick())
        f.answerWrite(write)
        try await flow.discard(click: UserClick())
        #expect(f.written == [write])
        #expect(f.savedMark == nil && f.polls.values.count == 1)
        await f.end()
    }

    // Just before an edit, a fresh read of the review must show it pending and the user's:
    // GitHub's update edits a submitted review or comment too. A submitted review, or one of
    // another user, gets no edit, and a poll follows. A read that fails sends nothing, and its
    // line goes to the Event log. A summary write whose answer isn't pending stops the send, and
    // a poll follows too.
    @Test func aSubmittedCommentIsNotEdited() async throws {
        let (f, flow) = try await opened()
        flow.comments[0].text = "Better."
        f.github.answers[ReviewQueries.reviewName] = .success(
            DraftAnswers.reviewNow(state: "COMMENTED", commit: f.head))
        #expect(await refusal { () async throws(DraftRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .notPending)
        f.github.answers[ReviewQueries.reviewName] = .success(
            DraftAnswers.reviewNow(mine: false, commit: f.head))
        #expect(await refusal { () async throws(DraftRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .notPending)
        #expect(f.written.isEmpty && f.polls.values.count == 2)
        #expect(
            DraftRefusal.notPending.message
                == "Claude's review isn't a draft on GitHub any more. Check the pull request on "
                + "GitHub.")
        f.github.answers[ReviewQueries.reviewName] = .failure(.refused("Not Found"))
        #expect(await refusal { () async throws(DraftRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .readFailed(.refused("Not Found")))
        #expect(
            f.lines.values == [
                "Reviews: GitHub couldn't load the draft review of \(f.pr.text). It said: "
                    + GitHubError.refused("Not Found").message
            ])
        f.github.answers[ReviewQueries.reviewName] = .success(
            DraftAnswers.reviewNow(commit: f.head))
        flow.comments[0].text = "Use <."
        flow.summary = "New summary."
        let body = GitHubWrite.editDraftBody(
            review: try ReviewData.node(FlowFixture.claudeReview), body: "New summary.",
            click: UserClick())
        f.answerWrite(body, state: "COMMENTED")
        #expect(await refusal { () async throws(DraftRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .notPending)
        #expect(f.written == [body] && f.polls.values.count == 3 && f.savedMark != nil)
        await f.end()
    }

    // A second action while one runs sends nothing and says so; the first one goes on.
    @Test func aSecondActionWhileOneRunsSendsNothing() async throws {
        let (f, flow) = try await opened()
        let submit = GitHubWrite.submitDraft(
            review: try ReviewData.node(FlowFixture.claudeReview), event: .comment,
            click: UserClick())
        f.answerWrite(submit, state: "COMMENTED")
        let second = Recorder<DraftRefusal>()
        f.github.onWrite = { _ in
            do throws(DraftRefusal) {
                try await flow.discard(click: UserClick())
            } catch {
                second.record(error)
            }
        }
        try await flow.send(.comment, click: UserClick())
        #expect(second.values == [.busy])
        #expect(f.written == [submit] && f.savedMark == nil)
        #expect(
            DraftRefusal.busy.message
                == "Bifrost is still working on this draft. Wait for it to finish, then try again.")
        await f.end()
    }

    // A mark that Bifrost couldn't save after a send leaves the change on GitHub, and the Event
    // log says so. The poll that follows shows the change.
    @Test func aFailedSaveOfTheMarkGoesToTheEventLog() async throws {
        let (f, flow) = try await opened()
        let submit = GitHubWrite.submitDraft(
            review: try ReviewData.node(FlowFixture.claudeReview), event: .comment,
            click: UserClick())
        f.answerWrite(submit, state: "COMMENTED")
        // The store closes while GitHub takes the write, so the save of the mark fails.
        let store = f.store
        f.github.onWrite = { _ in await store.close().value }
        try await flow.send(.comment, click: UserClick())
        #expect(f.written == [submit] && f.polls.values.count == 1)
        #expect(
            f.lines.values == ["Reviews: Bifrost couldn't save the draft change of \(f.pr.text)."])
        f.folder.remove()
    }

    // Approve instead deletes Claude's draft, keeps the mark as deleted, then approves the head
    // with no text. It waits for CI, and an approval of the head stops it before the delete.
    @Test func approveInsteadDeletesTheDraftThenApproves() async throws {
        let (f, flow) = try await opened()
        f.answerFresh(ci: "PENDING")
        #expect(await refusal { () async throws(DraftRefusal) in
            try await flow.approveInstead(click: UserClick())
        } == .approveRefused(.ciRunning))
        #expect(f.written.isEmpty)
        let discard = GitHubWrite.discardDraft(
            review: try ReviewData.node(FlowFixture.claudeReview), click: UserClick())
        let approve = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, click: UserClick())
        f.answerWrite(discard)
        f.answerWrite(approve, state: "APPROVED")
        // The read of the delete shows Claude's draft; the read of the approval shows none.
        f.github.queued[DraftQueries.freshName] = [
            .success(DraftAnswers.fresh(
                f.pr, head: f.head,
                pending: DraftAnswers.Pending(id: FlowFixture.claudeReview, commit: f.head))),
            .success(DraftAnswers.fresh(f.pr, head: f.head)),
        ]
        try await flow.approveInstead(click: UserClick())
        #expect(f.written == [discard, approve])
        #expect(f.savedMark?.deleted == true && f.savedMark?.reviewID == nil)
        #expect(f.savedMark?.value == .comment)
        await f.end()
    }
}
