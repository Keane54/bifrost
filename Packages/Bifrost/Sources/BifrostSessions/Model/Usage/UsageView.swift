import Foundation

// One bar of the Usage HUD. percent is the rounded percent from 0 to 100, or nil when no value
// is known (the HUD shows "-"). level comes from the percent (UsageLevel).
package struct UsageBar: Sendable, Equatable {
    package var label: String
    package var percent: Int?
    package var level: UsageLevel
    package var detail: String

    package init(label: String, percent: Int?, level: UsageLevel, detail: String) {
        self.label = label
        self.percent = percent
        self.level = level
        self.detail = detail
    }
}

// The bars and the texts of the Usage HUD (docs/behaviour/usage.md, "The Usage HUD").
package enum UsageView {
    private static let fiveHourLabel = "5-hour limit"
    private static let sevenDayLabel = "7-day limit"
    private static let noData = "No data"
    private static let noWindow = "No data for this limit yet."
    private static let noFiveHour = "No 5-hour limit right now."

    // The bars come from the source that UsageSource.pick gives: the account values when they
    // are 15 minutes old or less, else the usage lines of the sessions. The usage notification
    // uses the same choice.
    package static func of(
        _ snapshot: UsageSnapshot?, now: Int, account: AccountUsage?, zone: TimeZone = .current
    ) -> (bars: [UsageBar], source: String) {
        switch UsageSource.pick(snapshot, now: now, account) {
        case .account(let account):
            let age = TimeText.age(since: account.fetchedAt, now: now)
            return (
                bars(account.limits, now: now, zone: zone, noFiveHour: noFiveHour),
                "From your Anthropic account, updated \(age) ago."
            )
        case .session(let snapshot):
            let age = TimeText.age(since: snapshot.updatedAt, now: now)
            return (
                bars(snapshot.limits, now: now, zone: zone, noFiveHour: noWindow),
                "From \(snapshot.name), \(age) ago."
            )
        case nil:
            return (
                [
                    UsageBar(label: fiveHourLabel, percent: nil, level: .normal, detail: noData),
                    UsageBar(label: sevenDayLabel, percent: nil, level: .normal, detail: noData),
                ],
                "No usage data yet."
            )
        }
    }

    // The time until the reset and the reset time: "45 min (12:45)", "2 h 05 min (14:05)",
    // "1 d 1 h (Fri 13:00)". The span is a Duration, so a time far from now does not overflow.
    package static func reset(_ resetsAt: Int, now: Int, zone: TimeZone = .current) -> String {
        let span = Duration.milliseconds(resetsAt) - .milliseconds(now)
        return "\(TimeText.duration(span)) (\(TimeText.clockOrDay(resetsAt, now: now, zone: zone)))"
    }

    // A source with a 7-day window and no 5-hour window gives the 7-day bar only: a plan can have
    // no 5-hour window (user decision, 2026-11-10). A source with no window gives both bars.
    private static func bars(_ limits: RateLimits, now: Int, zone: TimeZone, noFiveHour: String)
        -> [UsageBar]
    {
        let seven = bar(sevenDayLabel, limits.sevenDay, now: now, zone: zone, noWindow: noWindow)
        if limits.fiveHour == nil, limits.sevenDay != nil { return [seven] }
        let five = bar(fiveHourLabel, limits.fiveHour, now: now, zone: zone, noWindow: noFiveHour)
        return [five, seven]
    }

    private static func bar(
        _ label: String, _ window: RateWindow?, now: Int, zone: TimeZone, noWindow: String
    ) -> UsageBar {
        guard let window else {
            return UsageBar(label: label, percent: nil, level: .normal, detail: noWindow)
        }
        // After the reset time, the use of the new window is not known until the next message.
        // The old value is wrong, and 0% is only a guess. So the bar shows "-" and the reset
        // time, as Show Info does.
        if window.resetsAt <= now {
            let at = TimeText.clockOrDay(window.resetsAt, now: now, zone: zone)
            return UsageBar(label: label, percent: nil, level: .normal, detail: "Reset at \(at).")
        }
        let detail = "Resets in \(reset(window.resetsAt, now: now, zone: zone))"
        // A value that is not a finite number is not known. It shows "-", not 0%.
        guard window.usedPercent.isFinite else {
            return UsageBar(label: label, percent: nil, level: .normal, detail: detail)
        }
        let percent = Int(min(100, max(0, window.usedPercent)).rounded())
        return UsageBar(
            label: label, percent: percent, level: UsageLevel(percent: percent),
            detail: detail)
    }
}
