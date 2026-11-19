import BifrostSessions

// A notifier that records each notification and keeps its callbacks, so a test can click it or
// refuse it as macOS does. It shows no notification.
@MainActor
package final class FakeNotifier: Notifier {
    package private(set) var shown: [AlertNote] = []
    private var clicks: [(String?) -> Void] = []
    private var failures: [() -> Void] = []

    package init() {}

    package func show(
        _ note: AlertNote, onClick: @escaping (String?) -> Void, onFailed: @escaping () -> Void
    ) {
        shown.append(note)
        clicks.append(onClick)
        failures.append(onFailed)
    }

    // The user clicks the notification at the index.
    package func click(_ index: Int) {
        clicks[index](shown[index].sessionId)
    }

    // macOS refuses the notification at the index.
    package func refuse(_ index: Int) {
        failures[index]()
    }
}
