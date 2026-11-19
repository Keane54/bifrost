// The reads and the writes of Reviews on GitHub (docs/behaviour/reviews.md, "The GitHub data").
// The client has no state. Each call goes through the GitHubAccess of the app: gh in the app and
// FakeGitHub in the tests.
import BifrostFoundation
import Foundation
import OSLog

@MainActor package final class GitHubClient {
    private static let logger = Logger(bifrost: "reviews")
    private let access: any GitHubAccess

    package init(access: any GitHubAccess) {
        self.access = access
    }

    // One call for both lists. An answer with data and errors is kept, and the errors go to the
    // log.
    package func poll() async throws(GitHubError) -> PollAnswer {
        let data = try await access.read(PollQuery.query)
        let answer = try await Self.decode(data).get()
        for message in answer.errors {
            Self.logger.error("GitHub gave an error to a poll. \(message, privacy: .private)")
        }
        if answer.dropped > 0 {
            Self.logger.error(
                "A poll dropped \(answer.dropped, privacy: .public) PRs that are not valid.")
        }
        return answer
    }

    // One read: the query goes through the check of the access, which refuses a mutation.
    package func read(_ query: GitHubQuery) async throws(GitHubError) -> Data {
        try await access.read(query)
    }

    // The write goes through the closed GitHubWrite and the check of the access.
    package func write(_ write: GitHubWrite) async throws(GitHubError) -> Data {
        try await access.write(write)
    }

    // The answer of a busy account can be large, so the decode runs off the main actor.
    @concurrent private static func decode(_ data: Data) async -> Result<PollAnswer, GitHubError> {
        PollAnswer.decode(data)
    }
}
