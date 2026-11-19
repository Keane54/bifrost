import Foundation
import Testing

@testable import BifrostReviews

// The texts, the tips and the colours of the rows (docs/behaviour/reviews.md, "The rows").

private typealias R = Rows

private let ciFailingTip =
    "CI is failing on this pull request, so Bifrost won't review or approve it. It can be "
    + "reviewed again when CI passes."
private let ciRunningTip =
    "CI is still running. Claude can review now, but you can approve only when it has passed."

// The one To review row of the PR, with a state that saw its request after the turn-on.
private func row(
    _ pr: PullRequest, _ change: (inout ReviewsState) throws -> Void = { _ in }
) throws -> ReviewRow {
    var state = R.turnedOn()
    state.requests[pr.key] = RequestMark(firstSeen: R.at(-60), baseline: false)
    try change(&state)
    return try #require(R.toReview(R.answer(toReview: [pr]), state).first)
}

private func mark(
    _ value: Recommendation, why: String = "", review: String? = nil, deleted: Bool = false
) throws -> RecommendationMark {
    RecommendationMark(
        value: value, why: why, headSHA: try R.commit("a"), reviewID: try review.map(R.node),
        at: R.at(-5), deleted: deleted)
}

private func label(_ text: String, _ tone: RowTone, _ tip: String? = nil) -> RowLabel {
    RowLabel(text: text, tone: tone, tip: tip)
}

// A draft comment of the review: a summary has no path.
private func draft(_ review: String, path: String) throws -> DraftRecord {
    DraftRecord(
        reviewID: try R.node(review), pr: try R.key("owner-a/repo-a#1"), path: path, line: 1,
        body: "A comment.", at: R.at(-5))
}

@Suite("the row texts", .timeLimit(.minutes(1)))
struct RowTextTests {
    @Test func theAgeAndTheSizeTexts() {
        #expect(RowText.age(.seconds(-5)) == "just now")
        #expect(RowText.age(.seconds(59)) == "just now")
        #expect(RowText.age(.seconds(60)) == "1m ago")
        #expect(RowText.age(.seconds(3599)) == "59m ago")
        #expect(RowText.age(.seconds(3600)) == "1h ago")
        #expect(RowText.age(.seconds(86_399)) == "23h ago")
        #expect(RowText.age(.seconds(86_400 * 3 + 5)) == "3d ago")
        #expect(RowText.size(additions: 12, deletions: 3) == "+12 \u{2212}3")
    }

    @Test func theTextOfEachToReviewState() {
        let text = { (state: ToReviewState) in RowText.toReview(state, now: R.now) }
        #expect(text(.newRequest) == "")
        #expect(text(.draftReady) == "Draft ready")
        #expect(text(.reviewed) == "Looks good")
        #expect(text(.failed("No result.")) == "Review failed")
        #expect(text(.waitingForYou) == "Waiting for you")
        #expect(text(.reviewing) == "Reviewing")
        #expect(text(.queued) == "Queued")
        #expect(text(.paused(until: R.at(41.5))) == "Paused 42m")
        #expect(text(.paused(until: R.at(0.1))) == "Paused 1m")
        #expect(text(.paused(until: R.at(-3))) == "Paused 1m")
        #expect(text(.youApproved) == "You approved")
        #expect(text(.approvedByOthers) == "Approved by others")
        #expect(text(.teamRequest) == "Team request")
    }

    @Test func aRowWithNoResultShowsTheAuthorTheSizeAndTheAge() throws {
        let plain = try row(
            R.pull("owner-a/repo-a#1", title: "Fix the cache", requestedAt: R.at(-150)))
        #expect(plain.repo == "repo-a" && plain.title == "Fix the cache")
        #expect(plain.notes == ["user-a", "+12 \u{2212}3", "2h ago"])
        #expect(plain.status == RowLabel(text: "", tone: .plain, tip: nil))
        #expect(plain.dot == nil && plain.tag == nil && plain.review == nil)

        let key = try R.key("owner-a/repo-a#1")
        let failed = try row(R.pull(key.text)) {
            $0.prs[key, default: PRState()].lastError = "Claude didn't write a result."
        }
        #expect(failed.status == label("Review failed", .red, "Claude didn't write a result."))
    }

    @Test func claudesResultGivesTheTextTheLineTheDotAndTheTip() throws {
        let key = try R.key("owner-a/repo-a#1")
        let looksGood = try row(R.pull(key.text)) {
            $0.prs[key, default: PRState()].recommendation = try mark(
                .approve, why: "Small and safe.")
        }
        #expect(looksGood.toReviewState == .reviewed && looksGood.dot == .green)
        #expect(
            looksGood.status
                == RowLabel(
                    text: "Approval recommended", tone: .green,
                    tip: "Claude suggests: Approve. Small and safe. Nothing was posted."))
        #expect(looksGood.notes == ["Claude found nothing to change."])

