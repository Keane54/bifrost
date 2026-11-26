// The findings form of the Review panel (docs/behaviour/reviews.md, "The Review panel") on
// FakeGitHub: the open with its ticks, Approve, Comment and Request changes with their checks,
// the one write of each and its progress on the row. No test reaches GitHub.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@MainActor
@Suite("the findings form flow", .testTimeLimit)
struct FindingsFlowTests {
    // Claude's Approve mark on the head with the note and the findings, the fresh read of an open
    // PR with no pending review, and a flow that opened the mark.
    private func opened() async throws -> (FlowFixture, FindingsFlow) {
        let f = try await FlowFixture()
        await f.setMark(f.findingsMark())
        f.answerFresh(pending: .some(nil))
        let flow = f.findingsFlow()
        try flow.open(f.pr)
        return (f, flow)
    }

    private func refusal(_ work: () async throws(FindingsRefusal) -> Void) async
        -> FindingsRefusal?
    {
        do throws(FindingsRefusal) {
            try await work()
            return nil
        } catch {
            return error
        }
    }

    private func openRefusal(_ flow: FindingsFlow, _ pr: PRKey) -> FindingsRefusal? {
        do throws(FindingsRefusal) {
            try flow.open(pr)
            return nil
        } catch {
            return error
        }
    }

