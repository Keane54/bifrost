// The rules of the Event log panel (docs/behaviour/panels.md, The Event log panel): the filter,
// the texts of a row, the session labels and the session options.
//
// The panel reads only the names of the session rows (names(_:known:)), not the rows. A row
// changes at each event of its session, and its name changes seldom, so the panel does no work
// for a change that its labels do not show. Each name gets the rule of the texts of the log
// (EventLog.safe), so a label never shows a hidden character or a token.
import Foundation

// The texts of one row of the panel. A notice has no session: its text also takes the session
// column, and its title holds the whole text, because a narrow panel cuts the text.
package struct LogRow: Sendable, Equatable {
    package var session: String?
    package var text: String
    package var title: String?

    package init(session: String?, text: String, title: String?) {
        self.session = session
        self.text = text
        self.title = title
    }
}

// One choice of the Session filter: the row ID and its label.
package struct SessionOption: Sendable, Equatable {
    package var id: String
    package var label: String

    package init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

package enum LogView {
    // The short form of a session ID: its first 8 Characters.
    private static let shortID = 8
    // The compare of the labels: the English order, where case and accents count less than the
    // letters.
    private static let english = Locale(identifier: "en")

    // The entries of one session, or all entries for nil.
    package static func filter(_ entries: [LogEntry], session: String?) -> [LogEntry] {
        guard let session else { return entries }
        return entries.filter { $0.sessionId == session }
    }

    // The name of the event, then the tool in brackets. A notice gives its own text.
    package static func text(_ entry: LogEntry) -> String {
        switch entry.kind {
        case .notice(let text): text
        case .event(_, let name, nil): name.rawValue
        case .event(_, let name, let tool?): "\(name.rawValue) (\(tool))"
        }
    }

    package static func row(_ entry: LogEntry, names: [String: String]) -> LogRow {
        let text = text(entry)
        guard let sessionId = entry.sessionId else {
            return LogRow(session: nil, text: text, title: text)
        }
        return LogRow(session: sessionLabel(sessionId, names: names), text: text, title: nil)
    }

    // The safe name of each session row by row ID (EventLog.safe). The first row of an ID gives
    // its name. known holds the safe form of each name of the last call, so a name that did not
    // change costs no new work. The call keeps in known only the names of these rows.
    package static func names(_ rows: [SessionRow], known: inout [String: String])
        -> [String: String]
    {
        var names: [String: String] = [:]
        var next: [String: String] = [:]
        for row in rows where names[row.sessionId] == nil {
            let safe = next[row.name] ?? known[row.name] ?? EventLog.safe(row.name)
            next[row.name] = safe
            names[row.sessionId] = safe
        }
        known = next
        return names
    }

    // The label of a session: its safe name (names(_:known:)), else the first 8 Characters of
    // its safe ID.
    package static func sessionLabel(_ id: String, names: [String: String]) -> String {
        let name = names[id] ?? ""
        return name.isEmpty ? String(EventLog.safe(id).prefix(shortID)) : name
    }

    // Each session of the entries one time, in the order of the labels. Two equal labels keep
    // the order of their first entry. A notice has no session.
    package static func sessionOptions(_ entries: [LogEntry], names: [String: String])
        -> [SessionOption]
    {
        var seen: Set<String> = []
        var options: [SessionOption] = []
        for case let sessionId? in entries.map(\.sessionId) {
            guard seen.insert(sessionId).inserted else { continue }
            let label = sessionLabel(sessionId, names: names)
            options.append(SessionOption(id: sessionId, label: label))
        }
        return options.sorted {
            $0.label.compare($1.label, range: nil, locale: english) == .orderedAscending
        }
    }
}
