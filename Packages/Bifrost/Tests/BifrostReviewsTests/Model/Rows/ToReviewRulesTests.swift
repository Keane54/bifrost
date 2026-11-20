import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

// The rules of the To review tab (docs/behaviour/reviews.md, "The rows"): the states, the
// flash, the order, the marks that a poll leaves in the state, the team filter and Remove.

private typealias R = Rows

// The state of the row of one PR, or nil when the PR shows no row.
private func stateOf(
    _ pr: PullRequest, _ state: ReviewsState, _ config: ReviewsConfig = ReviewsConfig()
) -> ToReviewState? {
    R.toReview(R.answer(toReview: [pr]), state, config).first?.toReviewState
}

// A state that saw the request of the key, after the first turn-on.
private func seen(
    _ key: PRKey, at time: Date = R.at(-60), baseline: Bool = false
) -> ReviewsState {
    var state = R.turnedOn()
    state.requests[key] = RequestMark(firstSeen: time, baseline: baseline)
    return state
}

@Suite("the To review rows", .testTimeLimit)
struct ToReviewRulesTests {
    @Test func theRequestsOpenAtTheFirstTurnOnDoNotFlash() throws {
        var state = ReviewsState()
        let open = try R.pull("owner-a/repo-a#1", requestedAt: R.at(-90))
        let team = try R.pull("owner-a/repo-a#2", direct: false, requestedAt: R.at(-60))
        let first = R.answer(toReview: [open, team])
        #expect(!ReviewRows.isNewRequest(open, state))
        #expect(state.recordPoll(first, now: R.at(-30)).isEmpty)
        #expect(state.turnedOnAt == R.at(-30))
        #expect(state.requests[open.key] == RequestMark(firstSeen: R.at(-30), baseline: true))
        let rows = R.toReview(first, state)
        #expect(rows.map(\.toReviewState) == [.waitingForYou, .teamRequest])
        #expect(rows.allSatisfy { !$0.flash })

        // A request made after the turn-on flashes. A request from before the turn-on that shows
        // only now, because GitHub gave more than 50, does not.
        let later = try R.pull("owner-a/repo-b#3", requestedAt: R.at(-10))
        let beyond = try R.pull("owner-a/repo-b#4", requestedAt: R.at(-120))
        let next = R.answer(toReview: [open, team, later, beyond])
        #expect(ReviewRows.isNewRequest(later, state))
        #expect(!ReviewRows.isNewRequest(beyond, state))
        #expect(state.recordPoll(next, now: R.now) == [later.key])
        #expect(state.requests[beyond.key] == RequestMark(firstSeen: R.now, baseline: true))
        let rows2 = R.toReview(next, state)
        #expect(rows2.map(\.id) == [later.key, beyond.key, open.key, team.key])
        #expect(rows2.map(\.flash) == [true, false, false, false])
    }

    @Test func theFirstTurnOnStartsTheNewRequestWorkAndKeepsAnEarlierStart() throws {
        let answer = R.answer(toReview: [try R.pull("owner-a/repo-a#1")])
        var fresh = ReviewsState()
        fresh.recordPoll(answer, now: R.now)
        #expect(fresh.fixFrom == R.now)
        // A state with a start (a take-over sets one) keeps it, and a later poll never moves it.
        var taken = ReviewsState()
        taken.fixFrom = R.at(-5)
        taken.recordPoll(answer, now: R.now)
        taken.recordPoll(answer, now: R.at(5))
        #expect(taken.fixFrom == R.at(-5))
    }

    @Test func theFirstTurnOnMarksTheOpenItemsOfMyPRs() throws {
        var state = ReviewsState()
        let member = R.person("user-e")
        let mine = try R.pull(
            "owner-a/repo-c#9", direct: false,
            reviews: [
                R.review("PRR_c1", by: R.copilot, .commented),
                R.review("PRR_m1", by: member, .changesRequested, body: "Split this."),
            ],
            threads: [
                R.thread("PRRT_1", by: R.copilot, review: "PRR_c1"),
                R.thread("PRRT_2", by: member, resolved: true),
            ],
            comments: [R.comment("IC_1", by: member)])
        state.recordPoll(R.answer(mine: [mine]), now: R.now)
        #expect(try state.baseline == [R.node("PRRT_1"), R.node("PRR_m1"), R.node("IC_1")])

        // A later poll keeps the marks of the first turn-on.
        state.recordPoll(R.answer(), now: R.at(5))
        #expect(state.turnedOnAt == R.now && state.baseline.count == 3)
    }

