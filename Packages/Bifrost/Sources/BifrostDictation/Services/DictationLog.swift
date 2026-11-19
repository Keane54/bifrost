import BifrostFoundation
import OSLog

// An event of the dictation service for the log. No event has a text of the user.
package enum DictationLogEvent: Sendable, Equatable {
    // The boot of the engine failed with this code.
    case bootFailed(DictationErrorCode)
    // The engine did not get ready in time (DictationService.engineLimit).
    case noReady
    // The engine did not open the microphone in time (DictationService.engineLimit).
    case noSession
    // The model download made no progress for 2 minutes (DictationService.downloadStall).
    case downloadStalled
}

// Where the dictation service sends its events. The app uses SystemDictationLog. A test records
// the events.
package protocol DictationLog: Sendable {
    func record(_ event: DictationLogEvent)
}

// The log of the dictation service in the unified log of macOS.
package struct SystemDictationLog: DictationLog {
    private static let logger = Logger(bifrost: "dictation")

    package init() {}

    package func record(_ event: DictationLogEvent) {
        let log = Self.logger
        switch event {
        case .bootFailed(let code):
            log.error("The speech engine didn't start (\(code.rawValue, privacy: .public)).")
        case .noReady:
            log.error("The speech engine didn't get ready in time.")
        case .noSession:
            log.error("The speech engine didn't open the microphone in time.")
        case .downloadStalled:
            log.error("The speech model download made no progress for 2 minutes.")
        }
    }
}
