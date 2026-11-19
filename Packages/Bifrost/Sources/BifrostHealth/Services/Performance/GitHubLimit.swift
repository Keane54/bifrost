import BifrostFoundation
import Foundation

// The GraphQL points of GitHub that remain, the limit, and the time of the reset.
package struct GitHubPoints: Sendable, Equatable {
    package var remaining: Int
    package var limit: Int
    package var reset: Date

    package init(remaining: Int, limit: Int, reset: Date) {
        self.remaining = remaining
        self.limit = limit
        self.reset = reset
    }
}

// Why the panel has no GitHub points.
package enum GitHubLimitError: Error, Sendable, Equatable {
    case noGH, loggedOut, failed

    // The text of the row of the panel.
    package var message: String {
        switch self {
        case .noGH: "GitHub CLI isn't installed"
        case .loggedOut: "GitHub CLI isn't signed in"
        case .failed: "Couldn't read the GitHub limit"
        }
    }
}

// Reads the GitHub points with gh api rate_limit (docs/behaviour/health.md, "Performance"). The
// read costs no points and changes nothing. gh uses its own login: Bifrost reads no token.
package struct GitHubLimit: Sendable {
    package static let arguments = ["api", "rate_limit"]
    // gh gives this exit code when the user is not signed in.
    private static let signedOutCode: Int32 = 4

    private let command: @Sendable () async -> GHCommand?

    package init(gh: GHCommand) {
        command = { gh }
    }

    // command gives the gh command at each read. The app knows the env of gh (the env of the
    // claude runs) only after it found claude, so it gives nil before that and with no claude.
    // A read with no command gives noGH.
    package init(command: @escaping @Sendable () async -> GHCommand?) {
        self.command = command
    }

    @concurrent package func read() async -> Result<GitHubPoints, GitHubLimitError> {
        guard let gh = await command() else { return .failure(.noGH) }
        let result = await gh.run(Self.arguments)
        switch result.end {
        case .exited(0):
            return Self.parse(result.stdout).map { .success($0) } ?? .failure(.failed)
        case .notStarted:
            return .failure(.noGH)
        case .exited(Self.signedOutCode):
            return .failure(.loggedOut)
        default:
            return .failure(result.stderr.contains("gh auth login") ? .loggedOut : .failed)
        }
    }

    // The GraphQL part of the answer: resources.graphql with limit, remaining and reset (in
    // seconds since 1970). nil for an answer of another form.
    package static func parse(_ stdout: String) -> GitHubPoints? {
        struct Answer: Decodable {
            struct Resources: Decodable { var graphql: Limit }
            struct Limit: Decodable {
                var limit: Int
                var remaining: Int
                var reset: Int
            }
            var resources: Resources
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: Data(stdout.utf8)),
            answer.resources.graphql.limit >= 0, answer.resources.graphql.remaining >= 0
        else { return nil }
        let graphql = answer.resources.graphql
        return GitHubPoints(
            remaining: graphql.remaining, limit: graphql.limit,
            reset: Date(timeIntervalSince1970: Double(graphql.reset)))
    }
}