    @Test func aRequestAgainFlashesAndLosesItsPause() throws {
        let key = try R.key("owner-a/repo-a#1")
        let teamKey = try R.key("owner-a/repo-a#2")
        var state = seen(key, at: R.at(-100), baseline: true)
        state.requests[teamKey] = RequestMark(firstSeen: R.at(-100), baseline: true)
        state.pauses = [key: R.at(30), teamKey: R.at(30)]
        var reviewed = PRState()
        reviewed.lastError = "The review failed."
        reviewed.recommendation = RecommendationMark(
            value: .comment, why: "", headSHA: try R.commit("a"), reviewID: nil, at: R.at(-90))
        state.prs[key] = reviewed

        // The same request time changes nothing.
        let same = try R.pull(key.text, requestedAt: R.at(-100))
        var unchanged = state
        #expect(unchanged.recordPoll(R.answer(toReview: [same]), now: R.now).isEmpty)
        #expect(unchanged.pauses[key] == R.at(30))

        // A direct request made again is new: it loses its pause, its mark and its error. A team
        // request made again keeps its pause.
        let again = try R.pull(key.text, requestedAt: R.at(-5))
        let teamAgain = try R.pull(teamKey.text, direct: false, requestedAt: R.at(-5))
        #expect(ReviewRows.isNewRequest(again, state))
        #expect(!ReviewRows.isNewRequest(teamAgain, state))
        let answer = R.answer(toReview: [again, teamAgain])
        #expect(state.recordPoll(answer, now: R.now) == [key])
        #expect(state.requests[key] == RequestMark(firstSeen: R.now, baseline: false))
        #expect(state.pauses == [teamKey: R.at(30)])
        #expect(state.prs[key]?.lastError == nil && state.prs[key]?.recommendation == nil)
        let rows = R.toReview(answer, state)
        #expect(rows.map(\.toReviewState) == [.newRequest, .paused(until: R.at(30))])
        #expect(rows.map(\.flash) == [true, false])
    }

    @Test func aLateClockNeverMakesARequestNewAgain() throws {
        var state = R.turnedOn()
        // GitHub's time of the request is after the clock of this computer.
        let ahead = try R.pull("owner-a/repo-a#1", requestedAt: R.at(3))
        #expect(state.recordPoll(R.answer(toReview: [ahead]), now: R.now) == [ahead.key])
        #expect(state.requests[ahead.key]?.firstSeen == R.at(3))
        #expect(state.recordPoll(R.answer(toReview: [ahead]), now: R.at(1)).isEmpty)
    }

    @Test func anApprovedPRDoesNotFlash() throws {
        var state = R.turnedOn()
        let approved = try R.pull("owner-a/repo-a#1", requestedAt: R.at(-5), decision: .approved)
        // A PR with no required reviews has no decision, and it flashes.
        let open = try R.pull("owner-a/repo-a#2", requestedAt: R.at(-5))
        let answer = R.answer(toReview: [approved, open])
        state.recordPoll(answer, now: R.now)
        let rows = R.toReview(answer, state)
        #expect(rows.map(\.id) == [open.key, approved.key])
        #expect(rows.map(\.toReviewState) == [.newRequest, .approvedByOthers])
        #expect(rows.map(\.flash) == [true, false])
    }

    // A new request whose CI fails does not flash (user decision, 2026-11-19): the user cannot
    // review it yet. It keeps its state, the "CI failing" text and no Review. Running or passed
    // CI, or no checks, flash as before.
    @Test func aNewRequestWithFailingCIDoesNotFlash() throws {
        let key = try R.key("owner-a/repo-a#1")
        func row(_ ci: CIState?) throws -> ReviewRow {
            let answer = R.answer(toReview: [try R.pull(key.text, ci: ci)])
            return try #require(R.toReview(answer, seen(key)).first)
        }
        let failing = try row(.failing)
        #expect(failing.toReviewState == .newRequest && !failing.flash)
        #expect(failing.status.text == "CI failing" && failing.status.tone == .red)
        #expect(!failing.reviewable && failing.ci == .failing)
        for ci: CIState? in [.running, .passed, nil] {
            #expect(try row(ci).flash)
        }
    }

    // A new request notifies one time, at the first poll where its row flashes. While its CI
    // fails, its notice waits in its mark, also over more polls. The first poll where CI does not
    // fail gives the notice and ends the wait. A later fail and pass of CI gives no notice.
    @Test func theNoticeOfARequestWithFailingCIWaitsAndGoesOutOnce() throws {
        let key = try R.key("owner-a/repo-a#1")
        var state = R.turnedOn()
        func poll(_ ci: CIState?, at minutes: Double) throws -> [PRKey] {
            let pr = try R.pull(key.text, requestedAt: R.at(-5), ci: ci)
            let answer = R.answer(toReview: [pr])
            let arrived = state.recordPoll(answer, now: R.at(minutes))
            return state.recordNotices(R.toReview(answer, state), arrived: arrived)
        }
        for minutes in [0.0, 2] {
            #expect(try poll(.failing, at: minutes).isEmpty)
            #expect(state.requests[key]?.noticeWaitsForCI == true)
        }
        #expect(try poll(.passed, at: 4) == [key])
        #expect(state.requests[key]?.noticeWaitsForCI == false)
        for (ci, minutes) in [(CIState.passed, 6.0), (.failing, 8), (.running, 10), (.passed, 12)] {
            #expect(try poll(ci, at: minutes).isEmpty)
        }
        #expect(state.requests[key]?.noticeWaitsForCI == false)

        // A request with running CI notifies at once, as before, and nothing waits.
        state = R.turnedOn()
        #expect(try poll(.running, at: 0) == [key])
        #expect(state.requests[key]?.noticeWaitsForCI == false)
    }

