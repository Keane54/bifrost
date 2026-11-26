import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

// The scopes of the gh login, from the headers of `gh api --include user`
// (docs/behaviour/reviews.md, "The workflow scope").
@Suite("the scopes of the GitHub login", .testTimeLimit)
struct GitHubScopesTests {
    private static func answer(_ scopes: String?, newline: String = "\n") -> String {
        var lines = ["HTTP/2.0 200 OK", "X-Accepted-Oauth-Scopes: "]
        if let scopes { lines.append("X-Oauth-Scopes: \(scopes)") }
        lines.append("Content-Type: application/json; charset=utf-8")
        return lines.joined(separator: newline) + newline + newline + #"{"login":"someone"}"#
    }

    @Test func theNamesComeFromTheScopesHeader() {
        let scopes = GitHubScopes(output: Self.answer("admin:public_key, gist, read:org, repo"))
        #expect(scopes?.names == ["admin:public_key", "gist", "read:org", "repo"])
        #expect(scopes?.lacksWorkflow == true)
        // The header name has no case, and a line can end in a carriage return.
        let more = GitHubScopes(output: Self.answer("repo,workflow", newline: "\r\n"))
        #expect(more?.names == ["repo", "workflow"] && more?.lacksWorkflow == false)
        let lower = GitHubScopes(output: "HTTP/2.0 200 OK\nx-oauth-scopes: repo, workflow\n\n{}")
        #expect(lower?.lacksWorkflow == false)
    }

    // No header means a token with no scopes (a fine-grained token or a GitHub App token), so the
    // scopes are unknown. An empty header is a classic token with no scope: it is known.
    @Test func noHeaderMeansUnknownAndAnEmptyHeaderMeansNoScopes() {
        #expect(GitHubScopes(output: Self.answer(nil)) == nil)
        #expect(GitHubScopes(output: "") == nil)
        let empty = GitHubScopes(output: Self.answer(""))
        #expect(empty?.names == [] && empty?.lacksWorkflow == true)
    }

    // Only the headers count: a line of the body that looks like the header, and the header of
    // accepted scopes, give nothing.
    @Test func onlyTheHeaderBlockCounts() {
        let body = "HTTP/2.0 200 OK\nX-Accepted-Oauth-Scopes: workflow\n\nX-Oauth-Scopes: workflow"
        #expect(GitHubScopes(output: body) == nil)
    }
}
