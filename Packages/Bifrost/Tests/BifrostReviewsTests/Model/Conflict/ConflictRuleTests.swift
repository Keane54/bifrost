// When a poll starts a conflict round on a PR of the user, and the message of the merge commit
// (docs/behaviour/reviews.md, "Merging the base branch"). The table starts from a PR with
// conflicts, the setting on and its consent, and changes one thing in each case.
import Foundation
import Testing

@testable import BifrostReviews

private typealias R = Rows

// The inputs of the rule for one case.
private struct RuleInputs {
    var pr: PullRequest
    var prState = PRState()
    var state: ReviewsState
    var config = ReviewsConfig(resolveConflicts: true)
    var busy = false

    // A PR with conflicts at the head (a) and the base (b) of the tests, the setting on and the
    // consent of the user.
    init() throws {
        pr = try R.pull("owner-a/repo-a#1", mergeable: .conflicting, base: R.base)
        state = R.turnedOn()
        state.consentToConflictFix()
    }

    var startsRound: Bool {
        ConflictRule.startsRound(pr, prState, state: state, config: config, busy: busy)
    }
}

// One case of the table: what changes, and whether a round starts.
struct ConflictRuleCase: Sendable, CustomTestStringConvertible {
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

    // An attempt on the head and the base of the tests, or on another commit.
    private static func attempt(
        _ outcome: ConflictOutcome = .failed("It failed."), head: Character = "a",
        base: Character = "b"
    ) throws -> ConflictMark {
        ConflictMark(
            head: try R.commit(head), base: try R.commit(base), at: R.at(-5), outcome: outcome)
    }

    static let all: [ConflictRuleCase] = [
        ConflictRuleCase("conflicts with the setting and its consent", true) { _ in },
        ConflictRuleCase("no consent", false) { $0.state.conflictConsent = nil },
        ConflictRuleCase("a refused consent", false) { $0.state.conflictConsent = false },
        ConflictRuleCase("the setting off", false) { $0.config.resolveConflicts = false },
        ConflictRuleCase("a fork", false) { $0.pr.isCrossRepository = true },
        ConflictRuleCase("an ignored repository", false) {
            $0.config.ignore = [try #require(IgnoreEntry("Owner-A/*"))]
        },
        ConflictRuleCase("a failed attempt on the same pair", false) {
            $0.prState.conflict = try attempt()
        },
        ConflictRuleCase("a running attempt on the same pair", false) {
            $0.prState.conflict = try attempt(.working)
        },
        ConflictRuleCase("a pushed attempt on the same pair", false) {
            $0.prState.conflict = try attempt(.pushed(try R.commit("f")))
        },
        ConflictRuleCase("an outbox", false) {
            $0.prState.outbox = Outbox(
                headSHA: try R.commit("a"), mergeBase: try R.commit("b"), startedAt: R.at(-20),
                seen: [:],
                posts: [
                    OutboxPost(id: "1", state: .todo, write: .resolve(item: try R.node("PRRT_4")))
                ])
        },
        // The work of the user waits: changes in the worktree that no round made, an own
        // request that Bifrost did not commit, and an own outbox that did not reach GitHub.
        ConflictRuleCase("kept worktree changes", false) {
            $0.prState.waiting = WaitsForYou(
                reason: "Bifrost found changes that no round made.", files: ["src/a.swift"])
        },
        ConflictRuleCase("an own request that did not go", false) {
            $0.prState.waiting = WaitsForYou(reason: "Bifrost didn't commit your change.")
        },
        ConflictRuleCase("an own outbox that did not go", false) {
            $0.prState.outbox = Outbox(
                headSHA: try R.commit("a"), mergeBase: try R.commit("b"), startedAt: R.at(-20),
                seen: [:], posts: [], own: true)
            $0.prState.waiting = WaitsForYou(reason: "GitHub didn't accept your change.")
        },
        // busy: a round of any kind, or an own request of the user, runs on the PR.
        ConflictRuleCase("a busy PR", false) { $0.busy = true },
        // An entry of the PR waits in the queue, of any kind.
        ConflictRuleCase("a queued request round", false) {
            $0.state.queue = [QueueEntry(pr: $0.pr.key, kind: .request, at: R.at(-2))]
        },
        ConflictRuleCase("a queued conflict round", false) {
            $0.state.queue = [QueueEntry(pr: $0.pr.key, kind: .conflict, at: R.at(-2))]
        },
        ConflictRuleCase("a queued CI round", false) {
            $0.state.queue = [QueueEntry(pr: $0.pr.key, kind: .ci, at: R.at(-2))]
        },
        ConflictRuleCase("a queued review round", false) {
            $0.state.queue = [QueueEntry(pr: $0.pr.key, kind: .review, at: R.at(-2))]
        },
        ConflictRuleCase("a queued round of another PR", true) {
            $0.state.queue = [
                QueueEntry(pr: try R.key("owner-a/repo-a#2"), kind: .request, at: R.at(-2))
            ]
        },
        ConflictRuleCase("a round", false) {
            $0.prState.round = ActiveRound(
                phase: .running, startedAt: R.at(-1), at: R.at(-1), kind: .request)
        },
        ConflictRuleCase("an unknown merge state", false) { $0.pr.mergeable = .unknown },
        ConflictRuleCase("no merge state", false) { $0.pr.mergeable = nil },
        ConflictRuleCase("no conflicts", false) { $0.pr.mergeable = .mergeable },
        ConflictRuleCase("no base commit", false) { $0.pr.baseSHA = "" },
        ConflictRuleCase("no head commit", false) { $0.pr.headSHA = "" },
        ConflictRuleCase("a new head", true) { $0.prState.conflict = try attempt(head: "c") },
        ConflictRuleCase("a new base", true) { $0.prState.conflict = try attempt(base: "c") },
    ]
}

@Suite("the conflict round rule")
struct ConflictRuleTests {
    @Test(arguments: ConflictRuleCase.all) func aPollStartsARoundOnlyWhenTheRuleAllows(
        _ rule: ConflictRuleCase
    ) throws {
        var inputs = try RuleInputs()
        try rule.change(&inputs)
        #expect(inputs.startsRound == rule.starts)
    }

    // The merge commit names the base branch and the branch of the PR.
    @Test func theMergeMessageNamesTheBaseAndTheBranch() {
        #expect(ConflictRule.mergeMessage(base: "main", branch: "feat") == "Merge main into feat")
    }
}
