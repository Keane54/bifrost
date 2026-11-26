import BifrostReviews
import Foundation

// The GitHub of the tests: it answers each call from answers and records it. It does not send a
// read whose text holds a mutation, as GHRunner does, and records no such read, because it never
// reaches GitHub.
@MainActor
package final class FakeGitHub: GitHubAccess {
    package enum Call: Sendable, Equatable {
        // A read, by the name of its query.
        case read(String)
        case write(GitHubWrite)
    }

    // The key of the REST create of a pending review in answers. Each other write has the key of
    // its GraphQL field (GitHubWrite.mutation).
    package static let pendingReviewKey = "POST pulls/reviews"

    package private(set) var calls: [Call] = []
    // The answer of each read (by the name of its query) and of each write (by key(_:)). A call
    // with no answer fails as a refusal, so it never looks like a write that may have happened.
    package var answers: [String: Result<Data, GitHubError>]
    // Answers in order for a key: each call of the key takes the first one, and after the last
    // one the call gets the answer of answers.
    package var queued: [String: [Result<Data, GitHubError>]] = [:]
    // Runs at each write before its answer, as GitHub makes the change. A test plays GitHub with
    // it, for example by moving a branch of a local repository and setting the answer.
    package var onWrite: (@MainActor (GitHubWrite) async -> Void)?
    // Runs at each read before its answer, with the name of its query. A test acts while Bifrost
    // reads, for example as a person who types into a session.
    package var onRead: (@MainActor (String) async -> Void)?

    // The answer of scopes(), and the number of its reads. A scopes read is no entry of calls: it
    // is no query and no write. The default is a login with no scope header (unknown).
    package var scopes: Result<GitHubScopes?, GitHubError> = .success(nil)
    package private(set) var scopeReads = 0

    package init(answers: [String: Result<Data, GitHubError>] = [:]) {
        self.answers = answers
    }

    package static func key(_ write: GitHubWrite) -> String {
        write.mutation ?? pendingReviewKey
    }

    // The protocol is not isolated, so each method states the main actor. A call from another
    // actor hops to it.
    @MainActor package func read(_ query: GitHubQuery) async throws(GitHubError) -> Data {
        guard query.isRead else { throw .notSent }
        calls.append(.read(query.name))
        await onRead?(query.name)
        return try answer(query.name)
    }

    @MainActor package func write(_ write: GitHubWrite) async throws(GitHubError) -> Data {
        calls.append(.write(write))
        await onWrite?(write)
        return try answer(Self.key(write))
    }

    @MainActor package func scopes() async throws(GitHubError) -> GitHubScopes? {
        scopeReads += 1
        return try scopes.get()
    }

    private func answer(_ key: String) throws(GitHubError) -> Data {
        if var list = queued[key], !list.isEmpty {
            let first = list.removeFirst()
            queued[key] = list
            return try first.get()
        }
        guard let answer = answers[key] else {
            throw .refused("FakeGitHub has no answer for \(key).")
        }
        return try answer.get()
    }
}
