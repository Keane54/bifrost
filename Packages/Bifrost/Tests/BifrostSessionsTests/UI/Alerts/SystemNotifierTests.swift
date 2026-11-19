import BifrostTestSupport
import Testing
import UserNotifications

@testable import BifrostSessions

// The system notifier (the section "Notifications" of docs/behaviour/alerts.md): the content of a
// notification, a click and a refusal. The tests give fakes of the two calls of the notification
// centre, so no test calls the centre or shows a notification.

private struct AddFailed: Error {}

// The calls of the centre in a test: the answer of the permission, an error of the add, and the
// ID of each request that the notifier gave to the add.
@MainActor
private final class FakeCentre {
    var allowed = true
    var addFails = false
    private(set) var added: [String] = []

    var centre: SystemNotifier.Centre {
        SystemNotifier.Centre(
            authorize: { [weak self] in self?.allowed ?? false },
            add: { [weak self] request in
                self?.added.append(request.identifier)
                if self?.addFails ?? true { throw AddFailed() }
            })
    }
}

@MainActor
@Suite("system notifier")
struct SystemNotifierTests {
    @Test func aNotificationIsSilentUnlessItAsksForSound() {
        let silent = SystemNotifier.content(
            AlertNote(title: "t", body: "b", source: .box(sessionId: "s1")))
        #expect(silent.title == "t")
        #expect(silent.body == "b")
        #expect(silent.sound == nil)
        let loud = SystemNotifier.content(
            AlertNote(title: "t", body: "b", source: .boxSummary, sound: true))
        #expect(loud.sound == .default)
    }

    // A click runs the action of its notification one time, with its session. A second click on
    // it, and a click on an ID that the notifier does not know, run nothing.
    @Test func aClickRunsTheActionOfItsNotificationOneTime() async throws {
        let fake = FakeCentre()
        let log = Recorder<NotifierEvent>()
        let notifier = SystemNotifier(centre: fake.centre, log: log)
        var clicked: [String?] = []
        notifier.show(
            AlertNote(title: "t", body: "b", source: .box(sessionId: "s1")),
            onClick: { clicked.append($0) },
            onFailed: { Issue.record("The notification was refused.") })
        await notifier.lastShow?.value
        #expect(log.values == [.showed(.box(sessionId: "s1"))])
        let id = try #require(fake.added.first)
        notifier.click(id: "another")
        notifier.click(id: id)
        notifier.click(id: id)
        #expect(clicked == ["s1"])
    }

    // A refusal calls onFailed of each notification, and the log gets only the first refusal of
    // the run. A refused permission adds no request.
    @Test func aRefusalCallsOnFailedEachTimeAndLogsOneTime() async {
        let fake = FakeCentre()
        fake.allowed = false
        let log = Recorder<NotifierEvent>()
        let notifier = SystemNotifier(centre: fake.centre, log: log)
        await confirmation("a refusal", expectedCount: 2) { refused in
            for _ in 0..<2 {
                notifier.show(
                    AlertNote(title: "t", body: "b", source: .boxSummary),
                    onClick: { _ in Issue.record("A refused notification got a click.") },
                    onFailed: { refused() })
                await notifier.lastShow?.value
            }
        }
        #expect(fake.added.isEmpty)
        #expect(log.values.count == 1)
        guard case .refused = log.values.first else {
            Issue.record("The log has no refusal.")
            return
        }
    }

    // A failed add calls onFailed, and the notification leaves the list of the open
    // notifications, so a later click on it runs nothing.
    @Test func aFailedAddDropsTheClickAction() async throws {
        let fake = FakeCentre()
        fake.addFails = true
        let notifier = SystemNotifier(centre: fake.centre, log: Recorder<NotifierEvent>())
        try await confirmation("a refusal") { refused in
            notifier.show(
                AlertNote(title: "t", body: "b", source: .box(sessionId: "s1")),
                onClick: { _ in Issue.record("A failed notification got a click.") },
                onFailed: { refused() })
            await notifier.lastShow?.value
            notifier.click(id: try #require(fake.added.first))
        }
    }
}
