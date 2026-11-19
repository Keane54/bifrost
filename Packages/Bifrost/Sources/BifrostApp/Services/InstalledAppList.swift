// The installed apps of Open project and Open in terminal (ProjectApps.projectApps) for the action
// runner (docs/behaviour/actions.md, "The apps of a session"). The runner reads the list at each
// run on the main actor, so the find reads the file system off the main actor (BlockingExecutor)
// and the list keeps the last result. The list is observable, so the buttons and the row menu
// follow a new list.
//
// - The list is empty until the first find ends.
// - The list depends on the Terminal app setting, so a find runs at the start and after each
//   change of that setting (follow(_:)). A change of another setting gives the same value of the
//   Terminal app setting, and it runs no search.
// - A find that ends after a later find changes nothing.
import BifrostFoundation
import BifrostSessions
import BifrostSettings
import Foundation
import Observation

@MainActor
@Observable
package final class InstalledAppList {
    package private(set) var apps: [InstalledApp] = []
    // The search of the apps for a Terminal app setting. A test gives a fake, so no test reads
    // the folders of the apps.
    @ObservationIgnored private let search: @Sendable (TerminalAppID?) -> [InstalledApp]
    // Each find adds one, so the result of an old find goes nowhere.
    @ObservationIgnored private var finds = 0
    // The Terminal app setting of the last search, or nil before the first search.
    @ObservationIgnored private var searched: TerminalAppID??
    @ObservationIgnored private var following: Task<Void, Never>?

    // The apps in /Applications and in <home>/Applications.
    package convenience init(home: URL) {
        self.init { terminal in
            ProjectApps.projectApps(home: home, exists: ProjectApps.fileExists, terminal: terminal)
        }
    }

    package init(search: @escaping @Sendable (TerminalAppID?) -> [InstalledApp]) {
        self.search = search
    }

    isolated deinit {
        following?.cancel()
    }

    // Find the apps for the Terminal app setting of the store, now and after each change of the
    // setting. Only the first call counts. The result is the task that follows the setting. A
    // test waits for the finds of its changes.
    @discardableResult
    package func follow(_ settings: SettingsStore) -> Task<Void, Never> {
        if let following { return following }
        let changes = Observations { settings.settings.terminalApp }
        let task = Task { [weak self] in
            for await terminal in changes {
                guard let self else { return }
                await self.find(terminal)
            }
        }
        following = task
        return task
    }

    // Find the apps for the Terminal app setting off the main actor, and keep the result. The
    // value of the last search needs no new search.
    package func find(_ terminal: TerminalAppID?) async {
        if searched == .some(terminal) { return }
        searched = .some(terminal)
        finds += 1
        let number = finds
        let search = search
        let found = await BlockingExecutor.run { search(terminal) }
        guard number == finds, found != apps else { return }
        apps = found
    }
}
