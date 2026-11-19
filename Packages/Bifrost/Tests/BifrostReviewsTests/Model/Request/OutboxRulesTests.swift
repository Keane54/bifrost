import BifrostFoundation
import Foundation
import Testing

@testable import BifrostReviews

@Suite("the rules of the outbox", .timeLimit(.minutes(1)))
struct OutboxRulesTests {
    private static func full(_ head: CommitID) throws -> FullPR {
        let member = Rows.person("user-b")
        return FullPR(
            key: try ReviewData.pr(), author: Rows.viewer, headSHA: head,
            threads: [
                FullThread(
                    thread: try Rows.thread("PRRT_1", by: member), isOutdated: false, diffHunk: "",
                    viewerCanReply: true),
                FullThread(
                    thread: try Rows.thread("PRRT_2", by: member), isOutdated: false, diffHunk: "",
                    viewerCanReply: true),
            ],
            comments: [try Rows.comment("IC_1", by: member, body: "Can @user-c look?\nLine 2.")])
    }

    // The plan: the fix commit and its push, then for each item in the order of the round its
    // reply and resolve (a thread) or its PR comment with the quote (a top-level comment), then
    // the review requests. No action, Needs you and a deleted item get no write.
    @Test func thePlanHasTheFixThenEachItemThenTheReviewRequests() throws {
        let head = try ReviewData.commit()
        let ids = try ["PRRT_1", "PRRT_2", "IC_1", "PRRT_9", "PRRT_8"].map(ReviewData.node)
        let outcome = RequestOutcome(
            items: [
                ItemResult(id: ids[2], outcome: .noFix(reply: "It stays.")),
                ItemResult(id: ids[0], outcome: .fixed(by: nil)),
                ItemResult(id: ids[1], outcome: .noAction),
                ItemResult(id: ids[3], outcome: .fixed(by: nil)),
                ItemResult(id: ids[4], outcome: .needsYou(question: "Why?")),
            ],
            commit: CommitPlan(message: "fix: it", paths: ["src/a.swift"]), checks: .passed)
        let outbox = OutboxRules.plan(
            outcome, order: ids, full: try Self.full(head), seen: [:], head: head,
            mergeBase: head, startedAt: Rows.now, signed: true)
        #expect(
            outbox.posts.map(\.id) == [
                "commit", "push", "reply:PRRT_1", "resolve:PRRT_1", "comment:IC_1", "rerequest",
            ])
        #expect(outbox.posts.allSatisfy { $0.state == .todo })
        #expect(outbox.posts[1].write == .push(commit: nil, signed: true))
        #expect(
            outbox.posts[4].write
                == .comment(
                    item: ids[2], quote: "> Can @\u{200B}user-c look?\n> Line 2.",
                    text: "It stays.", by: nil, comment: nil))
    }

    // A "Fixed by" text waits for the push: it names the fix commit, or the commit that GitHub
    // made for a signed fix. A fix that did not go drops its commit, its push, its "Fixed by"
    // replies and their resolves; the other writes stay.
    @Test func aFixThatDidNotGoDropsItsReplies() throws {
        let (head, fix, made) = (
            try ReviewData.commit(), try ReviewData.commit(ReviewData.oldHex),
            try ReviewData.commit(ReviewData.baseHex)
        )
        let (one, two) = (try ReviewData.node("PRRT_1"), try ReviewData.node("PRRT_2"))
        var outbox = Outbox(
            headSHA: head, mergeBase: head, startedAt: Rows.now, seen: [:],
            posts: [
                OutboxPost(
                    id: "commit", state: .done,
                    write: .commit(paths: ["a"], message: "m", commit: fix)),
                OutboxPost(id: "push", state: .todo, write: .push(commit: nil, signed: false)),
                try Posts.reply("PRRT_1", nil), try Posts.resolve("PRRT_1"),
                try Posts.reply("PRRT_2", "No."), try Posts.resolve("PRRT_2"),
            ])
        #expect(OutboxRules.body(of: outbox.posts[2], in: outbox) == nil)
        outbox.posts[1].state = .done
        #expect(OutboxRules.body(of: outbox.posts[2], in: outbox) == "Fixed by \(fix.short)")
        outbox.posts[1].write = .push(commit: made, signed: true)
        #expect(OutboxRules.body(of: outbox.posts[2], in: outbox) == "Fixed by \(made.short)")
        outbox.posts[1].state = .sending
        OutboxRules.dropFix(&outbox)
        #expect(
            outbox.posts.map(\.state) == [.dropped, .dropped, .dropped, .dropped, .todo, .todo])
        #expect(OutboxRules.counts(outbox) == (0, 2))
        #expect(OutboxRules.openItems(outbox) == [one, two])
    }

    // A sent reply is the comment of the viewer with the same text, made at most five minutes
    // before the start of the outbox.
    @Test func aSentReplyIsFoundByItsTextAndTime() throws {
        let viewer = Rows.person(Rows.viewer)
        let start = Rows.at(-10)
        let comments = [
            try Rows.comment("C_OLD", by: viewer, at: Rows.at(-20), body: "We keep it."),
            try Rows.comment(
                "C_OTHER", by: Rows.person("user-b"), at: Rows.at(-9), body: "We keep it."),
            try Rows.comment("C_NEW", by: viewer, at: Rows.at(-14), body: "We keep it.\r\n"),
        ]
        let found = OutboxRules.sentComment(
            "We keep it.", in: comments, viewer: Rows.viewer.uppercased(), since: start)
        #expect(found?.id == (try ReviewData.node("C_NEW")))
    }

    // A refusal of GitHub drops the outbox, because it would come again in each run, but not a
    // refusal for the rate limit. A failure of the network or of the login keeps the outbox.
    @Test func onlyARefusalThatComesAgainDropsTheOutbox() {
        #expect(OutboxRules.lasts(.refused("Could not resolve to a User")))
        #expect(OutboxRules.lasts(.refused("")))
        #expect(!OutboxRules.lasts(.refused("You have exceeded a secondary rate limit")))
        #expect(!OutboxRules.lasts(.refused("API rate limit exceeded")))
        #expect(!OutboxRules.lasts(.refused("was submitted too quickly")))
        let kept: [GitHubError] = [
            .unknownOutcome("connection reset"), .timedOut, .badAnswer, .notLoggedIn,
            .notInstalled,
        ]
        for error in kept { #expect(!OutboxRules.lasts(error), "\(error)") }
    }

    // The end of the writes: an item whose writes all went is handled; an item with a dropped
    // write (a resolve that a newer trusted comment dropped) and no write that waits is held;
    // an item with a write that waits stays in the outbox. The open commit keeps the worktree.
    @Test func theEndHandlesTheDoneItemsAndHoldsTheDroppedOnes() throws {
        let head = try ReviewData.commit()
        let ids = try ["PRRT_1", "PRRT_2", "PRRT_3"].map(ReviewData.node)
        func reply(_ index: Int, _ state: PostState) -> OutboxPost {
            OutboxPost(
                id: "reply:\(ids[index].text)", state: state,
                write: .reply(item: ids[index], text: "Ok.", by: nil, comment: nil))
        }
        func resolve(_ index: Int, _ state: PostState) -> OutboxPost {
            OutboxPost(
                id: "resolve:\(ids[index].text)", state: state, write: .resolve(item: ids[index]))
        }
        let outbox = Outbox(
            headSHA: head, mergeBase: head, startedAt: Rows.at(-10), seen: [ids[0]: Rows.at(-60)],
            posts: [
                reply(0, .done), resolve(0, .done), reply(1, .done), resolve(1, .dropped),
                reply(2, .done), resolve(2, .todo),
            ])
        var state = PRState()
        let handled = OutboxRules.settle(&state, outbox, now: Rows.now)
        #expect(handled == [ids[0]])
        #expect(state.handled[ids[0]] == Handled(at: Rows.now, lastReplyAt: Rows.at(-60)))
        #expect(state.held == [ids[1]])
        #expect(!OutboxRules.commitOpen(outbox))
        var committing = outbox
        committing.posts.insert(
            OutboxPost(
                id: OutboxRules.commitID, state: .sending,
                write: .commit(paths: ["a.txt"], message: "fix", commit: nil)), at: 0)
        #expect(OutboxRules.commitOpen(committing))
    }
}
