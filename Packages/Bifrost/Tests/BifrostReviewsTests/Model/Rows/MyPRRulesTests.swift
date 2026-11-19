import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

// The rules of the My PRs tab (docs/behaviour/reviews.md, "The rows"): the open items, the review
// status, the reviewers and their colours, the Claude state and the order.

private typealias R = Rows

private let member = R.person("user-e")

// The one My PRs row of the PR.
private func row(
    _ pr: PullRequest, _ state: ReviewsState = R.turnedOn(),
    _ config: ReviewsConfig = ReviewsConfig()
) throws -> ReviewRow {
    try #require(R.mine(R.answer(mine: [pr]), state, config).first)
}

// The open items of the PR, with no turn-on marks unless the test gives them.
private func items(
    _ pr: PullRequest, _ state: PRState = PRState(), since: Date? = nil,
    baseline: Set<NodeID> = []
) -> OpenItems {
    OpenItems(
        threads: pr.threads, reviews: pr.reviews, comments: pr.comments, viewer: R.viewer,
        state: state, baseline: baseline, since: since)
}

private func ids(_ list: [OpenItems.Item]) -> [String] {
    list.map(\.id.text)
}

@Suite("the My PRs rows", .testTimeLimit)
struct MyPRRulesTests {
    @Test func copilotCanShowCommentsButNeverApproved() throws {
        let first = try R.review("PRR_c1", by: R.copilot, .commented, at: R.at(-300))
        let later = try R.review("PRR_c2", by: R.copilot, .commented, at: R.at(-100))
        let copilotApproval = try R.review("PRR_c3", by: R.copilot, .approved, at: R.at(-50))
        let thread = try R.thread("PRRT_1", by: R.copilot, review: "PRR_c1")
        let open = try R.pull(
            "owner-a/repo-a#1", reviews: [first, later], decisions: [copilotApproval],
            threads: [thread])
        #expect(try row(open).mineState?.status == .comments)

        // Once the thread of the first Copilot review is resolved, the approval of Copilot does
        // not make the PR approved, and a thread of a later Copilot review does not give
        // Comments: it waits for Handle Copilot comments.
        let laterThread = try R.thread("PRRT_2", by: R.copilot, review: "PRR_c2")
        let resolved = try R.pull(
            "owner-a/repo-a#1", reviews: [first, later], decisions: [copilotApproval],
            threads: [R.thread("PRRT_1", by: R.copilot, resolved: true, review: "PRR_c1"),
                laterThread])
        let shown = try row(resolved)
        #expect(shown.mineState?.status == .pending)
        #expect(shown.notes == ["Copilot: 1 more"])
        #expect(shown.reviewers == [Reviewer(name: "Copilot", tone: .dim)])
    }

