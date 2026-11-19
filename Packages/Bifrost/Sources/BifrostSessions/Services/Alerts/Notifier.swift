import BifrostFoundation
import OSLog

// The notifications of the app (docs/behaviour/alerts.md, "Notifications"). Each part that shows
// a notification gives it to the one notifier of the app. The app uses the system notifier
// (SystemNotifier). A test home uses the recorder, which shows no notification, and a test uses a
// fake.

// One notification.
package struct AlertNote: Sendable, Equatable {
    // The part of the app that shows the notification.
    package enum Source: Sendable, Equatable {
        // The new box of the session with this row ID. A click opens the session.
        case box(sessionId: String)
        // A summary of new boxes.
        case boxSummary
        // The usage notification of a limit. A click opens the Usage HUD.
        case usageLimit
        // A Reviews notification. A click opens the Reviews panel.
        case reviews
        // A reminder of the Daily update. A click opens the Daily update panel.
        case dailyUpdate
    }

    package var title: String
    package var body: String
    package var source: Source
    // True lets macOS play its notification sound. Else the notification is silent.
    package var sound: Bool

    package init(title: String, body: String, source: Source, sound: Bool = false) {
        self.title = title
        self.body = body
        self.source = source
        self.sound = sound
    }

    // The session of a box, or nil.
    package var sessionId: String? {
        if case .box(let sessionId) = source { sessionId } else { nil }
    }
}

@MainActor
package protocol Notifier: AnyObject {
    // Show the notification. A click calls onClick with the session of the notification. macOS
    // can refuse the notification, for example when the user does not allow notifications for the
    // app. Then onFailed runs.
    func show(
        _ note: AlertNote, onClick: @escaping (String?) -> Void, onFailed: @escaping () -> Void)
}

// The notifier of a test home: it records each notification and shows none, so a test run never
// shows a notification of macOS. It calls no callback.
@MainActor
package final class RecordingNotifier: Notifier {
    package private(set) var recorded: [AlertNote] = []
    private let log: any NotifierLog

    package init(log: any NotifierLog = SystemNotifierLog()) {
        self.log = log
    }

    package func show(
        _ note: AlertNote, onClick: @escaping (String?) -> Void, onFailed: @escaping () -> Void
    ) {
        recorded.append(note)
        log.record(.recorded(note.source))
    }
}

// The notifier of the app for its home. A test home gets the recorder, so it never makes the
// system notifier. Else system makes the notifier. The app gives this one notifier to each part
// that shows a notification.
@MainActor
package func appNotifier(testHome: Bool, system: () -> any Notifier) -> any Notifier {
    testHome ? RecordingNotifier() : system()
}

// The click actions of the open notifications, oldest first. A new notification past the limit
// drops the action of the oldest one. A click takes the action of its notification one time.
package struct OpenNotifications<Action> {
    // The most open notifications that the list keeps.
    package static var limit: Int { 20 }

    private var actions: [(id: String, action: Action)] = []

    package init() {}

    // The IDs of the open notifications, oldest first.
    package var ids: [String] { actions.map(\.id) }

    package mutating func add(_ id: String, _ action: Action) {
        actions.append((id, action))
        if actions.count > Self.limit { actions.removeFirst(actions.count - Self.limit) }
    }

    // The action of the notification, or nil when the list does not have it. The notification
    // leaves the list.
    package mutating func take(_ id: String) -> Action? {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return nil }
        return actions.remove(at: index).action
    }
}

// What a notifier logs: the show or the record of a notification, with its source, and a
// refusal of macOS with the detail of its error. The system notifier logs only the first refusal
// of a run.
package enum NotifierEvent: Sendable, Equatable {
    case showed(AlertNote.Source)
    case recorded(AlertNote.Source)
    case refused(detail: String)
}

// Where a notifier sends its events. The app uses SystemNotifierLog. A test records the events.
package protocol NotifierLog: Sendable {
    func record(_ event: NotifierEvent)
}

// The log of the notifications in the unified log of macOS. The name of a source is a fixed text
// of the app. A session ID and the detail of an error are private.
package struct SystemNotifierLog: NotifierLog {
    private static let logger = Logger(bifrost: "alerts")

    package init() {}

    package func record(_ event: NotifierEvent) {
        let logger = Self.logger
        switch event {
        case .showed(let name): Self.record("showed", name)
        case .recorded(let name): Self.record("recorded", name)
        case .refused(let detail):
            logger.error("Bifrost cannot show a notification. \(detail, privacy: .private)")
        }
    }

    private static func record(_ verb: String, _ source: AlertNote.Source) {
        switch source {
        case .box(let id):
            logger.info(
                "Bifrost \(verb, privacy: .public) a notification for \(id, privacy: .private).")
        case .boxSummary:
            logger.info("Bifrost \(verb, privacy: .public) a notification for a summary.")
        case .usageLimit:
            logger.info("Bifrost \(verb, privacy: .public) a notification for usage limit.")
        case .reviews:
            logger.info("Bifrost \(verb, privacy: .public) a notification for reviews.")
        case .dailyUpdate:
            logger.info("Bifrost \(verb, privacy: .public) a notification for daily update.")
        }
    }
}
