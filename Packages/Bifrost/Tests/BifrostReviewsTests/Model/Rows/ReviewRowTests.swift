import Foundation
import Testing

@testable import BifrostReviews

// The rows of both tabs from a real poll answer (Fixtures/poll-basic.json), and the To review rows
// that stay while their PR has an approval progress.

private typealias R = Rows

@Suite("the rows of a poll", .timeLimit(.minutes(1)))
struct ReviewRowTests {
    @Test func theBasicAnswerGivesTheRowsOfBothTabs() throws {
        let answer = try PollAnswer.decode(FixtureFiles.data("poll-basic")).get()
        var state = ReviewsState()
        state.recordPoll(answer, now: R.now)

        let toReview = R.toReview(answer, state)
        #expect(
            try toReview.map(\.id)
                == [R.key("owner-a/repo-b#101"), R.key("owner-a/repo-b#102"),
                    R.key("owner-a/repo-a#7")])
        #expect(toReview.allSatisfy { $0.tab == .toReview && !$0.flash })
        #expect(
            toReview.map(\.toReviewState) == [.waitingForYou, .approvedByOthers, .teamRequest])
        let first = toReview[0]
        #expect(first.repo == "repo-b" && first.title == "Add search box")
        #expect(first.notes == ["user-a", "+10 \u{2212}2", "4d ago"])
        #expect(first.status == RowLabel(text: "Waiting for you", tone: .plain, tip: nil))
        #expect(toReview[2].tag == RowLabel(text: "team", tone: .dim, tip: nil))
        #expect(toReview[2].notes == ["user-b", "+10 \u{2212}2", "6d ago"])

        let mine = R.mine(answer, state)
        #expect(try mine.map(\.id) == [R.key("owner-a/repo-b#90"), R.key("owner-a/repo-a#31")])
        #expect(mine.allSatisfy { $0.tab == .mine && !$0.flash })
        #expect(mine[0].mineState?.status == .changesRequested)
        #expect(mine[0].mineState?.claude == .waiting)
        #expect(
            mine[0].reviewers
                == [Reviewer(name: "user-e", tone: .red), Reviewer(name: "Copilot", tone: .dim)])
        // The open items of the first turn-on wait for Handle now: the Copilot thread, the
        // review body and the comment.
        #expect(mine[0].notes == ["3 older comments"])
        #expect(mine[0].tag?.tip == "1 check failed")
        #expect(mine[1].mineState?.status == .approved)
        #expect(mine[1].reviewers == [Reviewer(name: "user-f", tone: .green)])
        #expect(mine[1].notes.isEmpty && mine[1].tag == nil)
    }

    // A held row that the new rows drop stays at its old place, or at the end. A held row that
    // the new rows still have takes its new form. With no held PR, the new rows stay as they are.
    @Test func aHeldRowStaysAtItsPlace() throws {
        let answer = try PollAnswer.decode(FixtureFiles.data("poll-basic")).get()
        var state = ReviewsState()
        state.recordPoll(answer, now: R.now)
        let old = R.toReview(answer, state)
        let (a, b, c) = (old[0], old[1], old[2])
        #expect(ReviewRows.holding([b.id], old: old, new: [a, c]) == old)
        #expect(ReviewRows.holding([c.id], old: old, new: [a]) == [a, c])
        #expect(ReviewRows.holding([a.id, c.id], old: old, new: [b]) == old)
        var changed = b
        changed.title = "Add search box, part 2"
        #expect(ReviewRows.holding([b.id], old: old, new: [a, changed, c]) == [a, changed, c])
        #expect(ReviewRows.holding([], old: old, new: [c]) == [c])
    }
}
