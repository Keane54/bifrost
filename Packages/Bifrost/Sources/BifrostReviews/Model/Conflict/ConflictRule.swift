// When a poll starts a conflict round on a PR of the user, and the message of the merge commit
// (docs/behaviour/reviews.md, "Merging the base branch"). Bifrost tries one time for each pair of
// a head commit and a base commit: the conflict mark of the PR keeps the pair of the last attempt,
// so a failed attempt waits for a new head, a new base or Resolve now.

package enum ConflictRule {
    // True when a poll queues an automatic conflict round for the PR:
    // - GitHub says that the PR has conflicts, and the PR does not come from a fork.
    // - The repository is not in the ignore list.
    // - The setting "Resolve merge conflicts automatically" is on, and the user confirmed it in
    //   this app (ReviewsState.allowsConflictFix). The setting alone never starts a round.
    // - No round runs, and no writes wait (an outbox, also an own outbox).
    // - The work of the user does not wait (PRState.waiting): changes in the worktree that no
    //   round made, or an own request that Bifrost did not commit or push. A conflict round
    //   moves the worktree, so it must not start over that work.
    // - No entry of the PR, of any kind, waits in the queue of the state.
    // - busy is false. The caller (ReviewRounds) knows the jobs and the own requests, so it
    //   gives busy: true while a job of the PR runs (a round of any kind), or while an own
    //   request of the user on the PR runs (ReviewRounds.ownRuns).
    // - The poll gives the full head commit and base commit, and the conflict mark is not for
    //   this pair. With no base commit, no mark could stop a second try on the same pair.
    package static func startsRound(
        _ pr: PullRequest, _ prState: PRState, state: ReviewsState, config: ReviewsConfig,
        busy: Bool
    ) -> Bool {
        guard pr.mergeable == .conflicting, !pr.isCrossRepository,
            !IgnoreRule.matches(config.ignore, pr.key.repo),
            state.allowsConflictFix(config.resolveConflicts), prState.round == nil,
            prState.outbox == nil, prState.waiting == nil,
            !state.queue.contains(where: { $0.pr == pr.key }), !busy,
            CommitID(pr.headSHA) != nil, CommitID(pr.baseSHA) != nil
        else { return false }
        return prState.conflict?.matches(pr) != true
    }

    // The message of the merge commit: "Merge <base> into <branch>". Bifrost never signs it.
    package static func mergeMessage(base: String, branch: String) -> String {
        "Merge \(base) into \(branch)"
    }
}
