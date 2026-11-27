// The writes of a request round (docs/behaviour/reviews.md, "The push and the writes"): a Reviews
// store in a temporary folder and the fake GitHub, with outboxes of replies, resolves and review
// requests. No test here makes a commit or a push.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@MainActor
@Suite("the writes of a request round", .serialized, .testTimeLimit)
struct RoundWritesTests {
    // A member answered thread 1 after the round read it: the reply goes, but the thread stays
    // open and its item waits in held, as at a drop of the outbox, so the next round handles the
    // new comment. Thread 2 gets its reply and its resolve. Each reply breaks the mentions, and
    // the writes wait one second between two writes.
    @Test func aThreadThatATrustedAuthorAnsweredIsNotResolved() async throws {
        let newer = WritesData.Comment(
            id: "PRRC_N", login: "user-c", body: "And this too.", at: Rows.at(-30))
        let clock = GapClock()
        let f = try await WritesFixture(clock: clock) {
            WritesData.github(
                head: $0,
                threads: [
                    WritesData.thread("PRRT_1", replies: [newer]), WritesData.thread("PRRT_2"),
                ])
        }
        f.github.queued["addPullRequestReviewThreadReply"] = [
            .success(WritesData.replied("PRRC_A")), .success(WritesData.replied("PRRC_B")),
        ]
        let (first, second) = (try ReviewData.node("PRRT_1"), try ReviewData.node("PRRT_2"))
        let seen = [first: Rows.at(-120), second: Rows.at(-120)]
        await f.save(
            f.outbox(
                [
                    try Posts.reply("PRRT_1", "Thanks @user-b, we keep it."),
                    try Posts.resolve("PRRT_1"), try Posts.reply("PRRT_2", "No change needed."),
                    try Posts.resolve("PRRT_2"), Posts.rerequest(),
                ], seen: seen))
        try await f.writes.run(try #require(f.state?.outbox), for: f.pr)
        #expect(
            f.written == [
                .replyToThread(thread: first, body: "Thanks @\u{200B}user-b, we keep it."),
                .replyToThread(thread: second, body: "No change needed."),
                .resolveThread(second),
            ])
        #expect(clock.spans == [RoundWrites.postGap, RoundWrites.postGap])
        let state = try #require(f.state)
        #expect(state.outbox == nil && state.held == [first])
        #expect(state.handled[second] == Handled(at: Rows.now, lastReplyAt: Rows.at(-120)))
        #expect(state.handled[first] == nil)
        let posted = f.store.state.posted
        #expect(posted.map(\.id) == [try ReviewData.node("PRRC_A"), try ReviewData.node("PRRC_B")])
        #expect(posted.first?.body == "Thanks @\u{200B}user-b, we keep it.")
        await f.end()
    }

