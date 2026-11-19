import BifrostFoundation
import Foundation

// How the app finds claude and the env of each claude run.
package enum ClaudeLookup: Sendable, Equatable {
    // The path of claude and the env of the claude runs from one interactive login shell
    // (LoginShell.load). The app can start from Finder, so its own env has the short
    // launchd PATH.
    case loginShell
    // The first claude on the PATH of the app env, and the app env. A test home uses this lookup,
    // so a test never runs the real login shell.
    case environmentPath
}

// The decisions of the start that come from the identity, the home and the env: the lookup of
// claude, the forced listen of Live details, the home of the plugin commands, the socket of the
// debug test port, the notifier, the account usage poller, the skip roots of the branch reader,
// the store files, the shared home and the source of the one-time import. The plan only gives
// values. It reads no file and makes no folder. The Live details server listens on the shared
// socket of the shared home (SharedClaudeState.liveSocket) by the start rule of LiveControl, so
// the plan has no socket of its own for it.
public struct StartPlan: Sendable, Equatable {
    // The dot folders of the development app and of the Electron app (and of the release app),
    // as AppIdentity.dotFolderName gives them.
    private static let dotFolderNames = [".bifrost-native-dev", ".bifrost"]

    package let claude: ClaudeLookup
    // True when Live details listens at the start with no check of the plugin: only the
    // development app with a test home, and only when the env has BIFROST_LIVE_LISTEN=1, for a
    // test by hand. The smoke test installs Live details through the test port instead. Each
    // other start listens only by the start rule.
    package let forceListen: Bool
    // The home of the plugin commands: the test home, or nil. With a test home, each claude
    // plugin command gets HOME and CLAUDE_CONFIG_DIR of the test home
    // (PluginCLI.environment(_:testHome:)), so it changes only files under the test home.
    package let pluginHome: URL?
    // The socket of the debug test port, or nil. Only the development app with a test home, in
    // its own dot folder: <test home>/.bifrost-native-dev/test.sock. Never in the real home, so a
    // test home that is the real home gives no socket. The app makes the port only in a Debug
    // build.
    public let testPort: String?
    // True when dictation uses the fake speech engine: only the development app with a test home,
    // so no test opens the microphone. The app makes the fake engine only in a Debug build. Each
    // other start uses the real engine.
    package let fakeSpeech: Bool
    // True when the app records each notification in memory and shows none: only the
    // development app with a test home, so no test run shows a notification of macOS
    // (RecordingNotifier). Each other start uses the notification centre of macOS.
    package let recordsNotifications: Bool
    // True when the app polls the account usage of Anthropic while the setting is on. A test
    // home has no poller, so a test run never reads the Keychain or reaches the network.
    package let pollsAccount: Bool
    // True when the app reads the public status pages of Claude, GitHub and Sentry each minute. A
    // test home has no such check, so a test run never reaches the network.
    package let checksServiceStatus: Bool
    // The file that holds the answer of the releases API in a test home: github-releases.json in
    // the test home. The release notes read it in place of GitHub, so a test run reaches no
    // network. nil with no test home.
    package let releasesFile: URL?
    // The state of What's new, release-notes.json in the support folder.
    package let releaseNotesFile: URL
    // True when What's new can open by itself at the start: only the release app. Bifrost Dev
    // never opens it by itself.
    package let opensWhatsNew: Bool
    // True when the Performance panel measures the network: the response times of Anthropic and
    // GitHub and the GitHub points. A test home measures none, so a test run makes no request.
    package let measuresNetwork: Bool
    // The folder of health.log of the Performance monitor: the logs folder of the app in the home
    // (DataFolders.logs), so a test home writes its log in the test home.
    package let healthLogFolder: URL
    // The home folder of the user in the user database, also with a test home: the sandbox of a
    // request session of Reviews refuses the secret paths in it.
    package let realHome: URL
    // The folders where a PR session can write its .git file and its git config: the reviews folder
    // of each dot folder, in the home and in the real home, with no repeated folder. The branch
    // reader reads no HEAD file and runs no git in them. A test home also skips the folders of the
    // real home, because its claude can list the real sessions (row D20 of
    // docs/ports/registry/DELIBERATE-DIFFERENCES.md).
    package let branchSkipRoots: [String]
    // The store files, in the support folder: the same names as the Electron app.
    package let settingsFile: URL
    package let registryFile: URL
    // The UI state and the window state. The app opens them before it shows the window.
    package let uiStateFile: URL
    package let windowStateFile: URL
    // The notified periods of the usage notification.
    package let usageAlertsFile: URL
    // The run folder of Open in terminal, which holds the command files of the attach: <dot
    // folder of the identity>/run (the own folders rule). So the development app never writes to
    // ~/.bifrost/run.
    package let runFolder: URL
    // The home of the state that Bifrost shares with Claude Code (SharedClaudeState): the
    // resolved home. With a test home, it is the test home, so no test reaches a real shared
    // path.
    package let sharedHome: URL
    // The support folder of the Electron app for the one-time import (ElectronImport), in the
    // resolved home: <home>/Library/Application Support/Bifrost. Only a development identity
    // imports. The release app uses that folder as its own support folder, so it gets nil. With
    // a test home, the folder is in the test home, so no test reads the real folder.
    package let electronSupport: URL?
    // The folder of the source repositories of the review clones in a test home:
    // <test home>/git-remotes, where <owner>/<repo>.git is a local bare repository. nil in each
    // other start: the clones come from GitHub.
    package let reviewsRemotes: URL?

