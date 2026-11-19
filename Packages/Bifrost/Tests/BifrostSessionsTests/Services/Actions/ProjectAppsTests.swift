// The installed apps of Open project and Open in terminal (docs/behaviour/actions.md, "The apps
// of a session"). The tests give a fake existence check, so no test looks for a real app.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSessions

private let home = URL(filePath: "/home/u", directoryHint: .isDirectory)
private let finder = "/System/Library/CoreServices/Finder.app"
private let terminal = "/System/Applications/Utilities/Terminal.app"

// An existence check that knows only these paths.
private func have(_ paths: String...) -> (String) -> Bool {
    { paths.contains($0) }
}

@Suite("the apps of a session")
struct ProjectAppsTests {
    @Test func theProjectAppsAreFinderVSCodeAndZedThenTheFirstTerminalApp() {
        let exists = have(
            finder, "/Applications/Visual Studio Code.app", "/Applications/Zed.app",
            "/Applications/Ghostty.app", "/Applications/iTerm.app")
        let apps = ProjectApps.projectApps(home: home, exists: exists, terminal: nil)
        #expect(apps.map(\.app.id) == [.finder, .vscode, .zed, .ghostty])
        #expect(apps.map(\.path).last == "/Applications/Ghostty.app")
    }

    @Test func anAppInTheApplicationsFolderOfTheHomeIsFound() {
        let apps = ProjectApps.projectApps(
            home: home, exists: have("/home/u/Applications/Zed.app"), terminal: nil)
        let zed = InstalledApp(
            app: ProjectApp(id: .zed, label: "Zed"), path: "/home/u/Applications/Zed.app")
        #expect(apps == [zed])
    }

    @Test func anAppInTheMainApplicationsFolderComesFirst() {
        let exists = have("/Applications/Zed.app", "/home/u/Applications/Zed.app")
        let apps = ProjectApps.projectApps(home: home, exists: exists, terminal: nil)
        #expect(apps.map(\.path) == ["/Applications/Zed.app"])
    }

    // Finder and Terminal are found only at their own paths in the system folders.
    @Test func aSystemAppIsFoundOnlyAtItsOwnPath() {
        let exists = have("/Applications/Finder.app", "/Applications/Terminal.app")
        #expect(ProjectApps.projectApps(home: home, exists: exists, terminal: nil).isEmpty)
    }

    @Test func terminalIsTheLastTerminalApp() {
        let apps = ProjectApps.projectApps(
            home: home, exists: have(finder, terminal), terminal: nil)
        #expect(apps.map(\.app.id) == [.finder, .terminal])
    }

    @Test func theChosenTerminalAppComesWhenItIsInstalled() {
        let exists = have(finder, "/Applications/Warp.app", terminal)
        let chosen = ProjectApps.projectApps(home: home, exists: exists, terminal: .terminal)
        #expect(chosen.map(\.app.id) == [.finder, .terminal])
    }

    @Test func aChosenTerminalAppThatIsNotInstalledGivesTheFirstInstalledOne() {
        let exists = have(finder, "/Applications/Warp.app", terminal)
        let missing = ProjectApps.projectApps(home: home, exists: exists, terminal: .ghostty)
        #expect(missing.map(\.app.id) == [.finder, .warp])
    }

    @Test func theTerminalsAreEachInstalledTerminalAppInTheTerminalOrder() {
        let exists = have(terminal, "/Applications/Warp.app", "/Applications/Zed.app")
        let apps = ProjectApps.terminals(home: home, exists: exists)
        #expect(apps.map(\.app.id) == [.warp, .terminal])
    }

    @Test func eachAppHasTheLabelOfTheMenu() {
        let exists = have(
            finder, "/Applications/Visual Studio Code.app", "/Applications/Zed.app",
            "/Applications/Warp.app", "/Applications/Ghostty.app", "/Applications/iTerm.app",
            terminal)
        let labels = ProjectApps.projectApps(home: home, exists: exists, terminal: nil).map(
            \.app.label)
        #expect(labels == ["Finder", "VS Code", "Zed", "Warp"])
        #expect(
            ProjectApps.terminals(home: home, exists: exists).map(\.app.label)
                == ["Warp", "Ghostty", "iTerm2", "Terminal"])
    }

    @Test func theExistenceCheckSeesAFolderAndNotAMissingPath() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        #expect(ProjectApps.fileExists(folder.path))
        #expect(!ProjectApps.fileExists(folder.appending("Zed.app")))
        #expect(!ProjectApps.fileExists(""))
    }
}
