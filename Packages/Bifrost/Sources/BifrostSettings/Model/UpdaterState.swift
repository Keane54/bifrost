import Foundation
import Observation

// What the updater of the app does now. off: the updater does not run (Bifrost Dev, or a release
// build with no feed). idle: it runs and no update cycle runs. checking: an update cycle runs, from
// the start of a check to the end of the cycle (Sparkle's window can stay open for it).
public enum UpdaterPhase: Sendable, Equatable {
    case off, idle, checking
}

// The state of the updater, as one observed value. The app target keeps it at the events of the
// updater (the start of a check and the end of an update cycle), so the rows of Settings >
// Updates change at the event and not at a later draw.
@MainActor
@Observable
public final class UpdaterState {
    public var phase: UpdaterPhase
    // The time of the last check, or nil before the first check.
    public var lastCheck: Date?

    public init(phase: UpdaterPhase = .off, lastCheck: Date? = nil) {
        self.phase = phase
        self.lastCheck = lastCheck
    }
}