    // A waiting notice goes with no notification when the row is not a new request any more: the
    // user acted on it in Bifrost, paused it, started a review on GitHub or gave a review that
    // GitHub confirmed here, or others approved it. Then CI that passes gives no notice.
    @Test func aWaitingNoticeGoesWhenTheRowIsNoLongerANewRequest() throws {
        let key = try R.key("owner-a/repo-a#1")
        var waiting = seen(key, at: R.at(-5))
        waiting.requests[key]?.noticeWaitsForCI = true
        let passed = try R.pull(key.text, requestedAt: R.at(-5), ci: .passed)
        func notices(
            _ start: ReviewsState, _ pr: PullRequest, here: [PRKey: ConfirmedReview] = [:]
        ) -> (state: ToReviewState?, due: [PRKey], waits: Bool?) {
            var state = start
            let rows = ReviewRows.toReview(
                R.answer(toReview: [pr]), state, ReviewsConfig(), reviewedHere: here, now: R.now)
            let due = state.recordNotices(rows, arrived: [])
            return (rows.first?.toReviewState, due, state.requests[key]?.noticeWaitsForCI)
        }
        // With no change, the notice goes out now.
        let plain = notices(waiting, passed)
        #expect(plain.state == .newRequest && plain.due == [key] && plain.waits == false)

        var acted = waiting
        acted.prs[key, default: PRState()].actedAt = R.at(-1)
        var paused = waiting
        paused.pauses[key] = R.at(30)
        let pending = try R.pull(key.text, requestedAt: R.at(-5), ci: .passed, pending: "PRR_p")
        let approved = try R.pull(
            key.text, requestedAt: R.at(-5), decision: .approved, ci: .passed)
        let reviewed = [key: ConfirmedReview(.comment, head: passed.headSHA)]
        let ended = [
            notices(acted, passed), notices(paused, passed), notices(waiting, pending),
            notices(waiting, approved), notices(waiting, passed, here: reviewed),
        ]
        #expect(
            ended.map(\.state) == [
                .waitingForYou, .paused(until: R.at(30)), .draftReady, .approvedByOthers,
                .youCommented,
            ])
        #expect(ended.allSatisfy { $0.due.isEmpty && $0.waits == false })
    }

    // A cut answer can miss an open request, so a waiting notice stays while the PR has no row,
    // and goes out when the PR shows again with CI that passes. A request that leaves a full
    // answer loses its mark, and its notice with it.
    @Test func aWaitingNoticeStaysOverACutAnswer() throws {
        let key = try R.key("owner-a/repo-a#1")
        var state = seen(key, at: R.at(-5))
        state.requests[key]?.noticeWaitsForCI = true
        var kept = state
        let cut = R.answer(cut: true)
        let none = kept.recordPoll(cut, now: R.now)
        #expect(kept.recordNotices(R.toReview(cut, kept), arrived: none).isEmpty)
        #expect(kept.requests[key]?.noticeWaitsForCI == true)
        let back = R.answer(toReview: [try R.pull(key.text, requestedAt: R.at(-5), ci: .passed)])
        let arrived = kept.recordPoll(back, now: R.at(2))
        #expect(kept.recordNotices(R.toReview(back, kept), arrived: arrived) == [key])

        var gone = state
        gone.recordPoll(R.answer(), now: R.now)
        #expect(gone.requests[key] == nil)
    }

    @Test func aCutAnswerKeepsTheMissingEntryAndItsPause() throws {
        let shown = try R.pull("owner-a/repo-a#1")
        let missing = try R.key("owner-a/repo-a#2")
        var state = seen(shown.key, baseline: true)
        state.requests[missing] = RequestMark(firstSeen: R.at(-60), baseline: true)
        state.pauses[missing] = R.at(30)
        state.hidden[missing] = R.at(-20)

        for answer in [
            R.answer(toReview: [shown], cut: true),
            R.answer(toReview: [shown], errors: ["Something went wrong."]),
        ] {
            var kept = state
            kept.recordPoll(answer, now: R.now)
            #expect(kept.requests[missing] != nil)
            #expect(kept.pauses[missing] == R.at(30) && kept.hidden[missing] == R.at(-20))
        }

        // A full answer with no errors drops the entry, the pause and the remove, so the request
        // is new when it comes back.
        var gone = state
        gone.recordPoll(R.answer(toReview: [shown]), now: R.now)
        #expect(gone.requests[missing] == nil && gone.pauses.isEmpty && gone.hidden.isEmpty)
        let back = try R.pull(missing.text, requestedAt: R.at(-60))
        #expect(gone.recordPoll(R.answer(toReview: [shown, back]), now: R.at(5)) == [missing])
    }

    @Test func aRemovedRowComesBackOnANewRequest() throws {
        var state = R.turnedOn()
        let approved = try R.pull("owner-a/repo-a#1", requestedAt: R.at(-60), decision: .approved)
        state.recordPoll(R.answer(toReview: [approved]), now: R.now)
        let row = try #require(R.toReview(R.answer(toReview: [approved]), state).first)
        #expect(row.isRemovable)

        state.hide(approved, now: R.now)
        #expect(state.hidden[approved.key] == R.now)
        #expect(R.toReview(R.answer(toReview: [approved]), state).isEmpty)
        // The same request at the next poll stays hidden.
        state.recordPoll(R.answer(toReview: [approved]), now: R.at(5))
        #expect(R.toReview(R.answer(toReview: [approved]), state).isEmpty)

        // A new request for the review shows the PR again.
        let again = try R.pull(approved.key.text, requestedAt: R.at(8), decision: .approved)
        state.recordPoll(R.answer(toReview: [again]), now: R.at(10))
        #expect(state.hidden.isEmpty)
        #expect(R.toReview(R.answer(toReview: [again]), state).map(\.id) == [again.key])

        // With a request time after the clock, the remove keeps the later time, so the same
        // request never shows the PR again.
        let ahead = try R.pull("owner-a/repo-a#3", requestedAt: R.at(4), decision: .approved)
        state.hide(ahead, now: R.now)
        #expect(state.hidden[ahead.key] == R.at(4))
    }

    @Test func onlyAnApprovedByOthersRowIsRemovable() throws {
        let key = try R.key("owner-a/repo-a#1")
        let rows = R.toReview(
            R.answer(toReview: [
                try R.pull(key.text, decision: .approved),
                try R.pull("owner-a/repo-a#2"),
            ]), seen(key))
        #expect(rows.map(\.isRemovable) == [false, true])
    }

    // The Approve button: a Looks good or a Draft ready row whose mark lets the user approve, for
    // the head commit, with no approval of the user on it. Failing CI gives none, and running CI
    // gives one that waits. The Review panel: a Draft ready row with Claude's Comment or Request
    // changes draft.
    // An approval that GitHub confirmed in Bifrost shows You approved before a poll shows it, so
    // the row never offers Approve again. Only the approved head counts.
    @Test func anApprovalConfirmedHereShowsYouApprovedBeforeAPoll() throws {
        let key = try R.key("owner-a/repo-a#1")
        var state = seen(key)
        state.prs[key, default: PRState()].recommendation = RecommendationMark(
            value: .approve, why: "", headSHA: try R.commit("a"), reviewID: nil, at: R.at(-5))
        let pr = try R.pull(key.text)
        func row(_ here: [PRKey: ConfirmedReview]) -> ReviewRow? {
            ReviewRows.toReview(
                R.answer(toReview: [pr]), state, ReviewsConfig(), reviewedHere: here, now: R.now
            ).first
        }
        #expect(row([:])?.toReviewState == .reviewed && row([:])?.approve == .ready)
        let approved = row([key: ConfirmedReview(.approve, head: pr.headSHA)])
        #expect(approved?.toReviewState == .youApproved && approved?.approve == nil)
        let older = ConfirmedReview(.approve, head: String(repeating: "b", count: 40))
        #expect(row([key: older])?.toReviewState == .reviewed)
    }

    // A review of the user that GitHub confirmed in Bifrost shows its state before a poll shows
    // it: a send of Claude's draft gives You requested changes or You commented, also while the
    // answer still has the draft as the pending review. The row then offers neither the draft nor
    // Approve. Only the reviewed head counts.
    @Test func aSendConfirmedHereShowsItsStateBeforeAPoll() throws {
        let key = try R.key("owner-a/repo-a#1")
        var state = seen(key)
        state.prs[key, default: PRState()].recommendation = RecommendationMark(
            value: .requestChanges, why: "", headSHA: try R.commit("a"),
            reviewID: try R.node("PRR_c"), at: R.at(-5))
        let pr = try R.pull(key.text, pending: "PRR_c")
        func row(_ here: ConfirmedReview?) -> ReviewRow? {
            ReviewRows.toReview(
                R.answer(toReview: [pr]), state, ReviewsConfig(),
                reviewedHere: here.map { [key: $0] } ?? [:], now: R.now
            ).first
        }
        #expect(row(nil)?.toReviewState == .draftReady && row(nil)?.draft == .requestChanges)
        let changes = try #require(row(ConfirmedReview(.requestChanges, head: pr.headSHA)))
        #expect(changes.toReviewState == .youRequestedChanges)
        #expect(changes.draft == nil && changes.approve == nil && changes.dot == nil)
        #expect(changes.status.text == "You requested changes" && changes.status.tone == .red)
        let comment = try #require(row(ConfirmedReview(.comment, head: pr.headSHA)))
        #expect(comment.toReviewState == .youCommented && comment.draft == nil)
        #expect(comment.status.text == "You commented" && comment.status.tone == .amber)
        let older = ConfirmedReview(.requestChanges, head: String(repeating: "b", count: 40))
        #expect(row(older)?.toReviewState == .draftReady)
    }

    // The newest opinion of the user on the head gives the state: an approval, or a change
    // request. With no opinion on the head, a comment on the head gives You commented. A comment
    // does not change an opinion. A new request on the same commit stays new, as for an approval.
    @Test func theReviewOfTheUserOnTheHeadShowsItsState() throws {
        let key = try R.key("owner-a/repo-a#1")
        let other = String(repeating: "b", count: 40)
        func opinion(_ state: ReviewState, on commit: String = R.head, at minutes: Double)
            -> ViewerOpinion
        {
            ViewerOpinion(state: state, commit: commit, submittedAt: R.at(minutes))
        }
        let waiting = seen(key, baseline: true)
        func stateWith(_ opinions: [ViewerOpinion]) throws -> ToReviewState? {
            stateOf(try R.pull(key.text, viewerReviews: opinions), waiting)
        }
        let changes = opinion(.changesRequested, at: -5)
        let comment = opinion(.commented, at: -2)
        #expect(try stateWith([changes]) == .youRequestedChanges)
        #expect(try stateWith([comment]) == .youCommented)
        #expect(try stateWith([changes, comment]) == .youRequestedChanges)
        #expect(try stateWith([opinion(.approved, at: -5), comment]) == .youApproved)
        // An opinion of an older commit, or a dismissal, leaves the comment on the head.
        #expect(try stateWith([opinion(.changesRequested, on: other, at: -9)]) == .waitingForYou)
        #expect(
            try stateWith([opinion(.changesRequested, on: other, at: -9), comment])
                == .youCommented)
        #expect(try stateWith([opinion(.dismissed, at: -1)]) == .waitingForYou)
        #expect(try stateWith([opinion(.commented, on: other, at: -1)]) == .waitingForYou)
        // A new request on the same commit stays new, so it flashes as before.
        #expect(stateOf(try R.pull(key.text, viewerReviews: [changes]), seen(key)) == .newRequest)
        #expect(stateOf(try R.pull(key.text, viewerReviews: [comment]), seen(key)) == .newRequest)
        #expect(ToReviewRules.reviewOnHead([changes], head: "") == nil)
        // The row offers no Approve and no draft.
        let answer = R.answer(toReview: [try R.pull(key.text, viewerReviews: [changes])])
        let row = try #require(R.toReview(answer, waiting).first)
        #expect(row.approve == nil && row.draft == nil)
    }

    @Test func theApproveButtonAndTheReviewPanelFollowTheMark() throws {
        let key = try R.key("owner-a/repo-a#1")
        var state = seen(key)
        func row(_ pr: PullRequest) -> ReviewRow? {
            R.toReview(R.answer(toReview: [pr]), state).first
        }
        state.prs[key, default: PRState()].recommendation = RecommendationMark(
            value: .approve, why: "", headSHA: try R.commit("a"), reviewID: nil, at: R.at(-5))
        let plain = try R.pull(key.text)
        #expect(row(plain)?.approve == .ready && row(plain)?.draft == nil)
        #expect(row(try R.pull(key.text, ci: .running))?.approve == .waitsForCI)
        #expect(row(try R.pull(key.text, ci: .failing))?.approve == nil)
        let approval = ViewerOpinion(state: .approved, commit: R.head, submittedAt: R.at(-1))
        #expect(row(try R.pull(key.text, viewerReviews: [approval]))?.approve == nil)
        // A mark of an older commit has no Approve.
        state.prs[key]?.recommendation?.headSHA = try R.commit("b")
        #expect(row(plain)?.approve == nil)
        // Claude's Approve draft: Approve submits it.
        state.prs[key]?.recommendation = RecommendationMark(
            value: .approve, why: "", headSHA: try R.commit("a"), reviewID: try R.node("PRR_c"),
            at: R.at(-5))
        let pending = try R.pull(key.text, pending: "PRR_c")
        #expect(row(pending)?.approve == .ready && row(pending)?.draft == nil)
        // Claude's Request changes or Comment draft: the Review panel, and no Approve.
        state.prs[key]?.recommendation?.value = .requestChanges
        #expect(row(pending)?.approve == nil && row(pending)?.draft == .requestChanges)
        state.prs[key]?.recommendation?.value = .comment
        #expect(row(pending)?.draft == .comment)
        // The user's own pending review shows no mark of Claude, so neither.
        let own = try R.pull(key.text, pending: "PRR_mine")
        #expect(row(own)?.approve == nil && row(own)?.draft == nil)
        // A draft that the user deleted with Approve instead offers Approve.
        state.prs[key]?.recommendation = RecommendationMark(
            value: .comment, why: "", headSHA: try R.commit("a"), reviewID: nil, at: R.at(-5),
            deleted: true)
        #expect(row(plain)?.approve == .ready && row(plain)?.draft == nil)
    }

    @Test func eachStateFollowsItsRule() throws {
        let key = try R.key("owner-a/repo-a#1")
        let pr = try R.pull(key.text)
        let fresh = seen(key)
        #expect(stateOf(pr, fresh) == .newRequest)
        #expect(stateOf(pr, seen(key, baseline: true)) == .waitingForYou)
        // The user acted on the request (a Review click or a round) after its first sight.
        var acted = fresh
        acted.prs[key, default: PRState()].actedAt = R.at(-50)
        #expect(stateOf(pr, acted) == .waitingForYou)

        var reviewing = fresh
        reviewing.prs[key, default: PRState()].round = ActiveRound(
            phase: .running, startedAt: R.at(-5), at: R.at(-6), kind: .review)
        #expect(stateOf(pr, reviewing) == .reviewing)
        var queued = fresh
        queued.queue = [QueueEntry(pr: key, kind: .review, at: R.at(-5))]
        #expect(stateOf(pr, queued) == .queued)

        #expect(stateOf(try R.pull(key.text, pending: "PRR_p1"), fresh) == .draftReady)

        // An Approve with nothing to say leaves a mark with no draft for the head commit.
        var looksGood = fresh
        looksGood.prs[key, default: PRState()].recommendation = RecommendationMark(
            value: .approve, why: "", headSHA: try R.commit("a"), reviewID: nil, at: R.at(-5))
        #expect(stateOf(pr, looksGood) == .reviewed)
        // The same mark on an older commit than the head shows New commits.
        looksGood.prs[key]?.recommendation?.headSHA = try R.commit("b")
        #expect(stateOf(pr, looksGood) == .newCommits)

        var failed = fresh
        failed.prs[key, default: PRState()].lastError = "Claude didn't finish the review."
        #expect(stateOf(pr, failed) == .failed("Claude didn't finish the review."))

        var paused = fresh
        paused.pauses[key] = R.at(30)
        #expect(stateOf(pr, paused) == .paused(until: R.at(30)))
        paused.pauses[key] = R.now
        #expect(stateOf(pr, paused) == .newRequest)

        #expect(stateOf(try R.pull(key.text, decision: .approved), fresh) == .approvedByOthers)
        #expect(stateOf(try R.pull(key.text, direct: false), fresh) == .teamRequest)
    }

    @Test func anApprovalOfTheHeadByTheUserShowsYouApproved() throws {
        let key = try R.key("owner-a/repo-a#1")
        let approval = ViewerOpinion(state: .approved, commit: R.head, submittedAt: R.at(-2))
        let older = ViewerOpinion(
            state: .approved, commit: String(repeating: "b", count: 40), submittedAt: R.at(-2))
        let dismissed = ViewerOpinion(state: .dismissed, commit: R.head, submittedAt: R.at(-1))
        let approved = try R.pull(key.text, viewerReviews: [approval])
        #expect(stateOf(approved, seen(key, baseline: true)) == .youApproved)
        // A new request on the same commit stays new, so it flashes as before.
        #expect(stateOf(approved, seen(key)) == .newRequest)
        let waiting = seen(key, baseline: true)
        #expect(stateOf(try R.pull(key.text, viewerReviews: [older]), waiting) == .waitingForYou)
        #expect(
            stateOf(try R.pull(key.text, viewerReviews: [approval, dismissed]), waiting)
                == .waitingForYou)
        #expect(ToReviewRules.approvedOnHead([approval], head: R.head))
        #expect(!ToReviewRules.approvedOnHead([approval], head: ""))
    }

    @Test func teamRequestsOffHidesATeamRowButKeepsItsSession() throws {
        let key = try R.key("owner-a/repo-a#1")
        var off = ReviewsConfig()
        off.teamRequests = false
        let team = try R.pull(key.text, direct: false)
        var paused = seen(key)
        paused.pauses[key] = R.at(30)
        #expect(stateOf(team, paused, off) == nil)
        #expect(stateOf(try R.pull(key.text), paused, off) == .paused(until: R.at(30)))
        var reviewing = seen(key)
        reviewing.prs[key, default: PRState()].round = ActiveRound(
            phase: .running, startedAt: R.at(-5), at: R.at(-6), kind: .review)
        #expect(stateOf(team, reviewing, off) == .reviewing)
    }

    @Test func theTeamTagShowsInEachState() throws {
        let key = try R.key("owner-a/repo-a#1")
        var paused = seen(key)
        paused.pauses[key] = R.at(30)
        let row = try #require(
            R.toReview(R.answer(toReview: [try R.pull(key.text, direct: false)]), paused).first)
        #expect(row.toReviewState == .paused(until: R.at(30)))
        #expect(row.tag == RowLabel(text: "team", tone: .dim, tip: nil))
        let direct = try #require(
            R.toReview(R.answer(toReview: [try R.pull(key.text)]), paused).first)
        #expect(direct.tag == nil)
    }

    // A queued review of a repository whose clone needs the trust of the user waits for it. A
    // clone that runs, and another repository, keep the row queued.
    @Test func aQueuedReviewOfAnUntrustedRepositoryNeedsTrust() throws {
        let key = try R.key("owner-a/repo-a#1")
        let pr = try R.pull(key.text)
        let other = try #require(RepoName("owner-a/repo-b"))
        var state = seen(key)
        state.queue = [QueueEntry(pr: key, kind: .review, at: R.at(-5))]
        let stateWith = { (clones: CloneStates) in
            R.toReview(R.answer(toReview: [pr]), state, clones: clones).first?.toReviewState
        }
        #expect(stateWith(CloneStates(needsTrust: [key.repo])) == .trustNeeded)
        #expect(stateWith(CloneStates(cloning: [key.repo])) == .queued)
        #expect(stateWith(CloneStates(needsTrust: [other])) == .queued)
        let row = try #require(
            R.toReview(
                R.answer(toReview: [pr]), state, clones: CloneStates(needsTrust: [key.repo])
            ).first)
        #expect(row.status == RowLabel(text: "Trust needed", tone: .plain, tip: RowText.trustTip))
        // A running round wins.
        state.prs[key, default: PRState()].round = ActiveRound(
            phase: .running, startedAt: R.at(-5), at: R.at(-6), kind: .review)
        #expect(stateWith(CloneStates(needsTrust: [key.repo])) == .reviewing)
    }

    @Test func theTabOrderIsTheGroupThenTheOldestRequest() throws {
        let keys = try (0...13).map { try R.key("owner-a/repo-a#\($0 + 1)") }
        let untrusted = try R.key("owner-a/repo-b#15")
        let (changed, commented) = (try R.key("owner-a/repo-c#16"), try R.key("owner-a/repo-c#17"))
        var state = R.turnedOn()
        for key in keys { state.requests[key] = RequestMark(firstSeen: R.at(-60), baseline: false) }
        for index in [3, 4, 12] { state.requests[keys[index]]?.baseline = true }
        for key in [changed, commented] {
            state.requests[key] = RequestMark(firstSeen: R.at(-60), baseline: true)
        }
        state.pauses[keys[5]] = R.at(50)
        state.pauses[keys[6]] = R.at(20)
        state.requests[untrusted] = RequestMark(firstSeen: R.at(-60), baseline: false)
        state.queue = [
            QueueEntry(pr: keys[7], kind: .review, at: R.at(-1)),
            QueueEntry(pr: untrusted, kind: .review, at: R.at(-2)),
        ]
        state.prs[keys[10], default: PRState()].recommendation = RecommendationMark(
            value: .approve, why: "", headSHA: try R.commit("a"), reviewID: nil, at: R.at(-5))
        state.prs[keys[11], default: PRState()].lastError = "The review failed."
        state.prs[keys[13], default: PRState()].round = ActiveRound(
            phase: .running, startedAt: R.at(-5), at: R.at(-6), kind: .review)
        let approval = ViewerOpinion(state: .approved, commit: R.head, submittedAt: R.at(-2))
        let changes = ViewerOpinion(
            state: .changesRequested, commit: R.head, submittedAt: R.at(-2))
        let comment = ViewerOpinion(state: .commented, commit: R.head, submittedAt: R.at(-2))
        let answer = R.answer(toReview: [
            try R.pull(commented.text, requestedAt: R.at(-400), viewerReviews: [comment]),
            try R.pull(changed.text, requestedAt: R.at(-400), viewerReviews: [changes]),
            try R.pull(keys[0].text, direct: false, requestedAt: R.at(-200)),
            try R.pull(keys[1].text, requestedAt: R.at(-10)),
            try R.pull(keys[2].text, requestedAt: R.at(-20)),
            try R.pull(keys[3].text, requestedAt: R.at(-30)),
            try R.pull(keys[4].text, requestedAt: R.at(-90)),
            // The first pause to end comes first, also when its request is newer.
            try R.pull(keys[5].text, requestedAt: R.at(-90)),
            try R.pull(keys[6].text, requestedAt: R.at(-10)),
            try R.pull(keys[7].text, requestedAt: R.at(-10)),
            try R.pull(keys[8].text, requestedAt: R.at(-300), decision: .approved),
            try R.pull(keys[9].text, requestedAt: R.at(-1), pending: "PRR_p1"),
            try R.pull(keys[10].text, requestedAt: R.at(-1)),
            try R.pull(keys[11].text, requestedAt: R.at(-1)),
            try R.pull(keys[12].text, requestedAt: R.at(-1), viewerReviews: [approval]),
            try R.pull(keys[13].text, requestedAt: R.at(-1)),
            try R.pull(untrusted.text, requestedAt: R.at(-1)),
        ])
        let rows = R.toReview(
            answer, state, clones: CloneStates(needsTrust: [untrusted.repo]))
        // Each group of the tab has a row, in the order of the groups.
        var order = [2, 1, 9, 10, 11, 4, 3].map { keys[$0] } + [untrusted]
        order += [13, 7, 6, 5, 12].map { keys[$0] } + [changed, commented]
        order += [8, 0].map { keys[$0] }
        #expect(rows.map(\.id) == order)
        #expect(
            rows.map(\.toReviewState) == [
                .newRequest, .newRequest, .draftReady, .reviewed, .failed("The review failed."),
                .waitingForYou, .waitingForYou, .trustNeeded, .reviewing, .queued,
                .paused(until: R.at(20)),
                .paused(until: R.at(50)), .youApproved, .youRequestedChanges, .youCommented,
                .approvedByOthers, .teamRequest,
            ])
    }

    // One PR with the input of each rule from the top rule down. The row has the state of the
    // top rule, so each rule wins over each rule below it.
    @Test(arguments: [StateRule?](StateRule.allCases) + [nil])
    func theFirstRuleThatHoldsWins(_ top: StateRule?) throws {
        let (pr, state) = try stacked(from: top)
        #expect(stateOf(pr, state) == (top?.state ?? .newRequest))
    }

    // With Show team requests off, the team filter is below the sessions and above every other
    // rule.
    @Test(arguments: [StateRule.queue, .pending])
    func theTeamFilterIsBelowTheSessions(_ top: StateRule) throws {
        var off = ReviewsConfig()
        off.teamRequests = false
        let (pr, state) = try stacked(from: top)
        #expect(stateOf(pr, state, off) == (top == .queue ? .queued : nil))
    }
}

