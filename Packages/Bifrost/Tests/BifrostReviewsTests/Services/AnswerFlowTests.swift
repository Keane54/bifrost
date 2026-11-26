// The Answer panel (docs/behaviour/reviews.md, "The Answer panel"): the answers go to the real
// request rounds (RequestRounds.answerQuestions) of a Reviews store in a temporary folder. The
// queue of the rounds holds each job, so no session starts and no git or GitHub call runs.
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostReviews

@MainActor
private final class AnswerFixture {
    let repos: RepoFixture
    let deps = FakeActionDeps()
    let store: ReviewsStore
    let rounds: ReviewRounds
    let config: ReviewsConfig
    let pr: PRKey
    let first: NodeID
    let second: NodeID
    // The PR of the last poll, with a failed job, when the PR has a question about failed CI.
    var polled: PullRequest?

    // Two open questions of Claude on PR 7 of the user, the first one older; the automatic
    // rounds are off. ci: the PR also has a question about failed CI on its head, with the
    // setting on and, when consent is true, its consent.
    init(ci: Bool = false, consent: Bool = true) async throws {
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
        config.fixCI = ci
        self.config = config
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
        if ci {
            polled = try Rows.pull(
                "Owner-A/Repo-A#7", author: Rows.viewer, ci: .failing, failedChecks: 1,
                checks: HeadChecks(
                    checks: [
                        HeadCheck(
                            name: "test", outcome: .failed("FAILURE"),
                            source: .actions(
                                job: try #require(JobID(101)), run: try #require(RunID(9001))))
                    ], onHead: true))
            rounds.answer = { [weak self] in self?.polled.map { Rows.answer(mine: [$0]) } }
        }
        await store.update { state in
            if ci && consent { state.ciConsent = true }
            var prState = PRState()
            if ci {
                prState.ci = CIMark(
                    chain: [CommitID(Rows.head)!],
                    question: CIQuestion(
                        text: "CI still fails. What next?", head: CommitID(Rows.head)!,
                        jobs: ["test"], at: Rows.at(-10), byClaude: true))
            }
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
        return AnswerFlow(
            pr: pr, store: store,
            send: { answers in await rounds.answerQuestions(pr, answers) },
            ciQuestion: { rounds.ciQuestion(of: pr) },
            sendCI: { answer in await rounds.answerCI(pr, answer) })
    }

    var requestEntries: [QueueEntry] {
        store.state.queue.filter { $0.pr == pr && $0.kind == .request }
    }

    // The config of the fixture with "Fix failing CI automatically" on or off.
    func config(fixCI: Bool) -> ReviewsConfig {
        var changed = config
        changed.fixCI = fixCI
        return changed
    }

    // The user pushes a new head, and the poll shows it. question: the CI rounds also ask about
    // the failed jobs of the new head. The result is the new head.
    @discardableResult
    func newHead(question: Bool) async throws -> CommitID {
        let head = try #require(CommitID(String(repeating: "b", count: 40)))
        polled?.headSHA = head.hex
        guard question else { return head }
        let pr = pr
        await store.update { state in
            state.prs[pr]?.ci?.chain = [head]
            state.prs[pr]?.ci?.question = CIQuestion(
                text: "The new head fails too. What next?", head: head, jobs: ["test"],
                at: Rows.at(-5), byClaude: true)
        }
        return head
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

    // A CI question alone needs a text or the check. A blank text is no answer.
    @Test func theCIQuestionNeedsAnAnswerOrTheCheck() async throws {
        let f = try await AnswerFixture(ci: true)
        await f.store.update { $0.prs[f.pr]?.questions = [:] }
        let flow = f.flow()
        #expect(flow.questions.isEmpty && flow.ciQuestion?.question.jobs == ["test"])
        #expect(!flow.canSubmit)
        flow.answerCI("Retry it.")
        #expect(flow.canSubmit)
        flow.answerCI("   ")
        #expect(!flow.canSubmit)
        flow.handleCIMyself()
        #expect(flow.canSubmit && flow.ciHandled)
        flow.handleCIMyself(false)
        flow.answerCI(String(repeating: "a", count: Question.maxAnswer + 5))
        #expect(flow.ciAnswer.count == Question.maxAnswer && flow.canSubmit)
        await f.end()
    }

    // One send gives the comment answers to their round first, then the CI answer to the CI
    // round. A first send that the rounds refuse sends no CI answer, and the result is false.
    @Test func aSendGivesBothAnswersToTheirRounds() async throws {
        let f = try await AnswerFixture(ci: true)
        let log = Recorder<String>()
        let taken = Mutex(true)
        let (store, pr, rounds) = (f.store, f.pr, f.rounds)
        let flow = AnswerFlow(
            pr: pr, store: store,
            send: { answers in
                log.record("comments \(answers.count)")
                return taken.withLock { $0 }
            },
            ciQuestion: { rounds.ciQuestion(of: pr) },
            sendCI: { answer in
                log.record("ci \(answer)")
                return true
            })
        flow.answer(f.first, "Use 50.")
        flow.handleMyself(f.second)
        flow.answerCI(" Retry it. ")
        #expect(await flow.submit())
        #expect(log.values == ["comments 2", "ci text(\"Retry it.\")"])
        taken.withLock { $0 = false }
        flow.handleCIMyself()
        #expect(await flow.submit() == false)
        #expect(log.values == ["comments 2", "ci text(\"Retry it.\")", "comments 2"])
        taken.withLock { $0 = true }
        #expect(await flow.submit())
        #expect(log.values.suffix(2) == ["comments 2", "ci handleMyself"])
        await f.end()
    }

    // With no consent, the CI question is hidden: it doesn't count for the send.
    @Test func theCIQuestionHidesWithoutConsent() async throws {
        let f = try await AnswerFixture(ci: true, consent: false)
        await f.store.update { $0.prs[f.pr]?.questions = [:] }
        let flow = f.flow()
        #expect(flow.ciQuestion == nil)
        flow.answerCI("Retry it.")
        #expect(!flow.canSubmit)
        await f.end()
    }

    // The CI question also hides with the setting off, and when the poll shows a newer head
    // than the head of the question.
    @Test func theCIQuestionHidesWithTheSettingOffOrForAnOldHead() async throws {
        let f = try await AnswerFixture(ci: true)
        await f.store.update { $0.prs[f.pr]?.questions = [:] }
        let flow = f.flow()
        flow.answerCI("Retry it.")
        #expect(flow.ciQuestion != nil && flow.canSubmit)
        f.rounds.apply(f.config(fixCI: false))
        #expect(flow.ciQuestion == nil && !flow.canSubmit)
        f.rounds.apply(f.config(fixCI: true))
        #expect(flow.ciQuestion != nil)
        try await f.newHead(question: false)
        #expect(flow.ciQuestion == nil && !flow.canSubmit)
        #expect(await flow.submit() == false)
        #expect(f.store.state.prs[f.pr]?.ci?.question?.answer == nil)
        await f.end()
    }

    // The CI answer and its check belong to their question. A new push gives a new question, and
    // the answer for the old question doesn't show or go with it.
    @Test func aCIAnswerBelongsToItsQuestion() async throws {
        let f = try await AnswerFixture(ci: true)
        await f.store.update { $0.prs[f.pr]?.questions = [:] }
        let flow = f.flow()
        flow.answerCI("Retry it.")
        flow.handleCIMyself()
        #expect(flow.ciAnswer == "Retry it." && flow.ciHandled && flow.canSubmit)
        let head = try await f.newHead(question: true)
        #expect(flow.ciQuestion?.question.head == head)
        #expect(flow.ciAnswer.isEmpty && !flow.ciHandled && !flow.canSubmit)
        flow.answerCI("Fix the test.")
        #expect(flow.canSubmit)
        #expect(await flow.submit())
        let question = f.store.state.prs[f.pr]?.ci?.question
        #expect(question?.head == head && question?.answer == "Fix the test.")
        await f.end()
    }

    // The CI question goes hidden after the request rounds took the comment answers (the setting
    // goes off, say). No CI answer goes, and nothing is left to send, so the send is done.
    @Test func aCIQuestionThatGoesAfterTheCommentAnswersEndsTheSend() async throws {
        let f = try await AnswerFixture(ci: true)
        let (rounds, pr, off) = (f.rounds, f.pr, f.config(fixCI: false))
        let sentCI = Recorder<QuestionAnswer>()
        let flow = AnswerFlow(
            pr: pr, store: f.store,
            send: { answers in
                let taken = await rounds.answerQuestions(pr, answers)
                rounds.apply(off)
                return taken
            },
            ciQuestion: { rounds.ciQuestion(of: pr) },
            sendCI: { answer in
                sentCI.record(answer)
                return await rounds.answerCI(pr, answer)
            })
        flow.answer(f.first, "Use 50.")
        flow.handleMyself(f.second)
        flow.answerCI("Retry it.")
        #expect(await flow.submit())
        #expect(f.requestEntries.count == 1 && sentCI.values.isEmpty)
        #expect(f.store.state.prs[f.pr]?.ci?.question?.answer == nil)
        await f.end()
    }

    // The CI rounds refuse the CI answer after the request rounds took the comment answers: the
    // send fails, and the next send gives only the CI answer, so no comment answer goes twice.
    @Test func aRetryAfterARefusedCISendSendsOnlyTheCIAnswer() async throws {
        let f = try await AnswerFixture(ci: true)
        let (rounds, pr) = (f.rounds, f.pr)
        let sent = Recorder<Int>()
        let refuse = Mutex(true)
        let flow = AnswerFlow(
            pr: pr, store: f.store,
            send: { answers in
                sent.record(answers.count)
                return await rounds.answerQuestions(pr, answers)
            },
            ciQuestion: { rounds.ciQuestion(of: pr) },
            sendCI: { answer in
                if refuse.withLock({ $0 }) {
                    refuse.withLock { $0 = false }
                    return false
                }
                return await rounds.answerCI(pr, answer)
            })
        flow.answer(f.first, "Use 50.")
        flow.handleMyself(f.second)
        flow.answerCI("Retry it.")
        #expect(await flow.submit() == false)
        #expect(sent.values == [2] && f.requestEntries.count == 1)
        #expect(flow.questions.isEmpty && flow.ciQuestion != nil && flow.canSubmit)
        #expect(await flow.submit())
        #expect(sent.values == [2] && f.requestEntries.count == 1)
        #expect(f.store.state.prs[f.pr]?.ci?.question?.answer == "Retry it.")
        #expect(f.store.state.queue.contains { $0.pr == f.pr && $0.kind == .ci })
        await f.end()
    }

    // The CI question changes to another one while the comment answers go (a new push, say): no
    // CI answer goes, the send fails, and the new question has no answer.
    @Test func aCIAnswerNeverGoesToAQuestionThatChangedDuringTheSend() async throws {
        let f = try await AnswerFixture(ci: true)
        let (rounds, pr) = (f.rounds, f.pr)
        let sentCI = Recorder<QuestionAnswer>()
        let flow = AnswerFlow(
            pr: pr, store: f.store,
            send: { answers in
                let taken = await rounds.answerQuestions(pr, answers)
                _ = try? await f.newHead(question: true)
                return taken
            },
            ciQuestion: { rounds.ciQuestion(of: pr) },
            sendCI: { answer in
                sentCI.record(answer)
                return await rounds.answerCI(pr, answer)
            })
        flow.answer(f.first, "Use 50.")
        flow.handleMyself(f.second)
        flow.answerCI("Retry it.")
        #expect(await flow.submit() == false)
        #expect(f.requestEntries.count == 1 && sentCI.values.isEmpty)
        let question = f.store.state.prs[f.pr]?.ci?.question
        #expect(question?.text == "The new head fails too. What next?")
        #expect(question?.answer == nil)
        await f.end()
    }
}
