// The rules of the box alerts (docs/behaviour/alerts.md): the boxes of the rows that are new
// since the last update, and the text of the notification of a box. The mark of a row is its
// SessionAlert. Only the colour and the time of a box make it new. The cause of a red box does
// not.

// A box that is new since the last update of the rows.
package struct NewBox: Sendable, Equatable {
    package var sessionId: String
    package var name: String
    package var alert: SessionAlert
    package var state: SessionState

    package init(sessionId: String, name: String, alert: SessionAlert, state: SessionState) {
        self.sessionId = sessionId
        self.name = name
        self.alert = alert
        self.state = state
    }
}

package enum AlertRules {
    // Show at most this many notifications for one update. More new boxes give one summary.
    package static let maxNotifications = 3
    // The least time between two alert sounds.
    package static let soundGap = Duration.seconds(2)

    // Find the boxes that are new since previous, in the order of the rows. A box is new when its
    // row has no mark in previous, or the mark has another colour or another time. A nil previous
    // is the first update after the start: it only records the marks. A row with no box has no
    // mark, and a session that is not in the rows loses its mark.
    package static func newBoxes(
        _ previous: [String: SessionAlert]?, _ rows: [SessionRow]
    ) -> (marks: [String: SessionAlert], added: [NewBox]) {
        var marks: [String: SessionAlert] = [:]
        var added: [NewBox] = []
        for row in rows where row.alert != .none {
            marks[row.sessionId] = row.alert
            guard let previous else { continue }
            if let mark = previous[row.sessionId], sameBox(mark, row.alert) { continue }
            let box = NewBox(
                sessionId: row.sessionId, name: row.name, alert: row.alert, state: row.state)
            added.append(box)
        }
        return (marks, added)
    }

    // The text of the notification of one box.
    package static func text(_ box: NewBox) -> (title: String, body: String) {
        if case .yellow = box.alert { return (box.name, "Claude finished its turn.") }
        if box.state == .error { return (box.name, "The session stopped with an error.") }
        return (box.name, "Claude needs you.")
    }

    // The text of the one notification for more than maxNotifications new boxes.
    package static func summary(count: Int) -> (title: String, body: String) {
        ("Bifrost", "\(count) sessions need you.")
    }

    // True when the two marks have the same colour and the same time.
    private static func sameBox(_ mark: SessionAlert, _ alert: SessionAlert) -> Bool {
        switch (mark, alert) {
        case (.yellow(let a), .yellow(let b)), (.red(_, let a), .red(_, let b)): a == b
        default: false
        }
    }
}
