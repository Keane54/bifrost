// The failures in a row of the polls and the other past events (docs/behaviour/health.md,
// "Performance").
import BifrostFoundation
import Foundation
import Testing

@testable import BifrostHealth

private let utc = TimeZone(identifier: "UTC") ?? .current
private let start = wall(2026, 11, 18, 9, 0)
private let time = EventTime(at: .seconds(5), wall: start)

private func reasons(_ events: PastEvents, online: Bool = true) -> [HealthReason] {
    HealthChecks.reasons(
        HealthInput(now: .seconds(10), wall: start, events: events, online: online), zone: utc)
}

// Record the result of the part the number of times, and give the lines of the health log.
@discardableResult
private func record(
    _ result: PollResult, of part: PollPart, times: Int, in events: inout PastEvents,
    online: Bool = true
) -> [String] {
    (0..<times).compactMap { _ in events.record(.poll(part, result), online: online, at: time) }
}

@Suite("performance poll streaks")
struct PollStreaksTests {
    @Test func threeFailuresWarnAndTenAreAProblem() {
        var events = PastEvents()
        let lines = record(.failed, of: .sessions, times: 2, in: &events)
        #expect(
            lines == ["poll failed: sessions (1 in a row)", "poll failed: sessions (2 in a row)"])
        #expect(reasons(events).isEmpty)
        record(.failed, of: .sessions, times: 1, in: &events)
        #expect(
            reasons(events) == [
                HealthReason(
                    level: .warning, text: "Bifrost couldn't check for sessions 3 times in a row.",
                    past: true)
            ])
        record(.failed, of: .sessions, times: 7, in: &events)
        #expect(
            reasons(events) == [
                HealthReason(
                    level: .problem, text: "Bifrost couldn't check for sessions 10 times in a row.",
                    past: true)
            ])
        // A poll with no data changes nothing and writes no line. A good poll ends the streak.
        #expect(record(.noData, of: .sessions, times: 1, in: &events).isEmpty)
        #expect(events.streaks[.sessions] == 10)
        #expect(record(.ok, of: .sessions, times: 1, in: &events).isEmpty)
        #expect(events.streaks[.sessions] == 0)
        #expect(reasons(events).isEmpty)
    }

    @Test func eachPartHasItsOwnStreakAndText() {
        var events = PastEvents()
        for part in PollPart.allCases { record(.failed, of: part, times: 3, in: &events) }
        #expect(
            reasons(events).map(\.text) == [
                "Bifrost couldn't check for sessions 3 times in a row.",
                "Bifrost couldn't check GitHub for reviews 3 times in a row.",
                "Bifrost couldn't check your account usage 3 times in a row.",
                "Bifrost couldn't check Claude's status 3 times in a row.",
                "Bifrost couldn't check for updates 3 times in a row.",
            ])
        // A poll that stopped ends its streak.
        _ = events.record(.stopped(.reviews), online: true, at: time)
        #expect(events.streaks[.reviews] == 0)
        #expect(events.streaks[.updates] == 3)
    }

    @Test func offlineFailuresOfANetworkPartDoNotCount() {
        var events = PastEvents()
        record(.failed, of: .reviews, times: 4, in: &events)
        // While offline, a failure of a network part is no data: no count and no line.
        #expect(record(.failed, of: .reviews, times: 5, in: &events, online: false).isEmpty)
        #expect(events.streaks[.reviews] == 4)
        // While offline, a network part gives no reason. Online again, the streak shows.
        #expect(reasons(events, online: false).isEmpty)
        #expect(reasons(events).map(\.level) == [.warning])
    }

    @Test func theSessionsPollCountsOffline() {
        var events = PastEvents()
        let lines = record(.failed, of: .sessions, times: 3, in: &events, online: false)
        #expect(lines.count == 3)
        #expect(events.streaks[.sessions] == 3)
        #expect(reasons(events, online: false).map(\.level) == [.warning])
    }

    @Test func clearResetsTheStreaksAndKeepsTheLiveReasons() {
        var events = PastEvents()
        record(.failed, of: .accountUsage, times: 10, in: &events)
        _ = events.record(.saveFailed(what: "the UI state"), online: true, at: time)
        _ = events.record(.liveStart(failed: "No socket."), online: true, at: time)
        // The memory of Bifrost is a live measurement: Clear keeps it.
        let input = HealthInput(
            now: .seconds(30), wall: start, history: history(until: 30) { _ in 1200 },
            events: events, orphans: 1)
        let before = HealthChecks.reasons(input, zone: utc)
        #expect(before.count == 5)
        #expect(before.filter(\.past).count == 3)
        #expect(events.clear() == "cleared by the user")
        #expect(events.streaks[.accountUsage] == 0)
        var cleared = input
        cleared.events = events
        let after = HealthChecks.reasons(cleared, zone: utc)
        #expect(after == before.filter { !$0.past })
        #expect(after.map(\.text) == [
            "Bifrost's own processes are using 1.2 GB RAM, above the 1 GB limit.",
            "1 chat terminal is running with no chat window.",
        ])
        // A new failure counts from 0 again.
        record(.failed, of: .accountUsage, times: 1, in: &events)
        #expect(events.streaks[.accountUsage] == 1)
    }
}
