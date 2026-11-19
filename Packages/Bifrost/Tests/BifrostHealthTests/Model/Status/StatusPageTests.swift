// The rules of the status pages (docs/behaviour/health.md, "Service status"). The answers are the
// files of Fixtures. No test reaches the network.
import Foundation
import Testing

@testable import BifrostHealth

private let now = wall(2026, 11, 18, 10, 5)

@Suite("status page rules")
struct StatusPageTests {
    private func status(
        _ id: ServiceID, _ status: String?, components: String? = nil, incidents: String? = nil
    ) throws -> ServiceStatus {
        StatusPage.status(
            id, status: try status.map(fixture), components: try components.map(fixture),
            incidents: try incidents.map(fixture), now: now)
    }

    @Test func anOperationalPageIsNone() throws {
        let result = try status(
            .claude, "status-none.json", components: "components-all-operational.json",
            incidents: "incidents-none.json")
        #expect(
            result
                == ServiceStatus(
                    id: .claude, level: .none, since: nil, incidents: [], checkedAt: now))
    }

    @Test func anIgnoredComponentDoesNotCount() throws {
        // The indicator says major, but only parts that Claude Code does not use are down: the
        // components answer replaces the indicator.
        let result = try status(
            .claude, "status-major.json", components: "components-ignored-down.json",
            incidents: "incidents-none.json")
        #expect(result.level == .none)
        // An incident that names only an ignored part does not show. An incident that names no
        // part shows.
        let incidents = try status(
            .claude, "status-none.json", components: "components-ignored-down.json",
            incidents: "incidents-ignored.json")
        #expect(incidents.incidents.map(\.name) == ["No components named"])
        #expect(incidents.level == .minor)
        // Sentry ignores no part, so it reads no components answer and keeps its indicator.
        let sentry = try status(
            .sentry, "status-major.json", components: "components-ignored-down.json")
        #expect(sentry.level == .major)
        #expect(StatusPage.urls(.sentry).components == nil)
        #expect(StatusPage.urls(.claude).components != nil)
    }

    @Test func theComponentsGiveTheLevelOfTheKeptParts() throws {
        let partial = try status(
            .claude, "status-none.json", components: "components-api-partial.json")
        #expect(partial.level == .major)
        let maintenance = try status(
            .github, "status-none.json", components: "components-maintenance.json")
        #expect(maintenance.level == .maintenance)
    }

    @Test func theWorseOfTheIndicatorAndTheIncidentsShows() throws {
        let result = try status(.github, "status-minor.json", incidents: "incidents-major.json")
        #expect(result.level == .major)
        // The oldest incident at the level gives the start: the major one.
        #expect(result.since == wall(2026, 11, 18, 9, 3))
        // The list has the heavier incident first.
        #expect(result.incidents.map(\.name) == ["Elevated errors on the API", "Slow logins"])
        #expect(result.incidents.map(\.impact) == [.major, .minor])
        #expect(result.incidents[1].startedAt == wall(2026, 11, 18, 8, 0))
        // An indicator that is worse than each incident stays.
        let worse = try status(.sentry, "status-major.json", incidents: "incidents-major.json")
        #expect(worse.level == .major)
        let better = try status(.sentry, "status-none.json", incidents: "incidents-major.json")
        #expect(better.level == .major)
    }

    @Test func anIncidentThatClaudeMonitorsWeighsAtMostAMinorIssue() throws {
        let result = try status(.sentry, "status-none.json", incidents: "incidents-monitoring.json")
        #expect(result.level == .minor)
        #expect(result.incidents.map(\.impact) == [.critical])
    }

    @Test func aBadAnswerIsUnknown() throws {
        let unknown = ServiceStatus(id: .sentry, level: .unknown, checkedAt: now)
        #expect(try status(.sentry, nil) == unknown)
        #expect(try status(.sentry, "not-json.txt") == unknown)
        #expect(try status(.sentry, "status-unknown-indicator.json") == unknown)
        // A bad components or incidents answer only leaves out its part.
        let leftOut = try status(
            .claude, "status-minor.json", components: "not-json.txt", incidents: "not-json.txt")
        #expect(leftOut.level == .minor)
        #expect(leftOut.incidents.isEmpty)
    }

    @Test func eachServiceHasItsPages() {
        #expect(
            StatusPage.urls(.claude).status.absoluteString
                == "https://status.claude.com/api/v2/status.json")
        #expect(
            StatusPage.urls(.github).components?.absoluteString
                == "https://www.githubstatus.com/api/v2/components.json")
        #expect(
            StatusPage.urls(.sentry).incidents.absoluteString
                == "https://status.sentry.io/api/v2/incidents/unresolved.json")
        #expect(ServiceID.allCases.map(\.name) == ["Claude", "GitHub", "Sentry"])
        #expect(StatusPage.maxBytes == 1_000_000)
        #expect(StatusPage.timeout == .seconds(5))
    }
}