    // A reviewer whose latest review requests changes and whose threads are all resolved gets a
    // new review request, once for each head commit. A bot, Copilot, a reviewer with an open
    // thread and a reviewer who approved get none.
    @Test func aReviewerIsAskedOncePerHeadAndNeverABot() async throws {
        let resolved = WritesData.thread("PRRT_1", resolved: true)
        var open = WritesData.thread("PRRT_2")
        open.comments[0].login = "user-c"
        let f = try await WritesFixture {
            WritesData.github(
                head: $0, threads: [resolved, open],
                decisions: [
                    .init(login: "user-b"), .init(login: "user-c"),
                    .init(login: "ci-bot", typename: "Bot"),
                    .init(login: Authors.copilotLogin, typename: "Bot"),
                    .init(login: "user-d", state: "APPROVED"),
                ])
        }
        await f.save(f.outbox([Posts.rerequest()]))
        try await f.writes.run(try #require(f.state?.outbox), for: f.pr)
        let node = try #require(NodeID(WritesData.prNode))
        let userB = try ReviewData.node("U_user-b")
        #expect(f.written == [.requestReviews(pr: node, users: [userB])])
        #expect(f.state?.askedReviewers == ["user-b": f.head])
        // A later round on the same head asks nobody again.
        await f.save(f.outbox([Posts.rerequest()]))
        try await f.writes.run(try #require(f.state?.outbox), for: f.pr)
        #expect(f.written.count == 1)
        await f.end()
    }

    // Bifrost quits during the gap after the first reply: the next start sends only the writes
    // that were not done, and the first reply goes once in all.
    @Test func aQuitMidRoundResumesOnlyTheUnsentWrites() async throws {
        let manual = ManualClock()
        let f = try await WritesFixture(clock: manual) {
            WritesData.github(
                head: $0, threads: [WritesData.thread("PRRT_1"), WritesData.thread("PRRT_2")])
        }
        let (first, second) = (try ReviewData.node("PRRT_1"), try ReviewData.node("PRRT_2"))
        let seen = [first: Rows.at(-120), second: Rows.at(-120)]
        await f.save(
            f.outbox(
                [
                    try Posts.reply("PRRT_1", "We keep it."), try Posts.resolve("PRRT_1"),
                    try Posts.reply("PRRT_2", "No change needed."), try Posts.resolve("PRRT_2"),
                    Posts.rerequest(),
                ], seen: seen),
            posting: true, items: seen)
        let quit = Task { await f.writes.resume(f.pr) }
        await waitUntil { manual.sleeperCount == 1 }
        quit.cancel()
        await ended(quit)
        #expect(f.written == [.replyToThread(thread: first, body: "We keep it.")])
        #expect(f.state?.round?.phase == .posting)
        #expect(f.state?.outbox?.posts.map(\.state) == [.done, .todo, .todo, .todo, .todo])

        // The next start, on a clock that does not wait.
        let restarted = RoundWrites(
            store: f.store, github: GitHubClient(access: f.github), repos: f.repos,
            clock: GapClock(), now: { Rows.now }, viewer: { WritesData.viewer },
            eventLine: { _ in })
        await restarted.resume(f.pr)
        #expect(
            f.written == [
                .replyToThread(thread: first, body: "We keep it."), .resolveThread(first),
                .replyToThread(thread: second, body: "No change needed."), .resolveThread(second),
            ])
        let state = try #require(f.state)
        #expect(state.round == nil && state.lastError == nil && state.outbox == nil)
        #expect(state.handled[first] != nil && state.handled[second] != nil)
        await f.end()
    }

    // A reply that a quit cut off is on GitHub already (GitHub changed its line ends and dropped
    // the mention break): it is not sent again, and its thread gets the resolve. A write that
    // GitHub may have made stops the writes and is never sent again by itself; the reason of gh
    // goes to the Event log with each token hidden.
    @Test func aReplyFoundOnGitHubIsNotSentAgain() async throws {
        let sent = WritesData.Comment(
            id: "PRRC_S", login: WritesData.viewer, body: "Thanks @user-b,\r\nwe keep it.",
            at: Rows.at(-9))
        let f = try await WritesFixture {
            WritesData.github(head: $0, threads: [WritesData.thread("PRRT_1", replies: [sent])])
        }
        let item = try ReviewData.node("PRRT_1")
        await f.save(
            f.outbox(
                [
                    try Posts.reply("PRRT_1", "Thanks @user-b,\nwe keep it.", .sending),
                    try Posts.resolve("PRRT_1"), Posts.rerequest(),
                ], seen: [item: Rows.at(-120)]))
        try await f.writes.run(try #require(f.state?.outbox), for: f.pr)
        #expect(f.written == [.resolveThread(item)])
        #expect(f.store.state.posted.map(\.id) == [try ReviewData.node("PRRC_S")])
        #expect(f.state?.handled[item] != nil)

        let g = try await WritesFixture {
            WritesData.github(head: $0, threads: [WritesData.thread("PRRT_1")])
        }
        g.github.answers["addPullRequestReviewThreadReply"] = .failure(
            .unknownOutcome("connection reset, token ghp_abcdefghijklmnopqrstuvwxyz0123"))
        await g.save(
            g.outbox([try Posts.reply("PRRT_1", "We keep it."), try Posts.resolve("PRRT_1")]))
        await #expect(
            throws: RoundFailure.writesStopped(
                done: 0, total: 2,
                .unknownOutcome("connection reset, token ghp_abcdefghijklmnopqrstuvwxyz0123"))
        ) {
            try await g.writes.run(try #require(g.state?.outbox), for: g.pr)
        }
        #expect(g.written.count == 1)
        #expect(g.state?.outbox?.posts.map(\.state) == [.sending, .todo])
        #expect(g.lines.values.contains { $0.contains("***") && !$0.contains("ghp_") })
        await f.end()
        await g.end()
    }

    // GitHub refuses a reply, and it would refuse it again in each run (a locked thread, for
    // example): the outbox goes, so it never blocks the PR, and the item waits in held. A refusal
    // for the rate limit keeps the outbox for Try again.
    @Test func aRefusalThatComesAgainDropsTheOutboxAndARateLimitKeepsIt() async throws {
        let f = try await WritesFixture {
            WritesData.github(head: $0, threads: [WritesData.thread("PRRT_1")])
        }
        let item = try ReviewData.node("PRRT_1")
        f.github.answers["addPullRequestReviewThreadReply"] = .failure(
            .refused("Thread is locked"))
        let posts = [try Posts.reply("PRRT_1", "We keep it."), try Posts.resolve("PRRT_1")]
        await f.save(f.outbox(posts, seen: [item: Rows.at(-120)]))
        await #expect(
            throws: RoundFailure.writesRefused(done: 0, total: 2, .refused("Thread is locked"))
        ) {
            try await f.writes.run(try #require(f.state?.outbox), for: f.pr)
        }
        #expect(f.written.count == 1)
        #expect(f.state?.outbox == nil && f.state?.held == [item])

        f.github.answers["addPullRequestReviewThreadReply"] = .failure(
            .refused("API rate limit exceeded for user"))
        await f.save(f.outbox(posts, seen: [item: Rows.at(-120)]))
        await #expect(
            throws: RoundFailure.writesStopped(
                done: 0, total: 2, .refused("API rate limit exceeded for user"))
        ) {
            try await f.writes.run(try #require(f.state?.outbox), for: f.pr)
        }
        #expect(f.state?.outbox?.posts.map(\.state) == [.todo, .todo])
        await f.end()
    }

    // The PR merges while the writes run: the read of its state before the next write stops the
    // rest, the outbox goes, the item whose writes went is handled, and the other item waits.
    @Test func aPRThatMergesDuringTheWritesStopsTheRest() async throws {
        let f = try await WritesFixture {
            WritesData.github(
                head: $0, threads: [WritesData.thread("PRRT_1"), WritesData.thread("PRRT_2")])
        }
        f.github.queued[RequestQueries.stateName] = [
            .success(WritesData.lifecycle()), .success(WritesData.lifecycle("MERGED")),
        ]
        let (first, second) = (try ReviewData.node("PRRT_1"), try ReviewData.node("PRRT_2"))
        let seen = [first: Rows.at(-120), second: Rows.at(-120)]
        await f.save(
            f.outbox(
                [
                    try Posts.reply("PRRT_1", "We keep it."), try Posts.resolve("PRRT_1"),
                    try Posts.reply("PRRT_2", "No change needed."), try Posts.resolve("PRRT_2"),
                ], seen: seen))
        await #expect(throws: RoundFailure.prClosed) {
            try await f.writes.run(try #require(f.state?.outbox), for: f.pr)
        }
        #expect(
            f.written == [
                .replyToThread(thread: first, body: "We keep it."), .resolveThread(first),
            ])
        let state = try #require(f.state)
        #expect(state.outbox == nil && state.handled[first] != nil && state.held == [second])
        await f.end()
    }

    // The PR merged before the writes: nothing goes, the outbox goes, and its items wait.
    @Test func aClosedPRStopsTheWrites() async throws {
        let f = try await WritesFixture {
            WritesData.github(head: $0, threads: [WritesData.thread("PRRT_1")], state: "MERGED")
        }
        let item = try ReviewData.node("PRRT_1")
        await f.save(
            f.outbox([try Posts.reply("PRRT_1", "We keep it."), try Posts.resolve("PRRT_1")]))
        await #expect(throws: RoundFailure.prClosed) {
            try await f.writes.run(try #require(f.state?.outbox), for: f.pr)
        }
        #expect(f.written.isEmpty)
        #expect(f.state?.outbox == nil && f.state?.held == [item])
        #expect(
            RoundFailure.prClosed.message(for: .request)
                == "This pull request was closed, so Bifrost stopped posting.")
        await f.end()
    }
}
