import BifrostSessions
import BifrostTestSupport
import Testing

// The core of the alert monitor (the sections "Notifications" and "The alert sound" of
// docs/behaviour/alerts.md): the notifications and the sounds of the new boxes of each update.

private let a = "aaaaaaaa-0000-4000-8000-000000000001"

// The core with the inputs of an update, and each notification and sound so far. A sound records
// the time of the update that played it.
private struct Monitor {
    var core = AlertMonitorCore()
    var now = Duration.zero
    var notifications = true
    var redBoxSound = true
    var focused = false
    var notes: [AlertNote] = []
    var sounds: [Duration] = []

    mutating func update(_ rows: [SessionRow]) {
        core.update(
            rows, now: now, notifications: notifications, redBoxSound: redBoxSound,
            focused: focused)
        for effect in core.takeEffects() {
            switch effect {
            case .notify(let note): notes.append(note)
            case .playSound: sounds.append(now)
            }
        }
    }
}

private func note(_ title: String, _ body: String, _ sessionId: String?) -> AlertNote {
    let source = sessionId.map { AlertNote.Source.box(sessionId: $0) } ?? .boxSummary
    return AlertNote(title: title, body: body, source: source)
}

@Suite("alert monitor core")
struct AlertMonitorCoreTests {
    @Test func theFirstUpdateRecordsTheBoxesAndGivesNoAlert() {
        var monitor = Monitor()
        monitor.update([alertRow(a, .red(.prompt, since: 1000))])
        #expect(monitor.notes.isEmpty)
        #expect(monitor.sounds.isEmpty)
    }

    @Test func aNewYellowBoxGivesANotificationWhenTheWindowIsNotFocused() {
        var monitor = Monitor()
        monitor.update([alertRow(a, .none, name: "bifrost-test-a")])
        monitor.update([alertRow(a, .yellow(since: 1000), name: "bifrost-test-a")])
        #expect(monitor.notes == [note("bifrost-test-a", "Claude finished its turn.", a)])
        #expect(monitor.sounds.isEmpty)
    }

    // A notification of a box is silent, and its source is the box: the alert sound is the sound
    // of a box.
    @Test func aBoxNotificationIsSilentAndHasNoLabel() {
        var monitor = Monitor()
        monitor.update([alertRow(a, .none)])
        monitor.update([alertRow(a, .red(.prompt, since: 1000))])
        #expect(monitor.notes.map(\.sound) == [false])
        #expect(monitor.notes.map(\.source) == [.box(sessionId: a)])
    }

    @Test func noNotificationWhenTheWindowIsFocusedOrTheSettingIsOff() {
        var monitor = Monitor()
        monitor.update([alertRow(a, .none)])
        monitor.focused = true
        monitor.update([alertRow(a, .yellow(since: 1000))])
        #expect(monitor.notes.isEmpty)
        monitor.focused = false
        monitor.notifications = false
        monitor.update([alertRow(a, .yellow(since: 2000))])
        #expect(monitor.notes.isEmpty)
    }

    @Test func aNewRedBoxPlaysTheSoundOneTimeAlsoWhenTheWindowIsFocused() {
        var monitor = Monitor()
        monitor.focused = true
        monitor.update([alertRow(a, .none)])
        monitor.update([alertRow(a, .red(.prompt, since: 1000))])
        #expect(monitor.sounds == [.zero])
        #expect(monitor.notes.isEmpty)
        monitor.now = .seconds(10)
        monitor.redBoxSound = false
        monitor.update([alertRow(a, .red(.prompt, since: 2000))])
        #expect(monitor.sounds == [.zero])
    }

    @Test func anEscalatedBoxIsANewRedBox() {
        var monitor = Monitor()
        monitor.update([alertRow(a, .yellow(since: 1000))])
        monitor.update([alertRow(a, .red(.escalated, since: 601_000))])
        #expect(monitor.notes.map(\.body) == ["Claude needs you."])
        #expect(monitor.sounds.count == 1)
    }

    @Test func theSameBoxInTheNextUpdateGivesNoAlert() {
        var monitor = Monitor()
        monitor.update([alertRow(a, .none)])
        monitor.update([alertRow(a, .red(.prompt, since: 1000))])
        monitor.now = .seconds(5)
        monitor.update([alertRow(a, .red(.prompt, since: 1000), lastActivity: 99)])
        #expect(monitor.notes.count == 1)
        #expect(monitor.sounds == [.zero])
    }

    @Test func aBoxThatClearsAndComesBackIsNew() {
        var monitor = Monitor()
        monitor.update([alertRow(a, .none)])
        monitor.update([alertRow(a, .yellow(since: 1000))])
        monitor.update([alertRow(a, .none)])
        monitor.update([alertRow(a, .yellow(since: 1000))])
        #expect(monitor.notes.count == 2)
    }

    @Test func moreThan3NewBoxesGiveOneSummaryNotification() {
        var monitor = Monitor()
        let ids = alertIds(8)
        monitor.update(ids.map { alertRow($0, .yellow(since: 1000)) })
        monitor.update(ids.map { alertRow($0, .red(.escalated, since: 601_000)) })
        #expect(monitor.notes == [note("Bifrost", "8 sessions need you.", nil)])
        #expect(monitor.sounds.count == 1)
    }

    @Test func threeNewBoxesGiveThreeNotifications() {
        var monitor = Monitor()
        let ids = alertIds(3)
        monitor.update(ids.map { alertRow($0, .none) })
        monitor.update(ids.map { alertRow($0, .yellow(since: 1000)) })
        #expect(monitor.notes.map(\.sessionId) == ids)
    }

    @Test func theSoundPlaysAtMostOnceEach2Seconds() {
        var monitor = Monitor()
        monitor.update([alertRow(a, .none)])
        for (time, since) in [(Duration.zero, 1), (.milliseconds(1500), 2), (.seconds(2), 3)] {
            monitor.now = time
            monitor.update([alertRow(a, .red(.prompt, since: since))])
        }
        #expect(monitor.sounds == [.zero, .seconds(2)])
    }

    // takeEffects gives each effect one time.
    @Test func theEffectsOfAnUpdateComeOneTime() {
        var core = AlertMonitorCore()
        core.update(
            [alertRow(a, .none)], now: .zero, notifications: true, redBoxSound: true,
            focused: false)
        core.update(
            [alertRow(a, .red(.prompt, since: 1))], now: .zero, notifications: true,
            redBoxSound: true, focused: false)
        #expect(core.takeEffects().count == 2)
        #expect(core.takeEffects().isEmpty)
    }
}
