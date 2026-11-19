import BifrostLook
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

// The bars and the texts of the Usage HUD (the section "The Usage HUD" of
// docs/behaviour/usage.md). The zone is UTC, so the reset times do not change with the zone of
// the computer.

private let now = utcMs(2026, 11, 5, 12, 0)
private let minute = 60_000
private let hour = 60 * minute
private let day = 24 * hour
private let utc = TimeZone.gmt

private func snap(_ limits: RateLimits, updatedAt: Int = now - 2 * minute) -> UsageSnapshot {
    UsageSnapshot(
        sessionId: "abcdef12-0000", name: "bifrost-test-a", updatedAt: updatedAt, limits: limits)
}

private func five(_ usedPercent: Double, resetsAt: Int = now + hour) -> RateLimits {
    RateLimits(fiveHour: RateWindow(usedPercent: usedPercent, resetsAt: resetsAt))
}

private func view(_ snapshot: UsageSnapshot?, account: AccountUsage? = nil)
    -> (bars: [UsageBar], source: String)
{
    UsageView.of(snapshot, now: now, account: account, zone: utc)
}

@Suite("usage view")
struct UsageViewTests {
    @Test func noSnapshotGivesNoDataForEachBar() {
        let v = view(nil)
        #expect(
            v.bars == [
                UsageBar(label: "5-hour limit", percent: nil, level: .normal, detail: "No data"),
                UsageBar(label: "7-day limit", percent: nil, level: .normal, detail: "No data"),
            ])
        #expect(v.source == "No usage data yet.")
    }

    @Test func aPlanWithNoFiveHourWindowShowsOnlyTheSevenDayBar() {
        let seven = RateWindow(usedPercent: 10, resetsAt: now + 3 * day)
        let v = view(snap(RateLimits(sevenDay: seven)))
        #expect(
            v.bars == [
                UsageBar(
                    label: "7-day limit", percent: 10, level: .normal,
                    detail: "Resets in 3 d 0 h (Sun 12:00)")
            ])
    }

    @Test func aWindowWhoseResetTimePassedShowsADashAndTheResetTime() {
        #expect(
            view(snap(five(95, resetsAt: now - hour))).bars[0]
                == UsageBar(
                    label: "5-hour limit", percent: nil, level: .normal, detail: "Reset at 11:00."))
        // A reset time at this moment has passed too.
        let at = view(snap(five(95, resetsAt: now))).bars[0]
        #expect(at.detail == "Reset at 12:00." && at.percent == nil)
        // A reset on another day shows the day.
        let old = view(snap(RateLimits(sevenDay: RateWindow(usedPercent: 40, resetsAt: now - day))))
        #expect(old.bars[0].detail == "Reset at Wed 12:00." && old.bars[0].percent == nil)
    }

    @Test func aUsedPercentThatIsNotFiniteShowsADashNotZero() {
        for usedPercent in [Double.nan, .infinity, -.infinity] {
            #expect(
                view(snap(five(usedPercent))).bars[0]
                    == UsageBar(
                        label: "5-hour limit", percent: nil, level: .normal,
                        detail: "Resets in 1 h 00 min (13:00)"))
        }
    }

    @Test func aResetUnderOneMinuteFromNowShowsLessThanOneMinute() {
        #expect(UsageView.reset(now + 30_000, now: now, zone: utc) == "less than 1 min (12:00)")
        #expect(
            view(snap(five(97, resetsAt: now + 59_999))).bars[0]
                == UsageBar(
                    label: "5-hour limit", percent: 97, level: .high,
                    detail: "Resets in less than 1 min (12:00)"))
    }

    @Test func thePercentIsRoundedAndClampedAndHighFrom90() {
        func at(_ usedPercent: Double) -> UsageBar { view(snap(five(usedPercent))).bars[0] }
        #expect(at(89.6).percent == 90 && at(89.6).level == .high)
        #expect(at(89.5).percent == 90 && at(89.5).level == .high)
        #expect(at(89.4).percent == 89 && at(89.4).level == .raised)
        #expect(at(120).percent == 100 && at(120).level == .high)
        #expect(at(-3).percent == 0 && at(-3).level == .normal)
    }

    // The 5-hour bar and the 7-day bar use the same levels: normal up to 70 %, raised from 71 %
    // to 89 %, high from 90 %.
    @Test(arguments: [
        (70.0, UsageLevel.normal), (71, .raised), (89, .raised), (90, .high), (100, .high),
    ])
    func bothBarsHaveTheSameLevelAtTheLimits(used: Double, level: UsageLevel) {
        let window = RateWindow(usedPercent: used, resetsAt: now + hour)
        let bars = view(snap(RateLimits(fiveHour: window, sevenDay: window))).bars
        #expect(bars.map(\.percent) == [Int(used), Int(used)])
        #expect(bars.map(\.level) == [level, level])
    }

    @Test func aBarWithNoValueIsNormal() {
        let bars = view(nil).bars
        #expect(bars.map(\.percent) == [nil, nil])
        #expect(bars.map(\.level) == [.normal, .normal])
    }

    @Test func eachLevelHasItsToken() {
        #expect(UsageLevel.allCases == [.normal, .raised, .high])
        #expect(UsageLevel.normal.colour == ThemeTokens.usage)
        #expect(UsageLevel.raised.colour == ThemeTokens.usageRaised)
        #expect(UsageLevel.high.colour == ThemeTokens.usageHigh)
        #expect(ThemeTokens.usageRaised == .rgb(0xd4, 0x73, 0x0a))
        #expect(ThemeTokens.usageHigh == ThemeTokens.watchRed)
    }

    @Test func theResetTextGivesMinutesHoursAndDays() {
        #expect(UsageView.reset(now + 45 * minute, now: now, zone: utc) == "45 min (12:45)")
        #expect(UsageView.reset(now + 125 * minute, now: now, zone: utc) == "2 h 05 min (14:05)")
        #expect(UsageView.reset(now + 25 * hour, now: now, zone: utc) == "1 d 1 h (Fri 13:00)")
    }

    @Test func theResetTextOfAFarTimeDoesNotOverflow() {
        #expect(UsageView.reset(Int.max, now: Int.min, zone: utc).hasSuffix(")"))
    }

    @Test func theSourceNamesTheSessionAndTheAge() {
        #expect(view(snap(five(5))).source == "From bifrost-test-a, 2 min ago.")
    }

    @Test func aSessionWithNoWindowKeepsBothBarsWithTheReasons() {
        #expect(
            view(snap(RateLimits())).bars.map { [$0.label, $0.detail] } == [
                ["5-hour limit", "No data for this limit yet."],
                ["7-day limit", "No data for this limit yet."],
            ])
    }

    @Test func theFiveHourBarComesBackWhenTheWindowComesBack() {
        let seven = RateWindow(usedPercent: 36, resetsAt: now + 3 * day)
        #expect(view(snap(RateLimits(sevenDay: seven))).bars.map(\.label) == ["7-day limit"])
        let again = RateLimits(
            fiveHour: RateWindow(usedPercent: 20, resetsAt: now + hour), sevenDay: seven)
        #expect(view(snap(again)).bars.map(\.label) == ["5-hour limit", "7-day limit"])
    }
}

