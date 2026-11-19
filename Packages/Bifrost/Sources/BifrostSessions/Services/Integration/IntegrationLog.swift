import BifrostFoundation
import OSLog

// An event of the edit of the Claude Code settings file and of the clean-up of the old hook data.
// Each path and each error text is private in the log. A name of the old hook data is a fixed
// word.
package enum IntegrationLogEvent: Sendable, Equatable {
    // Bifrost removed the old hook install from the settings file. backup is the copy of the old
    // bytes.
    case oldInstallRemoved(file: String, backup: String)
    // The clean-up removed these items of the old hook data.
    case oldHookDataRemoved([String])
    // The clean-up could not remove an item of the old hook data. The next start tries again.
    case oldHookDataNotRemoved(path: String, FileError)
}

// Where the integration sends its events. The app uses SystemIntegrationLog. A test records the
// events.
package protocol IntegrationLog: Sendable {
    func record(_ event: IntegrationLogEvent)
}

// The log of the integration in the unified log of macOS.
package struct SystemIntegrationLog: IntegrationLog {
    private static let logger = Logger(bifrost: "integration")

    package init() {}

    package func record(_ event: IntegrationLogEvent) {
        let log = Self.logger
        switch event {
        case .oldInstallRemoved(let file, let backup):
            log.notice(
                """
                Bifrost removed the old hook install from \(file, privacy: .private). \
                Backup: \(backup, privacy: .private).
                """)
        case .oldHookDataRemoved(let names):
            let list = names.joined(separator: ", ")
            log.notice("Bifrost removed the old hook data: \(list, privacy: .public).")
        case .oldHookDataNotRemoved(let path, let error):
            log.error(
                """
                Bifrost cannot remove the old hook data at \(path, privacy: .private). \
                The next start tries again. \(error.message, privacy: .private)
                """)
        }
    }
}
