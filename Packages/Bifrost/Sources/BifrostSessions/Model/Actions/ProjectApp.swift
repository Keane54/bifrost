// The apps that the session actions open: the terminal apps of Open in terminal and the apps of
// Open project. The settings keep the choice of the user with these IDs.

// The terminal apps, in the order of the default rule.
package enum TerminalAppID: String, Sendable, CaseIterable, Codable {
    case warp, ghostty, iterm2, terminal
}

// The apps for "Open project". finder is still a value that loads, so an old file loads. It acts
// as Automatic.
package enum ProjectAppID: String, Sendable, CaseIterable, Codable {
    case finder, vscode, zed, warp, ghostty, iterm2, terminal

    // The terminal app of the same name, or nil for an app that is not a terminal app.
    package var terminal: TerminalAppID? { TerminalAppID(rawValue: rawValue) }

    // The name of the app that the menus and the Settings selects show.
    package var name: String {
        switch self {
        case .finder: "Finder"
        case .vscode: "VS Code"
        case .zed: "Zed"
        case .warp: "Warp"
        case .ghostty: "Ghostty"
        case .iterm2: "iTerm2"
        case .terminal: "Terminal"
        }
    }
}

// An installed app that can open a project folder, with the name that the menu shows.
package struct ProjectApp: Sendable, Equatable {
    package var id: ProjectAppID
    package var label: String

    package init(id: ProjectAppID, label: String) {
        self.id = id
        self.label = label
    }
}