    // The env key of the forced listen of Live details.
    package static let forceListenKey = "BIFROST_LIVE_LISTEN"

    // home is the resolved home (HomeLocator.choose). realHome is the home folder of the user,
    // from the launch code. testHome is true when the home is a test home (HomeLocator.choose).
    // A release identity ignores testHome: the release app never has a test home. folders are
    // the folders that the caller made. The plan uses the folders of the identity, and gives no
    // test port when the folders of the caller are other folders. environment is the env of the
    // app. With no env, nothing forces a listen.
    public init(
        identity: AppIdentity, home: URL, realHome: URL, testHome: Bool, folders: DataFolders,
        environment: [String: String] = [:]
    ) {
        let own = DataFolders(identity: identity, home: home)
        let testHome = testHome && identity.variant == .development
        claude = testHome ? .environmentPath : .loginShell
        forceListen = testHome && environment[Self.forceListenKey] == "1"
        pluginHome = testHome ? home : nil
        let realHomeIsHome = home.standardizedFileURL.path == realHome.standardizedFileURL.path
        testPort =
            testHome && folders == own && !realHomeIsHome
            ? own.dot.appendingPathComponent("test.sock").path : nil
        fakeSpeech = testHome
        recordsNotifications = testHome
        pollsAccount = !testHome
        checksServiceStatus = !testHome
        releasesFile = testHome ? home.appendingPathComponent("github-releases.json") : nil
        releaseNotesFile = own.support.appendingPathComponent("release-notes.json")
        opensWhatsNew = identity.variant == .release
        measuresNetwork = !testHome
        healthLogFolder = own.logs
        self.realHome = realHome
        var roots: [String] = []
        for folder in [home, realHome] {
            for name in Self.dotFolderNames {
                let root = Self.reviewsRoot(folder.appendingPathComponent(name, isDirectory: true))
                if !roots.contains(root) { roots.append(root) }
            }
        }
        branchSkipRoots = roots
        settingsFile = own.support.appendingPathComponent("settings.json")
        registryFile = own.support.appendingPathComponent("registry.json")
        uiStateFile = own.support.appendingPathComponent("ui-state.json")
        windowStateFile = own.support.appendingPathComponent("window-state.json")
        usageAlertsFile = own.support.appendingPathComponent("usage-alerts.json")
        runFolder = own.dot.appendingPathComponent("run", isDirectory: true)
        sharedHome = home
        electronSupport =
            identity.variant == .development ? ElectronStores(home: home).folder : nil
        reviewsRemotes =
            testHome ? home.appendingPathComponent("git-remotes", isDirectory: true) : nil
    }

    // The folder of the review repos of a dot folder: <dot folder>/reviews/repos.
    private static func reviewsRoot(_ dot: URL) -> String {
        dot.appendingPathComponent("reviews", isDirectory: true)
            .appendingPathComponent("repos", isDirectory: true).path
    }
}
