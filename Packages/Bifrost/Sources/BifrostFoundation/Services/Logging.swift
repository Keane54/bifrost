import Foundation
import OSLog

// The log of Bifrost is the unified log of macOS. Each module makes one os.Logger for each of its
// areas with Logger(bifrost:). macOS keeps the log on disk, and a sysdiagnose collects it. So
// each call of a logger sets the level and the privacy of each value:
// - .error for a failure, .notice for an event that the user can need later, .info for a routine
//   event, .debug for a detail;
// - privacy: .private for each path, each session name and each text from the user or from
//   Claude; .public only for fixed words and numbers.
// Where a test must read the lines, the module gives a small protocol and a recording fake, for
// example StoreLog.
extension Logger {
    // The subsystem of each log of the app: the bundle ID of the running app (AppIdentity), so
    // the release app and the development app log apart.
    package static let bifrostSubsystem = Bundle.main.bundleIdentifier ?? "Bifrost"

    // The logger of one area of the app, for example "stores".
    public init(bifrost category: String) {
        self.init(subsystem: Self.bifrostSubsystem, category: category)
    }
}
