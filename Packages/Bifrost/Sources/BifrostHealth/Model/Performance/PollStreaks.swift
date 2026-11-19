import BifrostFoundation
import Foundation

// The failures in a row of each poll of the app (docs/behaviour/health.md, "Performance").
package struct PollStreaks: Sendable, Equatable {
    private var counts: [PollPart: Int] = [:]

    package init() {}

    // The failures in a row of the part.
    package subscript(part: PollPart) -> Int { counts[part] ?? 0 }

    // Record one result of the poll. A good poll ends the streak. A poll with no data changes
    // nothing. While the Mac is offline, a failed poll of a network part is a poll with no data, so
    // the streak does not grow while offline. The result is the new count after a failure that
    // counts, else nil.
    package mutating func record(_ part: PollPart, _ result: PollResult, online: Bool) -> Int? {
        switch result {
        case .ok:
            counts[part] = 0
            return nil
        case .noData:
            return nil
        case .failed:
            guard online || !part.usesNetwork else { return nil }
            let count = self[part] + 1
            counts[part] = count
            return count
        }
    }

    // The poll stopped: no more results come, so its streak ends.
    package mutating func stopped(_ part: PollPart) {
        counts[part] = 0
    }

    // Each streak goes to 0, so a new failure counts from 0 again.
    package mutating func clear() {
        counts = [:]
    }
}

// A time of an event: on the timeline of the monitor for its age, and on the wall clock for the
// time that a text shows.
package struct EventTime: Sendable, Equatable {
    package var at: Duration
    package var wall: Date

    package init(at: Duration, wall: Date) {
        self.at = at
        self.wall = wall
    }
}

// A save that failed: the fixed name of the data (StoreEvent) and the time of the last failure.
package struct SaveFailure: Sendable, Equatable {
    package var what: String
    package var time: EventTime
}

// A start of the Live details socket that failed: the error text and the time.
package struct LiveStartFailure: Sendable, Equatable {
    package var message: String
    package var time: EventTime
}

// The past events of the health stream: the failures in a row of the polls, the failed saves and
// the last failed start of Live details. Clear removes them all. The live measurements are not
// here, so Clear keeps them.
package struct PastEvents: Sendable, Equatable {
    // A failed save shows for this time.
    package static let saveSpan = Duration.seconds(3600)

    package private(set) var streaks = PollStreaks()
    // The failed saves of the last hour, the oldest first. A data has one item: its last failure.
    package private(set) var saves: [SaveFailure] = []
    package private(set) var liveStart: LiveStartFailure?

    package init() {}

    // Record an event. The result is the line of the health log, or nil when the event writes no
    // line: a good poll, a poll with no data, a failure of a network part while offline, a stop
    // and a good start of Live details.
    package mutating func record(
        _ event: HealthEvent, online: Bool, at time: EventTime
    ) -> String? {
        switch event {
        case .poll(let part, let result):
            guard let count = streaks.record(part, result, online: online) else { return nil }
            return "poll failed: \(part.rawValue) (\(count) in a row)"
        case .stopped(let part):
            streaks.stopped(part)
            return nil
        case .saveFailed(let what):
            // A good save does not clear an earlier failure. The old failures go here, so the
            // list stays small.
            saves.removeAll { $0.what == what || time.at - $0.time.at >= Self.saveSpan }
            saves.append(SaveFailure(what: what, time: time))
            return "save failed: \(what)"
        case .liveStart(let failed):
            guard let failed else {
                liveStart = nil
                return nil
            }
            liveStart = LiveStartFailure(message: failed, time: time)
            return "live details did not start: \(failed)"
        }
    }

    // The user cleared the past events. The result is the line of the health log.
    package mutating func clear() -> String {
        streaks.clear()
        saves = []
        liveStart = nil
        return "cleared by the user"
    }
}
