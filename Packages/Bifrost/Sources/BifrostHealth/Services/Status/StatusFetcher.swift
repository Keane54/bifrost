import BifrostFoundation
import Foundation

// Reads one status page answer. The app uses SessionStatusFetcher. A test gives a fake, so no test
// reaches the network. nil: no answer (a fetch error, a timeout, a redirect, a status that is not
// 2xx, or a body over StatusPage.maxBytes).
package protocol StatusFetcher: Sendable {
    func fetch(_ url: URL) async -> Data?
}

// The fetcher of the app. The request follows the rules of GuardedGet. No request carries a token
// or data of the user.
package struct SessionStatusFetcher: StatusFetcher {
    private let get: GuardedGet

    // The configuration of each session. The app uses an ephemeral configuration. A test adds its
    // stub protocol.
    package init(
        configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }
    ) {
        get = GuardedGet(configuration: configuration)
    }

    package func fetch(_ url: URL) async -> Data? {
        let answer = await get.get(
            url, headers: ["Accept": "application/json"], timeout: StatusPage.timeout,
            maxBytes: StatusPage.maxBytes)
        guard let answer, answer.isSuccess, !answer.tooLarge else { return nil }
        return answer.body  // nil: the read of the body failed
    }
}
