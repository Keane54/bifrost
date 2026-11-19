import BifrostFoundation
import OSLog

// The reason of a poll of the account usage that gave no new values. It is also the event for the
// log. SECURITY: no event holds a text. Each event is a fixed reason, with an HTTP status at most,
// so no log line can hold the token or the answer.
package enum AccountUsageEvent: Sendable, Hashable {
    // The Keychain read gave no token: no login, an expired token or another shape.
    case noToken
    // 401 or 403: the login has expired. Claude Code refreshes the token itself.
    case loginRefused(status: Int)
    // 429: the poller waits 15 minutes.
    case rateLimited
    // Another status that is not 2xx, also a redirect that the fetcher refused.
    case badStatus(Int)
    // The request got no answer: no network, a timeout or a refused connection.
    case fetchFailed
    // The read of the body failed.
    case readFailed
    // The body is over the limit, is not JSON, or has no good window.
    case badAnswer
    // The poll did not end within its deadline.
    case pastDeadline

    // The result of the poll for the health log.
    package var result: PollResult {
        switch self {
        case .noToken, .loginRefused, .rateLimited: .noData
        case .badStatus, .fetchFailed, .readFailed, .badAnswer, .pastDeadline: .failed
        }
    }

    // True when the poll clears the values. The other reasons keep the old values.
    package var clearsValues: Bool {
        switch self {
        case .loginRefused, .badAnswer: true
        case .noToken, .rateLimited, .badStatus, .fetchFailed, .readFailed, .pastDeadline: false
        }
    }

    // The line of the log, in fixed words and numbers only.
    package var message: String {
        switch self {
        case .noToken: "Account usage: no token, so no request."
        case .loginRefused(let status):
            "Account usage: the login has expired (status \(status)). The next poll tries again."
        case .rateLimited: "Account usage: rate limited (status 429). The next poll is in 15 min."
        case .badStatus(let status): "Account usage: the request failed with status \(status)."
        case .fetchFailed: "Account usage: the request failed with no answer."
        case .readFailed: "Account usage: the read of the answer failed."
        case .badAnswer: "Account usage: the answer is not usable."
        case .pastDeadline: "Account usage: the poll did not end within its deadline."
        }
    }
}

// Where the poller sends its events. The app uses SystemAccountUsageLog. A test records the
// events.
package protocol AccountUsageLog: Sendable {
    func record(_ event: AccountUsageEvent)
}

// The log of the account usage in the unified log of macOS.
package struct SystemAccountUsageLog: AccountUsageLog {
    private static let logger = Logger(bifrost: "usage")

    package init() {}

    package func record(_ event: AccountUsageEvent) {
        let log = Self.logger
        switch event {
        // No login is a normal state, so it does not show in the default log.
        case .noToken:
            log.info("\(event.message, privacy: .public)")
        case .loginRefused, .rateLimited:
            log.notice("\(event.message, privacy: .public)")
        case .badStatus, .fetchFailed, .readFailed, .badAnswer, .pastDeadline:
            log.error("\(event.message, privacy: .public)")
        }
    }
}
