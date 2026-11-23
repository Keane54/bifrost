import Foundation

// The log line of a slow main thread. The watch gives the longest pass of the last full 60 s
// window, and each tick reads the same value until the next window ends. So the log gets one line
// for each window that has a slow pass, and no second line for the same window. A pass is slow
// when the Performance panel calls it slow (HealthChecks.delayWarning).
package struct SlowMainLog: Sendable {
    // The number of the window that has its line already.
    private var logged: Int?

    package init() {}

    // The line for the window, or nil when the pass is not slow or the window has its line.
    package mutating func line(delay: Duration?, window: Int) -> String? {
        guard let delay, window != logged else { return nil }
        let ms = Int((delay / .milliseconds(1)).rounded())
        guard ms > HealthChecks.delayWarning else { return nil }
        logged = window
        return "main thread slow to respond: up to \(ms) ms"
    }
}
