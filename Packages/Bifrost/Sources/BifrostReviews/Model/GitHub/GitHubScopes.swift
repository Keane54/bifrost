// The scopes of the gh login (docs/behaviour/reviews.md, "The workflow scope"). GitHub pushes a
// change of a workflow file only with the workflow scope, so Bifrost reads the scopes to warn the
// user before a round fails. Only the names of the scopes stay: never a token.
import BifrostFoundation
import Foundation

package struct GitHubScopes: Sendable, Equatable {
    package let names: Set<String>

    package init(names: Set<String>) {
        self.names = names
    }

    // The scopes from the answer of `gh api --include user`: the status line and the headers,
    // an empty line, then the body. The header X-OAuth-Scopes (in any case) holds the names with
    // commas between them. nil when the answer has no such header, which is the case for a
    // fine-grained token and a GitHub App token: then the scopes are unknown.
    package init?(output: String) {
        let name = "x-oauth-scopes"
        for line in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            // A line break of two characters ("\r\n") is one Character, so the empty line ends the
            // headers for both forms.
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":"),
                line[..<colon].trimmed().lowercased() == name
            else { continue }
            let values = line[line.index(after: colon)...].split(separator: ",")
            self.init(names: Set(values.map { $0.trimmed() }.filter { !$0.isEmpty }))
            return
        }
        return nil
    }

    // True when the login can't push a change of a workflow file.
    package var lacksWorkflow: Bool { !names.contains("workflow") }
}
