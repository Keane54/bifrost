import BifrostFoundation
import Foundation

// The rules of the usage notification (docs/behaviour/usage.md, "The usage notification"). When
// the 5-hour limit or the 7-day limit gets to 90 percent or more, Bifrost shows one notification.
// Each limit notifies one time in each reset period.
//
// A wall time is an Int of milliseconds since 1970: the form of RateWindow.resetsAt and of the
// file usage-alerts.json. The rules compare two times as Durations, so a time far from now does
// not overflow.

// A limit of the plan. The raw value is the key of the limit in usage-alerts.json.
package enum LimitID: String, Sendable, CaseIterable {
    case fiveHour, sevenDay

    // The name of the limit in the texts.
    package var name: String {
        switch self {
        case .fiveHour: "5-hour limit"
        case .sevenDay: "7-day limit"
        }
    }
}

// The reset time of the last period that notified, for each limit, in milliseconds since 1970.
// nil means that no period notified. The value is the content of usage-alerts.json, so a restart
// does not notify again for the same period.
package struct NotifiedPeriods: Sendable, Equatable {
    package var fiveHour: Int?
    package var sevenDay: Int?
    // The top-level fields of the file that this app does not know. A save writes them again.
    package var unknown: UnknownFields

    package init(fiveHour: Int? = nil, sevenDay: Int? = nil, unknown: UnknownFields = .init()) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.unknown = unknown
    }

    // The kept reset time of a limit.
    package subscript(limit: LimitID) -> Int? {
        get {
            switch limit {
            case .fiveHour: fiveHour
            case .sevenDay: sevenDay
            }
        }
        set {
            switch limit {
            case .fiveHour: fiveHour = newValue
            case .sevenDay: sevenDay = newValue
            }
        }
    }
}

// The file form. No period gives null. The unknown fields come after the two keys. The read of
// the file is UsageAlertRules.parse, because the check of a kept value needs the time of now.
extension NotifiedPeriods: Encodable {
    private enum Key: String, CodingKey {
        case fiveHour, sevenDay
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(fiveHour, forKey: .fiveHour)
        try container.encode(sevenDay, forKey: .sevenDay)
        try unknown.encode(to: encoder)
    }
}

// One notification of a limit: the used percent as the values give it, and the reset time of
// the period in milliseconds since 1970.
package struct UsageAlert: Sendable, Equatable {
    package var limit: LimitID
    package var usedPercent: Double
    package var resetsAt: Int

    package init(limit: LimitID, usedPercent: Double, resetsAt: Int) {
        self.limit = limit
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

package enum UsageAlertRules {
    // The account values and the session values can give a slightly different reset time for
    // the same period. A reset time that is this much later or less is the same period.
    package static let samePeriod = Duration.seconds(900)

    // A 7-day window resets within 7 days. A kept value more than this time (8 days) after now
    // is bad: it would stop each notification of its limit until that time.
    package static let maxKeptAhead = Duration.seconds(691_200)

    // True when the reset time is more than samePeriod after the kept reset time, or when no
    // period notified.
    package static func isNewPeriod(_ resetsAt: Int, kept: Int?) -> Bool {
        guard let kept else { return true }
        return .milliseconds(resetsAt) > .milliseconds(kept) + samePeriod
    }

    // The limits that must notify now: the rounded percent is 90 or more, the reset time is
    // after now, and the period did not notify yet. The rounded percent agrees with the colour of
    // the HUD. A percent that is not a number never notifies. The 5-hour limit comes first.
    package static func due(_ limits: RateLimits, _ notified: NotifiedPeriods, now: Int)
        -> [UsageAlert]
    {
        LimitID.allCases.compactMap { limit in
            guard let window = limits[limit], window.resetsAt > now,
                window.usedPercent.rounded() >= Double(UsageSource.highPercent),
                isNewPeriod(window.resetsAt, kept: notified[limit])
            else { return nil }
            return UsageAlert(
                limit: limit, usedPercent: window.usedPercent, resetsAt: window.resetsAt)
        }
    }

    // Follow the reset time of each kept period. A value in the same period with a later reset
    // time raises the kept value to that reset time. Thus small steps of the reset time cannot
    // add up to more than samePeriod and make a new period. The percent does not matter here.
    package static func follow(_ limits: RateLimits, _ notified: NotifiedPeriods, now: Int)
        -> NotifiedPeriods
    {
        var next = notified
        for limit in LimitID.allCases {
            guard let window = limits[limit], let kept = notified[limit], window.resetsAt > now
            else { continue }
            if window.resetsAt > kept, !isNewPeriod(window.resetsAt, kept: kept) {
                next[limit] = window.resetsAt
            }
        }
        return next
    }

    // The notified periods after the alerts show.
    package static func after(_ notified: NotifiedPeriods, _ alerts: [UsageAlert])
        -> NotifiedPeriods
    {
        var next = notified
        for alert in alerts { next[alert.limit] = alert.resetsAt }
        return next
    }

    // The title and the body of the notification. With extra usage on, the text warns that real
    // money can be spent. The percent is the rounded percent, kept between 0 and 100 (a due
    // alert is never below 89.5). The reset time is the clock on the day of now, else the day
    // and the clock.
    package static func text(
        _ alert: UsageAlert, extraUsage: Bool, now: Int, zone: TimeZone = .current
    ) -> (title: String, body: String) {
        let name = alert.limit.name
        let percent = Int(min(100, max(0, alert.usedPercent)).rounded())
        let clock = TimeText.clockOrDay(alert.resetsAt, now: now, zone: zone)
        if extraUsage {
            return (
                title: "Warning: extra usage is on",
                body: "Your \(name) is at \(percent)%. After 100%, Claude Code spends your extra "
                    + "usage credits, which costs real money. It resets at \(clock).")
        }
        return (
            title: "\(name) at \(percent)%",
            body: "Claude Code stops at 100% until the limit resets at \(clock).")
    }

    // The notified periods of the content of usage-alerts.json, or no period for a value that is
    // not an object. A kept time must be a whole number of milliseconds, and not more than
    // maxKeptAhead after now. Each other value gives nil. The other top-level fields stay as
    // unknown fields.
    package static func parse(_ value: JSONValue?, now: Int) -> NotifiedPeriods {
        guard let object = value?.object else { return NotifiedPeriods() }
        func kept(_ limit: LimitID) -> Int? {
            guard let time = object[limit.rawValue]?.wholeNumber,
                .milliseconds(time) - .milliseconds(now) <= maxKeptAhead
            else { return nil }
            return time
        }
        return NotifiedPeriods(
            fiveHour: kept(.fiveHour), sevenDay: kept(.sevenDay),
            unknown: UnknownFields(object, known: Set(LimitID.allCases.map(\.rawValue))))
    }
}

extension RateLimits {
    // The window of a limit, or nil when the plan lacks it.
    fileprivate subscript(limit: LimitID) -> RateWindow? {
        switch limit {
        case .fiveHour: fiveHour
        case .sevenDay: sevenDay
        }
    }
}
