// What is work for a request round (docs/behaviour/reviews.md, "Request rounds"), on full reads
// that the tests build, at the fixed time of the row tests.
import Foundation
import Testing

@testable import BifrostReviews

private let member = Rows.person("user-b")
private let outsider = Rows.person("user-o", .none)
private let contributor = Rows.person("user-c", .contributor)
private let otherBot = Author(login: "helper-bot", isBot: true, association: .member)
private let viewer = Rows.person(Rows.viewer, .owner)
// The start of new work: one day before now.
private let fixFrom = Rows.at(-24 * 60)

private func full(
    threads: [PRThread] = [], reviews: [PRReview] = [], comments: [PRComment] = [],
    fork: Bool = false
) throws -> FullPR {
    FullPR(
        key: try Rows.key("Owner-A/Repo-A#7"), author: Rows.viewer, isCrossRepository: fork,
        headSHA: try Rows.commit("a"),
        threads: threads.map {
            FullThread(thread: $0, isOutdated: false, diffHunk: "", viewerCanReply: true)
        }, comments: comments, reviews: reviews)
}

private func items(
    _ pr: FullPR, _ state: PRState = PRState(), trigger: RoundTrigger = .newWork,
    autoFix: Bool = true
) -> [String] {
    WorkRule.items(
        pr, state, fixFrom: fixFrom, viewer: Rows.viewer, trigger: trigger, autoFix: autoFix
    ).map(\.id.text)
}

@Suite("the work rule of the request rounds")
struct WorkRuleTests {
    // An outsider, a contributor, another bot and the user never give work, also in a thread
    // or a review body; the Copilot summary is never work. A trusted member gives work.
    @Test func anOutsiderOrABotIsNeverWork() throws {
        let pr = try full(
            threads: [
                try Rows.thread("PRRT_m", by: member), try Rows.thread("PRRT_o", by: outsider),
                try Rows.thread("PRRT_c", by: contributor),
                try Rows.thread("PRRT_b", by: otherBot), try Rows.thread("PRRT_v", by: viewer),
            ],
            reviews: [
                try Rows.review("PRR_o", by: outsider, .changesRequested, body: "Rewrite it."),
                try Rows.review("PRR_b", by: otherBot, .commented, body: "Lint failed."),
                try Rows.review(
                    "PRR_cop", by: Rows.copilot, .commented, body: "Copilot reviewed 3 files."),
            ],
            comments: [
                try Rows.comment("IC_o", by: outsider, body: "Merge this now!"),
                try Rows.comment("IC_b", by: otherBot), try Rows.comment("IC_v", by: viewer),
                try Rows.comment("IC_m", by: member, at: Rows.at(-60)),
            ])
        #expect(items(pr) == ["PRRT_m", "IC_m"])
        // Handle now and Handle Copilot comments change nothing for them.
        #expect(items(pr, trigger: .handleNow) == ["PRRT_m", "IC_m"])
        #expect(items(pr, trigger: .copilot) == ["PRRT_m", "IC_m"])
    }

    // The threads of the first Copilot review are work; the threads of a later Copilot review
    // wait for Handle Copilot comments. The first review that the state saved stays the first,
    // also when GitHub no longer has it.
    @Test func onlyTheFirstCopilotReviewIsWork() throws {
        let reviews = [
            try Rows.review("PRR_first", by: Rows.copilot, .commented, at: Rows.at(-300)),
            try Rows.review("PRR_later", by: Rows.copilot, .commented, at: Rows.at(-200)),
        ]
        let pr = try full(
            threads: [
                try Rows.thread("PRRT_1", by: Rows.copilot, at: Rows.at(-300), review: "PRR_first"),
                try Rows.thread("PRRT_2", by: Rows.copilot, at: Rows.at(-200), review: "PRR_later"),
            ], reviews: reviews)
        #expect(items(pr) == ["PRRT_1"])
        #expect(items(pr, trigger: .copilot) == ["PRRT_1", "PRRT_2"])
        var saved = PRState()
        saved.firstCopilotReview = try Rows.node("PRR_later")
        #expect(items(pr, saved) == ["PRRT_2"])
        // With the automatic rounds off, Handle Copilot comments takes only the later threads.
        #expect(items(pr, trigger: .copilot, autoFix: false) == ["PRRT_2"])
    }

