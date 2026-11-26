// The reads and the writes of Reviews on GitHub (docs/behaviour/reviews.md, "The GitHub data").
// The client keeps only the faults that it logged, of the poll and of the head read. Each call
// goes through the GitHubAccess of the app: gh in the app and FakeGitHub in the tests.
import BifrostFoundation
import Foundation
import OSLog

@MainActor package final class GitHubClient {
    private static let logger = Logger(bifrost: "reviews")
    private let access: any GitHubAccess
    // The faults that the log has. The app makes one client for its run, so each fault goes to
    // the log one time in each run, not at each poll.
    private(set) var loggedFaults: Set<WireFault> = []

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
        logFaults(answer.faults, read: PollQuery.name)
        return answer
    }

    // Logs the fields that a read could not read, each fault one time for this client. The read
    // is the name of a query, and each fault is the path of a field of the query: all are fixed
    // words, so the log shows them.
    func logFaults(_ faults: [WireFault], read: String) {
        let new = newFaults(faults)
        guard !new.isEmpty else { return }
        let names = new.map(\.rawValue).joined(separator: ", ")
        Self.logger.error(
            """
            The read \(read, privacy: .public) got fields that GitHub left out or gave in another \
            form: \(names, privacy: .public)
            """)
    }

    // The faults that are not in the log yet, in their order. The client then counts them as
    // logged.
    func newFaults(_ faults: [WireFault]) -> [WireFault] {
        faults.filter { loggedFaults.insert($0).inserted }
    }

    // One read: the query goes through the check of the access, which refuses a mutation.
    package func read(_ query: GitHubQuery) async throws(GitHubError) -> Data {
        try await access.read(query)
    }

    // The scopes of the login, or nil when they are unknown (a login with no scope header). A
    // read that fails throws, so the caller can keep the last answer that it knew.
    package func scopes() async throws(GitHubError) -> GitHubScopes? {
        try await access.scopes()
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
