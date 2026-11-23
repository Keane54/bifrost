import BifrostSessions
import BifrostTestSupport
import Testing

// The rules of the box alerts (the sections "New boxes" and "The texts" of
// docs/behaviour/alerts.md): which boxes of the rows are new, and the text of each notification.

private let a = "aaaaaaaa-0000-4000-8000-000000000001"

private func box(_ alert: SessionAlert, _ state: SessionState) -> NewBox {
    NewBox(sessionId: a, name: "bifrost-test-a", alert: alert, state: state)
}

@Suite("alert rules")
struct AlertRulesTests {
    @Test func theLimitsAre3NotificationsAnd2Seconds() {
        #expect(AlertRules.maxNotifications == 3)
        #expect(AlertRules.soundGap == .seconds(2))
    }

    // The first update after the start has no tracks before it, so it only records them. A red
    // box of that update has its sound spent.
    @Test func theFirstUpdateOnlyRecordsTheTracks() {
        let found = AlertRules.newBoxes(
            nil, [alertRow(a, .red(.prompt, since: 5)), alertRow("x2", .none)])
        #expect(found.added.isEmpty)
        #expect(!found.soundDue)
        #expect(found.tracks[a] == AlertTrack(needsYou: true, soundSpent: true))
        #expect(found.tracks["x2"] == AlertTrack())
    }

    @Test func aSessionThatGoesAwayLosesItsTrack() {
        let first = AlertRules.newBoxes(nil, [alertRow(a, .yellow(since: 1))])
        let next = AlertRules.newBoxes(first.tracks, [])
        #expect(next.tracks.isEmpty)
        #expect(next.added.isEmpty)
    }

    // A change of the time, of the colour or of the cause is not a new box in one requirement.
    @Test func aChangeOfTheBoxIsNotANewBoxUntilTheSessionWorks() {
        let previous = AlertRules.newBoxes(nil, [alertRow(a, .yellow(since: 1000))]).tracks
        func added(_ rows: [SessionRow]) -> Int { AlertRules.newBoxes(previous, rows).added.count }
        #expect(added([alertRow(a, .yellow(since: 2000))]) == 0)
        #expect(added([alertRow(a, .red(.escalated, since: 1000))]) == 0)
        #expect(added([alertRow(a, .none)]) == 0)
        #expect(added([alertRow(a, .yellow(since: 2000), state: .working)]) == 1)
        #expect(added([alertRow(a, .yellow(since: 2000), busyAt: 50)]) == 1)
    }

    @Test func theSoundIsDueOneTimeEachRequirementAtTheRedBox() {
        let first = AlertRules.newBoxes(nil, [alertRow(a, .none)])
        let yellow = AlertRules.newBoxes(first.tracks, [alertRow(a, .yellow(since: 1))])
        #expect(yellow.added.count == 1)
        #expect(!yellow.soundDue)
        let red = AlertRules.newBoxes(yellow.tracks, [alertRow(a, .red(.escalated, since: 9))])
        #expect(red.added.isEmpty)
        #expect(red.soundDue)
        let again = AlertRules.newBoxes(red.tracks, [alertRow(a, .red(.prompt, since: 10))])
        #expect(!again.soundDue)
    }

    // A new box keeps the name and the state of its row.
    @Test func theNewBoxesComeInTheOrderOfTheRows() {
        let ids = alertIds(3)
        let previous = AlertRules.newBoxes(nil, ids.map { alertRow($0, .none) }).tracks
        let rows = ids.reversed().map {
            alertRow($0, .red(.prompt, since: 7), name: "n\($0.suffix(1))")
        }
        let found = AlertRules.newBoxes(previous, rows)
        #expect(found.added.map(\.sessionId) == ids.reversed())
        #expect(
            found.added.first
                == NewBox(
                    sessionId: ids[2], name: "n2", alert: .red(.prompt, since: 7),
                    state: .needsYou))
    }

    @Test func theTextsOfAYellowBoxARedBoxAndAnError() {
        let yellow = AlertRules.text(box(.yellow(since: 1), .idle))
        #expect(yellow.title == "bifrost-test-a")
        #expect(yellow.body == "Claude finished its turn.")
        let red = AlertRules.text(box(.red(.prompt, since: 1), .needsYou))
        #expect(red.body == "Claude needs you.")
        #expect(
            AlertRules.text(box(.red(.error, since: 1), .error)).body
                == "The session stopped with an error.")
    }

    @Test func theSummaryNamesTheNumberOfSessions() {
        let summary = AlertRules.summary(count: 8)
        #expect(summary.title == "Bifrost")
        #expect(summary.body == "8 sessions need you.")
    }
}
