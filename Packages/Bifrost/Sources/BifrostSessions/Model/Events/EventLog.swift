// The Event log (docs/behaviour/panels.md, The Event log): the newest state events of the
// sessions, and the notice lines of Bifrost for the user. The log is in memory only. Nothing goes
// to disk.
//
// Each text of the log is safe to show (EventLog.safe): the tool of an event and the text of a
// notice or a line come from Claude Code or from an error, so the log removes the hidden
// characters and the default-ignorable characters, hides each secret (TokenMask) and cuts the
// text to textMax Characters, in that order. The clean comes before the mask, so an invisible
// character inside a token does not stop the mask. The cut comes after the mask, so a cut never
// leaves a part of a token.
import BifrostFoundation

// One entry of the Event log: a state event of a session, or a notice line of Bifrost.
package struct LogEntry: Sendable, Equatable {
    // What the entry holds.
    package enum Kind: Sendable, Equatable {
        // A state event of a session: the row ID of the session, the event, and the safe text of
        // its tool when it has one.
        case event(sessionId: String, name: HookEventName, tool: String?)
        // A line of Bifrost for the user, with its safe text.
        case notice(String)
    }

    // The number of the entry in the log. The log has its own numbers: they are not the numbers
    // of the mod.
    package var seq: Int
    // The time of the event in milliseconds since 1970 (row D1 of docs/ports/registry).
    package var at: Int
    package var kind: Kind

    // A state event of a session.
    package init(seq: Int, at: Int, sessionId: String, name: HookEventName, tool: String? = nil) {
        self.seq = seq
        self.at = at
        kind = .event(sessionId: sessionId, name: name, tool: tool)
    }

    // A notice line of Bifrost.
    package init(seq: Int, at: Int, notice text: String) {
        self.seq = seq
        self.at = at
        kind = .notice(text)
    }

    // The row ID of the session of an event, or nil for a notice.
    package var sessionId: String? {
        if case .event(let sessionId, _, _) = kind { sessionId } else { nil }
    }

    // The safe text of the tool of an event, or nil for an event with no tool and for a notice.
    package var tool: String? {
        if case .event(_, _, let tool) = kind { tool } else { nil }
    }

    // True for a notice line of Bifrost.
    package var isNotice: Bool {
        if case .notice = kind { true } else { false }
    }
}

package struct EventLog: Sendable {
    // The log keeps this many entries, the newest.
    package static let max = 5000
    // The most Characters of one text of the log. A longer text ends with an ellipsis.
    package static let textMax = 500
    // The line that shows when macOS does not show a notification. A person reads it.
    package static let notificationRefused =
        "macOS didn't show a notification. Allow notifications for Bifrost in System Settings."

    private let limit: Int
    // The entries in the order of their numbers. The log removes the old entries in steps: it
    // can hold up to two times the limit, so an append of one event does not move all entries.
    // entries gives only the newest.
    private var all: [LogEntry] = []
    private var next = 1
    // The texts of the notices that the log made. A notice shows one time.
    private var notices: Set<String> = []

    // A limit below 1 keeps 1 entry.
    package init(max: Int = EventLog.max) {
        limit = Swift.max(max, 1)
    }

    // The newest entries, at most max, in the order of their numbers.
    package var entries: [LogEntry] {
        all.count <= limit ? all : Array(all.suffix(limit))
    }

    // Add one entry for each event. Return the new entries.
    package mutating func append(_ events: [HookEvent]) -> [LogEntry] {
        let added = events.map { event in
            defer { next += 1 }
            return LogEntry(
                seq: next, at: event.at, sessionId: event.sessionId, name: event.name,
                tool: event.toolName.map(Self.safe))
        }
        keep(added)
        return added
    }

    // Add a line for the user one time for each text, for example the line of a refused
    // notification. The log compares the safe text. Return the new entry, or nil when the log
    // had the text before.
    package mutating func notice(_ text: String, at: Int) -> LogEntry? {
        let safe = Self.safe(text)
        guard notices.insert(safe).inserted else { return nil }
        return add(safe, at: at)
    }

    // Add a line for the user each time, for example a line of a Daily update run. Return the
    // new entry.
    package mutating func line(_ text: String, at: Int) -> LogEntry {
        add(Self.safe(text), at: at)
    }

    private mutating func add(_ safe: String, at: Int) -> LogEntry {
        let entry = LogEntry(seq: next, at: at, notice: safe)
        next += 1
        keep([entry])
        return entry
    }

    private mutating func keep(_ added: [LogEntry]) {
        all.append(contentsOf: added)
        if all.count >= 2 * limit { all.removeFirst(all.count - limit) }
    }

    // The text with no hidden or default-ignorable character, with each secret hidden, and cut
    // to textMax Characters. A line break or a tab becomes a space, so the words stay apart. A
    // default-ignorable character (for example a soft hyphen, a word joiner or a variation
    // selector) shows nothing, so it could split a token and stop the mask. A visible mark (a
    // combining accent or a no-break space) stays. The Event log panel gives the names of the
    // session rows the same rule (LogView.names).
    package static func safe(_ text: String) -> String {
        var spaced = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !scalar.properties.isDefaultIgnorableCodePoint {
            spaced.append(isBreak(scalar) ? " " : scalar)
        }
        let masked = TokenMask.mask(withoutHiddenCharacters(String(spaced)), token: nil)
        guard masked.count > textMax else { return masked }
        return String(masked.prefix(textMax - 1)) + "…"
    }

    // A tab, a line break, or the line and paragraph separators.
    private static func isBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x85, 0x2028, 0x2029: true
        default: false
        }
    }
}
