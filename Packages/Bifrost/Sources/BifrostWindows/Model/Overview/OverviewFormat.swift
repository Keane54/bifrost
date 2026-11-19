import BifrostFoundation
import BifrostSessions
import Foundation

// The colour band of the context bar.
package enum ContextBand: String, Sendable {
    case low, mid, high
}

// The tone of a state label.
package enum Tone: String, Sendable {
    case active, yellow, red, dim, parked
}

// The cell texts and the tones of the Overview.
package enum OverviewFormat {
    // The last two parts of the repository path (repoPath). The root folder gives "/".
    package static func projectLabel(_ cwd: String) -> String {
        let parts = repoPath(cwd).unicodeScalars.split(separator: "/")
        guard !parts.isEmpty else { return cwd.isEmpty ? "" : "/" }
        return parts.suffix(2).map { String($0) }.joined(separator: "/")
    }

    // The cost from Claude Code is a simulated cost: the token counts times the public API
    // prices. So the text starts with the mark "≈", as the status line of the user does (user
    // decision, 2026-11-10). A cost above 0 and below one cent gives "<$0.01" with no mark: the
    // "<" already shows that the value is not exact. A value that is not finite gives no text.
    package static func cost(_ usd: Double?) -> String {
        guard let usd, usd.isFinite else { return "" }
        if usd > 0, usd < 0.01 { return "<$0.01" }
        return "≈$" + twoDecimals(usd)
    }

    // The percent as a whole number. A half rounds up.
    package static func percent(_ p: Double?) -> String {
        guard let p, p.isFinite else { return "" }
        let whole = roundHalfUp(p)
        return (Int(exactly: whole).map(String.init) ?? "\(whole)") + "%"
    }

    // The fill of the context bar, from 0 to 100. A value that is not finite gives an empty bar.
    package static func barFill(_ p: Double?) -> Double {
        guard let p, p.isFinite else { return 0 }
        return min(100, max(0, p))
    }

    // The band of the context bar: low below 40, mid from 40 to below 70, high from 70. A value
    // that is not finite has no band.
    package static func contextBand(_ p: Double?) -> ContextBand? {
        guard let p, p.isFinite else { return nil }
        if p < 40 { return .low }
        return p < 70 ? .mid : .high
    }

    // The band of the percent that the cell shows. The text rounds the percent to a whole
    // number, so the band uses that number: 39.6 shows 40% with the mid band.
    package static func shownContextBand(_ p: Double?) -> ContextBand? {
        guard let p, p.isFinite else { return nil }
        return contextBand(roundHalfUp(p))
    }

    package static func stateLabel(_ state: SessionState) -> String {
        switch state {
        case .working: "Working"
        case .needsYou: "Alert"
        case .error: "Error"
        case .idle: "Idle"
        case .parked: "Parked"
        }
    }

    // Red for an error and for a row that needs the user, except with a yellow box.
    package static func stateTone(_ row: SessionRow) -> Tone {
        switch row.state {
        case .error: return .red
        case .needsYou:
            if case .yellow = row.alert { return .yellow }
            return .red
        case .working: return .active
        case .idle: return .dim
        case .parked: return .parked
        }
    }

    // The first lines of the text that have content, trimmed. A line ends at each line feed, so
    // a carriage return before it goes with the trim.
    package static func previewLines(_ text: String?, max: Int = 3) -> [String] {
        guard let text, max > 0 else { return [] }
        let lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        return Array(lines.lazy.map { String($0).trimmed() }.filter { !$0.isEmpty }.prefix(max))
    }

    // MARK: - Helpers

    // The nearest whole number. A half rounds up, also below zero: -2.5 gives -2.
    private static func roundHalfUp(_ value: Double) -> Double {
        let down = value.rounded(.down)
        return value - down >= 0.5 ? down + 1 : down
    }

    // The number with two decimals: the nearest text, and the larger magnitude when the number
    // is exactly halfway between two texts. Only a number m / 8 with an odd m can be exactly
    // halfway, and printf gives the even last digit for it, so that case counts the cents
    // itself. The count is exact for a number below 2^40.
    private static func twoDecimals(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let size = value.magnitude
        let eighths = size * 8
        let halfway =
            size < 0x1p40 && eighths == eighths.rounded(.down)
            && eighths.truncatingRemainder(dividingBy: 2) == 1
        guard halfway else { return sign + String(format: "%.2f", size) }
        let cents = Int((size * 100).rounded(.up))
        let fraction = cents % 100
        return sign + "\(cents / 100)." + (fraction < 10 ? "0" : "") + "\(fraction)"
    }
}
