// The answer of one poll (docs/behaviour/reviews.md, "The GitHub data"): the viewer and the two
// lists of PRs. GitHub can answer with data and errors together. The answer then keeps the data,
// and the errors go with it. Only an answer with no usable data fails.
import BifrostFoundation
import BifrostSessions
import Foundation

package struct PollAnswer: Sendable, Equatable {
    package var viewer: String
    package var toReview: [PullRequest]
    package var mine: [PullRequest]
    // True when GitHub has more PRs than the first 50 of the list, or when the answer has no
    // result for the list. Either way the list can lack open PRs.
    package var toReviewCut: Bool
    package var mineCut: Bool
    // The error messages of a partial answer, each one time, 200 characters at most. A list can
    // then lack PRs that are open.
    package var errors: [String]
    // The count of PRs that the answer left out because they were not valid.
    package var dropped: Int

    // The longest error message that the answer keeps.
    static let errorLimit = 200

    package init(
        viewer: String, toReview: [PullRequest] = [], mine: [PullRequest] = [],
        toReviewCut: Bool = false, mineCut: Bool = false, errors: [String] = [], dropped: Int = 0
    ) {
        self.viewer = viewer
        self.toReview = toReview
        self.mine = mine
        self.toReviewCut = toReviewCut
        self.mineCut = mineCut
        self.errors = errors
        self.dropped = dropped
    }

    // Reads the output of gh. The answer is usable when it names the viewer and, if it holds
    // errors, also has a result for both searches. An answer that is not JSON, or that names no
    // viewer, is a bad answer. An answer with errors and no usable data is the refusal of GitHub.
    package static func decode(_ data: Data) -> Result<PollAnswer, GitHubError> {
        guard let wire = try? JSONDecoder().decode(PollWire.self, from: data) else {
            return .failure(.badAnswer)
        }
        let errors = messages(wire.errors ?? [])
        let body = wire.data
        let viewer = body?.viewer?.login
        if !errors.isEmpty, viewer == nil || body?.toReview == nil || body?.mine == nil {
            return .failure(.refused(errors[0]))
        }
        guard let body, let viewer else { return .failure(.badAnswer) }
        let toReview = list(body.toReview, viewer: viewer, isToReview: true)
        let mine = list(body.mine, viewer: viewer, isToReview: false)
        return .success(
            PollAnswer(
                viewer: viewer, toReview: toReview.pulls, mine: mine.pulls,
                toReviewCut: body.toReview?.isCut ?? true, mineCut: body.mine?.isCut ?? true,
                errors: errors, dropped: toReview.dropped + mine.dropped))
    }

    private static func list(
        _ search: PollWire.Search?, viewer: String, isToReview: Bool
    ) -> (pulls: [PullRequest], dropped: Int) {
        let pulls = (search?.items ?? []).compactMap {
            $0.decoded?.pullRequest(viewer: viewer, isToReview: isToReview)
        }
        return (pulls, (search?.items.count ?? 0) - pulls.count)
    }

    // Each message one time, in the order of the answer, with no hidden characters. An error
    // with no message gives a general text.
    private static func messages(_ failures: [PollWire.Failure]) -> [String] {
        var seen: [String] = []
        for failure in failures {
            let text = String(
                withoutHiddenCharacters(failure.message ?? "").trimmed().prefix(errorLimit))
            let message = text.isEmpty ? "GitHub gave an error." : text
            if !seen.contains(message) { seen.append(message) }
        }
        return seen
    }
}
