import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation

// The shared paths of a home. Each path is only a value. Only the test of the file paths makes
// folders, in a temporary home.

private let home = URL(fileURLWithPath: "/Users/someone")

// The paths of the value, in the order of its fields. Mirror gives each field, so a new field is
// in the list without a change of the tests.
private func paths(_ state: SharedClaudeState) -> [String] {
    Mirror(reflecting: state).children.compactMap { ($0.value as? URL)?.path }
}

// A path check that reads no file: no path is a link.
private let noLinks = PathCheck(ignoresCase: true, realPath: { _ in nil })

@Suite("shared Claude state", .testTimeLimit)
struct SharedClaudeStateTests {
    // The shared state has only the paths of the user decision of 2026-11-16 and the three
    // folders of phase 5. A new path needs a new review. Each path is under the home that the
    // init gets.
    @Test func theSharedPathsFollowTheHome() {
        for home in [home, URL(fileURLWithPath: "/tmp/x")] {
            let state = SharedClaudeState(home: home)
            let labels = Mirror(reflecting: state).children.map(\.label)
            #expect(
                labels == [
                    "liveSocket", "modFolder", "skillsFolder", "claudeSettings", "backups",
                    "savedStatusLine", "bifrostHome", "reviewsFolder", "dailyUpdateFolder",
                    "handoversFolder",
                ])
            let root = home.path
            #expect(
                paths(state) == [
                    "\(root)/.bifrost/live.sock", "\(root)/.bifrost/mod",
                    "\(root)/.bifrost/skills", "\(root)/.claude/settings.json",
                    "\(root)/.bifrost/backups", "\(root)/.bifrost/statusline-original.json",
                    "\(root)/.bifrost", "\(root)/.bifrost/reviews",
                    "\(root)/.bifrost/daily-update", "\(root)/.bifrost/handovers",
                ])
        }
    }

    // The folders of Reviews, the Daily update and the hand-over notes keep their Electron names in
    // the dot folder.
    @Test func theReviewsDailyUpdateAndHandOverFoldersAreInTheDotFolder() {
        let state = SharedClaudeState(home: home)
        let folders = [
            (state.reviewsFolder, "reviews"), (state.dailyUpdateFolder, "daily-update"),
            (state.handoversFolder, "handovers"),
        ]
        for (folder, name) in folders {
            #expect(folder.path == "/Users/someone/.bifrost/\(name)")
            #expect(!folder.path.hasSuffix("/"))
        }
    }

    // A test home from the environment gives each shared path under the test home, and no path
    // under the real home.
    @Test func aTestHomeGivesPathsUnderTheTestHome() {
        let environment = [HomeLocator.testHomeKey: "/tmp/bifrost-test-home/"]
        let choice = HomeLocator.choose(
            variant: .development, environment: environment, realHome: home, check: noLinks)
        guard case .home(let testHome, isTest: true) = choice else {
            Issue.record("The test home was refused: \(choice)")
            return
        }
        let state = SharedClaudeState(home: testHome)
        #expect(paths(state).count == 10)
        for path in paths(state) {
            #expect(path.hasPrefix("/tmp/bifrost-test-home/"), "\(path)")
            #expect(!path.hasPrefix(home.path), "\(path)")
        }
    }

    // The saved status line of the user is a file in the dot folder of Bifrost, beside the
    // backups of the settings file of Claude Code (statusline-original.json of the Electron
    // integration).
    @Test func theSavedStatusLineIsInTheBifrostFolder() {
        let state = SharedClaudeState(home: home)
        #expect(state.savedStatusLine.lastPathComponent == "statusline-original.json")
        #expect(state.savedStatusLine.deletingLastPathComponent().path == state.bifrostHome.path)
        #expect(state.backups.deletingLastPathComponent().path == state.bifrostHome.path)
        #expect(state.bifrostHome.path == "/Users/someone/.bifrost")
    }

    // A file path gets no "/" at its end, also when a folder is at the path, so a text that names
    // the path shows it as it is.
    @Test func aFolderAtAFilePathAddsNoSlash() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let files = [
            ".bifrost/live.sock", ".claude/settings.json", ".bifrost/statusline-original.json",
        ]
        for file in files {
            try FileManager.default.createDirectory(
                atPath: folder.appending(file), withIntermediateDirectories: true)
        }
        let state = SharedClaudeState(home: folder.url)
        let shown = [state.liveSocket, state.claudeSettings, state.savedStatusLine]
            .map { $0.path(percentEncoded: false) }
        #expect(shown == files.map { folder.appending($0) })
    }

    // The shared state never gives a store folder of the Electron app.
    @Test func noSharedPathIsInApplicationSupport() {
        let state = SharedClaudeState(home: home)
        #expect(paths(state).count == 10)
        for path in paths(state) {
            #expect(!path.contains("Library/Application Support"))
            #expect(path.hasPrefix("/Users/someone/"))
        }
    }
}
