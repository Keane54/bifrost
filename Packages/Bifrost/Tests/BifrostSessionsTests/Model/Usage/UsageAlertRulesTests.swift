import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

// The rules of the usage notification (the section "The usage notification" of
// docs/behaviour/usage.md). The zone is UTC, so the reset times do not change with the zone of the
// computer.

private let now = utcMs(2026, 11, 10, 12, 0)
private let minute = 60_000
private let hour = 60 * minute
private let day = 24 * hour
private let utc = TimeZone.gmt
private let fiveReset = now + 2 * hour + 5 * minute
private let sevenReset = now + 3 * day + hour

private func five(_ usedPercent: Double, resetsAt: Int = fiveReset) -> RateLimits {
    RateLimits(fiveHour: RateWindow(usedPercent: usedPercent, resetsAt: resetsAt))
}

private func periods(five: Int? = nil, seven: Int? = nil) -> NotifiedPeriods {
    NotifiedPeriods(fiveHour: five, sevenDay: seven)
}

private func alert(_ limit: LimitID, _ usedPercent: Double, _ resetsAt: Int) -> UsageAlert {
    UsageAlert(limit: limit, usedPercent: usedPercent, resetsAt: resetsAt)
}

@Suite("usage alert rules")
struct UsageAlertRulesTests {
    // MARK: - The period

    @Test func aLimitWithNoNotifiedPeriodHasANewPeriod() {
        #expect(UsageAlertRules.isNewPeriod(fiveReset, kept: nil))
    }

    @Test func aResetTimeUpTo15MinutesAfterTheKeptValueIsTheSamePeriod() {
        #expect(UsageAlertRules.samePeriod == .seconds(15 * 60))
        #expect(!UsageAlertRules.isNewPeriod(fiveReset, kept: fiveReset))
        #expect(!UsageAlertRules.isNewPeriod(fiveReset + 15 * minute, kept: fiveReset))
        #expect(UsageAlertRules.isNewPeriod(fiveReset + 15 * minute + 1, kept: fiveReset))
        #expect(UsageAlertRules.isNewPeriod(fiveReset + 5 * hour, kept: fiveReset))
    }

    @Test func aResetTimeBeforeTheKeptValueIsNotANewPeriod() {
        #expect(!UsageAlertRules.isNewPeriod(fiveReset - minute, kept: fiveReset))
        #expect(!UsageAlertRules.isNewPeriod(fiveReset - 5 * hour, kept: fiveReset))
    }

    // The times come from a file and from the usage lines, so the extreme values must not trap.
    @Test func extremeTimesDoNotOverflow() {
        #expect(!UsageAlertRules.isNewPeriod(.max, kept: .max))
        #expect(UsageAlertRules.isNewPeriod(.max, kept: .min))
        #expect(!UsageAlertRules.isNewPeriod(.min, kept: .max))
        let far = RateLimits(fiveHour: RateWindow(usedPercent: 95, resetsAt: .max))
        #expect(UsageAlertRules.due(far, periods(five: .max - 1), now: now) == [])
        #expect(UsageAlertRules.follow(far, periods(five: .max - 1), now: now).fiveHour == .max)
        #expect(UsageAlertRules.parse(["fiveHour": .int(.max)], now: .max).fiveHour == .max)
        #expect(UsageAlertRules.parse(["fiveHour": .int(.max)], now: .min).fiveHour == nil)
    }

    // MARK: - The alerts that are due

