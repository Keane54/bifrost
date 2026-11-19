import BifrostFoundation
import OSLog

// An event of the plugin commands, the Live details control and the skills control for the log.
// A command name is a fixed word. Each error text can hold a path, so it is private in the log.
package enum LiveLogEvent: Sendable, Equatable {
    // A write command of claude plugin did not end at its limit of 30 s and got its SIGTERM.
    case writeTimedOut(command: String)
    // A write command gave no result 10 s after its SIGTERM, so Bifrost cancelled the run.
    case writeHung(command: String)
    // A write command ended by itself, but 30 s or more after its start.
    case writeEndedLate(command: String, after: Duration)
    // The start rule could not read the plugin list. It listens when the mod manifest exists.
    case pluginListUnreadable(PluginFailure)
    // The start rule could not copy the mod folder. It listens with the old mod files.
    case modCopyFailed(SyncFailure)
    // The start rule of the skills found no claude, could not read a list or could not sync the
    // skills folder. A failed sync is the case folder.
    case skillsStartFailed(PluginFailure)
}

// Where the plugin commands and the controls send their events. The app uses SystemLiveLog. A
// test records the events.
package protocol LiveLog: Sendable {
    func record(_ event: LiveLogEvent)
}

// The log of Live details in the unified log of macOS.
package struct SystemLiveLog: LiveLog {
    private static let logger = Logger(bifrost: "live")

    package init() {}

    package func record(_ event: LiveLogEvent) {
        let log = Self.logger
        switch event {
        case .writeTimedOut(let command):
            log.error("claude plugin \(command, privacy: .public) did not finish in 30 s.")
        case .writeHung(let command):
            log.error("claude plugin \(command, privacy: .public) hung after its SIGTERM.")
        case .writeEndedLate(let command, let after):
            let seconds = after.components.seconds
            log.error(
                """
                claude plugin \(command, privacy: .public) ended after \
                \(seconds, privacy: .public) s.
                """)
        case .pluginListUnreadable(let failure):
            log.error(
                """
                Live details: Bifrost could not read the plugin list. \
                \(failure.message, privacy: .private)
                """)
        case .modCopyFailed(let failure):
            log.error(
                """
                Live details: Bifrost could not copy the mod folder. \
                \(failure.message, privacy: .private)
                """)
        case .skillsStartFailed(let failure):
            log.error(
                """
                Bifrost skills: the start failed. \
                \(failure.message, privacy: .private)
                """)
        }
    }
}
