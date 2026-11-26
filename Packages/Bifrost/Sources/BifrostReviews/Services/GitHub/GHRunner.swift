// The way to GitHub (docs/behaviour/reviews.md, "Safety"). Each call is a read (a GitHubQuery,
// never a mutation) or one case of the closed GitHubWrite enum. gh runs in the Reviews folder,
// never in a clone or a worktree: a PR head can hold a git config, and gh reads the config of its
// folder. Bifrost reads no token: gh uses its own login.
import BifrostFoundation
import BifrostSessions
import Foundation

// The two ways to GitHub: GHRunner (gh) and FakeGitHub (the tests).
package protocol GitHubAccess: Sendable {
    func read(_ query: GitHubQuery) async throws(GitHubError) -> Data
    func write(_ write: GitHubWrite) async throws(GitHubError) -> Data
    // The scopes of the login, or nil when the login has no scope header.
    func scopes() async throws(GitHubError) -> GitHubScopes?
}

extension GitHubAccess {
    // An access that cannot tell the scopes gives none.
    package func scopes() async throws(GitHubError) -> GitHubScopes? { nil }
}

package struct GHRunner: GitHubAccess {
    package static let timeout = Duration.seconds(30), outputLimit = 16 * 1_048_576
    // The signed commit can carry 4 MiB of files, so it gets more time. A timeout of a write is
    // an unknown result.
    package static let signedCommitTimeout = Duration.seconds(120)
    // The longest error line, in characters.
    static let lineLimit = 200

    private let gh: GHCommand

    // gh: the gh command of the app (the env of the claude runs, with no prompt and no update
    // notice) with ReviewsLayout.folder as the folder of each run. After a cancel, a call ends
    // when gh ended.
    package init(gh: GHCommand) {
        self.gh = gh
    }

    // A read with a mutation in its text is not sent: gh does not start. gh exits with an error
    // code when GitHub gives errors next to the data. A read keeps such an answer, so the caller
    // keeps the data and reads the errors.
    package func read(_ query: GitHubQuery) async throws(GitHubError) -> Data {
        guard query.isRead else { throw .notSent }
        let result = await run(GitHubQuery.arguments, input: query.input, timeout: Self.timeout)
        if let error = Self.error(of: result) {
            switch error {
            case .refused, .unknownOutcome:
                guard Self.hasData(result.stdout) else { throw error }
            default:
                throw error
            }
        }
        return Data(result.stdout.utf8)
    }

    // A write never keeps an answer with errors, also with exit code 0. The errors give refused
    // only when the answer proves that GitHub did not make the change (graphQLFailure).
    package func write(_ write: GitHubWrite) async throws(GitHubError) -> Data {
        let timeout: Duration
        if case .createSignedCommit = write {
            timeout = Self.signedCommitTimeout
        } else {
            timeout = Self.timeout
        }
        let result = await run(write.arguments, input: write.input, timeout: timeout)
        if let error = Self.error(of: result) { throw error }
        if let failure = Self.graphQLFailure(result.stdout) { throw failure }
        return Data(result.stdout.utf8)
    }

    // The scopes of the login: the one closed read `gh api --include user`, which has no input.
    // Only the scope names leave this call. The body of the answer is the user of the login, and
    // it is dropped. Bifrost never reads or keeps a token.
    package func scopes() async throws(GitHubError) -> GitHubScopes? {
        let result = await run(["api", "--include", "user"], input: Data(), timeout: Self.timeout)
        if let error = Self.error(of: result) { throw error }
        return GitHubScopes(output: result.stdout)
    }

    private func run(_ arguments: [String], input: Data, timeout: Duration) async -> ExecResult {
        await gh.run(arguments, input: input, timeout: timeout, outputLimit: Self.outputLimit)
    }

    // The error of a run, or nil when gh ended well. gh gives exit code 4 when the user is not
    // logged in; an older gh only says to run gh auth login. A failure is a refusal only when the
    // answer proves that GitHub did not make the change: an HTTP 4xx status at the end of the
    // error line of gh, or GraphQL errors that graphQLFailure reads as a refusal. An HTTP 5xx
    // status and each other failure can come after GitHub made the change.
    static func error(of result: ExecResult) -> GitHubError? {
        switch result.end {
        case .exited(0): return nil
        case .notStarted: return .notInstalled
        case .timedOut: return .timedOut
        case .overflow: return .badAnswer
        case .exited(4): return .notLoggedIn
        case .exited, .signal, .cancelled: break
        }
        if result.stderr.contains("gh auth login") { return .notLoggedIn }
        let line = cleanLine(result.stderr)
        if result.stderr.contains(/\(HTTP 5\d\d\)/) { return .unknownOutcome(line) }
        if result.stderr.contains(/\(HTTP 4\d\d\)/) { return .refused(line) }
        return graphQLFailure(result.stdout) ?? .unknownOutcome(line)
    }

    // The failure of a GraphQL answer with errors, or nil when the output holds no errors. The
    // text is the first error message. GitHub did not make the change only when the answer has
    // no result (data is null, or each of its values is null) and no error says that GitHub
    // stopped on the way (a timeout, or "Something went wrong"): that error can come after a
    // write ran. An error next to a result came after the write ran.
    private static func graphQLFailure(_ stdout: String) -> GitHubError? {
        guard let answer = try? JSONDecoder().decode(JSONValue.self, from: Data(stdout.utf8)),
            let errors = answer.object?["errors"]?.array, !errors.isEmpty
        else { return nil }
        let messages = errors.map { $0.object?["message"]?.string ?? "" }
        let message = cleanLine(messages.first ?? "")
        let stopped = messages.contains { text in
            let lower = text.lowercased()
            return lower.contains("something went wrong") || lower.contains("timeout")
                || lower.contains("timed out")
        }
        let result: Bool
        switch answer.object?["data"] {
        case nil, .null?: result = false
        case .object(let fields)?: result = fields.values.contains { $0 != .null }
        default: result = true
        }
        return stopped || result ? .unknownOutcome(message) : .refused(message)
    }

    // The first line of a text that is not empty, without hidden characters, at most lineLimit
    // characters.
    private static func cleanLine(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmed() }.first { !$0.isEmpty } ?? ""
        return String(withoutHiddenCharacters(first).trimmed().prefix(lineLimit))
    }

    // True when the output is a GraphQL answer with data.
    private static func hasData(_ stdout: String) -> Bool {
        guard let answer = try? JSONDecoder().decode(JSONValue.self, from: Data(stdout.utf8))
        else { return false }
        return answer.object?["data"]?.object != nil
    }
}
