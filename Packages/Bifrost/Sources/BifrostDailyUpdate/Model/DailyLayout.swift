import Foundation

// The files of the Daily update in its folder (SharedClaudeState.dailyUpdateFolder). The folder
// has the layout of the Electron app, so the app takes the state over in place.
package struct DailyLayout: Sendable, Equatable {
    package let folder: URL

    package init(folder: URL) {
        self.folder = folder
    }

    // The day state.
    package var stateFile: URL { file("state.json") }
    // The copy of the day state that the first open of this app makes. It is never replaced.
    package var stateCopy: URL { file("state.json.before-native") }
    // The skills export of the settings.
    package var exportFile: URL { file("settings.json") }
    // The files of the runs.
    package var runsFolder: URL { folder.appendingPathComponent("runs", isDirectory: true) }
    // The lock file: the copy of Bifrost that holds the lock owns the state.
    package var lockFile: URL { file(".lock") }

    private func file(_ name: String) -> URL {
        folder.appendingPathComponent(name, isDirectory: false)
    }
}