    // The one review write of the post with the event.
    private func review(_ f: FlowFixture, _ event: ReviewEvent, _ post: ReviewPost) throws
        -> GitHubWrite
    {
        .reviewCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, event: event, body: post.body,
            threads: post.threads, click: UserClick())
    }

    // The open shows Claude's reason, the note and every finding from the mark, and reads and
    // writes nothing. The bug and the minor findings start ticked, the nit does not. A new open
    // starts again with no summary.
    @Test func openTicksTheBugAndMinorFindingsAndNoNit() async throws {
        let (f, flow) = try await opened()
        #expect(flow.pr == f.pr)
        #expect(
            flow.shown
                == FindingsFlow.Shown(
                    why: "the retry change is correct", note: FlowFixture.note,
                    findings: FlowFixture.findings))
        #expect(flow.ticked == [0, 1, 2])
        #expect(flow.summary.isEmpty && flow.isCurrent && !flow.busy)
        #expect(
            flow.post == FindingsPlan.post(FlowFixture.findings, ticked: [0, 1, 2], summary: ""))
        #expect(f.github.calls.isEmpty)
        flow.ticked = [3]
        flow.summary = "Typed."
        try flow.open(f.pr)
        #expect(flow.ticked == [0, 1, 2] && flow.summary.isEmpty)
        // A mark with a draft, a Comment mark, a deleted draft or a round that waits: the form has
        // nothing to show.
        let marks = [
            try f.mark(.approve),
            try f.mark(.comment),
            RecommendationMark(
                value: .comment, why: "", headSHA: f.head, reviewID: nil, at: Rows.at(-9),
                deleted: true),
        ]
        for mark in marks {
            await f.setMark(mark)
            #expect(openRefusal(flow, f.pr) == .notOffered)
            #expect(flow.shown == nil && flow.ticked.isEmpty && !flow.isCurrent)
        }
        await f.setMark(f.findingsMark())
        let pr = f.pr
        await f.store.update {
            $0.queue.append(QueueEntry(pr: pr, kind: .review, at: Rows.at(-1)))
        }
        #expect(openRefusal(flow, f.pr) == .notOffered)
        #expect(f.github.calls.isEmpty)
        await f.end()
    }

    // With nothing ticked and no summary, Approve approves the reviewed commit with no text. The
    // mark stays, and the row shows the approval.
    @Test func approveWithNothingTickedApprovesWithNoText() async throws {
        let (f, flow) = try await opened()
        let mark = f.savedMark
        let write = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, click: UserClick())
        f.answerWrite(write, state: "APPROVED")
        flow.ticked = []
        flow.summary = " \n"
        try await flow.approve(click: UserClick())
        #expect(f.written == [write])
        #expect(f.reads == [DraftQueries.freshName])
        #expect(f.savedMark == mark && flow.isCurrent && !flow.busy)
        #expect(f.writes.progress(f.pr) == .confirmed(.approve))
        #expect(f.polls.values.count == 1)
        await f.end()
    }

    // Approve with ticks sends one review write with the event Approve: the summary and each
    // ticked finding off the diff in the review text, and each ticked finding on the diff as a
    // line comment.
    @Test func approveWithTicksPostsThemWithTheApproval() async throws {
        let (f, flow) = try await opened()
        flow.summary = "Looks good, two small points."
        let post = flow.post
        #expect(post.threads == [try #require(FlowFixture.findings[0].comment)])
        #expect(
            post.body
                == "Looks good, two small points.\n\n"
                + "`src/b.swift` line 40: This log line names the wrong file.\n\n"
                + "No test covers the retry.")
        let write = try review(f, .approve, post)
        f.answerWrite(write, state: "APPROVED")
        try await flow.approve(click: UserClick())
        #expect(f.written == [write])
        #expect(f.writes.progress(f.pr) == .confirmed(.approve))
        await f.end()
    }

    // Comment and Request changes each send one review write of the ticked findings with their
    // event. Request changes with no summary sends nothing, also when ticked findings off the
    // diff give a review text. A Comment with nothing ticked and no summary sends nothing.
    @Test func commentAndRequestChangesPostTheTickedFindings() async throws {
        let (f, flow) = try await opened()
        let comment = try review(f, .comment, flow.post)
        f.answerWrite(comment, state: "COMMENTED")
        try await flow.send(.comment, click: UserClick())
        #expect(f.written == [comment])
        #expect(flow.ticked == [0, 1, 2] && !flow.post.body.isEmpty)
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.requestChanges, click: UserClick())
        } == .needsSummary)
        flow.ticked = [0]
        flow.summary = " \n"
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.requestChanges, click: UserClick())
        } == .needsSummary)
        #expect(f.written == [comment] && f.reads.count == 1)
        flow.summary = "Please fix the loop first."
        let changes = try review(f, .requestChanges, flow.post)
        #expect(
            changes
                == .reviewCommit(
                    pr: try ReviewData.node("PR_node7"), commit: f.head, event: .requestChanges,
                    body: "Please fix the loop first.",
                    threads: [try #require(FlowFixture.findings[0].comment)], click: UserClick()))
        f.answerWrite(changes, state: "CHANGES_REQUESTED")
        try await flow.send(.requestChanges, click: UserClick())
        #expect(f.written == [comment, changes])
        #expect(f.savedMark != nil && flow.isCurrent)
        flow.ticked = []
        flow.summary = ""
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .empty)
        #expect(f.written.count == 2)
        await f.end()
    }

    // With every finding ticked and a summary, no write of Approve, Comment or Request changes
    // holds Claude's private note.
    @Test func noWriteOfThePanelHoldsTheNote() async throws {
        let (f, flow) = try await opened()
        flow.ticked = Set(FlowFixture.findings.indices)
        flow.summary = "Summary."
        f.answerWrite(try review(f, .approve, flow.post), state: "APPROVED")
        try await flow.approve(click: UserClick())
        f.answerWrite(try review(f, .comment, flow.post), state: "COMMENTED")
        try await flow.send(.comment, click: UserClick())
        f.answerWrite(try review(f, .requestChanges, flow.post), state: "CHANGES_REQUESTED")
        try await flow.send(.requestChanges, click: UserClick())
        #expect(f.written.count == 3)
        for write in f.written {
            #expect(!String(decoding: write.input, as: UTF8.self).contains(FlowFixture.note))
            guard case .reviewCommit(_, _, _, let body, let threads, _) = write else {
                Issue.record("A write that is not a review: \(write)")
                continue
            }
            #expect(body.hasPrefix("Summary.") && threads.count == 2)
        }
        await f.end()
    }

    // A new mark after the open (a new round) sends nothing, and so does a mark that changes
    // while the fresh read runs.
    @Test func aChangedMarkSendsNothing() async throws {
        let (f, flow) = try await opened()
        await f.setMark(f.findingsMark(at: Rows.at(-5)))
        #expect(!flow.isCurrent)
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.approve(click: UserClick())
        } == .notOffered)
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .notOffered)
        #expect(f.github.calls.isEmpty)
        try flow.open(f.pr)
        let (store, pr) = (f.store, f.pr)
        let newer = f.findingsMark(at: Rows.at(-1))
        f.github.onRead = { _ in
            await store.update { $0.prs[pr]?.recommendation = newer }
        }
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .notOffered)
        try flow.open(f.pr)
        let newest = f.findingsMark(at: Rows.at(0))
        f.github.onRead = { _ in
            await store.update { $0.prs[pr]?.recommendation = newest }
        }
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.approve(click: UserClick())
        } == .approveRefused(.notSuggested))
        #expect(f.reads.count == 2 && f.written.isEmpty)
        await f.end()
    }

    // A second action while one runs sends nothing and says so, and the panel is busy until the
    // first one ends. An approval of the PR from the row stops the panel too, and its Approve says
    // the PR is still being approved.
    @Test func aSecondActionWhileOneRunsSendsNothing() async throws {
        let (f, flow) = try await opened()
        let comment = try review(f, .comment, flow.post)
        f.answerWrite(comment, state: "COMMENTED")
        let second = Recorder<FindingsRefusal>()
        let busy = Recorder<Bool>()
        f.github.onWrite = { _ in
            busy.record(flow.busy)
            do throws(FindingsRefusal) {
                try await flow.approve(click: UserClick())
            } catch {
                second.record(error)
            }
            do throws(FindingsRefusal) {
                try await flow.send(.requestChanges, click: UserClick())
            } catch {
                second.record(error)
            }
        }
        try await flow.send(.comment, click: UserClick())
        #expect(second.values == [.busy, .busy] && busy.values == [true] && !flow.busy)
        #expect(f.written == [comment])
        let plain = GitHubWrite.approveCommit(
            pr: try ReviewData.node("PR_node7"), commit: f.head, click: UserClick())
        f.answerWrite(plain, state: "APPROVED")
        let gate = TestGate()
        defer { gate.openAll() }
        f.github.onWrite = { _ in await gate.pass() }
        let (approver, pr) = (f.approver, f.pr)
        let row = Task { () async -> ApproveRefusal? in
            do throws(ApproveRefusal) {
                try await approver.approve(pr, click: UserClick())
                return nil
            } catch {
                return error
            }
        }
        #expect(await gate.waitUntilHolding(1))
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.approve(click: UserClick())
        } == .approveRefused(.busy))
        #expect(
            FindingsRefusal.approveRefused(.busy).message
                == "This pull request is still being approved, so try again once it's done.")
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .busy)
        gate.open()
        #expect(await row.value == nil)
        #expect(f.written == [comment, plain])
        await f.end()
    }

    // A write that GitHub can have made is never sent again by itself: the form says so, asks
    // for one poll and leaves the line of gh in the Event log. An Approve asks for its one poll
    // through the Approve button flow. A refusal of GitHub has its line there too. A poll after
    // each result lets the next action of the test go.
    @Test func aWriteThatMayHaveGoneAsksForAPoll() async throws {
        let (f, flow) = try await opened()
        let comment = try review(f, .comment, flow.post)
        let key = FakeGitHub.key(comment)
        f.github.answers[key] = .failure(.unknownOutcome("HTTP 502"))
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.approve(click: UserClick())
        } == .approveRefused(.unknown))
        #expect(f.written.count == 1 && f.polls.values.count == 1)
        // The approval may have gone with the ticked findings, so the form waits for a poll.
        #expect(flow.waitsForPoll)
        await f.pollAnswered()
        f.answerWrite(comment, state: "COMMENTED")
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.approve(click: UserClick())
        } == .approveRefused(.notApproved))
        #expect(f.written.count == 2 && f.polls.values.count == 2)
        #expect(flow.waitsForPoll)
        await f.pollAnswered()
        f.github.answers[key] = .failure(.unknownOutcome("HTTP 502"))
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .unknown)
        #expect(f.written.last == comment && f.polls.values.count == 3)
        #expect(
            f.lines.values.last
                == "Reviews: Bifrost can't tell whether GitHub saved the review of \(f.pr.text): "
                + GitHubError.unknownOutcome("HTTP 502").message)
        #expect(f.writes.progress(f.pr) == nil)
        // An answer with no review, or a review in another state, asks for one poll each.
        await f.pollAnswered()
        f.github.answers[key] = .success(Data("{}".utf8))
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .unknown)
        await f.pollAnswered()
        f.answerWrite(comment, state: "APPROVED")
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .notAsSent)
        #expect(f.written.count == 5 && f.polls.values.count == 5)
        // A refusal of GitHub asks for no poll.
        await f.pollAnswered()
        let lines = f.lines.values.count
        f.github.answers[key] = .failure(.refused("Can not comment"))
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .refusedByGitHub)
        #expect(f.polls.values.count == 5 && !flow.waitsForPoll)
        #expect(
            f.lines.values.last
                == "Reviews: GitHub rejected the review of \(f.pr.text): Can not comment")
        // A read that fails sends nothing.
        f.github.answers[DraftQueries.freshName] = .failure(.refused("Not Found"))
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .readFailed(.refused("Not Found")))
        #expect(f.written.count == 6 && f.lines.values.count == lines + 2)
        #expect(
            f.lines.values.last
                == "Reviews: GitHub couldn't load \(f.pr.text). It said: "
                + GitHubError.refused("Not Found").message)
        await f.end()
    }

    // An Approve of the form that GitHub may have saved asks for one poll, and the answer of that
    // poll ends the wait, so the row's Approve and draft buttons come back at once
    // (ReviewWrites.waitsForPoll). This holds for an unknown result and for a review in another
    // state. A poll that runs while the approval goes is behind GitHub, so only the poll after it
    // ends the wait.
    @Test func theFirstPollAfterAnUnsureApprovalUnlocksTheRow() async throws {
        let (f, flow) = try await opened()
        let approval = try review(f, .approve, flow.post)
        f.github.answers[FakeGitHub.key(approval)] = .failure(.unknownOutcome("HTTP 502"))
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.approve(click: UserClick())
        } == .approveRefused(.unknown))
        #expect(f.writes.waitsForPoll(f.pr) && f.watcherPolls.running)
        f.watcherPolls.answer()
        #expect(!f.writes.waitsForPoll(f.pr) && !flow.waitsForPoll)
        f.answerWrite(approval, state: "COMMENTED")
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.approve(click: UserClick())
        } == .approveRefused(.notApproved))
        #expect(f.writes.waitsForPoll(f.pr) && f.watcherPolls.running)
        f.watcherPolls.answer()
        #expect(!f.writes.waitsForPoll(f.pr))
        // A timer poll runs while the approval goes.
        let watcherPolls = f.watcherPolls
        f.github.onWrite = { _ in watcherPolls.start() }
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.approve(click: UserClick())
        } == .approveRefused(.notApproved))
        #expect(f.writes.waitsForPoll(f.pr))
        f.watcherPolls.answer()
        #expect(f.writes.waitsForPoll(f.pr) && f.watcherPolls.running)
        f.watcherPolls.answer()
        #expect(!f.writes.waitsForPoll(f.pr) && f.written == [approval, approval, approval])
        await f.end()
    }

    // A Comment or Request changes that GitHub may have saved is never sent again by itself.
    // Until a poll that started after the result gives a good answer, each button of the form for
    // the PR sends nothing and says so, also after a new open. A poll that ran during the send is
    // behind GitHub, so it does not end the wait. Then the form sends again.
    @Test func aSendThatMayHaveGoneWaitsForTheNextPoll() async throws {
        let (f, flow) = try await opened()
        let comment = try review(f, .comment, flow.post)
        let key = FakeGitHub.key(comment)
        f.watcherPolls.start()
        f.github.answers[key] = .failure(.unknownOutcome("HTTP 502"))
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .unknown)
        #expect(flow.waitsForPoll && f.written == [comment])
        f.watcherPolls.answer()
        f.answerWrite(comment, state: "COMMENTED")
        flow.summary = "Please fix the loop first."
        #expect(flow.waitsForPoll)
        for event in [DraftEvent.comment, .requestChanges] {
            #expect(await refusal { () async throws(FindingsRefusal) in
                try await flow.send(event, click: UserClick())
            } == .unknown)
        }
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.approve(click: UserClick())
        } == .unknown)
        let again = f.findingsFlow()
        try again.open(f.pr)
        #expect(again.waitsForPoll)
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await again.send(.comment, click: UserClick())
        } == .unknown)
        #expect(f.written == [comment] && f.reads.count == 1)
        #expect(
            FindingsRefusal.unknown.message
                == "Bifrost can't tell whether GitHub saved your review, so click Refresh to "
                + "check.")
        await f.pollAnswered()
        #expect(!flow.waitsForPoll && !again.waitsForPoll)
        let resend = try review(f, .comment, flow.post)
        try await flow.send(.comment, click: UserClick())
        #expect(f.written == [comment, resend])
        // GitHub saved a review, but not as sent: the form waits again.
        f.answerWrite(resend, state: "APPROVED")
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .notAsSent)
        #expect(flow.waitsForPoll)
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .unknown)
        #expect(f.written.count == 3)
        await f.end()
    }

    // A Comment that GitHub saved without telling us is never sent again. No poll can show a
    // comment, so the poll after it checks your own reviews, finds it on the head, and from then
    // on the row says You commented and the form sends nothing more for that head.
    @Test func anUnsureCommentThatGitHubSavedIsNeverSentAgain() async throws {
        let (f, flow) = try await opened()
        let comment = try review(f, .comment, flow.post)
        f.github.answers[FakeGitHub.key(comment)] = .failure(.unknownOutcome("HTTP 502"))
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .unknown)
        #expect(flow.waitsForPoll && !flow.commentFound)
        f.github.answers[DraftQueries.ownReviewsName] = .success(
            DraftAnswers.ownReviews([
                DraftAnswers.Opinion(state: "COMMENTED", commit: f.head, at: Rows.now)
            ]))
        await f.pollAnswered()
        #expect(!flow.waitsForPoll && flow.commentFound)
        #expect(f.reads.filter { $0 == DraftQueries.ownReviewsName }.count == 1)
        f.answerWrite(comment, state: "COMMENTED")
        flow.summary = "Please fix the loop first."
        for event in [DraftEvent.comment, .requestChanges] {
            #expect(await refusal { () async throws(FindingsRefusal) in
                try await flow.send(event, click: UserClick())
            } == .notOffered)
        }
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.approve(click: UserClick())
        } == .notOffered)
        try flow.open(f.pr)
        #expect(flow.commentFound)
        #expect(f.written == [comment])
        var request = try Rows.pull(f.pr.text)
        request.headSHA = f.head.hex
        let answer = Rows.answer(toReview: [request])
        let row = ReviewRows.toReview(
            answer, f.store.state, ReviewsConfig(), reviewedHere: f.writes.reviewedHere(answer),
            now: Rows.now
        ).first
        #expect(row?.toReviewState == .youCommented)
        await f.end()
    }

    // An unsure Comment that GitHub didn't save unlocks once a good read of your own reviews
    // shows nothing new on the head: an older comment, or one on another commit, doesn't count.
    @Test func anUnsureCommentThatGitHubDidNotSaveUnlocksAfterTheRead() async throws {
        let (f, flow) = try await opened()
        let comment = try review(f, .comment, flow.post)
        f.github.answers[FakeGitHub.key(comment)] = .failure(.unknownOutcome("HTTP 502"))
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .unknown)
        let other = try #require(CommitID(String(repeating: "e", count: 40)))
        f.github.answers[DraftQueries.ownReviewsName] = .success(
            DraftAnswers.ownReviews([
                DraftAnswers.Opinion(
                    state: "COMMENTED", commit: f.head, at: Rows.now.addingTimeInterval(-3_600)),
                DraftAnswers.Opinion(state: "COMMENTED", commit: other, at: Rows.now),
            ]))
        await f.pollAnswered()
        #expect(!flow.waitsForPoll && !flow.commentFound)
        f.answerWrite(comment, state: "COMMENTED")
        try await flow.send(.comment, click: UserClick())
        #expect(f.written == [comment, comment])
        await f.end()
    }

    // A failed read of your own reviews keeps the lock, so the form still sends nothing. The next
    // poll tries the read again, and a good read then settles it.
    @Test func aFailedReadKeepsTheLock() async throws {
        let (f, flow) = try await opened()
        let comment = try review(f, .comment, flow.post)
        f.github.answers[FakeGitHub.key(comment)] = .failure(.unknownOutcome("HTTP 502"))
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .unknown)
        f.github.answers[DraftQueries.ownReviewsName] = .failure(.timedOut)
        await f.pollAnswered()
        #expect(flow.waitsForPoll)
        #expect(await refusal { () async throws(FindingsRefusal) in
            try await flow.send(.comment, click: UserClick())
        } == .unknown)
        #expect(f.written == [comment])
        f.github.answers[DraftQueries.ownReviewsName] = .success(DraftAnswers.ownReviews([]))
        await f.pollAnswered()
        #expect(!flow.waitsForPoll && !flow.commentFound)
        await f.end()
    }

    // The row shows the send while it runs, then the result for the time of the hold, then You
    // commented until a poll shows the comment.
    @Test func theRowShowsTheProgressOfASend() async throws {
        let (f, flow) = try await opened()
        let comment = try review(f, .comment, flow.post)
        f.answerWrite(comment, state: "COMMENTED")
        var request = try Rows.pull(f.pr.text)
        request.headSHA = f.head.hex
        let answer = Rows.answer(toReview: [request])
        let gate = TestGate()
        defer { gate.openAll() }
        f.github.onWrite = { _ in await gate.pass() }
        let send = Task { () async -> FindingsRefusal? in
            do throws(FindingsRefusal) {
                try await flow.send(.comment, click: UserClick())
                return nil
            } catch {
                return error
            }
        }
        #expect(await gate.waitUntilHolding(1))
        #expect(f.writes.progress(f.pr) == .running(.comment) && flow.busy)
        gate.open()
        #expect(await send.value == nil)
        #expect(f.writes.progress(f.pr) == .confirmed(.comment))
        let reviewed = f.writes.reviewedHere(answer)
        #expect(reviewed == [f.pr: ConfirmedReview(.comment, head: f.head.hex)])
        let row = ReviewRows.toReview(
            answer, f.store.state, ReviewsConfig(), reviewedHere: reviewed, now: Rows.now
        ).first
        #expect(row?.toReviewState == .youCommented)
        await f.end()
    }
}
