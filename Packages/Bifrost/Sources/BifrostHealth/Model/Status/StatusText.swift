import BifrostLook
import BifrostSessions
import Foundation

// The texts of the Service status panel (docs/behaviour/health.md, "Service status"). Each time
// text uses TimeText, so it has a 24-hour clock and the names of the en_GB locale.
package enum StatusText {
    package static func level(_ level: ServiceLevel) -> String {
        switch level {
        case .none: "Operational"
        case .minor: "Minor issue"
        case .major: "Major outage"
        case .critical: "Critical outage"
        case .maintenance: "Maintenance"
        case .unknown: "No data"
        }
    }

    // "API errors - major (investigating), for 1 h 02 min"
    package static func incident(_ incident: Incident, now: Date) -> String {
        let text = "\(incident.name) - \(incident.impact.rawValue) (\(incident.status))"
        guard let started = incident.startedAt else { return text }
        return text + ", for " + TimeText.duration(.seconds(now.timeIntervalSince(started)))
    }

    // "Checked at 09:03.", or "Not checked yet." before the first check.
    package static func checked(_ checkedAt: Date?, zone: TimeZone = .current) -> String {
        guard let checkedAt else { return "Not checked yet." }
        return "Checked at \(TimeText.clock(checkedAt.millisecondsSince1970, zone: zone))."
    }

    // "since 09:03" on the day of now, else "since Wed 22:15". Only a level that is not ok shows
    // the start of its incident.
    package static func since(
        _ level: ServiceLevel, _ since: Date?, now: Date, zone: TimeZone = .current
    ) -> String? {
        guard let since, level != .none, level != .unknown else { return nil }
        let time = TimeText.clockOrDay(
            since.millisecondsSince1970, now: now.millisecondsSince1970, zone: zone)
        return "since \(time)"
    }

    // The line of a service that gave no answer, under its row.
    package static let noAnswer = "The status page didn't answer."

    package static let openPage = "Open status page"

    package static func openPageOf(_ id: ServiceID) -> String { "Open status page of \(id.name)" }

    // The text of a panel in a test home, which checks no status page.
    package static let testHome = "Bifrost doesn't check status pages in a test home."
}
