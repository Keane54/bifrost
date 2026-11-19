// The installed apps of Open project and Open in terminal (docs/behaviour/actions.md, "The apps
// of a session"). The find only checks paths: it asks Launch Services nothing and opens nothing.
import Darwin
import Foundation

// An installed app and the path of its bundle.
package struct InstalledApp: Sendable, Equatable {
    package var app: ProjectApp
    package var path: String

    package init(app: ProjectApp, path: String) {
        self.app = app
        self.path = path
    }
}

package enum ProjectApps {
    // The bundle of Finder. Open the worktree shows a folder with it.
    package static let finderPath = "/System/Library/CoreServices/Finder.app"

    // An app that Bifrost looks for. A bundle with no "/" at the start is in /Applications or in
    // <home>/Applications. A bundle with a "/" at the start is only at that path.
    private struct Candidate {
        var id: ProjectAppID
        var bundle: String
    }

    private static let candidates = [
        Candidate(id: .finder, bundle: finderPath),
        Candidate(id: .vscode, bundle: "Visual Studio Code.app"),
        Candidate(id: .zed, bundle: "Zed.app"),
        Candidate(id: .warp, bundle: "Warp.app"),
        Candidate(id: .ghostty, bundle: "Ghostty.app"),
        Candidate(id: .iterm2, bundle: "iTerm.app"),
        Candidate(id: .terminal, bundle: "/System/Applications/Utilities/Terminal.app"),
    ]

    // Each installed terminal app, in the terminal order (TerminalAppID). The Settings select of
    // the terminal app lists them.
    package static func terminals(home: URL, exists: (String) -> Bool) -> [InstalledApp] {
        let found = installed(home: home, exists: exists)
        return TerminalAppID.allCases.compactMap { found[ProjectAppID(terminal: $0)] }
    }

    // Finder, then VS Code and Zed when they are installed, then one terminal app: the chosen
    // one when it is installed, else the first installed one of the terminal order.
    package static func projectApps(home: URL, exists: (String) -> Bool, terminal: TerminalAppID?)
        -> [InstalledApp]
    {
        let found = installed(home: home, exists: exists)
        let chosen = terminal.flatMap { found[ProjectAppID(terminal: $0)] }
        let first = TerminalAppID.allCases.lazy.compactMap { found[ProjectAppID(terminal: $0)] }
            .first
        let apps = [ProjectAppID.finder, .vscode, .zed].compactMap { found[$0] }
        return apps + [chosen ?? first].compactMap { $0 }
    }

    // The existence check of a path (access with F_OK), which follows a link. It reads the file
    // system, so a caller runs it off the main actor.
    package static func fileExists(_ path: String) -> Bool {
        !path.isEmpty && !path.unicodeScalars.contains("\0") && access(path, F_OK) == 0
    }

    // The installed candidates, each at its first path that exists.
    private static func installed(home: URL, exists: (String) -> Bool)
        -> [ProjectAppID: InstalledApp]
    {
        var found: [ProjectAppID: InstalledApp] = [:]
        for candidate in candidates {
            if let path = locate(candidate.bundle, home: home, exists: exists) {
                found[candidate.id] = InstalledApp(
                    app: ProjectApp(id: candidate.id, label: candidate.id.name), path: path)
            }
        }
        return found
    }

    private static func locate(_ bundle: String, home: URL, exists: (String) -> Bool) -> String? {
        if bundle.hasPrefix("/") { return exists(bundle) ? bundle : nil }
        let folders = [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            home.appending(path: "Applications", directoryHint: .isDirectory),
        ]
        return folders.lazy.map {
            $0.appending(path: bundle, directoryHint: .notDirectory).path(percentEncoded: false)
        }.first(where: exists)
    }
}

extension ProjectAppID {
    // The app ID of a terminal app.
    package init(terminal: TerminalAppID) {
        switch terminal {
        case .warp: self = .warp
        case .ghostty: self = .ghostty
        case .iterm2: self = .iterm2
        case .terminal: self = .terminal
        }
    }
}
