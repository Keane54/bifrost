import BifrostFoundation
import BifrostSessions
import Foundation

// The texts of the Performance monitor (docs/behaviour/health.md, "Performance"). A size in MB or
// GB counts 1,048,576 bytes in a MB and 1,024 MB in a GB. A CPU value is in percent of one core.
// Each time text uses TimeText, so it has a 24-hour clock.
package enum HealthText {
    package static let checking = "Checking Bifrost…"
    package static let lowFrameRate = "The Performance panel ran below 30 fps for 10 seconds."
    package static let liveStart = "Bifrost couldn't start the Live details link."

    private static let megabyte = 1_048_576.0
    private static let gigabyte = 1_073_741_824.0

    // The headline of the panel: the OK text with the values of the fresh sample, the level word,
    // or "Checking Bifrost…" while the monitor has no data.
    package static func headline(_ level: HealthLevel?, use: Use?) -> String {
        switch level {
        case nil: checking
        case .warning: "Warning"
        case .problem: "Problem"
        case .ok: use.map(ok) ?? checking
        }
    }

    // "Bifrost is using 712 MB RAM and 2% CPU." The memory and the CPU include the chat terminals.
    package static func ok(_ use: Use) -> String {
        "Bifrost is using \(memory(use.memory)) RAM and \(Int(use.cpu.rounded()))% CPU."
    }

    // "712 MB", or "1.8 GB" from 1,024 MB. The rounded MB value decides, so 1,023.6 MB is
    // "1.0 GB".
    package static func memory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / megabyte
        let whole = Int(megabytes.rounded())
        if whole < 1024 { return "\(whole) MB" }
        return String(format: "%.1f GB", Double(bytes) / gigabyte)
    }

    // A value above a limit in GB with one decimal, for example "1.8 GB". When one decimal gives
    // the value of the limit, the value gets two decimals, rounded up, so it always shows above
    // the limit: "1.01 GB". The text shows the rounded value that the compare used.
    package static func overLimit(_ bytes: UInt64, limit: UInt64) -> String {
        let gigabytes = Double(bytes) / gigabyte
        let oneDecimal = (gigabytes * 10).rounded() / 10
        if oneDecimal > Double(limit) / gigabyte { return String(format: "%.1f GB", oneDecimal) }
        return String(format: "%.2f GB", (gigabytes * 100).rounded(.up) / 100)
    }

    // A limit in GB: "1 GB", "1.5 GB".
    package static func limit(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / gigabyte
        let text =
            gigabytes == gigabytes.rounded()
            ? String(Int(gigabytes)) : String(format: "%g", gigabytes)
        return "\(text) GB"
    }

    // The size in whole MB: 1,612.4 MB is 1,612.
    package static func wholeMegabytes(_ bytes: UInt64) -> Int {
        Int((Double(bytes) / megabyte).rounded())
    }

    // "1,612 MB"
    package static func megabytes(_ count: Int) -> String {
        "\(count.formatted(.number.locale(Locale(identifier: "en_US")))) MB"
    }

    package static func ownMemory(_ bytes: UInt64, limit: UInt64) -> String {
        // "Own processes" leaves out the chat terminals (user decision, 2026-11-10).
        "Bifrost's own processes are using \(overLimit(bytes, limit: limit)) RAM, above the "
            + "\(self.limit(limit)) limit."
    }

    package static func terminalMemory(megabytes count: Int, limit: Int) -> String {
        "A chat terminal is using \(megabytes(count)) RAM, above the \(megabytes(limit)) limit."
    }

    package static func growth(megabytesAnHour: Int) -> String {
        "Bifrost's memory is growing by about \(megabytesAnHour) MB an hour."
    }

    package static func cpu(percent: Int) -> String {
        "Bifrost is using \(percent)% CPU on average over the last 2 minutes."
    }

    package static func slow(ms: Int) -> String {
        "Bifrost's main process was slow to respond (up to \(ms) ms)."
    }

    package static func poll(_ part: PollPart, count: Int) -> String {
        "Bifrost couldn't \(action(part)) \(count) times in a row."
    }

    package static func orphans(_ count: Int) -> String {
        count == 1
            ? "1 chat terminal is running with no chat window."
            : "\(count) chat terminals are running with no chat window."
    }

    // "Bifrost couldn't save your settings at 09:03."
    package static func saveFailed(_ what: String, at time: Date, zone: TimeZone = .current)
        -> String
    {
        let clock = TimeText.clock(time.millisecondsSince1970, zone: zone)
        return "Bifrost couldn't save \(saved(what)) at \(clock)."
    }

    // The friendly name of the data of a store, from its fixed name (StoreEvent). A name with no
    // friendly form stays as it is.
    package static func saved(_ what: String) -> String {
        switch what {
        case "the settings": "your settings"
        case "the UI state": "the panel layout"
        case "the registry store": "the session list"
        case "the window state": "the window position"
        default: what
        }
    }

    private static func action(_ part: PollPart) -> String {
        switch part {
        case .sessions: "check for sessions"
        case .reviews: "check GitHub for reviews"
        case .accountUsage: "check your account usage"
        case .serviceStatus: "check Claude's status"
        case .updates: "check for updates"
        }
    }
}
