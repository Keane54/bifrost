// The values of the Show Info panel (docs/behaviour/panels.md, "Show Info"): the known values of
// one session, in seven sections. The rules are pure: the panel gives the row, the time of now,
// the PR of the PR lookup and the time zone.
import BifrostFoundation
import BifrostSessions
import Foundation

// One value of a section. A mono value is an ID or a path. control is the control that the panel
// shows with the value.
package struct InfoItem: Sendable, Equatable {
    package enum Control: Sendable, Equatable {
        case none
        // The Copy session ID button after the value.
        case copySessionId
        // The value is a link that opens the PR in the browser.
        case prLink
    }

    package var label: String
    package var value: String
    package var mono: Bool
    package var control: Control

    package init(label: String, value: String, mono: Bool = false, control: Control = .none) {
        self.label = label
        self.value = value
        self.mono = mono
        self.control = control
    }
}

package struct InfoSection: Sendable, Equatable {
    package var title: String
    package var items: [InfoItem]

    package init(title: String, items: [InfoItem]) {
        self.title = title
        self.items = items
    }
}

package enum ShowInfo {
    // The PR line while the PR lookup runs.
    package static let loading = "Loading..."
    // The text of the panel until the first session list comes.
    package static let waiting = "Waiting for the session list..."
    // The hint under the sections of a row with no live data.
    package static let liveHint =
        "Turn on Live details in Settings to see the model, effort, cost and limits."

    // The seven sections of the row, in order. A value that is not known shows "-". pr is nil
    // while the PR lookup runs.
    package static func sections(
        _ row: SessionRow, now: Int, pr: PRInfo?, zone: TimeZone = .current
    ) -> [InfoSection] {
        let usage = row.usage
        let limits = usage?.rateLimits
        return [
            InfoSection(title: "Session", items: sessionItems(row)),
            InfoSection(
                title: "Files",
                items: [
                    InfoItem(label: "Project folder", value: dash(row.cwd), mono: true),
                    InfoItem(label: "Transcript", value: dash(usage?.transcriptPath), mono: true),
                ]),
            InfoSection(
                title: "Git",
                items: [
                    InfoItem(label: "Branch", value: dash(row.branch)),
                    InfoItem(label: "PR", value: prText(pr), control: prControl(pr)),
                    InfoItem(
                        label: "Worktree",
                        value: WorktreeRoot(cwd: row.cwd, stored: row.worktree)?.worktree
                            ?? "None"),
                ]),
            InfoSection(
                title: "Model",
                items: [
                    InfoItem(label: "Model", value: dash(row.model)),
                    InfoItem(label: "Effort", value: dash(usage?.effort)),
                    InfoItem(label: "Permission mode", value: dash(usage?.permissionMode)),
                ]),
            InfoSection(
                title: "Time",
                items: [
                    InfoItem(
                        label: "Started",
                        value: row.startedAt > 0
                            ? TimeText.when(row.startedAt, now: now, zone: zone) : "-"),
                    InfoItem(label: "Duration", value: duration(row, now: now)),
                ]),
            InfoSection(
                title: "Cost and context",
                items: [
                    InfoItem(label: "Cost", value: dash(OverviewFormat.cost(usage?.costUsd))),
                    InfoItem(
                        label: "Context window",
                        value: usage?.contextWindow.map { "\(tokens($0)) tokens" } ?? "-"),
                    InfoItem(
                        label: "Context use",
                        value: dash(OverviewFormat.percent(usage?.contextPercent))),
                ]),
            // A plan can have no 5-hour window (user decision, 2026-11-10). Then its row hides,
            // as in the Usage HUD. A session with no limits yet shows both rows.
            InfoSection(
                title: "Limits and version",
                items: (limits?.sevenDay != nil && limits?.fiveHour == nil
                    ? []
                    : [
                        InfoItem(
                            label: "5-hour limit",
                            value: limit(limits?.fiveHour, now: now, zone: zone))
                    ])
                    + [
                        InfoItem(
                            label: "7-day limit",
                            value: limit(limits?.sevenDay, now: now, zone: zone)),
                        InfoItem(label: "Claude Code version", value: dash(usage?.version)),
                    ]),
        ]
    }

    // A count of tokens with one decimal at most: 999, 200k, 1.5M. The decimal rounds a half up.
    package static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return tenths(n, of: 1_000_000) + "M" }
        if n >= 1_000 { return tenths(n, of: 1_000) + "k" }
        return String(n)
    }

    // True for a row with no live line and no model: Live details is then off.
    package static func showsLiveHint(_ row: SessionRow) -> Bool {
        !row.live && row.model == nil
    }

    // MARK: - The parts

    // The Session section. The session ID is the ID that claude --resume needs, the ID that Copy
    // session ID copies (continueId). For a job after a /clear, that is not the conversation
    // that the row shows now, so the current conversation follows it. A local name hides the
    // real name, so the real name follows the name.
    private static func sessionItems(_ row: SessionRow) -> [InfoItem] {
        let resume = row.continueId?.text
        let current = row.currentIdOrRow
        var items = [InfoItem(label: "Name", value: dash(row.name))]
        if row.name != row.claudeName {
            items.append(InfoItem(label: "Claude Code name", value: dash(row.claudeName)))
        }
        items.append(
            InfoItem(
                label: "Session ID", value: dash(resume), mono: true, control: .copySessionId))
        if resume != current {
            items.append(InfoItem(label: "Current conversation", value: current, mono: true))
        }
        let kind =
            switch row.kind {
            case .owned: "Owned"
            case .external:
                "External" + (row.terminalApp.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? "")
            }
        items += [
            InfoItem(label: "Short ID", value: dash(row.shortId?.text), mono: true),
            InfoItem(label: "Kind", value: kind),
            InfoItem(label: "PID", value: row.pid.map(String.init) ?? "-"),
        ]
        return items
    }

    // Only a PR is a link.
    private static func prControl(_ pr: PRInfo?) -> InfoItem.Control {
        if case .pr? = pr { return .prLink }
        return .none
    }

    private static func prText(_ pr: PRInfo?) -> String {
        switch pr {
        case nil: loading
        case .pr(let number, let title, _, let state)?:
            "#\(number) \(title) (\(state.lowercased()))"
        case .none?: "None"
        case .unavailable(let reason)?: reason.text
        }
    }

    // After the reset time, the use of the new window is not known until the next message. Then
    // the limit shows "-" and the reset time, as in the Usage HUD. A percent that is not finite
    // also shows "-".
    private static func limit(_ window: RateWindow?, now: Int, zone: TimeZone) -> String {
        guard let window else { return "-" }
        let when = TimeText.when(window.resetsAt, now: now, zone: zone)
        if window.resetsAt <= now { return "-, reset at \(when)" }
        return "\(dash(OverviewFormat.percent(window.usedPercent))), resets \(when)"
    }

    private static func duration(_ row: SessionRow, now: Int) -> String {
        if row.state == .parked { return "Parked" }
        guard row.startedAt > 0 else { return "-" }
        let (elapsed, overflow) = now.subtractingReportingOverflow(row.startedAt)
        return overflow ? "-" : TimeText.duration(.milliseconds(elapsed))
    }

    // n in units of the size, with one decimal at most: 1500000 of 1000000 gives "1.5". The
    // count uses only whole numbers, so it cannot overflow, and an exact half rounds up.
    private static func tenths(_ n: Int, of size: Int) -> String {
        let tenth = size / 10
        let count = n / tenth + (n % tenth >= tenth / 2 ? 1 : 0)
        let whole = count / 10
        let decimal = count % 10
        return decimal == 0 ? String(whole) : "\(whole).\(decimal)"
    }

    // An empty or missing text shows "-".
    private static func dash(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "-" }
        return text
    }
}
