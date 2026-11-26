// The rules of the CI rounds on a PR of the user (docs/behaviour/reviews.md, "My PRs"): when a
// poll starts a CI round, what a round may do, and what the row of the PR shows of the CI work.
// The budget belongs to a chain: the head that the user pushed, then each commit that Bifrost
// pushed on top of it (a CI fix or a conflict merge). The commits of Bifrost never reset the
// counts, and a new push of the user starts a new chain. A failure of another CI service is
// status only.
import Foundation

// What a CI round can do with the failed jobs. A question to the user (needs-you) is always
// allowed, so it is not an action here.
package enum CIAction: String, Sendable, CaseIterable {
    // Claude fixes a fault in the code, and Bifrost commits and pushes the fix.
    case fix
    // Bifrost re-runs the failed jobs: a flaky or infrastructure failure.
    case retry
}

// The next step of the CI work on a head that the fresh read shows.
package enum CIStep: Sendable, Equatable {
    // The head has no failed Actions job.
    case nothing
    // A round runs, and its result may give only these actions.
    case round(allowed: Set<CIAction>)
    // The chain has no fix and no re-run left: Bifrost asks its question with no session.
    case limits
}

// The CI question that the row of a PR counts (ReviewRounds.ciQuestion): the question, and the
// names of the failed Actions jobs of the poll (the names of the question when the poll has none).
package struct OpenCIQuestion: Sendable, Equatable {
    package var question: CIQuestion
    package var failedJobs: [String]

    package init(question: CIQuestion, failedJobs: [String]) {
        self.question = question
        self.failedJobs = failedJobs
    }
}

package enum CIRule {
    // The most commits of a chain (CIMark.chain). The newest stay.
    package static let maxChain = 8
    // The most fix rounds and re-runs of one chain.
    package static let maxFixes = 2
    package static let maxRetries = 1

    // True while a re-run of the failed jobs of the head waits for its result: Bifrost re-ran the
    // failed jobs of this head, and CI runs, or the poll still shows the same failed jobs as the
    // failure that the round took. A new result of the jobs ends it.
    package static func isRetrying(_ pr: PullRequest, _ mark: CIMark?) -> Bool {
        guard let mark, mark.retrying?.hex == pr.headSHA else { return false }
        return pr.ci == .running || (!mark.handled.isEmpty && pr.checks.jobKey == mark.handled)
    }

    // The CI question that the row counts and the Answer panel shows: a question with no answer
    // on the head of the PR. allowed is false while the CI work is off or has no consent
    // (ReviewsState.allowsCIFix), and then the question is hidden.
    package static func visibleQuestion(
        _ pr: PullRequest, _ mark: CIMark?, allowed: Bool
    ) -> CIQuestion? {
        guard allowed, let question = mark?.question, question.answer == nil,
            question.head.hex == pr.headSHA
        else { return nil }
        return question
    }

    // The mark of the chain of the head:
    // - No mark: a fresh mark of the head.
    // - A mark whose chain holds the head: the mark as it is. A failure on a commit that Bifrost
    //   pushed keeps the budget of the chain.
    // - A mark with no chain: a damaged mark (CIMark reads the counts of a damaged mark as spent).
    //   It adopts the head and keeps each other field, so the damage never gives a fresh budget.
    // - Else a new push of the user: a fresh mark of the head.
    // Each result has a chain: a good save never writes a mark with no chain and other fields.
    package static func chainMark(_ mark: CIMark?, head: CommitID) -> CIMark {
        guard let mark else { return CIMark(chain: [head]) }
        if mark.chain.contains(head) { return mark }
        guard mark.chain.isEmpty else { return CIMark(chain: [head]) }
        var adopted = mark
        adopted.chain = [head]
        return adopted
    }

    // The actions that a round of the chain may give: a fix while the chain has fixes left, or
    // when the round answers a CI question of the user (one more fix), and a re-run while the
    // chain has re-runs left. A round that goes on after a restart checks its result against
    // this set with no fresh read.
    package static func allowed(_ mark: CIMark, answered: Bool) -> Set<CIAction> {
        var actions: Set<CIAction> = []
        if mark.fixes < maxFixes || answered { actions.insert(.fix) }
        if mark.retries < maxRetries { actions.insert(.retry) }
        return actions
    }

    // The step for the fresh read of the head and the mark of its chain (chainMark). A head with
    // no failed Actions job needs nothing. With no allowed action, the round asks its question
    // with no session.
    package static func step(_ read: HeadRead, mark: CIMark, answered: Bool) -> CIStep {
        guard !read.checks.failedJobs.isEmpty else { return .nothing }
        let actions = allowed(mark, answered: answered)
        return actions.isEmpty ? .limits : .round(allowed: actions)
    }

    // True when a poll queues an automatic CI round for the PR:
    // - The setting "Fix failing CI automatically" is on, and the user confirmed it in this app
    //   (ReviewsState.allowsCIFix). The repository is not in the ignore list, and the PR does
    //   not come from a fork.
    // - GitHub does not say that the PR has conflicts: the conflict round goes first.
    // - Each check of the head is done, the read has all of them, and an Actions job failed in a
    //   way that a round can act on. The poll gives the full head commit.
    // - The user does not fix the CI of this head (CIMark.userHandles).
    // - The failure is not the one that the last round took: the same head and the same failed
    //   job IDs never start a second round.
    // - No CI question waits for an answer on this head.
    // - No round runs, no writes wait (an outbox, also an own outbox), and the work of the user
    //   does not wait (PRState.waiting). A CI round moves the worktree, so it must not start over
    //   that work.
    // - No entry of the PR, of any kind, waits in the queue of the state.
    // - busy is false. The caller (ReviewRounds) gives busy: true while a job, an own request, a
    //   drop or a discard of the PR runs, or while a person uses its request session.
    // The rule does not check the limits: a round at its limits asks its question with no
    // session (step).
    package static func startsRound(
        _ pr: PullRequest, _ prState: PRState, state: ReviewsState, config: ReviewsConfig,
        busy: Bool
    ) -> Bool {
        guard state.allowsCIFix(config.fixCI), !IgnoreRule.matches(config.ignore, pr.key.repo),
            !pr.isCrossRepository, pr.mergeable != .conflicting, pr.checks.settled,
            !pr.checks.failedJobs.isEmpty, let head = CommitID(pr.headSHA),
            prState.round == nil, prState.outbox == nil, prState.waiting == nil,
            !state.queue.contains(where: { $0.pr == pr.key }), !busy
        else { return false }
        let mark = prState.ci
        if mark?.userHandles == head { return false }
        if let mark, mark.handledHead == head, mark.handled == pr.checks.jobKey { return false }
        return visibleQuestion(pr, mark, allowed: true) == nil
    }
}
