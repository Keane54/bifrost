// The git identity of a test home (docs/behaviour/reviews.md, "Running git"). The app gives none:
// a fix commit uses the identity of the user's own git config. A test home has no git config, so
// it gives this closed value. RepoGit puts its items before the safe items, so it can never undo
// one of them.
import BifrostFoundation
import BifrostSessions

package struct CommitIdentity: Sendable, Equatable {
    package let name: String
    package let email: String

    // Each value has 1 to 200 characters, no white space at the start or the end, no control or
    // hidden character, and no "<" or ">" (git uses them around the email).
    package init?(name: String, email: String) {
        guard Self.isValid(name), Self.isValid(email) else { return nil }
        self.name = name
        self.email = email
    }

    // The -c items of the identity.
    var configItems: [String] { ["-c", "user.name=\(name)", "-c", "user.email=\(email)"] }

    private static func isValid(_ text: String) -> Bool {
        (1...200).contains(text.count) && text.trimmed() == text
            && !text.unicodeScalars.contains { isHiddenInAName($0) || $0 == "<" || $0 == ">" }
    }
}
