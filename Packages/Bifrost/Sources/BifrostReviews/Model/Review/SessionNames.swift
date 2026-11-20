// The names of the PR sessions (docs/behaviour/reviews.md, "PR sessions"):
// <repo>-<number>-<kind>, and <owner>-<repo>-<number>-<kind> when the short name is in use, for
// example by a PR of another repository with the same name. The rounds on a PR of the user share
// its one request session, so each of their kinds (request, conflict, ci) gives "request". A test
// home puts bifrost-test- first, so a test can only send input, a signal, a stop or an attach to a
// session of its own. The repository part is cut so that the name has at most
// NewSessionSpec.maxName characters.
import BifrostSessions

package enum SessionNames {
    package static let testPrefix = "bifrost-test-"

    package static func name(
        _ pr: PRKey, _ kind: PRSessionKind, clash: Bool, testPrefix: Bool
    ) -> String {
        let prefix = testPrefix ? Self.testPrefix : ""
        let part = kind.isMine ? PRSessionKind.request.rawValue : kind.rawValue
        let tail = "-\(pr.number)-\(part)"
        let head = clash ? "\(pr.repo.owner)-\(pr.repo.name)" : pr.repo.name
        let room = max(NewSessionSpec.maxName - prefix.count - tail.count, 0)
        return prefix + String(head.prefix(room)) + tail
    }

    // The short name, or the name with the owner when a session in use has the short name.
    package static func free(
        _ pr: PRKey, _ kind: PRSessionKind, inUse: Set<String>, testPrefix: Bool
    ) -> String {
        let short = name(pr, kind, clash: false, testPrefix: testPrefix)
        return inUse.contains(short) ? name(pr, kind, clash: true, testPrefix: testPrefix) : short
    }
}
