// One icon for each panel kind. The side bar buttons and the minimised buttons use this map, so the
// two cannot show different icons for the same panel.
import BifrostLayout
import BifrostLook

@MainActor
extension PanelKind {
    package var icon: IconName {
        switch self {
        case .answer: .messageCircleQuestionMark
        case .chat: .messageSquare
        case .dailyUpdate: .messageSquareText
        case .eventLog: .scrollText
        case .heimdall: .shield
        // A module panel shows the icon of its manifest. This icon is for a module that is gone.
        case .module: .puzzle
        case .overview: .list
        case .overviewSettings: .slidersHorizontal
        case .performance: .heartPulse
        case .reviewDraft: .filePen
        case .reviews: .gitPullRequest
        case .selectedItem: .crosshair
        case .serviceStatus: .activity
        case .settings: .settings
        case .showInfo: .info
        case .trust: .shieldCheck
        case .usageHud: .gauge
        case .watchlist: .eye
        }
    }
}
