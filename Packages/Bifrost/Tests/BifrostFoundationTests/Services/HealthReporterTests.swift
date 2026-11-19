import Foundation
import BifrostTestSupport
import Testing

@testable import BifrostFoundation

// The health reporter and the store log that tells it about a failed save.

// The next events of a stream, at most count: the stream ends at the call of finish, so a test
// reads only the events that it recorded before.
private func next(_ count: Int, of events: AsyncStream<HealthEvent>) async -> [HealthEvent] {
    var result: [HealthEvent] = []
    for await event in events {
        result.append(event)
        if result.count == count { break }
    }
    return result
}

@Suite("health reporter", .testTimeLimit)
struct HealthReporterTests {
    @Test func aRecordedEventReachesTheStream() async {
        let (reporter, events) = HealthReporter.make()
        reporter.record(.poll(.reviews, .ok))
        reporter.record(.stopped(.updates))
        #expect(await next(2, of: events) == [.poll(.reviews, .ok), .stopped(.updates)])
    }

    // The stream has the newest 256 events: of 300 events, the first that a late reader gets is
    // the event 45.
    @Test func withNoReaderTheStreamKeepsTheNewest256Events() async {
        let (reporter, events) = HealthReporter.make()
        for number in 1...300 { reporter.record(.saveFailed(what: "data \(number)")) }
        let read = await next(HealthReporter.kept, of: events)
        #expect(read.count == 256)
        #expect(read.first == .saveFailed(what: "data 45"))
        #expect(read.last == .saveFailed(what: "data 300"))
    }

    @Test func theNoneReporterDropsEachEvent() {
        // The call must not fail and must not keep anything: there is no stream to read.
        HealthReporter.none.record(.poll(.sessions, .failed))
    }

    @Test func theStoreLogForwardsEachEventAndReportsAFailedSave() async {
        let base = Recorder<StoreEvent>()
        let (reporter, events) = HealthReporter.make()
        let log = HealthStoreLog(base: base, health: reporter)
        let error = FileError.system(.read, path: "a", code: ENOSPC)
        let all: [StoreEvent] = [
            .readFailed(file: "a", what: "the data", error: error),
            .keptUnreadableCopy(file: "a", copy: "b"),
            .copyFailed(file: "a", copy: "b", what: "the data", error: error),
            .tooLarge(file: "a", what: "the data", limit: 10),
            .saveFailed(what: "the data", error: error),
            .defaulted(file: "a", keys: ["k"]),
        ]
        for event in all { log.record(event) }
        #expect(base.values == all)
        #expect(await next(1, of: events) == [.saveFailed(what: "the data")])
    }

    @Test func onlyTheSessionsPollUsesNoNetwork() {
        for part in PollPart.allCases {
            #expect(part.usesNetwork == (part != .sessions))
        }
        #expect(PollPart.accountUsage.rawValue == "account-usage")
        #expect(PollPart.serviceStatus.rawValue == "service-status")
    }
}
