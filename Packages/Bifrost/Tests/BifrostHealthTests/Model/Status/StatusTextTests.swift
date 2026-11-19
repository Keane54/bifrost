// The texts of the Service status panel, with a fixed time zone.
import Foundation
import Testing

@testable import BifrostHealth

private let now = wall(2026, 11, 18, 10, 5)

@Suite("status texts")
struct StatusTextTests {
    @Test func eachLevelHasItsText() {
        let texts = [
            ServiceLevel.none, .minor, .major, .critical, .maintenance, .unknown,
        ].map(StatusText.level)
        #expect(
            texts == [
                "Operational", "Minor issue", "Major outage", "Critical outage", "Maintenance",
                "No data",
            ])
    }

    @Test func anIncidentLineHasItsAge() {
        let incident = Incident(
            name: "API errors", impact: .major, status: "investigating",
            startedAt: wall(2026, 11, 18, 9, 3))
        #expect(
            StatusText.incident(incident, now: now)
                == "API errors - major (investigating), for 1 h 02 min")
        var open = incident
        open.startedAt = nil
        #expect(StatusText.incident(open, now: now) == "API errors - major (investigating)")
    }

    @Test func theCheckTextHasTheClockOrSaysNotYet() {
        #expect(StatusText.checked(nil, zone: .gmt) == "Not checked yet.")
        #expect(StatusText.checked(now, zone: .gmt) == "Checked at 10:05.")
        // The zone changes the clock.
        let paris = TimeZone(identifier: "Europe/Paris") ?? .gmt
        #expect(StatusText.checked(now, zone: paris) == "Checked at 11:05.")
    }

    @Test func theSinceTextHasTheClockOnTheSameDayElseTheDay() {
        let today = wall(2026, 11, 18, 9, 3)
        let monday = wall(2026, 11, 16, 22, 15)
        #expect(StatusText.since(.major, today, now: now, zone: .gmt) == "since 09:03")
        #expect(StatusText.since(.major, monday, now: now, zone: .gmt) == "since Mon 22:15")
        #expect(StatusText.since(.minor, nil, now: now, zone: .gmt) == nil)
        #expect(StatusText.since(.none, today, now: now, zone: .gmt) == nil)
        #expect(StatusText.since(.unknown, today, now: now, zone: .gmt) == nil)
        #expect(StatusText.since(.maintenance, today, now: now, zone: .gmt) == "since 09:03")
    }

    @Test func theButtonTextsNameTheService() {
        #expect(StatusText.openPage == "Open status page")
        #expect(StatusText.openPageOf(.github) == "Open status page of GitHub")
    }
}
