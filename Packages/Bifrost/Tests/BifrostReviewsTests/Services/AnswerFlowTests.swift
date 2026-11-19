// The Answer panel (docs/behaviour/reviews.md, "The Answer panel"): the answers go to the real
// request rounds (RequestRounds.answerQuestions) of a Reviews store in a temporary folder. The
// queue of the rounds holds each job, so no session starts and no git or GitHub call runs.
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@MainActor
private final class AnswerFixture {
    let repos: RepoFixture
    let deps = FakeActionDeps()
    let store: ReviewsStore
    let rounds: ReviewRounds
    let pr: PRKey
    let first: NodeID
    let second: NodeID

    // Two open questions of Claude on PR 7 of the user, the first one older; the automatic
    // rounds are off.
    init() async throws {
        repos = try RepoFixture()
        store = try await ReviewsStore.open(layout: repos.layout, log: Recorder<StoreEvent>())
        let setup = RepoSetup(
            repos: repos.store, store: store, ptys: nil,
            home: URL(filePath: repos.root, directoryHint: .isDirectory), notify: { _ in },
            now: { Rows.now })
        let sessions = PRSessions(
            store: store, registry: deps.registry, actions: deps.makeActions(),
            claude: deps.claudeRunner(), clock: deps.clock, now: { Rows.now }, testPrefix: true)
        var config = ReviewsConfig()
        config.autoFix = false
        rounds = ReviewRounds(
            store: store, github: GitHubClient(access: FakeGitHub()), repos: repos.store,
            setup: setup, sessions: sessions,
            skills: URL(filePath: repos.root + "/skills", directoryHint: .isDirectory),
            userHome: URL(filePath: repos.root, directoryHint: .isDirectory), config: config,
            now: { Rows.now })
        // Each job waits in the queue.
        rounds.queue.isReady = { _ in false }
        pr = try ReviewData.pr()
        first = try ReviewData.node("PRRT_1")
        second = try ReviewData.node("PRRT_2")
        let (pr, first, second) = (pr, first, second)
        await store.update { state in
            var prState = PRState()
            prState.questions[second] = Question(
                text: "Keep the old name?", place: "src/a.swift line 20", author: "user-b",
                body: "Rename it.", kind: .thread, at: Rows.at(-30), seenUntil: Rows.at(-40))
            prState.questions[first] = Question(
                text: "Which limit?", place: "user-b", author: "user-b", body: "Too low.",
                kind: .comment, at: Rows.at(-60), seenUntil: Rows.at(-70))
            prState.held = [first]
            state.prs[pr] = prState
        }
    }

    func flow() -> AnswerFlow {
        let (rounds, pr) = (rounds, pr)
        return AnswerFlow(pr: pr, store: store) { answers in
            await rounds.answerQuestions(pr, answers)
        }
    }

    var requestEntries: [QueueEntry] {
        store.state.queue.filter { $0.pr == pr && $0.kind == .request }
    }

    func end() async {
        rounds.stop()
        await rounds.waitForEnd()
        await store.close().value
        repos.folder.remove()
    }
}

@MainActor
@Suite("the Answer panel flow", .testTimeLimit)
struct AnswerFlowTests {
    // The panel lists the open questions oldest first, with the line over the quote. Send waits
    // for an answer or the check on each question. The answers then start one request round,
    // with the answer texts in the state for its input, and the items leave the held items.
    @Test func theAnswersStartOneRound() async throws {
        let f = try await AnswerFixture()
        let flow = f.flow()
        #expect(flow.questions.map(\.id) == [f.first, f.second])
        #expect(
            flow.questions.map(\.header)
                == ["user-b on the PR", "user-b on src/a.swift line 20"])
        #expect(!flow.canSubmit)
        flow.answer(f.first, " Use 50. ")
        #expect(!flow.canSubmit)
        flow.answer(f.second, "   ")
        #expect(!flow.canSubmit)
        flow.answer(f.second, "Yes, keep it.")
        #expect(flow.canSubmit)
        #expect(await flow.submit())
        #expect(f.requestEntries.count == 1)
        #expect(f.rounds.queue.waiting == [f.pr])
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.questions[f.first]?.answer == "Use 50.")
        #expect(state.questions[f.second]?.answer == "Yes, keep it.")
        #expect(state.held.isEmpty)
        // The questions are answered, so the panel has none left, and a second send does nothing.
        #expect(flow.questions.isEmpty && !flow.canSubmit)
        #expect(await flow.submit() == false)
        #expect(f.requestEntries.count == 1)
        await f.end()
    }

    // "I'll handle this one myself" makes the item handled, with the time of the question as its
    // reply time, and starts no round. A text over the limit is cut.
    @Test func handleMyselfMarksTheItemHandledWithNoRound() async throws {
        let f = try await AnswerFixture()
        let flow = f.flow()
        flow.answer(f.first, String(repeating: "a", count: Question.maxAnswer + 5))
        #expect(flow.answers[f.first]?.count == Question.maxAnswer)
        flow.handleMyself(f.first)
        flow.handleMyself(f.second)
        flow.handleMyself(f.second, false)
        #expect(!flow.canSubmit)
        flow.handleMyself(f.second)
        #expect(await flow.submit())
        let state = try #require(f.store.state.prs[f.pr])
        #expect(state.questions.isEmpty)
        #expect(state.handled[f.first]?.lastReplyAt == Rows.at(-70))
        #expect(state.handled[f.second]?.lastReplyAt == Rows.at(-40))
        #expect(f.requestEntries.isEmpty && f.rounds.queue.waiting.isEmpty)
        await f.end()
    }
}
