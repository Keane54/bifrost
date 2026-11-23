// The core of the alert monitor (docs/behaviour/alerts.md): at each update of the rows it finds
// the new boxes (AlertRules), and gives the notifications and the alert sound as effects. The
// alert service (AlertMonitor) gives it the inputs and runs the effects, so a test checks the
// rules with plain values.

// An effect of an update.
package enum AlertEffect: Sendable, Equatable {
    case notify(AlertNote)
    case playSound
}

package struct AlertMonitorCore: Sendable {
    // The tracks of the last update, or nil before the first update.
    private var tracks: [String: AlertTrack]?
    // The time of the last sound.
    private var lastSound: Duration?
    private var effects: [AlertEffect] = []

    package init() {}

    // An update of the rows. now is the time of the update on the clock of the service. The
    // notifications show only with the setting on and with no focus in the window: at most
    // maxNotifications, else one summary. The sound plays only with its setting on, for a new red
    // box that starts a requirement or turns a yellow box of it red, at most once each soundGap,
    // also when the window has the focus. A session gives one notification and one sound for each
    // requirement, and the requirement ends when the session works again.
    package mutating func update(
        _ rows: [SessionRow], now: Duration, notifications: Bool, redBoxSound: Bool,
        focused: Bool
    ) {
        let found = AlertRules.newBoxes(tracks, rows)
        tracks = found.tracks
        let added = found.added
        if notifications, !focused, !added.isEmpty {
            if added.count <= AlertRules.maxNotifications {
                for box in added { notify(AlertRules.text(box), .box(sessionId: box.sessionId)) }
            } else {
                notify(AlertRules.summary(count: added.count), .boxSummary)
            }
        }
        if redBoxSound, found.soundDue {
            if let lastSound, now - lastSound < AlertRules.soundGap { return }
            lastSound = now
            effects.append(.playSound)
        }
    }

    // The effects since the last call, in order.
    package mutating func takeEffects() -> [AlertEffect] {
        defer { effects = [] }
        return effects
    }

    // A silent notification: the alert sound is the sound of a box.
    private mutating func notify(
        _ text: (title: String, body: String), _ source: AlertNote.Source
    ) {
        effects.append(.notify(AlertNote(title: text.title, body: text.body, source: source)))
    }
}
