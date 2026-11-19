import BifrostFoundation
import Foundation

// Reads the answer of the usage endpoint of the account (docs/behaviour/usage.md, "The account
// values"). The endpoint has no documentation, so each step is defensive. A bad answer gives nil
// ("no data"), never a throw. The parse ignores other keys.
package enum AccountAnswer {
    // An answer larger than this is a bad answer.
    package static let maxBytes = 1_000_000

    // The account usage of the answer, or nil when it has no good window. fetchedAt is the time
    // of the answer in milliseconds since 1970. extraUsage is set only when the answer gives a
    // boolean for it.
    package static func parse(_ data: Data, fetchedAt: Int) -> AccountUsage? {
        guard data.count <= maxBytes,
            let answer = (try? JSONDecoder().decode(JSONValue.self, from: data))?.object
        else { return nil }
        let limits = RateLimits(
            fiveHour: window(answer["five_hour"]),
            sevenDay: window(answer["seven_day"]) ?? weeklyAll(answer["limits"]))
        guard limits != RateLimits() else { return nil }
        return AccountUsage(fetchedAt: fetchedAt, limits: limits, extraUsage: extraUsage(answer))
    }

    // A window from an object with a utilization percent and a reset time.
    private static func window(_ value: JSONValue?) -> RateWindow? {
        guard let fields = value?.object else { return nil }
        return window(percent: fields["utilization"], resetsAt: fields["resets_at"])
    }

    // The first good weekly_all entry of the list "limits". The answer can give the seven-day
    // window only in this form.
    private static func weeklyAll(_ value: JSONValue?) -> RateWindow? {
        for entry in value?.array ?? [] {
            guard let fields = entry.object, fields["kind"] == "weekly_all" else { continue }
            if let found = window(percent: fields["percent"], resetsAt: fields["resets_at"]) {
                return found
            }
        }
        return nil
    }

    // A window from a percent and an ISO 8601 reset time. A percent above 100 becomes 100.
    private static func window(percent: JSONValue?, resetsAt: JSONValue?) -> RateWindow? {
        guard let percent = percent?.finiteNumber, percent >= 0,
            let text = resetsAt?.string, let time = RateWindow.resetTime(text)
        else { return nil }
        return RateWindow(usedPercent: min(100, percent), resetsAt: time)
    }

    // The flag extra_usage.is_enabled: true when extra usage (the spend above the plan) is on.
    // A missing value or a value that is not a boolean gives nil.
    private static func extraUsage(_ answer: [String: JSONValue]) -> Bool? {
        guard case .bool(let enabled) = answer["extra_usage"]?.object?["is_enabled"] else {
            return nil
        }
        return enabled
    }
}
