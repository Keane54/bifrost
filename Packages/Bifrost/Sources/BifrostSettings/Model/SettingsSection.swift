// The sections of the Settings panel (docs/behaviour/settings.md, "The sections"). The cases are
// in the order of the tabs. The raw value is the ID of the section.
package enum SettingsSection: String, Sendable, CaseIterable {
    case general, slash, keys, reviews, dailyUpdate = "daily-update", live, skills, modules
    case updates

    // The title of the tab. The search results show it above the hits of the section.
    package var title: String {
        switch self {
        case .general: "General"
        case .slash: "Slash commands"
        case .keys: "Keys"
        case .reviews: "Reviews"
        case .dailyUpdate: "Daily update"
        case .live: "Live details"
        case .skills: "Skills"
        case .modules: "Modules"
        case .updates: "Updates"
        }
    }
}
