import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

// The time texts (the section "Time texts" of docs/behaviour/usage.md). Each test gives a fixed
// time zone, so the texts do not change with the zone of the computer.

private let utc = TimeZone.gmt

// The zones of the tests. 5 Nov 2026 is in standard time in New York.
private func named(_ id: String) throws -> TimeZone { try #require(TimeZone(identifier: id)) }
private let zoneIDs = ["GMT", "Asia/Tokyo", "Asia/Kolkata", "America/New_York"]

@Suite("time texts")
struct TimeTextTests {
    @Test func theClockIsHoursAndMinutesWithA24HourClock() {
        #expect(TimeText.clock(utcMs(2026, 11, 5, 9, 7), zone: utc) == "09:07")
        #expect(TimeText.clock(utcMs(2026, 11, 5, 0, 5), zone: utc) == "00:05")
        #expect(TimeText.clock(utcMs(2026, 11, 5, 23, 59), zone: utc) == "23:59")
    }

    @Test func theClockUsesTheTimeZone() throws {
        let time = utcMs(2026, 11, 5, 9, 7)
        #expect(TimeText.clock(time, zone: try named("Asia/Tokyo")) == "18:07")
        #expect(TimeText.clock(time, zone: try named("Asia/Kolkata")) == "14:37")
        #expect(TimeText.clock(time, zone: try named("America/New_York")) == "04:07")
    }

    @Test func sameDayComparesTheDateInTheTimeZone() throws {
        let a = utcMs(2026, 11, 5)
        #expect(TimeText.sameDay(a, utcMs(2026, 11, 5, 23, 59), zone: utc))
        #expect(!TimeText.sameDay(a, utcMs(2026, 11, 4, 23, 59), zone: utc))
        #expect(!TimeText.sameDay(a, utcMs(2025, 11, 5), zone: utc))
        // 23:30 UTC on 4 Nov is 08:30 on 5 Nov in Tokyo.
        #expect(TimeText.sameDay(a, utcMs(2026, 11, 4, 23, 30), zone: try named("Asia/Tokyo")))
    }

    @Test func theDayClockIsTheWeekdayAndTheClock() {
        #expect(TimeText.dayClock(utcMs(2026, 11, 5, 14, 3), zone: utc) == "Thu 14:03")
    }

    @Test func clockOrDayGivesTheClockOnTheDayOfNowElseTheDayClock() throws {
        let now = utcMs(2026, 11, 5, 12, 0)
        #expect(TimeText.clockOrDay(utcMs(2026, 11, 5, 14, 5), now: now, zone: utc) == "14:05")
        #expect(TimeText.clockOrDay(utcMs(2026, 11, 5, 0, 0), now: now, zone: utc) == "00:00")
        #expect(TimeText.clockOrDay(utcMs(2026, 11, 6, 13, 0), now: now, zone: utc) == "Fri 13:00")
        #expect(TimeText.clockOrDay(utcMs(2026, 11, 4, 23, 59), now: now, zone: utc) == "Wed 23:59")
        // 23:30 UTC on 5 Nov is 08:30 on 6 Nov in Tokyo, and now is 21:00 on 5 Nov there.
        #expect(
            TimeText.clockOrDay(utcMs(2026, 11, 5, 23, 30), now: now, zone: try named("Asia/Tokyo"))
                == "Fri 08:30")
    }

    @Test func clockMsGivesTheSecondsAndTheMilliseconds() {
        #expect(TimeText.clockMs(utcMs(2026, 11, 5, 9, 7, 3, 45), zone: utc) == "09:07:03.045")
        #expect(TimeText.clockMs(utcMs(2026, 11, 5, 23, 0, 59, 999), zone: utc) == "23:00:59.999")
        #expect(TimeText.clockMs(utcMs(2026, 11, 5, 23, 0, 59, 0), zone: utc) == "23:00:59.000")
        // A time before 1970 counts back from the second before it.
        #expect(TimeText.clockMs(-1, zone: utc) == "23:59:59.999")
    }

    @Test func durationGivesTheUnits() {
        #expect(TimeText.duration(.zero) == "less than 1 min")
        #expect(TimeText.duration(.milliseconds(59_999)) == "less than 1 min")
        #expect(TimeText.duration(.seconds(60)) == "1 min")
        #expect(TimeText.duration(.seconds(3599)) == "59 min")
        #expect(TimeText.duration(.seconds(3720)) == "1 h 02 min")
        #expect(TimeText.duration(.seconds(86_399)) == "23 h 59 min")
        #expect(TimeText.duration(.seconds(86_400)) == "1 d 0 h")
        #expect(TimeText.duration(.seconds(90_000)) == "1 d 1 h")
        #expect(TimeText.duration(.milliseconds(-5)) == "less than 1 min")
    }

    @Test func whenGivesTheClockOnTheDayOfNowElseTheDayAndTheDate() throws {
        let now = utcMs(2026, 11, 5, 12, 0)
        #expect(TimeText.when(utcMs(2026, 11, 5, 9, 7), now: now, zone: utc) == "09:07")
        #expect(TimeText.when(utcMs(2026, 11, 4, 14, 3), now: now, zone: utc) == "Wed 4 Nov 14:03")
        // 23:30 UTC on 4 Nov is already 5 Nov in Tokyo.
        let late = utcMs(2026, 11, 4, 23, 30)
        #expect(TimeText.when(late, now: now, zone: try named("Asia/Tokyo")) == "08:30")
        #expect(TimeText.when(late, now: now, zone: utc) == "Wed 4 Nov 23:30")
    }

    // The names are those of the en_GB locale of the system, whatever the locale of the user.
    // September is "Sep" (row US1 of docs/ports/usage/DELIBERATE-DIFFERENCES.md).
    @Test func theNamesOfTheDaysAndTheMonthsAreEnglish() {
        let days = (2...8).map { TimeText.dayClock(utcMs(2026, 11, $0, 12, 0), zone: utc) }
        #expect(days == ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map { $0 + " 12:00" })
        let now = utcMs(2027, 1, 1)
        let months = (1...12).map {
            TimeText.when(utcMs(2026, $0, 15, 12, 0), now: now, zone: utc).split(separator: " ")[2]
        }
        #expect(
            months == [
                "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
            ])
    }

    @Test func theClockHasNoCommaInEachZoneOfTheTests() throws {
        let now = utcMs(2026, 11, 5, 12, 0)
        let times = [now, utcMs(2026, 11, 4, 23, 30, 5, 7), utcMs(2026, 9, 1, 0, 0)]
        for id in zoneIDs {
            let zone = try named(id)
            for time in times {
                let texts = [
                    TimeText.clock(time, zone: zone), TimeText.dayClock(time, zone: zone),
                    TimeText.clockOrDay(time, now: now, zone: zone),
                    TimeText.clockMs(time, zone: zone), TimeText.when(time, now: now, zone: zone),
                ]
                #expect(texts.allSatisfy { !$0.contains(",") }, "\(id): \(texts)")
            }
        }
    }

    // MARK: - Age

    @Test func theAgeTexts() {
        #expect(
            [0, 59, 60, 3599, 3600, 86_399, 86_400, 172_800].map {
                TimeText.age(since: 0, now: $0 * 1000)
            } == ["0 s", "59 s", "1 min", "59 min", "1 h", "23 h", "1 d", "2 d"])
        // A time before since shows 0 s.
        #expect(TimeText.age(since: 5000, now: 0) == "0 s")
    }

    @Test func theAgeStepIsTheTimeUntilTheAgeTextChanges() {
        let cases: [(since: Int, now: Int, step: Int)] = [
            (0, 30_500, 500), (0, 90_000, 30_000), (0, 3_605_000, 3_595_000),
            (10_000, 9_000, 2_000), (0, 172_200_000, 600_000),
        ]
        for (since, now, step) in cases {
            #expect(TimeText.ageStep(since: since, now: now) == .milliseconds(step), "\(now)")
            let text = TimeText.age(since: since, now: now)
            #expect(TimeText.age(since: since, now: now + step - 1) == text, "\(now)")
            #expect(TimeText.age(since: since, now: now + step) != text, "\(now)")
        }
        #expect(TimeText.ageStep(since: 0, now: 2 * 86_400_000) == .seconds(3600))
        #expect(TimeText.ageStep(since: 0, now: -10 * 3_600_000) == .seconds(3600))
    }

    @Test func aTimeThatOverflowsGivesNoAgeAndAStepOf60Seconds() {
        #expect(TimeText.age(since: Int.min, now: Int.max) == "")
        #expect(TimeText.ageStep(since: Int.min, now: Int.max) == .seconds(60))
        #expect(TimeText.ageStep(since: 1, now: Int.min) == .seconds(60))
    }

    // MARK: - Out of range

    // A time far from 1970 still gives a text, and no text stops the app.
    @Test func aTimeFarOutOfRangeGivesATextAndDoesNotStop() {
        for time in [Int.min, Int.max, -8_640_000_000_000_001, 8_640_000_000_000_001] {
            #expect(!TimeText.clockMs(time, zone: utc).isEmpty)
            #expect(!TimeText.when(time, now: 0, zone: utc).isEmpty)
        }
        #expect(!TimeText.duration(.milliseconds(Int.max)).isEmpty)
    }
}
