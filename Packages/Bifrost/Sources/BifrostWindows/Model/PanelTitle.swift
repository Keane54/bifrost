import BifrostFoundation
import BifrostLayout
import BifrostSessions

// The title of a panel as plain text. A chat panel and a Show Info panel take the name of the row
// of their session. A module panel takes the title of its manifest in phase 7. Until then it is
// "Module", as for a module that is not in the list.
package enum PanelTitle {
    package static func of(_ panel: PanelID, rows: [SessionRow]) -> String {
        switch panel {
        case .overview(let number):
            return number == 1 ? "Overview" : "Overview \(number)"
        case .overviewSettings(let number):
            return number == 1 ? "Overview Settings" : "Overview \(number) Settings"
        case .selectedItem: return "Selected Item"
        case .settings: return "Settings"
        case .watchlist: return "Watchlist"
        case .chat(let session):
            return name(of: session, in: rows) ?? "Chat"
        case .eventLog: return "Event log"
        case .usageHud: return "Usage HUD"
        case .serviceStatus: return "Service status"
        case .reviews: return "Reviews"
        case .performance: return "Performance"
        case .dailyUpdate: return "Daily update"
        case .trust: return "Trust a repository"
        case .answer: return "Answer Claude"
        case .reviewDraft: return "Review"
        case .showInfo(let session):
            return name(of: session, in: rows).map { "Show Info: \($0)" } ?? "Show Info"
        case .module: return "Module"
        case .heimdall: return "Heimdall"
        }
    }

    // The name of the first row of the session.
    private static func name(of session: SessionID, in rows: [SessionRow]) -> String? {
        rows.first { $0.sessionId == session.text }?.name
    }
}
