// The texts of the Performance panel (docs/behaviour/health.md, "The panel"). A size uses
// HealthText.memory, the form of the OK text. A CPU value is in percent of one core.
import BifrostFoundation
import BifrostSessions
import Foundation

// The texts of the panel. A value that the monitor did not measure is "-".
package enum PerformanceText {
    package static let checking = HealthText.checking
    package static let details = "Details"
    package static let clear = "Clear"
    package static let stop = "Stop"
    package static let noData = "No data yet."
    package static let noSessions = "No sessions are running."
    package static let none = "-"

    // The word of the level in the headline.
    package static func word(_ level: HealthLevel) -> String {
        switch level {
        case .ok: "OK"
        case .warning: "Warning"
        case .problem: "Problem"
        }
    }

    // The text of the dot of the side bar button: "Performance - Warning". OK has no dot.
    package static func attention(_ level: HealthLevel) -> String? {
        level == .ok ? nil : "Performance - \(word(level))"
    }

    // A CPU value in percent of one core: "3%".
    package static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    // The memory and the CPU of a group: "712 MB · CPU 3%".
    package static func total(_ use: Use) -> String {
        "\(HealthText.memory(use.memory)) · CPU \(percent(use.cpu))"
    }

    package static func terminals(_ count: Int) -> String { "Chat terminals (\(count))" }

    package static func more(_ count: Int) -> String { "\(count) more" }

    package static func frameRate(_ fps: Double?) -> String {
        fps.map { "\(Int($0.rounded())) fps" } ?? none
    }

    package static func delay(_ delay: Duration?) -> String {
        delay.map { "\(Int(($0 / .milliseconds(1)).rounded())) ms" } ?? none
    }

    package static func pressure(_ pressure: MemoryPressure?) -> String {
        switch pressure {
        case .normal: "Normal"
        case .warning: "Medium"
        case .critical: "High"
        case nil: none
        }
    }

    // "None" with no swap, else "512 MB of 2.0 GB".
    package static func swap(_ swap: SwapUse?) -> String {
        guard let swap else { return none }
        if swap.total == 0 { return "None" }
        return "\(HealthText.memory(swap.used)) of \(HealthText.memory(swap.total))"
    }

    // The load of all cores, from 0 to 1, in percent: "34%".
    package static func load(_ load: Double?) -> String {
        load.map { percent($0 * 100) } ?? none
    }

    // "82%, charging". A full battery on the power adapter is "plugged in".
    package static func battery(_ battery: BatteryState?) -> String {
        guard let battery else { return none }
        let power =
            switch battery.power {
            case .charging: "charging"
            case .pluggedIn: "plugged in"
            case .onBattery: "on battery"
            }
        return "\(battery.percent)%, \(power)"
    }

    // "Online · Wi-Fi", "Online" for a link of another kind, or "Offline".
    package static func link(_ network: NetworkValues) -> String {
        guard network.online else { return "Offline" }
        let kind: String? =
            switch network.kind {
            case .wifi: "Wi-Fi"
            case .ethernet: "Ethernet"
            case .vpn: "VPN"
            case .other, nil: nil
            }
        return kind.map { "Online · \($0)" } ?? "Online"
    }

    // A rate in steps of 1,000: "820 B/s", "12 KB/s", "1.2 MB/s". The rounded value decides the
    // unit.
    package static func rate(_ bytesPerSecond: Double) -> String {
        let bytes = Int(bytesPerSecond.rounded())
        if bytes < 1000 { return "\(bytes) B/s" }
        let kilobytes = Int((bytesPerSecond / 1000).rounded())
        if kilobytes < 1000 { return "\(kilobytes) KB/s" }
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }

    // "↓ 1.2 MB/s" and "↑ 12 KB/s".
    package static func rates(_ rates: ByteRates?) -> (down: String, up: String) {
        ("↓ \(rates.map { rate($0.down) } ?? none)", "↑ \(rates.map { rate($0.up) } ?? none)")
    }

    package static func responseTime(_ time: ResponseTime?) -> String {
        switch time {
        case .answered(let after): delay(after)
        case .noAnswer: "No answer"
        case .unreachable: "Can't reach"
        case nil: none
        }
    }

    // "4,321 of 5,000 left · resets 09:03", or "Not available - GitHub CLI isn't signed in".
    package static func points(
        _ points: Result<GitHubPoints, GitHubLimitError>?, zone: TimeZone
    ) -> String {
        switch points {
        case .success(let points):
            let left = grouped(points.remaining)
            let limit = grouped(points.limit)
            let reset = TimeText.clock(points.reset.millisecondsSince1970, zone: zone)
            return "\(left) of \(limit) left · resets \(reset)"
        case .failure(let error): return "Not available - \(error.message)"
        case nil: return none
        }
    }

    // The free disk in whole GB as Finder counts them (1,000,000,000 bytes in a GB): "123 GB".
    package static func disk(_ bytes: UInt64?) -> String {
        bytes.map { "\(Int((Double($0) / 1_000_000_000).rounded())) GB" } ?? none
    }

    // The key of the trend line: "Last 3 min" while the samples cover less than 10 minutes (the
    // minutes up to the next whole minute, from 1), then "Last 10 minutes".
    package static func trendKey(_ trend: [Sample]) -> String {
        let span = trend.last.map { last in last.at - (trend.first?.at ?? last.at) } ?? .zero
        let minutes = max(1, Int((span / .seconds(60)).rounded(.up)))
        return minutes >= 10 ? "Last 10 minutes" : "Last \(minutes) min"
    }

    private static func grouped(_ number: Int) -> String {
        number.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}