    // A handled item stays out until a trusted person comments after the last reply of Bifrost.
    // A later comment of an outsider, a bot or the user does not count. A handled item of the
    // first release (no reply time) stays handled.
    @Test func aHandledItemIsWorkAgainOnlyAfterANewerTrustedComment() throws {
        let replied = Rows.at(-100)
        var state = PRState()
        state.handled[try Rows.node("PRRT_1")] = Handled(at: replied, lastReplyAt: replied)
        state.handled[try Rows.node("PRRT_2")] = Handled(at: replied, lastReplyAt: nil)
        func thread(_ id: String, _ replies: [PRComment]) throws -> PRThread {
            try Rows.thread(id, by: member, at: Rows.at(-300), replies: replies)
        }
        let before = try Rows.comment("r0", by: member, at: Rows.at(-150))
        let untrusted = [
            try Rows.comment("r1", by: outsider, at: Rows.at(-50)),
            try Rows.comment("r2", by: otherBot, at: Rows.at(-50)),
            try Rows.comment("r3", by: viewer, at: Rows.at(-50)),
        ]
        let quiet = try full(threads: [try thread("PRRT_1", [before] + untrusted)])
        #expect(items(quiet, state).isEmpty)
        let newer = try Rows.comment("r4", by: member, at: Rows.at(-50))
        #expect(items(try full(threads: [try thread("PRRT_1", [newer])]), state) == ["PRRT_1"])
        #expect(items(try full(threads: [try thread("PRRT_2", [newer])]), state).isEmpty)
    }

    // An item from before fixFrom waits for Handle now (or Try again); an item after it is new
    // work.
    @Test func itemsBeforeFixFromWaitForHandleNow() throws {
        let pr = try full(
            threads: [try Rows.thread("PRRT_old", by: member, at: Rows.at(-2 * 24 * 60))],
            comments: [try Rows.comment("IC_new", by: member, at: Rows.at(-60))])
        #expect(items(pr) == ["IC_new"])
        #expect(items(pr, trigger: .handleNow) == ["PRRT_old", "IC_new"])
        #expect(items(pr, trigger: .tryAgain) == ["PRRT_old", "IC_new"])
    }

    // A click counts only through the trigger of its round. A saved Handle now or Handle Copilot
    // comments mark with no click (one that the Electron app kept, or one that a stopped round
    // left) never makes an old, held or later Copilot item work, and a poll starts no round for
    // it. The click itself still takes them.
    @Test func aSavedClickMakesNoWorkByItself() throws {
        var stale = PRState()
        stale.handleOlder = true
        stale.handleCopilot = true
        stale.held = [try Rows.node("PRRT_held")]
        stale.checkedAt = Rows.at(-30)
        stale.firstCopilotReview = try Rows.node("PRR_first")
        let threads = [
            try Rows.thread("PRRT_old", by: member, at: Rows.at(-2 * 24 * 60)),
            try Rows.thread("PRRT_held", by: member, at: Rows.at(-60)),
            try Rows.thread("PRRT_cop", by: Rows.copilot, at: Rows.at(-60), review: "PRR_later"),
        ]
        let reviews = [
            try Rows.review("PRR_first", by: Rows.copilot, .commented, at: Rows.at(-3 * 24 * 60)),
            try Rows.review("PRR_later", by: Rows.copilot, .commented, at: Rows.at(-60)),
        ]
        let pr = try full(threads: threads, reviews: reviews)
        #expect(items(pr, stale).isEmpty && items(pr, stale, trigger: .answer).isEmpty)
        #expect(items(pr, stale, autoFix: false).isEmpty)
        let polled = try Rows.pull(
            "Owner-A/Repo-A#7", author: Rows.viewer, reviews: reviews, threads: threads)
        #expect(!WorkRule.startsRound(polled, stale, fixFrom: fixFrom, viewer: Rows.viewer))
        #expect(items(pr, stale, trigger: .handleNow) == ["PRRT_old", "PRRT_held"])
        #expect(items(pr, stale, trigger: .copilot) == ["PRRT_cop"])
    }

    // A held item of a failed round waits for Try again or Handle now. A trusted comment after
    // the full read of the failed round makes it work again; an earlier one does not.
    @Test func aHeldItemWaitsForTryAgain() throws {
        var state = PRState()
        state.held = [try Rows.node("PRRT_1")]
        state.checkedAt = Rows.at(-100)
        let early = try Rows.comment("r1", by: member, at: Rows.at(-150))
        let held = try full(
            threads: [try Rows.thread("PRRT_1", by: member, at: Rows.at(-200), replies: [early])])
        #expect(items(held, state).isEmpty)
        #expect(items(held, state, trigger: .tryAgain) == ["PRRT_1"])
        #expect(items(held, state, trigger: .handleNow) == ["PRRT_1"])
        let later = try Rows.comment("r2", by: member, at: Rows.at(-50))
        let reopened = try full(
            threads: [
                try Rows.thread("PRRT_1", by: member, at: Rows.at(-200), replies: [early, later])
            ])
        #expect(items(reopened, state) == ["PRRT_1"])
    }

