import Foundation
import Testing

@testable import BifrostDailyUpdate

// The reminder rules (docs/behaviour/daily-update.md, "The schedule").
@Suite("the Daily update schedule", .timeLimit(.minutes(1)))
struct DailyScheduleTests {
    private let london = calendar()
    private let fresh = DayMarks.fresh("2026-11-18")

    private func action(
        _ hour: Int, _ minute: Int, _ marks: DayMarks? = nil, _ settings: DailySettings = settings()
    ) -> DailyAction {
        DailySchedule.action(
            now: wednesday(hour, minute), settings, marks ?? fresh, calendar: london)
    }

    @Test func nothingBeforeTheDraftTime() {
        #expect(action(0, 0) == .none)
        #expect(action(9, 29) == .none)
    }

    @Test func theFirstReminderRunsAtTheDraftTime() {
        #expect(action(9, 30) == .run(.first))
        #expect(action(9, 49) == .run(.first))
        var shown = fresh
        shown.firstShown = true
        #expect(action(9, 45, shown) == .none)
    }

    @Test func theSecondComesTenMinutesBeforeTheDeadline() {
        var shown = fresh
        shown.firstShown = true
        #expect(action(9, 49, shown) == .none)
        #expect(action(9, 50, shown) == .notifySecond)
        shown.secondShown = true
        #expect(action(9, 55, shown) == .none)
        #expect(DailySchedule.secondLead == .seconds(600))
        // A start after the first reminder time runs the draft for the second reminder.
        #expect(action(9, 50) == .run(.second))
    }

    @Test func aLateStartRunsOnceWithNoSecondReminder() {
        #expect(action(10, 0) == .run(.late))
        #expect(action(14, 30) == .run(.late))
        var shown = fresh
        shown.firstShown = true
        #expect(action(10, 5, shown) == .none)
        shown = fresh
        shown.secondShown = true
        #expect(action(10, 5, shown) == .none)
    }

    // Follow the minutes of a morning and mark what each action shows, as the service does.
    private func reminders(from start: Int, to end: Int) -> [DailyAction] {
        var marks = fresh
        var fired: [DailyAction] = []
        for minute in start...end {
            let next = action(minute / 60, minute % 60, marks)
            switch next {
            case .none: continue
            case .run(.first), .run(.late): marks.firstShown = true
            case .run(.second), .notifySecond: marks.secondShown = true
            }
            fired.append(next)
        }
        return fired
    }

    @Test func neverTheFirstAndSecondTogether() {
        #expect(reminders(from: 9 * 60, to: 10 * 60 + 30) == [.run(.first), .notifySecond])
        // The Mac wakes after the first reminder time: the second reminder is the only one.
        #expect(reminders(from: 9 * 60 + 55, to: 10 * 60 + 30) == [.run(.second)])
        // The start after the deadline gives the late run and nothing else.
        #expect(reminders(from: 10 * 60 + 5, to: 12 * 60) == [.run(.late)])
    }

    @Test func aSkippedOrSentDayHasNoReminder() {
        var skipped = fresh
        skipped.skipped = true
        #expect(action(9, 40, skipped) == .none)
        var sent = fresh
        sent.sent["area-1"] = wednesday(9, 35)
        #expect(action(9, 40, sent) == .none)
        // An area that is off does not need a send.
        let both = settings(areas: [areaOne, WorkArea(id: "area-2", on: false, name: "Beta")])
        #expect(action(9, 40, sent, both) == .none)
        let two = settings(areas: [areaOne, WorkArea(id: "area-2", name: "Beta")])
        #expect(action(9, 40, sent, two) == .run(.first))
    }