        let comment = try row(R.pull(key.text, pending: "PRR_d1")) {
            $0.prs[key, default: PRState()].recommendation = try mark(.comment, review: "PRR_d1")
            $0.drafts = [
                try draft("PRR_d1", path: ""), try draft("PRR_d1", path: "src/a.swift"),
                try draft("PRR_d1", path: "src/b.swift"), try draft("PRR_x9", path: "src/c.swift"),
            ]
        }
        #expect(comment.toReviewState == .draftReady && comment.dot == .amber)
        #expect(
            comment.status
                == RowLabel(
                    text: "Draft ready", tone: .amber,
                    tip: "Claude suggests: Comment. Click Comment to check the draft and send it."))
        #expect(comment.notes == ["Claude drafted a summary and 2 comments."])

        let changes = try row(R.pull(key.text, pending: "PRR_d2")) {
            $0.prs[key, default: PRState()].recommendation = try mark(
                .requestChanges, why: "It drops data.", review: "PRR_d2")
            $0.drafts = [try draft("PRR_d2", path: "src/a.swift")]
        }
        #expect(changes.dot == .red && changes.notes == ["Claude drafted 1 comment."])
        #expect(
            changes.status
                == RowLabel(
                    text: "Changes required", tone: .red,
                    tip: "Claude suggests: Request changes. It drops data. Click Request "
                        + "changes to check the draft and send it."))

        let approve = try row(R.pull(key.text, pending: "PRR_d3")) {
            $0.prs[key, default: PRState()].recommendation = try mark(.approve, review: "PRR_d3")
            $0.drafts = [try draft("PRR_d3", path: "")]
        }
        #expect(approve.notes == ["Claude drafted a summary."])
        #expect(
            approve.status.tip
                == "Claude suggests: Approve. Click Approve to submit Claude's draft as an "
                + "approval.")

        // Bifrost kept no draft comment of the review.
        let unknown = try row(R.pull(key.text, pending: "PRR_d4")) {
            $0.prs[key, default: PRState()].recommendation = try mark(.comment, review: "PRR_d4")
        }
        #expect(unknown.notes == ["Claude drafted a review."])

        // A pending review of the user has no mark of Claude.
        let own = try row(R.pull(key.text, pending: "PRR_u1")) {
            $0.prs[key, default: PRState()].recommendation = try mark(.comment, review: "PRR_d1")
        }
        #expect(own.status == RowLabel(text: "Draft ready", tone: .plain, tip: nil))
        #expect(own.dot == nil && own.notes.count == 3)

        let deleted = try row(R.pull(key.text)) {
            $0.prs[key, default: PRState()].recommendation = try mark(.comment, deleted: true)
        }
        #expect(deleted.toReviewState == .reviewed && deleted.dot == .dim)
        #expect(
            deleted.status
                == RowLabel(
                    text: "Draft deleted", tone: .dim,
                    tip: "You deleted Claude's draft. Click Approve to approve this pull request."))
        #expect(deleted.notes == ["You deleted Claude's draft. Approve when you're ready."])
    }

    @Test func approvedByOthersSaysHowManyApproved() throws {
        let line = { (approvals: Int) in
            try row(R.pull("owner-a/repo-a#1", decision: .approved, approvals: approvals)).notes
        }
        #expect(try line(0) == ["Others approved it, so you don't need to review it."])
        #expect(try line(1) == ["1 person approved it, so you don't need to review it."])
        #expect(try line(3) == ["3 people approved it, so you don't need to review it."])
        let shown = try row(R.pull("owner-a/repo-a#1", decision: .approved))
        #expect(shown.status == RowLabel(text: "Approved by others", tone: .dim, tip: nil))
        #expect(shown.dot == .dim)
    }

    @Test func ciReplacesTheStatusTextOfSomeStates() throws {
        let key = try R.key("owner-a/repo-a#1")
        #expect(
            try row(R.pull(key.text, ci: .running)).status
                == RowLabel(text: "CI running", tone: .dim, tip: ciRunningTip))
        #expect(
            try row(R.pull(key.text, ci: .failing)).status
                == RowLabel(text: "CI failing", tone: .red, tip: ciFailingTip))
        #expect(try row(R.pull(key.text, ci: .passed)).status.text == "")

        // A row of Claude's result keeps its line and its dot.
        let reviewed = try row(R.pull(key.text, ci: .running)) {
            $0.prs[key, default: PRState()].recommendation = try mark(.approve)
        }
        #expect(reviewed.status.text == "CI running" && reviewed.dot == .green)
        #expect(reviewed.notes == ["Claude found nothing to change."])

        // A session, a state of the user and approved by others keep their own text.
        let reviewing = try row(R.pull(key.text, ci: .failing)) {
            $0.queue = [QueueEntry(pr: key, kind: .review, at: R.at(-1))]
        }
        #expect(reviewing.status.text == "Queued")
        #expect(try row(R.pull(key.text, decision: .approved, ci: .failing)).status.text
            == "Approved by others")
    }

    @Test func theTipsOfTheToReviewStates() throws {
        let key = try R.key("owner-a/repo-a#1")
        let queued = try row(R.pull(key.text)) {
            $0.queue = [QueueEntry(pr: key, kind: .review, at: R.at(-1))]
        }
        #expect(queued.status == label("Queued", .plain, "Waiting for a free review slot."))
        let reviewing = try row(R.pull(key.text)) {
            $0.prs[key, default: PRState()].round = ActiveRound(
                phase: .running, startedAt: R.at(-1), at: R.at(-2), kind: .review)
        }
        #expect(reviewing.status.tip == "Claude is reviewing this pull request.")
        let opinion = ViewerOpinion(state: .approved, commit: R.head, submittedAt: R.at(-1))
        let approved = try row(R.pull(key.text, viewerReviews: [opinion])) {
            $0.requests[key]?.baseline = true
        }
        #expect(
            approved.status
                == RowLabel(
                    text: "You approved", tone: .green,
                    tip: "You approved this pull request on GitHub."))
        let waiting = try row(R.pull(key.text)) { $0.requests[key]?.baseline = true }
        #expect(waiting.status == RowLabel(text: "Waiting for you", tone: .plain, tip: nil))
        let paused = try row(R.pull(key.text)) { $0.pauses[key] = R.at(30) }
        #expect(paused.status == RowLabel(text: "Paused 30m", tone: .plain, tip: nil))
    }

    @Test func theTextsAndTipsOfTheMyPRsTab() throws {
        #expect(RowText.status(.changesRequested, cut: false) == label("Changes requested", .red))
        #expect(RowText.status(.comments, cut: false) == label("Comments", .blue))
        #expect(RowText.status(.approved, cut: false) == label("Approved", .green))
        #expect(
            RowText.status(.pending, cut: true)
                == label("Pending", .dim, "Bifrost read only the newest items of this PR."))

        let trust =
            "Bifrost needs you to trust this repository first. Click Trust at the top of the panel."
        let fork =
            "This pull request comes from a fork. Bifrost can't push there, so Claude leaves its "
            + "comments to you."
        let expected: [(ClaudeState, RowLabel)] = [
            (
                .needsYou(1),
                label("Needs you", .red, "Claude needs your answer on 1 comment. Click to answer.")
            ),
            (
                .needsYou(2),
                label("Needs you", .red, "Claude needs your answer on 2 comments. Click to answer.")
            ),
            (.fixing(1), label("Fixing 1", .plain, "Claude is working on 1 comment.")),
            (.fixing(3), label("Fixing 3", .plain, "Claude is working on 3 comments.")),
            (.queued, label("Queued", .dim, "Waiting for a free session slot.")),
            (.trustNeeded, label("Trust needed", .dim, trust)),
            (.cloning, label("Cloning", .dim, "Bifrost is copying this repository.")),
            (.waiting, label("Waiting", .dim)),
            (.error("The push failed."), label("Error", .red, "The push failed.")),
            (.fork, label("Fork", .dim, fork)),
        ]
        for (state, label) in expected {
            #expect(RowText.claude(state) == label)
        }

        let member = R.person("user-e")
        var state = R.turnedOn()
        state.fixFrom = R.at(-100)
        let pr = try R.pull(
            "owner-a/repo-a#1", title: "Rework the menu",
            reviews: [
                R.review("PRR_c1", by: R.copilot, .commented, at: R.at(-300)),
                R.review("PRR_c2", by: R.copilot, .commented, at: R.at(-100)),
            ],
            threads: [
                R.thread("PRRT_1", by: R.copilot, review: "PRR_c2"),
                R.thread("PRRT_2", by: R.copilot, review: "PRR_c2"),
                R.thread("PRRT_3", by: R.copilot, review: "PRR_c2"),
                R.thread("PRRT_4", by: member, at: R.at(-200)),
                R.thread("PRRT_5", by: member, at: R.at(-200)),
            ],
            failedChecks: 2)
        let shown = try #require(R.mine(R.answer(mine: [pr]), state).first)
        #expect(shown.repo == "repo-a" && shown.title == "Rework the menu")
        #expect(shown.tag == RowLabel(text: "\u{2715}", tone: .red, tip: "2 checks failed"))
        #expect(shown.notes == ["Copilot: 3 more", "2 older comments"])
        #expect(shown.review == RowText.status(.comments, cut: false))
        #expect(shown.status == RowText.claude(.waiting))
        #expect(!shown.flash && shown.dot == nil)
        let one = try #require(
            R.mine(R.answer(mine: [try R.pull("owner-a/repo-a#1", failedChecks: 1)]), state).first)
        #expect(one.tag?.tip == "1 check failed" && one.notes.isEmpty)
    }
}
