import BifrostFoundation
import Foundation

// The answer of the usage endpoint: the HTTP status and the body. body is nil when the read of
// the body failed after the response came, so the status still decides (a 429 is a rate limit,
// a 401 is a refused login). The body has at most AccountAnswer.maxBytes + 1 bytes: the read
// stops there.
package struct UsageResponse: Sendable, Equatable {
    package var status: Int
    package var body: Data?

    package init(status: Int, body: Data?) {
        self.status = status
        self.body = body
    }
}

// Sends the request of the account usage. The app uses SessionUsageFetcher. A test gives a fake,
// so no test reaches the network.
package protocol UsageFetcher: Sendable {
    // Send one GET with the token, with the time limit of the whole request. nil: a fetch error
    // (no answer, a timeout or a cancel).
    func fetch(token: String, timeout: Duration) async -> UsageResponse?
}

// The fetcher of the app. SECURITY: the token goes only to the fixed URL, in the header of one
// request. Each request has its own ephemeral URLSession with no cookies, no cache and no stored
// credentials, and the delegate refuses each redirect. The fetcher logs nothing and keeps no
// error text, because an error text can hold request data.
package struct SessionUsageFetcher: UsageFetcher {
    // Hard-coded. The token goes only to this URL.
    package static let url: URL = {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            preconditionFailure("bad usage URL")
        }
        return url
    }()
    // The beta header that the endpoint needs.
    package static let beta = "oauth-2025-04-20"

    private let get: GuardedGet

    // The configuration of each session. The app uses an ephemeral configuration. A test adds its
    // stub protocol.
    package init(
        configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }
    ) {
        get = GuardedGet(configuration: configuration)
    }

    package func fetch(token: String, timeout: Duration) async -> UsageResponse? {
        let answer = await get.get(
            Self.url, headers: ["Authorization": "Bearer \(token)", "anthropic-beta": Self.beta],
            timeout: timeout, maxBytes: AccountAnswer.maxBytes)
        guard let answer else { return nil }
        return UsageResponse(status: answer.status, body: answer.body)
    }
}