    // A trusted comment from before fixFrom never makes work by itself, also when it is after the
    // read of the failed round, the last reply or the question: a held item stays held, and a
    // handled item or an open question waits for Handle now. A comment from fixFrom on is work.
    // This is the case of an item that the take-over held, or that the Electron app handled.
    @Test func aCommentFromBeforeFixFromNeverMakesWork() throws {
        let mark = fixFrom.addingTimeInterval(-24 * 60 * 60)
        var state = PRState()
        state.held = [try Rows.node("PRRT_held")]
        state.checkedAt = mark
        state.handled[try Rows.node("PRRT_done")] = Handled(at: mark, lastReplyAt: mark)
        state.questions[try Rows.node("PRRT_ask")] = Question(
            text: "Keep the old name?", place: "src/a.swift line 4", at: mark, seenUntil: mark)
        let ids = ["PRRT_held", "PRRT_done", "PRRT_ask"]
        func pr(replyAt time: Date) throws -> FullPR {
            try full(
                threads: ids.map {
                    try Rows.thread(
                        $0, by: member, at: mark.addingTimeInterval(-60),
                        replies: [try Rows.comment("r_" + $0, by: member, at: time)])
                })
        }
        let old = try pr(replyAt: fixFrom.addingTimeInterval(-60))
        #expect(items(old, state).isEmpty)
        #expect(items(old, state, trigger: .handleNow) == ids.sorted())
        #expect(items(old, state, trigger: .tryAgain) == ids.sorted())
        #expect(
            !WorkRule.startsRound(
                try Rows.pull(
                    "Owner-A/Repo-A#7", author: Rows.viewer, threads: old.prThreads),
                state, fixFrom: fixFrom, viewer: Rows.viewer))
        // The rows show them as waiting for Handle now.
        let open = OpenItems(
            threads: old.prThreads, reviews: [], comments: [], viewer: Rows.viewer, state: state,
            baseline: [], since: fixFrom)
        #expect(Set(open.older.map(\.id.text)) == Set(ids) && open.questions.isEmpty)
        #expect(items(try pr(replyAt: fixFrom), state) == ids.sorted())
        #expect(items(try pr(replyAt: Rows.at(-60)), state) == ids.sorted())
    }

    // A round takes at most 30 items, the oldest first by the time of their first comment.
    @Test func atMost30OldestFirst() throws {
        let threads = try (0..<35).reversed().map {
            try Rows.thread("PRRT_\($0)", by: member, at: Rows.at(Double(-100 + $0)))
        }
        let pr = try full(threads: threads)
        let chosen = items(pr)
        #expect(chosen == (0..<30).map { "PRRT_\($0)" })
        let wanted = WorkRule.wanted(
            pr, PRState(), fixFrom: fixFrom, viewer: Rows.viewer, trigger: .newWork,
            autoFix: true)
        #expect(wanted.count == 35)
        #expect(wanted.first?.since == Rows.at(-100))
    }

    // A PR from a fork has no work, also after a click, and a poll starts no round for it.
    @Test func aForkHasNoWork() throws {
        let thread = try Rows.thread("PRRT_1", by: member, at: Rows.at(-60))
        let pr = try full(threads: [thread], fork: true)
        #expect(items(pr).isEmpty && items(pr, trigger: .handleNow).isEmpty)
        let polled = try Rows.pull(
            "Owner-A/Repo-A#7", author: Rows.viewer, threads: [thread], fork: true)
        #expect(!WorkRule.startsRound(polled, PRState(), fixFrom: fixFrom, viewer: Rows.viewer))
        let own = try Rows.pull("Owner-A/Repo-A#7", author: Rows.viewer, threads: [thread])
        #expect(WorkRule.startsRound(own, PRState(), fixFrom: fixFrom, viewer: Rows.viewer))
    }

    // With the automatic rounds off, a round takes only the items of its click or of an answer:
    // new work waits, an answered question goes, and Handle now takes all the work.
    @Test func withTheGateClosedOnlyTheClickedItemsGo() throws {
        var state = PRState()
        state.questions[try Rows.node("PRRT_q")] = Question(
            text: "Keep the old name?", place: "src/a.swift line 4", at: Rows.at(-30),
            answer: "Yes", seenUntil: Rows.at(-90))
        let pr = try full(
            threads: [
                try Rows.thread("PRRT_q", by: member, at: Rows.at(-90)),
                try Rows.thread("PRRT_new", by: member, at: Rows.at(-60)),
            ])
        #expect(items(pr, state, trigger: .answer, autoFix: false) == ["PRRT_q"])
        #expect(items(pr, state, trigger: .newWork, autoFix: false) == ["PRRT_q"])
        #expect(items(pr, state, trigger: .handleNow, autoFix: false) == ["PRRT_q", "PRRT_new"])
        #expect(items(pr, state, autoFix: true) == ["PRRT_q", "PRRT_new"])
    }

    // A poll starts a round for a cut thread list that changed after the last full read, which
    // can hold work that the poll does not show.
    @Test func aCutThreadListAfterTheLastReadStartsARound() throws {
        let pr = try Rows.pull(
            "Owner-A/Repo-A#7", author: Rows.viewer, updatedAt: Rows.at(-30), cutThreads: true)
        var state = PRState()
        #expect(WorkRule.startsRound(pr, state, fixFrom: fixFrom, viewer: Rows.viewer))
        state.checkedAt = Rows.at(-30)
        #expect(!WorkRule.startsRound(pr, state, fixFrom: fixFrom, viewer: Rows.viewer))
    }
}