    @Test func aLimitAt90PercentOrMoreNotifies() {
        #expect(
            UsageAlertRules.due(five(90), NotifiedPeriods(), now: now) == [
                alert(.fiveHour, 90, fiveReset)
            ])
        #expect(UsageAlertRules.due(five(100), NotifiedPeriods(), now: now).count == 1)
    }

    // The rule uses the rounded percent, as the colour of the HUD does, so the two agree.
    @Test func aRoundedValueOf90PercentNotifiesAndTheRawValueStaysInTheAlert() {
        #expect(
            UsageAlertRules.due(five(89.5), NotifiedPeriods(), now: now) == [
                alert(.fiveHour, 89.5, fiveReset)
            ])
    }

    @Test func aLimitBelow90PercentDoesNotNotify() {
        #expect(UsageAlertRules.due(five(89.4), NotifiedPeriods(), now: now) == [])
        #expect(UsageAlertRules.due(five(0), NotifiedPeriods(), now: now) == [])
        #expect(UsageAlertRules.due(RateLimits(), NotifiedPeriods(), now: now) == [])
    }

    @Test func bothLimitsCanNotifyAtTheSameTimeTheFiveHourLimitFirst() {
        let limits = RateLimits(
            fiveHour: RateWindow(usedPercent: 91, resetsAt: fiveReset),
            sevenDay: RateWindow(usedPercent: 95, resetsAt: sevenReset))
        #expect(
            UsageAlertRules.due(limits, NotifiedPeriods(), now: now) == [
                alert(.fiveHour, 91, fiveReset), alert(.sevenDay, 95, sevenReset),
            ])
    }

    @Test func aWindowWhoseResetTimePassedDoesNotNotify() {
        #expect(UsageAlertRules.due(five(95, resetsAt: now), NotifiedPeriods(), now: now) == [])
        #expect(
            UsageAlertRules.due(five(95, resetsAt: now - hour), NotifiedPeriods(), now: now) == [])
        #expect(
            UsageAlertRules.due(five(95, resetsAt: now + 1), NotifiedPeriods(), now: now).count
                == 1)
    }

    // A percent that is not a number does not notify. An infinite percent is above 90.
    @Test func aPercentThatIsNotANumberDoesNotNotify() {
        #expect(UsageAlertRules.due(five(.nan), NotifiedPeriods(), now: now) == [])
        #expect(UsageAlertRules.due(five(-.infinity), NotifiedPeriods(), now: now) == [])
        #expect(UsageAlertRules.due(five(.infinity), NotifiedPeriods(), now: now).count == 1)
    }

    @Test func aLimitNotifiesOneTimeInEachPeriod() {
        let notified = periods(five: fiveReset)
        #expect(UsageAlertRules.due(five(95), notified, now: now) == [])
        // The other source can give a reset time that is a little later for the same period.
        #expect(
            UsageAlertRules.due(five(95, resetsAt: fiveReset + 10 * minute), notified, now: now)
                == [])
        // The next period notifies again.
        let next = fiveReset + 5 * hour
        #expect(
            UsageAlertRules.due(five(92, resetsAt: next), notified, now: now) == [
                alert(.fiveHour, 92, next)
            ])
    }

    @Test func eachLimitKeepsItsOwnPeriod() {
        let limits = RateLimits(
            fiveHour: RateWindow(usedPercent: 91, resetsAt: fiveReset),
            sevenDay: RateWindow(usedPercent: 95, resetsAt: sevenReset))
        let due = UsageAlertRules.due(limits, periods(five: fiveReset), now: now)
        #expect(due.map(\.limit) == [.sevenDay])
    }

    // MARK: - The kept period follows a later reset time

    @Test func aLaterResetTimeInTheSamePeriodRaisesTheKeptValue() {
        let kept = periods(five: fiveReset)
        #expect(
            UsageAlertRules.follow(five(95, resetsAt: fiveReset + 10 * minute), kept, now: now)
                == periods(five: fiveReset + 10 * minute))
        #expect(
            UsageAlertRules.follow(five(95, resetsAt: fiveReset + 15 * minute), kept, now: now)
                .fiveHour == fiveReset + 15 * minute)
        // The percent does not matter, because the reset time tells the period.
        #expect(
            UsageAlertRules.follow(five(40, resetsAt: fiveReset + minute), kept, now: now).fiveHour
                == fiveReset + minute)
    }

    @Test func otherValuesKeepTheKeptValue() {
        let kept = periods(five: fiveReset)
        // An earlier or equal reset time, and a new period.
        #expect(
            UsageAlertRules.follow(five(95, resetsAt: fiveReset - minute), kept, now: now) == kept)
        #expect(UsageAlertRules.follow(five(95), kept, now: now) == kept)
        #expect(
            UsageAlertRules.follow(
                five(95, resetsAt: fiveReset + 15 * minute + 1), kept, now: now) == kept)
        // No kept value, no window, and a window whose reset time passed.
        #expect(
            UsageAlertRules.follow(five(95), NotifiedPeriods(), now: now) == NotifiedPeriods())
        #expect(UsageAlertRules.follow(RateLimits(), kept, now: now) == kept)
        let past = periods(five: now - 2 * hour)
        #expect(UsageAlertRules.follow(five(95, resetsAt: now - hour), past, now: now) == past)
    }

    @Test func theRulesKeepTheUnknownFields() {
        var kept = periods(five: fiveReset)
        kept.unknown = UnknownFields(["later": true])
        let followed = UsageAlertRules.follow(
            five(95, resetsAt: fiveReset + minute), kept, now: now)
        #expect(followed.unknown == kept.unknown)
        let after = UsageAlertRules.after(kept, [alert(.sevenDay, 90, sevenReset)])
        #expect(after.unknown == kept.unknown)
    }

    // MARK: - The periods after the alerts

    @Test func afterKeepsTheResetTimeOfEachAlertAndTheOtherValues() {
        #expect(
            UsageAlertRules.after(periods(five: fiveReset), [alert(.sevenDay, 90, sevenReset)])
                == periods(five: fiveReset, seven: sevenReset))
        #expect(UsageAlertRules.after(NotifiedPeriods(), []) == NotifiedPeriods())
    }

    // MARK: - The texts

    private let fiveAlert = alert(.fiveHour, 91.6, fiveReset)
    private let sevenAlert = alert(.sevenDay, 95, utcMs(2026, 11, 13, 13, 0))

    @Test func extraUsageOffGivesTheLimitAndTheResetTime() {
        let five = UsageAlertRules.text(fiveAlert, extraUsage: false, now: now, zone: utc)
        #expect(five.title == "5-hour limit at 92%")
        #expect(five.body == "Claude Code stops at 100% until the limit resets at 14:05.")
        let seven = UsageAlertRules.text(sevenAlert, extraUsage: false, now: now, zone: utc)
        #expect(seven.title == "7-day limit at 95%")
        #expect(seven.body == "Claude Code stops at 100% until the limit resets at Fri 13:00.")
    }

    @Test func extraUsageOnGivesAClearWarningAboutRealMoney() {
        let five = UsageAlertRules.text(fiveAlert, extraUsage: true, now: now, zone: utc)
        #expect(five.title == "Warning: extra usage is on")
        #expect(
            five.body
                == "Your 5-hour limit is at 92%. After 100%, Claude Code spends your extra usage "
                + "credits, which costs real money. It resets at 14:05.")
        let seven = UsageAlertRules.text(sevenAlert, extraUsage: true, now: now, zone: utc)
        #expect(seven.title == "Warning: extra usage is on")
        #expect(
            seven.body
                == "Your 7-day limit is at 95%. After 100%, Claude Code spends your extra usage "
                + "credits, which costs real money. It resets at Fri 13:00.")
    }

    @Test func theResetTimeUsesTheZone() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        // 14:05 UTC on 10 November is 23:05 in Tokyo, the same day as now there (21:00).
        #expect(
            UsageAlertRules.text(fiveAlert, extraUsage: false, now: now, zone: tokyo).body
                == "Claude Code stops at 100% until the limit resets at 23:05.")
    }

    @Test func thePercentIsTheRoundedValueCappedAt100() {
        func title(_ usedPercent: Double) -> String {
            UsageAlertRules.text(
                alert(.fiveHour, usedPercent, fiveReset), extraUsage: false, now: now, zone: utc
            ).title
        }
        #expect(title(90) == "5-hour limit at 90%")
        #expect(title(99.5) == "5-hour limit at 100%")
        #expect(title(130) == "5-hour limit at 100%")
        #expect(title(.infinity) == "5-hour limit at 100%")
        // No alert has these values. The text does not trap on them.
        #expect(title(.nan) == "5-hour limit at 0%")
        #expect(title(-.infinity) == "5-hour limit at 0%")
    }

    @Test func noTextHasAnEmDash() {
        for extraUsage in [false, true] {
            for alert in [fiveAlert, sevenAlert] {
                let text = UsageAlertRules.text(
                    alert, extraUsage: extraUsage, now: now, zone: utc)
                #expect(!"\(text.title) \(text.body)".contains("\u{2014}"))
            }
        }
    }

    // MARK: - The parse of usage-alerts.json

    @Test func theParseKeepsEachWholeNumberAndGivesNilForEachOtherValue() {
        let five = utcMs(2026, 11, 10, 14, 5)
        let seven = utcMs(2026, 11, 13, 13, 0)
        #expect(
            UsageAlertRules.parse(["fiveHour": .int(five), "sevenDay": .int(seven)], now: now)
                == periods(five: five, seven: seven))
        var withUnknown = periods(seven: seven)
        withUnknown.unknown = UnknownFields(["x": 1])
        #expect(
            UsageAlertRules.parse(["fiveHour": "1", "sevenDay": .int(seven), "x": 1], now: now)
                == withUnknown)
        // A whole number in the double form is a whole number. A fraction is not a time of the
        // file.
        #expect(
            UsageAlertRules.parse(["fiveHour": .double(Double(five)), "sevenDay": 1.5], now: now)
                == periods(five: five))
        #expect(
            UsageAlertRules.parse(["fiveHour": .null, "sevenDay": 1e300], now: now)
                == NotifiedPeriods())
        let bad: [JSONValue?] = [nil, .null, 7, "x", [.int(five)], [:]]
        for value in bad { #expect(UsageAlertRules.parse(value, now: now) == NotifiedPeriods()) }
    }

    // A 7-day window resets within 7 days. A kept value far in the future is bad, and it would
    // stop each notification of that limit until that time.
    @Test func theParseGivesNilForAKeptValueMoreThan8DaysAfterNow() {
        #expect(UsageAlertRules.maxKeptAhead == .seconds(8 * 24 * 3600))
        let value: JSONValue = [
            "fiveHour": .int(now + 8 * day + 1), "sevenDay": .int(now + 8 * day),
        ]
        #expect(UsageAlertRules.parse(value, now: now) == periods(seven: now + 8 * day))
        // A kept value in the past is a period that ended. It stays.
        let past = UsageAlertRules.parse(["fiveHour": .int(now - day)], now: now)
        #expect(past.fiveHour == now - day)
    }
}
