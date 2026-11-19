import BifrostFoundation
import Foundation

// The services that Claude Code depends on, and their public status pages
// (docs/behaviour/health.md, "Service status").
package enum ServiceID: String, Sendable, CaseIterable {
    case claude, github, sentry

    // The name of the service in the panel.
    package var name: String {
        switch self {
        case .claude: "Claude"
        case .github: "GitHub"
        case .sentry: "Sentry"
        }
    }

    // The status page that the button opens, and the base of its API.
    package var page: URL { StatusPage.url(base) }

    fileprivate var base: String {
        switch self {
        case .claude: "https://status.claude.com"
        case .github: "https://www.githubstatus.com"
        case .sentry: "https://status.sentry.io"
        }
    }

    // A component or an incident whose name starts like this is a part that Claude Code does not
    // use. It does not count. An empty list means that no part is ignored.
    fileprivate var ignoredPrefixes: [String] {
        switch self {
        case .claude: ["Claude Console", "Claude Cowork", "Claude for Government"]
        case .github: ["Copilot", "Codespaces", "Pages", "Packages"]
        case .sentry: []
        }
    }
}

// The level of a service. unknown: no answer from the status page.
package enum ServiceLevel: String, Sendable {
    case none, minor, major, critical, maintenance, unknown

    // The weight of a level: minor 1, major 2, critical 3, each other level 0.
    fileprivate var rank: Int {
        switch self {
        case .minor: 1
        case .major: 2
        case .critical: 3
        case .none, .maintenance, .unknown: 0
        }
    }

    // The level of a weight, from none (0) to critical (3).
    fileprivate static func of(rank: Int) -> ServiceLevel {
        [.none, .minor, .major, .critical][max(0, min(3, rank))]
    }
}

// One open incident of a status page. impact is none, minor, major or critical.
package struct Incident: Sendable, Equatable {
    package var name: String
    package var impact: ServiceLevel
    package var status: String
    package var startedAt: Date?

    package init(
        name: String, impact: ServiceLevel, status: String, startedAt: Date? = nil
    ) {
        self.name = name
        self.impact = impact
        self.status = status
        self.startedAt = startedAt
    }

    // The weight of the incident for the level of its service. An incident that Claude monitors
    // after a fix weighs at most a minor issue.
    fileprivate var rank: Int {
        status == "monitoring" ? min(impact.rank, 1) : impact.rank
    }
}

// The state of one service. checkedAt is nil before the first check.
package struct ServiceStatus: Sendable, Equatable {
    package var id: ServiceID
    package var level: ServiceLevel
    // The start of the oldest incident at the level. nil when no incident has a start.
    package var since: Date?
    package var incidents: [Incident]
    package var checkedAt: Date?

    package init(
        id: ServiceID, level: ServiceLevel, since: Date? = nil, incidents: [Incident] = [],
        checkedAt: Date? = nil
    ) {
        self.id = id
        self.level = level
        self.since = since
        self.incidents = incidents
        self.checkedAt = checkedAt
    }

    // A service that no check has read yet.
    package static func unchecked(_ id: ServiceID) -> ServiceStatus {
        ServiceStatus(id: id, level: .unknown)
    }
}

