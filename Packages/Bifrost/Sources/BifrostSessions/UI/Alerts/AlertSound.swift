import AppKit
import BifrostFoundation
import OSLog

// The alert sound of a new red box: the system sound Ping (docs/behaviour/alerts.md, "The alert
// sound"). No test plays it: a test home plays no sound (appAlertSound), and a test gives a
// counter.
@MainActor
package enum AlertSound {
    // The name of the system sound.
    package static let name = "Ping"
    private static let logger = Logger(bifrost: "alerts")

    // Play the sound, and do not wait for its end. A sound that cannot play is not an error for
    // the user, so the call only logs it.
    package static func play() {
        guard let sound = NSSound(named: name), sound.play() else {
            logger.error("Bifrost cannot play the alert sound.")
            return
        }
    }
}
