// The rules of the box alerts (docs/behaviour/alerts.md): the boxes of the rows that are new
// since the last update, and the text of the notification of a box. The mark of a row is its
// SessionAlert. Only the colour and the time of a box make it new. The cause of a red box does
// not, and neither does a change of its time: a session that needs you gives one alert until it
// works again.

// What the alert service remembers of one session between two updates.
package struct AlertTrack: Sendable, Equatable {
    // True from the first box of a requirement until the session works again.
    package var needsYou = false
    // True when the requirement has had its sound, or its red box was there at the start.
    package var soundSpent = false
    // The last busy sample of the row that the service saw.
    package var busyAt: Int?

    package init(needsYou: Bool = false, soundSpent: Bool = false, busyAt: Int? = nil) {
        self.needsYou = needsYou
        self.soundSpent = soundSpent
        self.busyAt = busyAt
    }
}

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

    // Find the boxes that are new since previous, in the order of the rows. A box is new when it
    // starts a requirement: the row has a box and its last requirement has ended. A requirement
    // ends only when the session works again. Until then a box that clears, comes back, changes
    // its time or changes its cause is the same requirement. The sound is due once for each
    // requirement, when its box is red. A nil previous is the first update after the start: it
    // only records the tracks, and a red box of that update has its sound spent. A session that
    // is not in the rows loses its track.
    package static func newBoxes(
        _ previous: [String: AlertTrack]?, _ rows: [SessionRow]
    ) -> (tracks: [String: AlertTrack], added: [NewBox], soundDue: Bool) {
        var tracks: [String: AlertTrack] = [:]
        var added: [NewBox] = []
        var soundDue = false
        for row in rows {
            var track = previous?[row.sessionId] ?? AlertTrack()
            if works(row, track) {
                track.needsYou = false
                track.soundSpent = false
            }
            track.busyAt = row.lastBusyAt
            defer { tracks[row.sessionId] = track }
            guard row.alert != .none else { continue }
            let isRed = if case .red = row.alert { true } else { false }
            if previous == nil {
                track.needsYou = true
                track.soundSpent = track.soundSpent || isRed
                continue
            }
            if !track.needsYou {
                track.needsYou = true
                added.append(
                    NewBox(
                        sessionId: row.sessionId, name: row.name, alert: row.alert,
                        state: row.state))
            }
            if isRed, !track.soundSpent {
                track.soundSpent = true
                soundDue = true
            }
        }
        return (tracks, added, soundDue)
    }

    // True when the row shows work: it works now, or the registry saw a busy sample since the
    // last update.
    private static func works(_ row: SessionRow, _ track: AlertTrack) -> Bool {
        if row.state == .working || row.status == .busy { return true }
        guard let busyAt = row.lastBusyAt else { return false }
        return busyAt != track.busyAt
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
}
