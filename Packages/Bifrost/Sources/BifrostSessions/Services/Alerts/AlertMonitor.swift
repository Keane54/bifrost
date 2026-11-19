import BifrostFoundation

// The alert service (docs/behaviour/alerts.md). The shell follows the session rows in their one
// place and gives each change of the rows after the first active poll to rows(_:). The first
// update only records the boxes. For each later new box the service shows a notification
// through the notifier and plays the alert sound, as the core gives.
//
// A click on a notification shows the window, then opens the session of the notification. While
// no window shows, the session waits for the next show of the window (PendingOpen). The shell
// tells the service each show and each close of the window. A refused notification tells the app,
// and the Event log keeps one line for it.
//
// The service reads the settings and the focus of the window at each update. The gap between two
// sounds counts on the injected clock.

// The settings of the alerts.
package struct AlertSettings: Sendable, Equatable {
    package var notifications: Bool
    package var redBoxSound: Bool

    package init(notifications: Bool, redBoxSound: Bool) {
        self.notifications = notifications
        self.redBoxSound = redBoxSound
    }
}

@MainActor
package final class AlertMonitor {
    // The one notifier of the app.
    package let notifier: any Notifier
    // A click on a notification shows the window in front. The shell shows it and then calls
    // windowShown().
    package var showWindow: @MainActor () -> Void = {}
    // Open the session of a clicked notification.
    package var open: @MainActor (String) -> Void = { _ in }
    // macOS refused a notification. The shell adds one line to the Event log.
    package var refused: @MainActor () -> Void = {}
    // True when the window has the focus. The shell reads it from the window, and a test sets
    // it. The default counts the window as not focused.
    package var focused: @MainActor () -> Bool = { false }

    private let sound: @MainActor () -> Void
    private let settings: @MainActor () -> AlertSettings
    private let timeline: Timeline
    private var core = AlertMonitorCore()
    private var pending = PendingOpen()

    // sound plays the alert sound.
    package init(
        notifier: any Notifier, sound: @escaping @MainActor () -> Void,
        settings: @escaping @MainActor () -> AlertSettings, clock: any Clock<Duration>
    ) {
        self.notifier = notifier
        self.sound = sound
        self.settings = settings
        timeline = Timeline(clock)
    }

    // The rows after a change.
    package func rows(_ rows: [SessionRow]) {
        let settings = settings()
        core.update(
            rows, now: timeline.now(), notifications: settings.notifications,
            redBoxSound: settings.redBoxSound, focused: focused())
        for effect in core.takeEffects() {
            switch effect {
            case .notify(let note):
                notifier.show(
                    note, onClick: { [weak self] in self?.clicked($0) },
                    onFailed: { [weak self] in self?.refused() })
            case .playSound:
                sound()
            }
        }
    }

    // The window shows. A session that waits opens now.
    package func windowShown() {
        if let sessionId = pending.windowShown() { open(sessionId) }
    }

    package func windowClosed() {
        pending.windowClosed()
    }

    // A click on a notification: the session of a box, or nil for a summary. The session waits
    // first when no window shows, so the show of the window opens it.
    private func clicked(_ sessionId: String?) {
        let now = sessionId.flatMap { pending.click($0) }
        showWindow()
        if let now { open(now) }
    }
}

// The alert sound of the app for its home. A test home plays no sound, so a test run never plays
// a sound aloud. Else system plays the sound.
package func appAlertSound(
    testHome: Bool, system: @escaping @MainActor () -> Void
) -> @MainActor () -> Void {
    if testHome { return {} }
    return system
}
