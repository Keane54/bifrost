import OSLog

// An event of a server on a UnixSocketListener for the log. Each error can hold a path, so it is
// private in the log.
package enum ListenerLogEvent: Sendable, Equatable {
    // The server does not listen, for this reason.
    case notListening(ListenError)
    // The listener failed after the listen, so the server closed.
    case failed(ListenError)
    // The listener closed this number of new connections at once in the last minute: the limit
    // of open connections was full. One event at most each minute.
    case refusedConnections(Int)
}

// Where a server sends its events. The app uses SystemListenerLog. A test records the events.
package protocol ListenerLog: Sendable {
    func record(_ event: ListenerLogEvent)
}

// The log of one server in the unified log of macOS.
package struct SystemListenerLog: ListenerLog {
    private let logger: Logger
    // The fixed name of the server at the start of each line, for example "Live details".
    private let server: String

    package init(category: String, server: String) {
        logger = Logger(bifrost: category)
        self.server = server
    }

    package func record(_ event: ListenerLogEvent) {
        switch event {
        case .notListening(let error):
            logger.error(
                """
                \(server, privacy: .public): the server does not listen. \
                \(error.message, privacy: .private)
                """)
        case .failed(let error):
            logger.error(
                "\(server, privacy: .public): server error. \(error.message, privacy: .private)")
        case .refusedConnections(let count):
            logger.error(
                """
                \(server, privacy: .public): the server closed \(count, privacy: .public) new \
                connections at once in the last minute, because the limit of open connections \
                was full.
                """)
        }
    }
}
