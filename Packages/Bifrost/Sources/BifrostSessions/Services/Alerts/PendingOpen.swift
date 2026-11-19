// The session of a click on a notification while no window shows (docs/behaviour/alerts.md,
// "A click"). Such a click keeps the session, and the next show of the window gives it, one time.
// A newer click replaces the session that waits. Before the first show, no window shows.
package enum PendingOpen: Sendable, Equatable {
    // No window shows. waiting is the session of the last click since the window went, or nil.
    case noWindow(waiting: String?)
    // The window shows, so a click opens its session at once.
    case windowShows

    package init() {
        self = .noWindow(waiting: nil)
    }

    // A click on a notification. Give the session to open now, or nil when it waits for a window.
    package mutating func click(_ sessionId: String) -> String? {
        switch self {
        case .windowShows: return sessionId
        case .noWindow:
            self = .noWindow(waiting: sessionId)
            return nil
        }
    }

    // The window closed. A session that waits keeps waiting.
    package mutating func windowClosed() {
        if self == .windowShows { self = .noWindow(waiting: nil) }
    }

    // The window shows. Give the session that waits, one time.
    package mutating func windowShown() -> String? {
        defer { self = .windowShows }
        if case .noWindow(let waiting) = self { return waiting }
        return nil
    }
}