// The rules of the To review state, in the order of ToReviewRules.state, each with the state that
// its input gives.
enum StateRule: Int, CaseIterable, Sendable {
    case round, queue, pending, approval, error, looksGood, pause, othersApproved, team, baseline

    var state: ToReviewState {
        switch self {
        case .round: .reviewing
        case .queue: .queued
        case .pending: .draftReady
        case .approval: .youApproved
        case .error: .failed("The review failed.")
        case .looksGood: .reviewed
        case .pause: .paused(until: Rows.at(30))
        case .othersApproved: .approvedByOthers
        case .team: .teamRequest
        case .baseline: .waitingForYou
        }
    }
}

// The PR and the state with the input of each rule from top down. nil gives no input: a new
// request.
private func stacked(from top: StateRule?) throws -> (PullRequest, ReviewsState) {
    let level = top?.rawValue ?? StateRule.allCases.count
    let rules = Set(StateRule.allCases.filter { $0.rawValue >= level })
    let key = try R.key("owner-a/repo-a#1")
    var state = seen(key, baseline: rules.contains(.baseline))
    var prState = PRState()
    if rules.contains(.round) {
        prState.round = ActiveRound(
            phase: .running, startedAt: R.at(-5), at: R.at(-6), kind: .review)
    }
    if rules.contains(.queue) { state.queue = [QueueEntry(pr: key, kind: .review, at: R.at(-5))] }
    if rules.contains(.error) { prState.lastError = "The review failed." }
    if rules.contains(.looksGood) {
        prState.recommendation = RecommendationMark(
            value: .approve, why: "", headSHA: try R.commit("a"), reviewID: nil, at: R.at(-5))
    }
    if rules.contains(.pause) { state.pauses[key] = R.at(30) }
    state.prs[key] = prState
    let approval = ViewerOpinion(state: .approved, commit: R.head, submittedAt: R.at(-2))
    let pr = try R.pull(
        key.text, direct: !rules.contains(.team),
        decision: rules.contains(.othersApproved) ? .approved : nil,
        pending: rules.contains(.pending) ? "PRR_p1" : nil,
        viewerReviews: rules.contains(.approval) ? [approval] : [])
    return (pr, state)
}