@Suite("usage view with account values")
struct UsageViewAccountTests {
    private let session = snap(
        RateLimits(
            fiveHour: RateWindow(usedPercent: 91, resetsAt: now + hour),
            sevenDay: RateWindow(usedPercent: 70, resetsAt: now + day)))
    private let sevenOnly = RateLimits(
        sevenDay: RateWindow(usedPercent: 36, resetsAt: now + 3 * day))

    private func account(age: Int, _ limits: RateLimits) -> AccountUsage {
        AccountUsage(fetchedAt: now - age, limits: limits)
    }

    @Test func freshAccountValuesWinOverTheSessionValues() {
        let v = view(session, account: account(age: 3 * minute, sevenOnly))
        #expect(
            v.bars == [
                UsageBar(
                    label: "7-day limit", percent: 36, level: .normal,
                    detail: "Resets in 3 d 0 h (Sun 12:00)")
            ])
        #expect(v.source == "From your Anthropic account, updated 3 min ago.")
    }

    @Test func aPlanWithNoFiveHourWindowShowsOnlyTheSevenDayBar() {
        let v = view(session, account: account(age: 0, sevenOnly))
        #expect(v.bars.map(\.label) == ["7-day limit"] && v.bars[0].percent == 36)
        #expect(v.source == "From your Anthropic account, updated 0 s ago.")
    }

    @Test func accountValuesWithNoWindowKeepBothBarsWithTheReasons() {
        #expect(
            view(nil, account: account(age: 0, RateLimits())).bars == [
                UsageBar(
                    label: "5-hour limit", percent: nil, level: .normal,
                    detail: "No 5-hour limit right now."),
                UsageBar(
                    label: "7-day limit", percent: nil, level: .normal,
                    detail: "No data for this limit yet."),
            ])
    }

    @Test func theBarRulesAreTheSameForTheAccountValues() {
        let limits = RateLimits(
            fiveHour: RateWindow(usedPercent: 90, resetsAt: now + hour),
            sevenDay: RateWindow(usedPercent: 89.4, resetsAt: now + day))
        let bars = view(nil, account: account(age: minute, limits)).bars
        #expect(bars[0].percent == 90 && bars[0].level == .high)
        #expect(bars[1].percent == 89 && bars[1].level == .raised)
    }

    @Test func accountValuesOfExactly15MinutesStillWin() {
        let v = view(session, account: account(age: 15 * minute, sevenOnly))
        #expect(v.source == "From your Anthropic account, updated 15 min ago.")
    }

    @Test func accountValuesOlderThan15MinutesFallBackToTheSessionValues() {
        let v = view(session, account: account(age: 15 * minute + 1, sevenOnly))
        #expect(v.bars[0].percent == 91)
        #expect(v.source == "From bifrost-test-a, 2 min ago.")
    }

    @Test func oldAccountValuesWithNoSessionValuesGiveNoUsageData() {
        let v = view(nil, account: account(age: 20 * minute, sevenOnly))
        #expect(v.source == "No usage data yet.")
    }

    @Test func noAccountValuesGiveTheSessionValues() {
        let withNone = view(session, account: nil)
        #expect(withNone.bars == view(session).bars && withNone.source == view(session).source)
        #expect(withNone.source == "From bifrost-test-a, 2 min ago.")
    }
}
