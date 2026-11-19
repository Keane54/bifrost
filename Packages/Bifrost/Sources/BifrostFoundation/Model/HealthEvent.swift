// The parts that poll, for the health log of the app (phase 5).
package enum PollPart: String, Sendable, CaseIterable {
    // The raw values are the part names of the Electron health log lines.
    case sessions, reviews, accountUsage = "account-usage", serviceStatus = "service-status"
    case updates

    // False only for the sessions poll, which reads the local registry.
    package var usesNetwork: Bool { self != .sessions }
}

// The result of one poll for the health log. ok: new values. noData: no token, an expired login
// or the rate limit. failed: each other reason (AccountUsageEvent.result).
package enum PollResult: String, Sendable {
    case ok
    case noData = "no-data"
    case failed
}

// An event for the health log. Nothing outside lane 5b switches over this enum.
package enum HealthEvent: Sendable, Equatable {
    case poll(PollPart, PollResult)
    // The poll stopped because its setting is off. Its streak of failures ends.
    case stopped(PollPart)
    // A save failed. what is the fixed name of the data, as in StoreEvent.
    case saveFailed(what: String)
    // The result of a start of the Live details socket. failed is the error text of a start that
    // failed. nil: a good start, or the user turned Live details off or removed it. Then the last
    // failure no longer applies.
    case liveStart(failed: String?)
}