    @Test func changesRequestedWinsAndOnlyThreadsGiveComments() throws {
        let thread = try R.thread("PRRT_1", by: member)
        let changes = try R.review("PRR_1", by: member, .changesRequested, at: R.at(-100))
        let approval = try R.review("PRR_2", by: member, .approved, at: R.at(-50))
        let status = { (pr: PullRequest) in try row(pr).mineState?.status }

        #expect(try status(R.pull("owner-a/repo-a#1", decisions: [changes], threads: [thread]))
            == .changesRequested)
        // The latest decision of a reviewer counts.
        #expect(try status(R.pull("owner-a/repo-a#1", decisions: [changes, approval]))
            == .approved)
        #expect(try status(R.pull("owner-a/repo-a#1", decisions: [approval], threads: [thread]))
            == .comments)
        // A review body or a top-level comment stays work, but only a thread gives Comments, so
        // a "Thanks" does not hide an approval.
        let body = try R.review("PRR_3", by: member, .commented, at: R.at(-40), body: "Nice.")
        #expect(try status(
            R.pull(
                "owner-a/repo-a#1", reviews: [body], decisions: [approval],
                comments: [R.comment("IC_1", by: member, body: "Thanks!")])) == .approved)
        // The user's own decision and a bot's decision are not reviewer decisions.
        let own = try R.review("PRR_4", by: R.person("Viewer-A"), .changesRequested)
        let bot = try R.review(
            "PRR_5", by: Author(login: "ci-bot", isBot: true, association: .none),
            .changesRequested)
        #expect(try status(R.pull("owner-a/repo-a#1", decisions: [own, bot])) == .pending)
        #expect(try status(R.pull("owner-a/repo-a#1")) == .pending)
    }

    @Test func onlyTrustedThreadsAndCommentsAreOpenItems() throws {
        let outsider = R.person("user-x", .contributor)
        let bot = Author(login: "ci-bot", isBot: true, association: .member)
        let pr = try R.pull(
            "owner-a/repo-a#1",
            reviews: [
                R.review("PRR_1", by: member, .changesRequested, body: "Split this."),
                R.review("PRR_2", by: member, .approved, body: "Good."),
                R.review("PRR_3", by: member, .commented, body: "  \n "),
                R.review("PRR_4", by: outsider, .commented, body: "Change it."),
            ],
            threads: [
                R.thread("PRRT_1", by: member),
                R.thread("PRRT_2", by: outsider),
                R.thread("PRRT_3", by: bot),
                R.thread("PRRT_4", by: R.person("viewer-a")),
                R.thread("PRRT_5", by: member, resolved: true),
            ],
            comments: [R.comment("IC_1", by: member), R.comment("IC_2", by: outsider)])
        let open = items(pr)
        #expect(ids(open.work) == ["PRRT_1", "PRR_1", "IC_1"])
        #expect(open.work.map(\.kind) == [.thread, .reviewBody, .comment])
        #expect(open.older.isEmpty && open.laterCopilot.isEmpty)
    }

    @Test func itemsFromBeforeTheTurnOnWaitAsOlder() throws {
        let pr = try R.pull(
            "owner-a/repo-a#1",
            threads: [
                R.thread("PRRT_1", by: member, at: R.at(-200)),
                R.thread("PRRT_2", by: member, at: R.at(-10)),
                R.thread("PRRT_3", by: member, at: R.at(-10)),
            ])
        let since = R.at(-100)
        let open = items(pr, since: since, baseline: [try R.node("PRRT_3")])
        #expect(ids(open.older) == ["PRRT_1", "PRRT_3"] && ids(open.work) == ["PRRT_2"])
        // Handle now makes them work.
        var handle = PRState()
        handle.handleOlder = true
        #expect(ids(items(pr, handle, since: since).work) == ["PRRT_1", "PRRT_2", "PRRT_3"])
    }

    @Test func aHandledItemIsOpenAgainOnlyAfterANewerTrustedComment() throws {
        var state = PRState()
        state.handled[try R.node("PRRT_1")] = Handled(at: R.at(-50), lastReplyAt: R.at(-60))
        state.handled[try R.node("PRRT_2")] = Handled(at: R.at(-50), lastReplyAt: R.at(-60))
        state.handled[try R.node("PRRT_3")] = Handled(at: R.at(-50), lastReplyAt: nil)
        let pr = try R.pull(
            "owner-a/repo-a#1",
            threads: [
                R.thread("PRRT_1", by: member, at: R.at(-90)),
                R.thread(
                    "PRRT_2", by: member, at: R.at(-90),
                    replies: [R.comment("PRRC_2", by: member, at: R.at(-30))]),
                R.thread(
                    "PRRT_3", by: member, at: R.at(-90),
                    replies: [R.comment("PRRC_3", by: member, at: R.at(-30))]),
            ])
        let open = items(pr, state)
        #expect(ids(open.work) == ["PRRT_2"] && open.older.isEmpty)
        // A handled thread that is still open does not give Comments.
        var both = R.turnedOn()
        both.prs[pr.key] = state
        let quiet = try R.pull(
            "owner-a/repo-a#1", threads: [R.thread("PRRT_1", by: member, at: R.at(-90))])
        #expect(try row(quiet, both).mineState?.status == .pending)
    }

    @Test func questionsHeldItemsAndTheOutboxKeepTheirLists() throws {
        let thread = { (id: String) in try R.thread(id, by: member, at: R.at(-90)) }
        var state = PRState()
        state.questions[try R.node("PRRT_1")] = Question(
            text: "Which name?", place: "src/a.swift line 4", at: R.at(-40),
            seenUntil: R.at(-40))
        state.questions[try R.node("PRRT_2")] = Question(
            text: "Which name?", place: "src/a.swift line 4", at: R.at(-40), answer: "Use b.",
            seenUntil: R.at(-40))
        state.held = [try R.node("PRRT_3")]
        state.outbox = Outbox(
            headSHA: try R.commit("a"), mergeBase: try R.commit("b"), startedAt: R.at(-20),
            seen: [:],
            posts: [
                OutboxPost(id: "1", state: .todo, write: .resolve(item: try R.node("PRRT_4")))
            ])
        let pr = try R.pull(
            "owner-a/repo-a#1",
            threads: [thread("PRRT_1"), thread("PRRT_2"), thread("PRRT_3"), thread("PRRT_4")])
        let open = items(pr, state)
        #expect(ids(open.questions) == ["PRRT_1"] && ids(open.work) == ["PRRT_2"])
        #expect(ids(open.older) == ["PRRT_3"] && ids(open.posting) == ["PRRT_4"])

        // A trusted comment after the read of the failed round opens a held item again.
        state.checkedAt = R.at(-50)
        let reopened = try R.pull(
            "owner-a/repo-a#1",
            threads: [
                R.thread(
                    "PRRT_3", by: member, at: R.at(-90),
                    replies: [R.comment("PRRC_3", by: member, at: R.at(-30))])
            ])
        #expect(ids(items(reopened, state).work) == ["PRRT_3"])
        // An item in the outbox still gives Comments.
        var both = R.turnedOn()
        both.prs[pr.key] = state
        let posting = try R.pull("owner-a/repo-a#1", threads: [thread("PRRT_4")])
        #expect(try row(posting, both).mineState?.status == .comments)
    }

    @Test func handleCopilotCommentsMakesTheLaterCopilotThreadsWork() throws {
        var state = PRState()
        state.handleCopilot = true
        let pr = try R.pull(
            "owner-a/repo-a#1",
            reviews: [
                R.review("PRR_c1", by: R.copilot, .commented, at: R.at(-300)),
                R.review("PRR_c2", by: R.copilot, .commented, at: R.at(-100)),
            ],
            threads: [R.thread("PRRT_2", by: R.copilot, review: "PRR_c2")])
        #expect(ids(items(pr, state).work) == ["PRRT_2"])
        // The first Copilot review that Bifrost saved wins over an earlier one that shows later.
        var saved = PRState()
        saved.firstCopilotReview = try R.node("PRR_c2")
        #expect(ids(items(pr, saved).work) == ["PRRT_2"])
        #expect(ids(items(pr).laterCopilot) == ["PRRT_2"])
    }

    @Test func theReviewerColours() throws {
        let pr = try R.pull(
            "owner-a/repo-a#1", reviewers: ["user-r"],
            reviews: [
                R.review("PRR_1", by: R.person("user-a"), .approved, at: R.at(-100)),
                // A later comment does not change an approval.
                R.review("PRR_2", by: R.person("user-a"), .commented, at: R.at(-50)),
                R.review("PRR_3", by: R.person("user-c"), .commented),
                R.review("PRR_4", by: R.person("user-d"), .changesRequested),
                R.review("PRR_5", by: R.person("user-g"), .commented, at: R.at(-100)),
                R.review("PRR_6", by: R.copilot, .commented),
                R.review("PRR_7", by: R.person("viewer-a"), .commented),
            ],
            decisions: [
                // A dismissed latest opinion is grey, even after a comment.
                R.review("PRR_8", by: R.person("user-g"), .dismissed, at: R.at(-90)),
                // A reviewer with only a decision shows too.
                R.review("PRR_9", by: R.person("user-h"), .approved),
            ])
        #expect(
            try row(pr).reviewers == [
                Reviewer(name: "user-r", tone: .dim), Reviewer(name: "user-a", tone: .green),
                Reviewer(name: "user-c", tone: .amber), Reviewer(name: "user-d", tone: .red),
                Reviewer(name: "user-g", tone: .dim), Reviewer(name: "Copilot", tone: .dim),
                Reviewer(name: "user-h", tone: .green),
            ])
    }

    @Test func theClaudeStateTakesTheFirstRuleThatHolds() throws {
        let key = try R.key("owner-a/repo-a#1")
        let pr = try R.pull(key.text)
        let claude = { (state: ReviewsState, pr: PullRequest) in
            try row(pr, state).mineState?.claude
        }
        var state = R.turnedOn()
        #expect(try claude(state, pr) == .waiting)
        #expect(try claude(state, R.pull(key.text, fork: true)) == .fork)
        state.prs[key, default: PRState()].lastError = "The push failed."
        #expect(try claude(state, R.pull(key.text, fork: true)) == .error("The push failed."))
        for id in ["PRRT_1", "PRRT_2"] {
            let item = try R.node(id)
            state.prs[key]?.questions[item] = Question(
                text: "Which?", place: "src/a.swift line 1", at: R.at(-5), seenUntil: R.at(-5))
        }
        #expect(try claude(state, pr) == .needsYou(2))
        state.queue = [QueueEntry(pr: key, kind: .request, at: R.at(-1))]
        #expect(try claude(state, pr) == .queued)
        state.prs[key]?.round = ActiveRound(
            phase: .running, startedAt: R.at(-1), at: R.at(-1), kind: .request,
            items: [try R.node("PRRT_3"): R.at(-9), try R.node("PRRT_4"): R.at(-9)])
        #expect(try claude(state, pr) == .fixing(2))
    }

    // The writes of a stopped round that wait for Try again (a kept outbox) show on the row, so
    // its menu can drop them. A round that runs or posts keeps its outbox, and the row shows none.
    @Test func aKeptOutboxShowsAsUnsentUpdates() throws {
        let key = try R.key("owner-a/repo-a#1")
        let pr = try R.pull(key.text)
        let head = try #require(CommitID(R.head))
        var state = R.turnedOn()
        #expect(try row(pr, state).unsentUpdates == false)
        state.prs[key, default: PRState()].outbox = Outbox(
            headSHA: head, mergeBase: head, startedAt: R.at(-10), seen: [:],
            posts: [
                OutboxPost(id: "rerequest", state: .todo, write: .rerequest(logins: nil))
            ])
        state.prs[key]?.lastError = "GitHub stopped after 0 of 1 updates."
        #expect(try row(pr, state).unsentUpdates == true)
        state.prs[key]?.round = ActiveRound(
            phase: .posting, startedAt: R.at(-1), at: R.at(-1), kind: .request)
        #expect(try row(pr, state).unsentUpdates == false)
    }

    // A queued request round waits for the clone of its repository while the clone runs, then
    // for the trust of the user while the clone needs it. Another repository changes nothing.
    @Test func aQueuedRoundWaitsForTheCloneAndTheTrustOfItsRepository() throws {
        let key = try R.key("owner-a/repo-a#1")
        let pr = try R.pull(key.text)
        let repo = key.repo
        let other = try #require(RepoName("owner-a/repo-b"))
        var state = R.turnedOn()
        state.queue = [QueueEntry(pr: key, kind: .request, at: R.at(-1))]
        let claude = { (clones: CloneStates) in
            R.mine(R.answer(mine: [pr]), state, clones: clones).first?.mineState?.claude
        }
        #expect(claude(CloneStates(cloning: [repo])) == .cloning)
        #expect(claude(CloneStates(cloning: [repo], needsTrust: [repo])) == .cloning)
        #expect(claude(CloneStates(needsTrust: [repo])) == .trustNeeded)
        #expect(claude(CloneStates(cloning: [other], needsTrust: [other])) == .queued)
        let row = try #require(
            R.mine(R.answer(mine: [pr]), state, clones: CloneStates(needsTrust: [repo])).first)
        #expect(row.status == RowText.claude(.trustNeeded))
        // With no queued round, the clone states change nothing.
        state.queue = []
        #expect(claude(CloneStates(cloning: [repo], needsTrust: [repo])) == .waiting)
    }

    @Test func needsYouComesFirstThenTheStatusGroupsThenTheLastUpdate() throws {
        let keys = try (1...6).map { try R.key("owner-a/repo-a#\($0)") }
        let approval = try R.review("PRR_a", by: member, .approved)
        let changes = try R.review("PRR_c", by: member, .changesRequested)
        var state = R.turnedOn()
        let item = try R.node("PRRT_q")
        state.prs[keys[5], default: PRState()].questions[item] = Question(
            text: "Which?", place: "src/a.swift line 1", at: R.at(-5), seenUntil: R.at(-5))
        let answer = R.answer(mine: [
            try R.pull(keys[0].text, updatedAt: R.at(-50), decisions: [approval]),
            try R.pull(keys[1].text, updatedAt: R.at(-40)),
            try R.pull(
                keys[2].text, updatedAt: R.at(-30), threads: [R.thread("PRRT_1", by: member)]),
            try R.pull(keys[3].text, updatedAt: R.at(-20), decisions: [changes]),
            try R.pull(keys[4].text, updatedAt: R.at(-10)),
            try R.pull(keys[5].text, updatedAt: R.at(-90), decisions: [approval]),
        ])
        let order = [keys[5], keys[3], keys[2], keys[4], keys[1], keys[0]]
        #expect(R.mine(answer, state).map(\.id) == order)
    }

    // Only the consent of the user in this app lets new work go to an automatic round. With no
    // consent (nil), or after the take-over (false), the new work waits for Handle now too.
    @Test func theOlderCountHoldsTheWorkWhileAutomaticFixesAreOff() throws {
        var state = R.turnedOn()
        state.fixFrom = R.at(-100)
        state.autoFixConsent = true
        let pr = try R.pull(
            "owner-a/repo-a#1",
            threads: [
                R.thread("PRRT_1", by: member, at: R.at(-200)),
                R.thread("PRRT_2", by: member, at: R.at(-10)),
            ])
        #expect(try row(pr, state).notes == ["1 older comment"])
        var off = ReviewsConfig()
        off.autoFix = false
        #expect(try row(pr, state, off).notes == ["2 older comments"])
        state.autoFixConsent = false
        #expect(try row(pr, state).notes == ["2 older comments"])
        state.autoFixConsent = nil
        #expect(try row(pr, state).notes == ["2 older comments"])
    }

    // A cut list of My PRs, or an answer with errors, changes no row: the rows come from the PRs
    // of the answer, and only the stored marks make an item handled.
    @Test func aCutAnswerGivesTheSameMyPRsRows() throws {
        var state = R.turnedOn()
        state.fixFrom = R.at(-100)
        let answer = R.answer(mine: [
            try R.pull(
                "owner-a/repo-a#1",
                threads: [
                    R.thread("PRRT_1", by: member, at: R.at(-200)),
                    R.thread("PRRT_2", by: member, at: R.at(-10)),
                ]),
            try R.pull("owner-a/repo-a#2", decisions: [R.review("PRR_1", by: member, .approved)]),
        ])
        var cut = answer
        cut.mineCut = true
        var errors = answer
        errors.errors = ["Something went wrong."]
        let rows = R.mine(answer, state)
        #expect(rows.count == 2)
        #expect(R.mine(cut, state) == rows && R.mine(errors, state) == rows)
    }

    @Test func aPRWithACutListSaysSoOnItsStatus() throws {
        let cut = try row(R.pull("owner-a/repo-a#1", cutThreads: true))
        #expect(cut.review?.tip == "Bifrost read only the newest items of this PR.")
        #expect(try row(R.pull("owner-a/repo-a#1")).review?.tip == nil)
    }
}
