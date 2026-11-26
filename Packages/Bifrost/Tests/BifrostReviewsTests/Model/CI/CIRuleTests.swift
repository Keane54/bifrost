// When a poll starts a CI round on a PR of the user, and what a round may do
// (docs/behaviour/reviews.md, "My PRs"). The budget belongs to a chain: the head that the user
// pushed and each commit that Bifrost pushed on top of it. The tables start from a PR whose head
// has one failed Actions job, with the setting on and its consent, and change one thing in each
// case.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private typealias R = Rows

// A job of GitHub Actions on the head, with its job ID.
private func job(_ name: String, _ id: Int, _ outcome: CheckOutcome) throws -> HeadCheck {
    HeadCheck(
        name: name, outcome: outcome,
        source: .actions(job: try #require(JobID(id)), run: try #require(RunID(9001))))
}

// The checks of the head: one failed Actions job (11) and one passed job.
private func failedChecks() throws -> HeadChecks {
    HeadChecks(
        checks: [try job("test", 11, .failed("FAILURE")), try job("lint", 12, .passed)],
        cut: false, onHead: true)
}

// The inputs of the rule for one case.
private struct RuleInputs {
    var pr: PullRequest
    var prState = PRState()
    var state: ReviewsState
    var config = ReviewsConfig(fixCI: true)
    var busy = false

    // A PR with no conflict whose head (a) has a failed Actions job, the setting on and the
    // consent of the user.
    init() throws {
        pr = try R.pull("owner-a/repo-a#1", mergeable: .mergeable, checks: try failedChecks())
        state = R.turnedOn()
        state.consentToCIFix()
    }

    var startsRound: Bool {
        CIRule.startsRound(pr, prState, state: state, config: config, busy: busy)
    }
}

// One case of the gate table: what changes, and whether a round starts.
struct CIGateCase: Sendable, CustomTestStringConvertible {
    let name: String
    let starts: Bool
    fileprivate let change: @Sendable (inout RuleInputs) throws -> Void

    fileprivate init(
        _ name: String, _ starts: Bool,
        _ change: @escaping @Sendable (inout RuleInputs) throws -> Void
    ) {
        self.name = name
        self.starts = starts
        self.change = change
    }

    var testDescription: String { name }

    static let all: [CIGateCase] = [
        CIGateCase("a failed job with the setting and its consent", true) { _ in },
        CIGateCase("no consent", false) { $0.state.ciConsent = nil },
        CIGateCase("a refused consent", false) { $0.state.ciConsent = false },
        CIGateCase("the setting off", false) { $0.config.fixCI = false },
        CIGateCase("a fork", false) { $0.pr.isCrossRepository = true },
        CIGateCase("an ignored repository", false) {
            $0.config.ignore = [try #require(IgnoreEntry("Owner-A/*"))]
        },
        CIGateCase("no head commit", false) { $0.pr.headSHA = "" },
        CIGateCase("a round", false) {
            $0.prState.round = ActiveRound(
                phase: .running, startedAt: R.at(-1), at: R.at(-1), kind: .request)
        },
        CIGateCase("an outbox", false) {
            $0.prState.outbox = Outbox(
                headSHA: try R.commit("a"), mergeBase: try R.commit("b"), startedAt: R.at(-20),
                seen: [:],
                posts: [
                    OutboxPost(id: "1", state: .todo, write: .resolve(item: try R.node("PRRT_4")))
                ])
        },
        // The work of the user waits: changes in the worktree that no round made, or an own
        // request that Bifrost did not commit.
        CIGateCase("kept worktree changes", false) {
            $0.prState.waiting = WaitsForYou(
                reason: "Bifrost found changes that no round made.", files: ["src/a.swift"])
        },
        CIGateCase("an own request that did not go", false) {
            $0.prState.waiting = WaitsForYou(reason: "Bifrost didn't commit your change.")
        },
        // busy: a job, an own request, a drop or a discard of the PR runs, or a person uses its
        // request session.
        CIGateCase("a busy PR", false) { $0.busy = true },
        CIGateCase("a queued request round", false) {
            $0.state.queue = [QueueEntry(pr: $0.pr.key, kind: .request, at: R.at(-2))]
        },
        CIGateCase("a queued conflict round", false) {
            $0.state.queue = [QueueEntry(pr: $0.pr.key, kind: .conflict, at: R.at(-2))]
        },
        CIGateCase("a queued CI round", false) {
            $0.state.queue = [QueueEntry(pr: $0.pr.key, kind: .ci, at: R.at(-2))]
        },
        CIGateCase("a queued review round", false) {
            $0.state.queue = [QueueEntry(pr: $0.pr.key, kind: .review, at: R.at(-2))]
        },
        CIGateCase("a queued round of another PR", true) {
            $0.state.queue = [
                QueueEntry(pr: try R.key("owner-a/repo-a#2"), kind: .request, at: R.at(-2))
            ]
        },
    ]
}

@Suite("the CI round rule", .testTimeLimit)
struct CIRuleTests {
    // The fresh read of the head (a) with the checks of the tests.
    private func read(_ checks: HeadChecks) throws -> HeadRead {
        HeadRead(author: "user-a", head: try R.commit("a"), checks: checks)
    }

    // A failure on a commit that Bifrost pushed on top of the head of the user (F on H) keeps the
    // mark: its counts and its records stay.
    @Test func aFailureOnBifrostsOwnCommitKeepsTheBudget() throws {
        let mark = CIMark(
            chain: [try R.commit("1"), try R.commit("f")], fixes: 1,
            handledHead: try R.commit("1"), handled: [try #require(JobID(11))])
        #expect(CIRule.chainMark(mark, head: try R.commit("f")) == mark)
        #expect(CIRule.chainMark(mark, head: try R.commit("1")) == mark)
    }

    // A head that is not in the chain is a new push of the user: a new chain with no spent
    // count. A PR with no mark gets the same fresh mark.
    @Test func aNewPushOfTheUserStartsAFreshBudget() throws {
        let mark = CIMark(
            chain: [try R.commit("1"), try R.commit("f")], fixes: 2, retries: 1,
            handledHead: try R.commit("f"), handled: [try #require(JobID(11))],
            retrying: try R.commit("f"), userHandles: try R.commit("1"))
        let user = try R.commit("e")
        #expect(CIRule.chainMark(mark, head: user) == CIMark(chain: [user]))
        #expect(CIRule.chainMark(nil, head: user) == CIMark(chain: [user]))
    }

    // A damaged mark reads with no chain and with spent counts. It adopts the head and keeps
    // the counts and its other fields, so the damage never gives a fresh budget.
    @Test func aDamagedMarkKeepsItsSpentBudget() throws {
        var dropped = DroppedFields()
        let damaged = try #require(
            CIMark(stored: ["fixes": 1, "handled": [11]], dropped: &dropped))
        try #require(damaged.chain.isEmpty)
        let head = try R.commit("a")
        let adopted = CIRule.chainMark(damaged, head: head)
        #expect(
            adopted
                == CIMark(
                    chain: [head], fixes: CIRule.maxFixes, retries: CIRule.maxRetries,
                    handled: [try #require(JobID(11))]))
        let read = try read(try failedChecks())
        #expect(CIRule.step(read, mark: adopted, answered: false) == .limits)
    }

    // The head and the job IDs of the last failure that a round took never start a second
    // round. A new job ID on the same head is a new failure.
    @Test func theSameJobsNeverStartTwice() throws {
        var inputs = try RuleInputs()
        inputs.prState.ci = CIMark(
            chain: [try R.commit("a")], fixes: 1, handledHead: try R.commit("a"),
            handled: [try #require(JobID(11))])
        #expect(!inputs.startsRound)
        inputs.pr.checks = HeadChecks(
            checks: [try job("test", 13, .failed("FAILURE"))], cut: false, onHead: true)
        #expect(inputs.startsRound)
    }

    // A failure of another CI service (a commit status) or of another app is status only.
    @Test func otherServicesOnlyStartNothing() throws {
        var inputs = try RuleInputs()
        #expect(inputs.startsRound)
        inputs.pr.checks = HeadChecks(
            checks: [
                try job("lint", 12, .passed),
                HeadCheck(name: "ci/legacy", outcome: .failed("ERROR"), source: .status),
                HeadCheck(name: "preview", outcome: .failed("FAILURE"), source: .app("app-a")),
            ],
            cut: false, onHead: true)
        #expect(!inputs.startsRound)
    }

    // A PR with conflicts waits: the conflict round goes first. A merge state that GitHub does
    // not know yet does not stop the round.
    @Test func aConflictingPRWaits() throws {
        var inputs = try RuleInputs()
        inputs.pr.mergeable = .conflicting
        #expect(!inputs.startsRound)
        inputs.pr.mergeable = .unknown
        #expect(inputs.startsRound)
        inputs.pr.mergeable = nil
        #expect(inputs.startsRound)
    }

    // A round starts only when each check of the head is done and the read has all of them.
    @Test func anUnsettledHeadWaits() throws {
        var inputs = try RuleInputs()
        #expect(inputs.startsRound)
        var running = try failedChecks()
        running.checks.append(HeadCheck(name: "docs", outcome: .running, source: .status))
        inputs.pr.checks = running
        #expect(!inputs.startsRound)
        var cut = try failedChecks()
        cut.cut = true
        inputs.pr.checks = cut
        #expect(!inputs.startsRound)
        var otherCommit = try failedChecks()
        otherCommit.onHead = false
        inputs.pr.checks = otherCommit
        #expect(!inputs.startsRound)
    }

    // The rule does not check the limits: a spent chain still starts its round, and the round
    // then asks its limits question with no session (step).
    @Test func aSpentChainStillStartsARound() throws {
        var inputs = try RuleInputs()
        inputs.prState.ci = CIMark(chain: [try R.commit("a")], fixes: 2, retries: 1)
        #expect(inputs.startsRound)
    }

    // The user fixes the CI of this head: no round starts on it. Another head starts again.
    @Test func aHeadTheUserHandlesWaits() throws {
        var inputs = try RuleInputs()
        inputs.prState.ci = CIMark(chain: [try R.commit("a")], userHandles: try R.commit("a"))
        #expect(!inputs.startsRound)
        inputs.prState.ci?.userHandles = try R.commit("e")
        #expect(inputs.startsRound)
    }

    // A CI question with no answer on the head waits for the user. An answered question, or a
    // question on another head, does not wait.
    @Test func anOpenQuestionWaits() throws {
        var inputs = try RuleInputs()
        let question = CIQuestion(
            text: "Should I raise the timeout?", head: try R.commit("a"), jobs: ["test"],
            at: R.at(-5), byClaude: true)
        inputs.prState.ci = CIMark(chain: [try R.commit("a")], question: question)
        #expect(!inputs.startsRound)
        inputs.prState.ci?.question?.answer = "Yes, to 20 minutes."
        #expect(inputs.startsRound)
        var other = question
        other.head = try R.commit("e")
        inputs.prState.ci?.question = other
        #expect(inputs.startsRound)
    }

    // Each gate of the consent, of the repository and of the state of the PR stops the rule.
    @Test(arguments: CIGateCase.all)
    func theGateAndTheStateStopTheRule(_ gate: CIGateCase) throws {
        var inputs = try RuleInputs()
        try gate.change(&inputs)
        #expect(inputs.startsRound == gate.starts)
    }

    // At the limits no round starts: the round asks its question with no session. A spent fix
    // budget leaves the re-run, and a head with no failed Actions job needs nothing.
    @Test func theLimitsGiveNoRound() throws {
        let read = try read(try failedChecks())
        let head = try R.commit("a")
        let spent = CIMark(chain: [head], fixes: 2, retries: 1)
        #expect(CIRule.step(read, mark: spent, answered: false) == .limits)
        let noFix = CIMark(chain: [head], fixes: 2)
        #expect(CIRule.step(read, mark: noFix, answered: false) == .round(allowed: [.retry]))
        let fresh = CIMark(chain: [head])
        #expect(CIRule.step(read, mark: fresh, answered: false) == .round(allowed: [.fix, .retry]))
        let passed = HeadChecks(checks: [try job("lint", 12, .passed)], cut: false, onHead: true)
        #expect(CIRule.step(try self.read(passed), mark: fresh, answered: false) == .nothing)
    }

    // An answer of the user allows one more fix at the limit. It never allows a second re-run.
    @Test func anAnswerAllowsOneMoreFix() throws {
        let read = try read(try failedChecks())
        let spent = CIMark(chain: [try R.commit("a")], fixes: 2, retries: 1)
        #expect(CIRule.step(read, mark: spent, answered: true) == .round(allowed: [.fix]))
        #expect(CIRule.allowed(spent, answered: true) == [.fix])
        #expect(CIRule.allowed(spent, answered: false) == [])
    }
}