    @Test func aDayThatIsNotDueHasNone() {
        let saturday = moment(2026, 11, 21, 9, 40, in: london)
        let marks = DayMarks.fresh("2026-11-21")
        #expect(DailySchedule.action(now: saturday, settings(), marks, calendar: london) == .none)
        #expect(action(9, 40, fresh, settings(areas: [])) == .none)
        #expect(
            action(9, 40, fresh, settings(areas: [WorkArea(id: "x", on: false, name: "X")]))
                == .none)
        // The marks of an earlier day count as fresh marks.
        var yesterday = DayMarks.fresh("2026-11-17")
        yesterday.skipped = true
        #expect(action(9, 40, yesterday) == .run(.first))
    }

    @Test func theMarkerStaysUntilMidnight() {
        func marker(_ now: Date, _ marks: DayMarks) -> Bool {
            DailySchedule.showsMarker(now: now, settings(), marks, calendar: london)
        }
        #expect(!marker(wednesday(9, 29), fresh))
        #expect(marker(wednesday(9, 30), fresh))
        #expect(marker(wednesday(23, 59), fresh))
        var shown = fresh
        shown.firstShown = true
        shown.secondShown = true
        #expect(marker(wednesday(23, 59), shown))
        var sent = fresh
        sent.sent["area-1"] = wednesday(9, 35)
        #expect(!marker(wednesday(9, 40), sent))
        // After midnight the day is a new day: the old marks are fresh marks, so no marker yet.
        let thursday = moment(2026, 11, 19, 0, 0, in: london)
        #expect(!marker(thursday, shown))
        #expect(marker(moment(2026, 11, 19, 9, 30, in: london), shown))
    }

    @Test func nextWakeSkipsTheMissingHourOfASpringChange() throws {
        let newYork = calendar("America/New_York")
        var plan = settings()
        plan.draftTime = ClockTime(hour: 2, minute: 30)
        let now = moment(2026, 3, 8, 0, 30, in: newYork)
        let wake = try #require(
            DailySchedule.nextWake(after: now, plan, .fresh("2026-03-08"), calendar: newYork))
        #expect(wake > now)
        let parts = newYork.dateComponents([.day, .hour], from: wake)
        #expect(parts.day == 8)
        #expect(parts.hour == 3)
    }

    @Test func nextWakeAtAnAutumnChangeComesOnce() throws {
        let newYork = calendar("America/New_York")
        var plan = settings()
        plan.draftTime = ClockTime(hour: 1, minute: 30)
        let marks = DayMarks.fresh("2026-11-01")
        let start = moment(2026, 11, 1, 0, 0, in: newYork)
        let first = try #require(
            DailySchedule.nextWake(after: start, plan, marks, calendar: newYork))
        #expect(first.timeIntervalSince(start) == 90 * 60)
        // The next wake is not the second 01:30 of the same night.
        let second = try #require(
            DailySchedule.nextWake(after: first, plan, marks, calendar: newYork))
        #expect(second.timeIntervalSince(first) > 3 * 3600)
        #expect(newYork.component(.hour, from: second) == 9)
    }

    @Test func nextWakeIsTheNearestOfTheFourTimes() throws {
        func wake(_ hour: Int, _ minute: Int) -> Date? {
            DailySchedule.nextWake(
                after: wednesday(hour, minute), settings(), fresh, calendar: london)
        }
        #expect(wake(8, 0) == wednesday(9, 30))
        #expect(wake(9, 30) == wednesday(9, 50))
        #expect(wake(9, 50) == wednesday(10, 0))
        #expect(wake(10, 0) == moment(2026, 11, 19, 0, 0, in: london))
    }

    @Test func sinceIsTheLastSendOrTheStartOfTheLastDueDay() {
        let sent = wednesday(9, 5)
        #expect(
            DailySchedule.since(
                now: wednesday(9, 40), days: [1, 2, 3], lastSent: sent, calendar: london)
                == sent)
        #expect(
            DailySchedule.since(
                now: wednesday(9, 40), days: [1, 2, 3, 4, 5], lastSent: nil, calendar: london)
                == moment(2026, 11, 17, 0, 0, in: london))
        // Monday looks back to Friday.
        let monday = moment(2026, 11, 16, 9, 40, in: london)
        #expect(
            DailySchedule.since(
                now: monday, days: [1, 2, 3, 4, 5], lastSent: nil, calendar: london)
                == moment(2026, 11, 13, 0, 0, in: london))
        // One due day in the week looks back 7 days.
        #expect(
            DailySchedule.since(now: wednesday(9, 40), days: [3], lastSent: nil, calendar: london)
                == moment(2026, 11, 11, 0, 0, in: london))
    }
}
