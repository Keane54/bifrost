// The labels of the rows of the Settings sections (docs/behaviour/settings.md, "The sections").
// This file is the one source of the labels: each row shows its label, and the search finds a
// row only by its label. The sections of a later build add their label lists here.

// The rows of Settings > General, in the order of the rows in the section. The raw value is the
// label of the row.
package enum GeneralRow: String, Sendable, CaseIterable {
    case labels = "Labels"
    case terminalApp = "Terminal app"
    case projectApp = #"Default app for "Open project""#
    case escalation = "Escalation time"
    case rowFlash = "Row flash"
    case notifications = "macOS notification"
    case redBoxSound = "Sound for a red box"
    case startAtLogin = "Start at login"
    case accountUsage = "Account usage from Anthropic"
    case poll = "Poll interval"
    case snap = "Snap distance"
    case transparency = "Panel transparency"
    case animatedBackground = "Animated background"
    case scale = "Interface scale"
    case font = "Terminal font"
    case displayMode = "Display mode"
    case introduction = "Introduction"
}

// A row of the Settings panel that saves. The panel keeps the save state and the error of each
// row, and drops them when the row goes away, for example when a search hides it
// (docs/behaviour/settings.md, "Saving").
package struct SettingsRowID: Hashable, Sendable {
    // When the row shows during a search.
    package enum Search: Hashable, Sendable {
        // The search finds the row by this ID (SearchRow.id), for example the label of a General
        // row or the stored ID of a key slot. The row shows when it matches, or when its whole
        // section shows.
        case found(String)
        // The row shows with each hit of its section, for example the list of slash commands.
        case withHit(String)
        // The row shows only with its whole section: with no search, or when the query matches
        // the title of the section. For example the field for a new slash command.
        case wholeSection(String)
    }

    package var section: SettingsSection
    package var search: Search

    package init(_ section: SettingsSection, _ search: Search) {
        self.section = section
        self.search = search
    }

    // The row of a row of Settings > General.
    package static func general(_ row: GeneralRow) -> SettingsRowID {
        SettingsRowID(.general, .found(row.rawValue))
    }

    // True when the row shows. With no search (hits is nil), the rows of the active section show.
    // During a search, the hit of the section of the row and the search rule of the row decide.
    package func isShown(section active: SettingsSection, hits: [SearchHit]?) -> Bool {
        guard let hits else { return section == active }
        guard let hit = hits.first(where: { $0.id == section }) else { return false }
        switch search {
        case .found(let id): return hit.whole || hit.rows.contains(id)
        case .withHit: return true
        case .wholeSection: return hit.whole
        }
    }
}