// The rules that turn the answers of a status page (Atlassian Statuspage, API v2) into the state
// of a service. The functions read data and never the network.
package enum StatusPage {
    // Bifrost reads at most this many bytes of one answer. A status page answer has a few kB.
    package static let maxBytes = 1_000_000
    // The time limit of one request.
    package static let timeout = Duration.seconds(5)

    static func url(_ text: String) -> URL {
        guard let url = URL(string: text) else { preconditionFailure("bad status page URL") }
        return url
    }

    // status.json and incidents/unresolved.json. components.json only for a service that ignores
    // some parts: its answer can lower the level that status.json gives.
    package static func urls(_ id: ServiceID) -> (status: URL, components: URL?, incidents: URL) {
        let api = id.base + "/api/v2"
        return (
            url(api + "/status.json"),
            id.ignoredPrefixes.isEmpty ? nil : url(api + "/components.json"),
            url(api + "/incidents/unresolved.json")
        )
    }

    // The state of a service from its answers. A nil answer is no answer. With no good status
    // answer (none, not JSON or no known indicator), the level is unknown. A bad components or
    // incidents answer only leaves out its part.
    package static func status(
        _ id: ServiceID, status: Data?, components: Data?, incidents: Data?, now: Date
    ) -> ServiceStatus {
        guard var level = indicator(of: status) else {
            return ServiceStatus(id: id, level: .unknown, checkedAt: now)
        }
        let ignored = id.ignoredPrefixes
        if !ignored.isEmpty, let fromComponents = componentLevel(of: components, ignoring: ignored)
        {
            level = fromComponents
        }
        let open = openIncidents(of: incidents, ignoring: ignored).sorted {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            return ($0.startedAt ?? .distantFuture) < ($1.startedAt ?? .distantFuture)
        }
        let combined = combine(level, open)
        return ServiceStatus(
            id: id, level: combined.level, since: combined.since, incidents: open, checkedAt: now)
    }

    // MARK: - The answers

    private static func json(_ data: Data?) -> JSONValue? {
        data.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }

    // The indicator of status.json, or nil when the data is not a good answer.
    private static func indicator(of data: Data?) -> ServiceLevel? {
        guard let text = json(data)?.object?["status"]?.object?["indicator"]?.string,
            let level = ServiceLevel(rawValue: text), level != .unknown
        else { return nil }
        return level
    }

    // The level of the components that the filter keeps, or nil when the data is not a list.
    private static func componentLevel(of data: Data?, ignoring prefixes: [String])
        -> ServiceLevel?
    {
        guard let list = json(data)?.object?["components"]?.array else { return nil }
        var weight = 0
        var maintenance = false
        for item in list {
            guard let component = item.object, component["group"] != .bool(true) else { continue }
            if let name = component["name"]?.string, ignores(name, prefixes) { continue }
            let status = component["status"]?.string
            switch status {
            case "degraded_performance": weight = max(weight, 1)
            case "partial_outage": weight = max(weight, 2)
            case "major_outage": weight = max(weight, 3)
            case "under_maintenance": maintenance = true
            default: break
            }
        }
        if weight > 0 { return .of(rank: weight) }
        return maintenance ? ServiceLevel.maintenance : ServiceLevel.none
    }

    private static func ignores(_ name: String, _ prefixes: [String]) -> Bool {
        prefixes.contains { name.hasPrefix($0) }
    }

    // The open incidents of unresolved.json that the filter keeps. An incident is kept unless each
    // component that it names is ignored.
    private static func openIncidents(of data: Data?, ignoring prefixes: [String]) -> [Incident] {
        guard let list = json(data)?.object?["incidents"]?.array else { return [] }
        var result: [Incident] = []
        for item in list {
            guard let raw = item.object else { continue }
            let names = (raw["components"]?.array ?? []).map { $0.object?["name"]?.string }
            let kept =
                prefixes.isEmpty || names.isEmpty
                || names.contains { name in name.map { !ignores($0, prefixes) } ?? true }
            guard kept else { continue }
            let impact = ServiceLevel.of(rank: rank(of: raw["impact"]?.string))
            result.append(
                Incident(
                    name: raw["name"]?.string ?? "Incident", impact: impact,
                    status: raw["status"]?.string ?? "",
                    startedAt: raw["started_at"]?.string.flatMap(date)))
        }
        return result
    }

    private static func rank(of impact: String?) -> Int {
        impact.flatMap(ServiceLevel.init(rawValue:))?.rank ?? 0
    }

    // A time of a status page: ISO 8601 with a zone, with or without fractions of a second.
    private static func date(_ text: String) -> Date? {
        let plain = Date.ISO8601FormatStyle()
        let fractions = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return (try? fractions.parse(text)) ?? (try? plain.parse(text))
    }

    // MARK: - The level

    // The worse of the indicator and the incidents, and the start of the oldest incident at it.
    private static func combine(_ indicator: ServiceLevel, _ incidents: [Incident])
        -> (level: ServiceLevel, since: Date?)
    {
        let heaviest = incidents.map(\.rank).max() ?? 0
        let level = heaviest > indicator.rank ? ServiceLevel.of(rank: heaviest) : indicator
        let weight = level.rank
        let since =
            oldest(incidents.filter { $0.rank >= weight })
            ?? oldest(incidents.filter { $0.impact.rank >= weight }) ?? oldest(incidents)
        return (level, since)
    }

    private static func oldest(_ incidents: [Incident]) -> Date? {
        incidents.compactMap(\.startedAt).min()
    }
}
