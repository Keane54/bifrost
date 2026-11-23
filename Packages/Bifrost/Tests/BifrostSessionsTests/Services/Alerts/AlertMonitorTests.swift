import BifrostSessions
import BifrostTestSupport
import Testing

// The alert service (docs/behaviour/alerts.md): it gives the rows to the core, shows the
// notifications through the notifier, plays the sound, and shows the window and opens the
// session of a click. The notifier is a fake, and the sound is a counter, so no test shows a
// notification or plays a sound.

private let a = "aaaaaaaa-0000-4000-8000-000000000001"

// What the monitor asks of the app, in order.
private enum AppCall: Equatable {
    case sound, showWindow, open(String), refused
}

// A monitor with a fake notifier, the settings and the focus of the test, a manual clock, and
// the calls to the app. The window shows at the start, as in the app. A show of the window tells
// the monitor, as the shell does.
@MainActor
private final class Scope {
    let notifier = FakeNotifier()
    let clock = ManualClock()
    var settings = AlertSettings(notifications: true, redBoxSound: true)
    var focused = false
    var calls: [AppCall] = []
    private(set) var monitor: AlertMonitor?

    init() {
        let monitor = AlertMonitor(
            notifier: notifier, sound: { [weak self] in self?.calls.append(.sound) },
            settings: { [weak self] in
                self?.settings ?? AlertSettings(notifications: false, redBoxSound: false)
            }, clock: clock)
        monitor.focused = { [weak self] in self?.focused ?? true }
        monitor.showWindow = { [weak self, weak monitor] in
            self?.calls.append(.showWindow)
            monitor?.windowShown()
        }
        monitor.open = { [weak self] in self?.calls.append(.open($0)) }
        monitor.refused = { [weak self] in self?.calls.append(.refused) }
        monitor.windowShown()
        self.monitor = monitor
    }

    // The first update only records the marks, so the box of the second update is new.
    func newBox(_ alert: SessionAlert, sessionId: String = a) {
        monitor?.rows([alertRow(sessionId, .none)])
        monitor?.rows([alertRow(sessionId, alert)])
    }
}

@MainActor
@Suite("alert monitor")
struct AlertMonitorTests {
    @Test func aBoxWhileTheWindowHasFocusShowsNoNotification() {
        let scope = Scope()
        scope.focused = true
        scope.newBox(.yellow(since: 1000))
        #expect(scope.notifier.shown.isEmpty)
    }

    @Test func aBoxWhileTheWindowHasNoFocusShowsOneNotification() {
        let scope = Scope()
        scope.newBox(.yellow(since: 1000))
        #expect(
            scope.notifier.shown == [
                AlertNote(
                    title: "bifrost-test-1", body: "Claude finished its turn.",
                    source: .box(sessionId: a))
            ])
        #expect(scope.calls.isEmpty)
    }

    // The monitor reads the settings at each update.
    @Test func theSettingsOfEachUpdateApply() {
        let scope = Scope()
        scope.settings = AlertSettings(notifications: false, redBoxSound: false)
        scope.newBox(.red(.prompt, since: 1000))
        #expect(scope.notifier.shown.isEmpty)
        #expect(scope.calls.isEmpty)
        scope.settings = AlertSettings(notifications: true, redBoxSound: true)
        scope.monitor?.rows([alertRow(a, .none, state: .working)])
        scope.monitor?.rows([alertRow(a, .red(.prompt, since: 2000))])
        #expect(scope.notifier.shown.count == 1)
        #expect(scope.calls == [.sound])
    }

    // The gap between two sounds counts on the clock of the monitor.
    @Test func theSoundGapCountsOnTheClock() {
        let scope = Scope()
        scope.newBox(.red(.prompt, since: 1))
        let b = "bbbbbbbb-0000-4000-8000-000000000002"
        let first = alertRow(a, .red(.prompt, since: 1))
        scope.clock.advance(by: .milliseconds(1999))
        scope.monitor?.rows([first, alertRow(b, .none)])
        scope.monitor?.rows([first, alertRow(b, .red(.prompt, since: 2))])
        #expect(scope.calls == [.sound])
        scope.clock.advance(by: .milliseconds(1))
        scope.monitor?.rows([first, alertRow(b, .none, state: .working)])
        scope.monitor?.rows([first, alertRow(b, .red(.prompt, since: 3))])
        #expect(scope.calls == [.sound, .sound])
    }

    // With the window open, a click shows the window in front, then opens the session.
    @Test func aClickShowsTheWindowThenOpensTheSession() {
        let scope = Scope()
        scope.newBox(.yellow(since: 1000))
        scope.notifier.click(0)
        #expect(scope.calls == [.showWindow, .open(a)])
    }

    // With no window, the click opens the window, and the session opens when the window shows,
    // one time.
    @Test func aClickWithNoWindowOpensTheSessionWhenTheWindowShows() {
        let scope = Scope()
        scope.newBox(.yellow(since: 1000))
        scope.monitor?.windowClosed()
        scope.notifier.click(0)
        #expect(scope.calls == [.showWindow, .open(a)])
        scope.monitor?.windowClosed()
        scope.monitor?.windowShown()
        #expect(scope.calls == [.showWindow, .open(a)])
    }

    // A click on the summary of more than 3 boxes shows the window and opens no session.
    @Test func aClickOnASummaryOpensNoSession() {
        let scope = Scope()
        let ids = alertIds(4)
        scope.monitor?.rows(ids.map { alertRow($0, .none) })
        scope.monitor?.rows(ids.map { alertRow($0, .yellow(since: 1000)) })
        #expect(scope.notifier.shown.map(\.sessionId) == [nil])
        scope.notifier.click(0)
        #expect(scope.calls == [.showWindow])
    }

    // Each refusal tells the app. The Event log keeps its line one time.
    @Test func aRefusedNotificationTellsTheApp() {
        let scope = Scope()
        scope.newBox(.yellow(since: 1000))
        scope.monitor?.rows([alertRow(a, .none, state: .working)])
        scope.monitor?.rows([alertRow(a, .yellow(since: 2000))])
        scope.notifier.refuse(0)
        scope.notifier.refuse(1)
        #expect(scope.calls == [.refused, .refused])
    }

    @Test func aShownNotificationTellsTheAppNothing() {
        let scope = Scope()
        scope.newBox(.yellow(since: 1000))
        #expect(scope.notifier.shown.count == 1)
        #expect(scope.calls.isEmpty)
    }

    // A test home records each notification and shows none.
    @Test func aTestHomeRecordsTheNotificationsOfTheBoxes() async throws {
        try await confirmation("a system notifier or a sound", expectedCount: 0) { made in
            let notifier = appNotifier(testHome: true) {
                made()
                return FakeNotifier()
            }
            let monitor = AlertMonitor(
                notifier: notifier, sound: appAlertSound(testHome: true) { made() },
                settings: { AlertSettings(notifications: true, redBoxSound: true) },
                clock: ManualClock())
            monitor.rows([alertRow(a, .none)])
            monitor.rows([alertRow(a, .red(.prompt, since: 1000))])
            let recorder = try #require(notifier as? RecordingNotifier)
            #expect(recorder.recorded.map(\.body) == ["Claude needs you."])
        }
    }
}
