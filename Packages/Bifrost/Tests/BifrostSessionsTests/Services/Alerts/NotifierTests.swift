import BifrostSessions
import BifrostTestSupport
import Testing

// The notifier of the app (the section "Notifications" of docs/behaviour/alerts.md): the record
// of a test home, the name of a notification in the log and the list of the open notifications.
// No test makes the system notifier.

@MainActor
@Suite("notifier")
struct NotifierTests {
    // A test home records each notification with its source and its sound, shows none, and
    // calls no callback.
    @Test func aTestHomeRecordsAndShowsNone() async throws {
        let notifier = appNotifier(testHome: true) {
            Issue.record("A test home made the system notifier.")
            return FakeNotifier()
        }
        let recorder = try #require(notifier as? RecordingNotifier)
        let usage = AlertNote(title: "t", body: "b", source: .usageLimit)
        let box = AlertNote(title: "u", body: "c", source: .box(sessionId: "s1"), sound: true)
        await confirmation("a callback", expectedCount: 0) { called in
            for note in [usage, box] {
                notifier.show(note, onClick: { _ in called() }, onFailed: { called() })
            }
        }
        #expect(recorder.recorded == [usage, box])
    }

    @Test func aTestHomeNeverMakesTheSystemNotifier() async {
        let fake = FakeNotifier()
        await confirmation("a system notifier", expectedCount: 0) { made in
            _ = appNotifier(testHome: true) {
                made()
                return fake
            }
        }
        await confirmation("a system notifier", expectedCount: 1) { made in
            let normal = appNotifier(testHome: false) {
                made()
                return fake
            }
            #expect(normal === fake)
        }
    }

    // A test home never plays the alert sound aloud. The test gives a counter in place of the
    // real sound.
    @Test func aTestHomePlaysNoSound() async {
        await confirmation("a sound", expectedCount: 0) { played in
            appAlertSound(testHome: true) { played() }()
        }
        await confirmation("a sound", expectedCount: 1) { played in
            appAlertSound(testHome: false) { played() }()
        }
    }

    @Test func aNotificationIsSilentByDefault() {
        let note = AlertNote(title: "t", body: "b", source: .boxSummary)
        #expect(!note.sound)
    }

    // Only a box has a session, which a click opens.
    @Test func onlyABoxHasASession() {
        #expect(AlertNote(title: "t", body: "b", source: .box(sessionId: "s1")).sessionId == "s1")
        #expect(AlertNote(title: "t", body: "b", source: .boxSummary).sessionId == nil)
        #expect(AlertNote(title: "t", body: "b", source: .usageLimit).sessionId == nil)
    }

    @Test func theOpenNotificationsKeepTheNewest20() {
        #expect(OpenNotifications<Int>.limit == 20)
        var open = OpenNotifications<Int>()
        for number in 0...20 { open.add("n\(number)", number) }
        #expect(open.ids == (1...20).map { "n\($0)" })
        #expect(open.take("n0") == nil)
        #expect(open.take("n20") == 20)
    }

    // A click takes the action of its notification one time.
    @Test func aClickedNotificationLeavesTheOpenList() {
        var open = OpenNotifications<Int>()
        open.add("a", 1)
        open.add("b", 2)
        #expect(open.take("a") == 1)
        #expect(open.take("a") == nil)
        #expect(open.ids == ["b"])
    }
}
