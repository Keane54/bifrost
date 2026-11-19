import Foundation
import Synchronization

// The time texts of the panels and the notifications (docs/behaviour/usage.md, "Time texts").
// Each text uses a 24-hour clock, no comma and the English names of the en_GB locale, so it does
// not change with the locale of the user. Only the time zone changes it: each function takes the
// zone, and the default is the zone of the computer.
//
// A wall time is an Int of milliseconds since 1970: the form of the session rows and of
// RateWindow.resetsAt (row D1 of docs/ports/registry/DELIBERATE-DIFFERENCES.md).
package enum TimeText {
    // 09:07
    package static func clock(_ ms: Int, zone: TimeZone = .current) -> String {
        format(ms, .clock, zone)
    }

    // Thu 14:03
    package static func dayClock(_ ms: Int, zone: TimeZone = .current) -> String {
        format(ms, .dayClock, zone)
    }

    // The clock on the day of now, else the day and the clock. The Usage HUD and the usage
    // notification use it.
    package static func clockOrDay(_ ms: Int, now: Int, zone: TimeZone = .current) -> String {
        sameDay(ms, now, zone: zone) ? clock(ms, zone: zone) : dayClock(ms, zone: zone)
    }

    // 09:07:03.045. The milliseconds come from the Int, so no rounding of a Double changes them.
    package static func clockMs(_ ms: Int, zone: TimeZone = .current) -> String {
        let millisecond = String(((ms % 1000) + 1000) % 1000)
        let padding = String(repeating: "0", count: 3 - millisecond.count)
        return format(ms, .clockSeconds, zone) + "." + padding + millisecond
    }

    // A length of time in whole minutes: "less than 1 min", "59 min", "1 h 02 min", "1 d 1 h".
    // A negative length gives "less than 1 min".
    package static func duration(_ span: Duration) -> String {
        let minutes = max(span, .zero).components.seconds / 60
        if minutes < 1 { return "less than 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours < 24 { return "\(hours) h \(rest < 10 ? "0" : "")\(rest) min" }
        return "\(hours / 24) d \(hours % 24) h"
    }

    // True when the two times have the same date in the time zone.
    package static func sameDay(_ a: Int, _ b: Int, zone: TimeZone = .current) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.isDate(date(a), inSameDayAs: date(b))
    }

    // The clock on the day of now, else the day, the date and the clock: "Thu 5 Nov 14:03".
    // Show Info and the update rows of the settings use it.
    package static func when(_ ms: Int, now: Int, zone: TimeZone = .current) -> String {
        sameDay(ms, now, zone: zone) ? clock(ms, zone: zone) : format(ms, .dayDateClock, zone)
    }

    // The age text of a time: seconds, minutes, hours or days. Both times are milliseconds since
    // 1970. A time after now gives "0 s". A difference that does not fit in an Int gives no text.
    package static func age(since: Int, now: Int) -> String {
        guard let elapsed = milliseconds(since: since, now: now) else { return "" }
        let seconds = max(0, elapsed / 1000)
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        if seconds < 86400 { return "\(seconds / 3600) h" }
        return "\(seconds / 86400) d"
    }

    // The time until the age text changes, at most one hour. A time after now shows "0 s" until
    // 1 s after since. A difference that does not fit in an Int gives 60 s.
    package static func ageStep(since: Int, now: Int) -> Duration {
        let hour = 3_600_000
        guard let elapsed = milliseconds(since: since, now: now) else { return .seconds(60) }
        if elapsed < 0 { return .milliseconds(elapsed < -hour ? hour : min(hour, 1000 - elapsed)) }
        let seconds = elapsed / 1000
        let unit = seconds < 60 ? 1 : seconds < 3600 ? 60 : seconds < 86400 ? 3600 : 86400
        let unitMilliseconds = unit * 1000
        return .milliseconds(min(hour, unitMilliseconds - elapsed % unitMilliseconds))
    }

    // MARK: - Formatters

    // The patterns of the texts.
    private enum Pattern: String {
        case clock = "HH:mm"
        case dayClock = "EEE HH:mm"
        case clockSeconds = "HH:mm:ss"
        case dayDateClock = "EEE d MMM HH:mm"
    }

    private struct Key: Hashable {
        var zone: TimeZone
        var pattern: Pattern
    }

    // One formatter for each zone and pattern, made at its first use. The lock keeps the cache
    // and each format call on one thread at a time.
    private static let formatters = Mutex<[Key: DateFormatter]>([:])

    private static func format(_ ms: Int, _ pattern: Pattern, _ zone: TimeZone) -> String {
        formatters.withLock { cache in
            let key = Key(zone: zone, pattern: pattern)
            if let formatter = cache[key] { return formatter.string(from: date(ms)) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_GB")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = zone
            formatter.dateFormat = pattern.rawValue
            cache[key] = formatter
            return formatter.string(from: date(ms))
        }
    }

    // The date of the whole second that holds the time. A whole number of seconds is exact in a
    // Double, so the second of a text never moves back by a rounding error.
    private static func date(_ ms: Int) -> Date {
        let seconds = ms / 1000 - (ms % 1000 < 0 ? 1 : 0)
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    // now minus since, or nil when the difference does not fit in an Int.
    private static func milliseconds(since: Int, now: Int) -> Int? {
        let (elapsed, overflow) = now.subtractingReportingOverflow(since)
        return overflow ? nil : elapsed
    }
}
