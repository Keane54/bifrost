// The rules of the CI rounds on a PR of the user (docs/behaviour/reviews.md, "My PRs"): what the
// row of the PR shows of the CI work.
import Foundation

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
}
