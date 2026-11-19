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

    // The first update after the start has no marks before it, so it only records the marks. A
    // row with no box has no mark.
    @Test func theFirstUpdateOnlyRecordsTheMarks() {
        let found = AlertRules.newBoxes(
            nil, [alertRow(a, .red(.prompt, since: 5)), alertRow("x2", .none)])
        #expect(found.added.isEmpty)
        #expect(found.marks == [a: .red(.prompt, since: 5)])
    }

    @Test func aSessionThatGoesAwayLosesItsMark() {
        let first = AlertRules.newBoxes(nil, [alertRow(a, .yellow(since: 1))])
        let next = AlertRules.newBoxes(first.marks, [])
        #expect(next.marks.isEmpty)
        #expect(next.added.isEmpty)
    }

    @Test func aChangeOfTheBoxOrOfItsTimeIsANewBox() {
        let previous: [String: SessionAlert] = [a: .yellow(since: 1000)]
        func added(_ alert: SessionAlert) -> Int {
            AlertRules.newBoxes(previous, [alertRow(a, alert)]).added.count
        }
        #expect(added(.yellow(since: 1000)) == 0)
        #expect(added(.yellow(since: 2000)) == 1)
        #expect(added(.red(.escalated, since: 1000)) == 1)
    }

    // Only the colour and the time of a box make it new. The cause of a red box does not.
    @Test func anotherCauseAtTheSameTimeIsTheSameBox() {
        let previous: [String: SessionAlert] = [a: .red(.prompt, since: 1000)]
        let found = AlertRules.newBoxes(previous, [alertRow(a, .red(.error, since: 1000))])
        #expect(found.added.isEmpty)
        #expect(found.marks == [a: .red(.error, since: 1000)])
    }

    // A new box keeps the name and the state of its row.
    @Test func theNewBoxesComeInTheOrderOfTheRows() {
        let ids = alertIds(3)
        let previous = AlertRules.newBoxes(nil, ids.map { alertRow($0, .none) }).marks
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
