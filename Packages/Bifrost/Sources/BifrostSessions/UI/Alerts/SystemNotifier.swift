import Foundation
import UserNotifications

// The notifier of the app: the notification centre of macOS, for the bundle ID of the app
// (docs/behaviour/alerts.md, "Notifications"). Each show asks for the permission first. macOS
// asks the user only one time, at the first notification, and later gives the answer of the user.
// A refusal or an error calls onFailed of the notification, and the log gets the first refusal of
// the run only.
//
// The notifier keeps the click action of each open notification, at most the newest
// OpenNotifications.limit of them. A click on a notification takes its action. A click on an older
// notification, or on one from an earlier run, only brings the app to the front, as macOS does.
// The notifications show also while the app is active: the alert rules choose when a notification
// shows.
//
// The app makes the notifier before its launch ends, so the notifier is the delegate of the
// centre in time for a click. A test home and the tests of the other parts use RecordingNotifier
// or a fake. The tests of this type give fakes of the two calls of the centre (Centre), so no test
// calls the notification centre.
@MainActor
package final class SystemNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    // The two calls of the notification centre that a show makes: the permission, then the add
    // of the request.
    package struct Centre {
        package var authorize: @MainActor () async throws -> Bool
        package var add: @MainActor (UNNotificationRequest) async throws -> Void

        package init(
            authorize: @escaping @MainActor () async throws -> Bool,
            add: @escaping @MainActor (UNNotificationRequest) async throws -> Void
        ) {
            self.authorize = authorize
            self.add = add
        }
    }

    private let centre: Centre
    private let log: any NotifierLog
    private var open = OpenNotifications<() -> Void>()
    private var refusalLogged = false
    // The task of the last show. A test waits for it.
    package private(set) var lastShow: Task<Void, Never>?

    // The notifier of the app: it becomes the delegate of the notification centre, so it gets
    // each click.
    override package convenience init() {
        let centre = UNUserNotificationCenter.current()
        self.init(
            centre: Centre(
                authorize: { try await centre.requestAuthorization(options: [.alert, .sound]) },
                add: { try await centre.add($0) }))
        centre.delegate = self
    }

    // The seam of the tests: this init never touches the notification centre.
    package init(centre: Centre, log: any NotifierLog = SystemNotifierLog()) {
        self.centre = centre
        self.log = log
        super.init()
    }

    package func show(
        _ note: AlertNote, onClick: @escaping (String?) -> Void, onFailed: @escaping () -> Void
    ) {
        let id = UUID().uuidString
        let sessionId = note.sessionId
        open.add(id) { onClick(sessionId) }
        let request = UNNotificationRequest(
            identifier: id, content: Self.content(note), trigger: nil)
        let centre = centre
        lastShow = Task {
            do {
                guard try await centre.authorize() else { throw NotificationRefusal.notAllowed }
                try await centre.add(request)
                log.record(.showed(note.source))
            } catch {
                _ = open.take(id)
                if !refusalLogged {
                    refusalLogged = true
                    log.record(.refused(detail: String(describing: error)))
                }
                onFailed()
            }
        }
    }

    // The content of the notification. A notification that does not ask for sound is silent.
    nonisolated package static func content(_ note: AlertNote) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.sound = note.sound ? .default : nil
        return content
    }

    // A click on the notification with the ID: its action runs one time. An ID that the list does
    // not have runs nothing.
    func click(id: String) {
        open.take(id)?()
    }

    // MARK: - The delegate

    // A click on a notification runs its action.
    package func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        click(id: response.notification.request.identifier)
    }

    // A notification shows also while the app is active, with its sound only when it has one.
    package func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.content.sound == nil ? [.banner, .list] : [.banner, .list, .sound]
    }
}

// The user did not allow notifications for the app.
private enum NotificationRefusal: Error {
    case notAllowed
}
