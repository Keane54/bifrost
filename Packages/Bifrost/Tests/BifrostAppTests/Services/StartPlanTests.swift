import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostApp
@testable import BifrostDictation
@testable import BifrostFoundation
@testable import BifrostSessions

// The start plan of the app: the lookup of claude, the forced listen of Live details, the home of
// the plugin commands, the skip roots of the branch reader, the store files and the shared home.
// The plan only gives paths. No test here makes a file on a real path.

private let home = URL(fileURLWithPath: "/tmp/x")
// The real home in a plan with a test home. The plan only gives paths, so the path is not read.
private let someRealHome = URL(fileURLWithPath: "/Users/someone")

private func identity(_ bundleID: String) throws -> AppIdentity {
    try #require(AppIdentity(bundleID: bundleID))
}

private func development() throws -> AppIdentity { try identity("com.example.app.native-dev") }
private func release() throws -> AppIdentity { try identity("com.example.app") }

// A plan as the app makes it. With no test home, the home is the real home.
private func plan(
    _ identity: AppIdentity, home: URL = home, realHome: URL? = nil, testHome: Bool,
    folders: DataFolders? = nil, environment: [String: String] = [:]
) -> StartPlan {
    StartPlan(
        identity: identity, home: home,
        realHome: realHome ?? (testHome ? someRealHome : home),
        testHome: testHome, folders: folders ?? DataFolders(identity: identity, home: home),
        environment: environment)
}

private let listen = [StartPlan.forceListenKey: "1"]

@Suite("start plan", .testTimeLimit)
struct StartPlanTests {
    // The Live details server listens on the shared socket of the shared home by the start rule
    // of the live control, so the plan has no socket of its own for it. No value of the plan
    // names a Live socket, for each identity and each test home value.
    @Test func thePlanHasNoOwnSocketAnyMore() throws {
        for identity in [try development(), try release()] {
            for testHome in [true, false] {
                let plan = plan(identity, testHome: testHome, environment: listen)
                let values = Mirror(reflecting: plan).children
                #expect(!values.contains { $0.label == "liveSocket" })
                #expect(!values.contains { "\($0.value)".contains("live.sock") })
            }
        }
    }

    // BIFROST_LIVE_LISTEN=1 forces a listen only in the development app with a test home: never
    // with no test home, never in a Release build and never with another value.
    @Test func forceListenWorksOnlyWithATestHome() throws {
        #expect(plan(try development(), testHome: true, environment: listen).forceListen)
        #expect(!plan(try development(), testHome: false, environment: listen).forceListen)
        for testHome in [true, false] {
            #expect(!plan(try release(), testHome: testHome, environment: listen).forceListen)
        }
        for value in ["0", "true", "", " 1"] {
            let environment = [StartPlan.forceListenKey: value]
            #expect(!plan(try development(), testHome: true, environment: environment).forceListen)
        }
        #expect(!plan(try development(), testHome: true).forceListen)
    }

    // The plugin commands run in the test home only with a test home of the development app.
    @Test func thePluginHomeIsTheTestHomeOnly() throws {
        #expect(plan(try development(), testHome: true).pluginHome == home)
        #expect(plan(try development(), testHome: false).pluginHome == nil)
        for testHome in [true, false] {
            #expect(plan(try release(), testHome: testHome).pluginHome == nil)
        }
    }

    @Test func aTestHomeUsesTheEnvironmentPath() throws {
        #expect(plan(try development(), testHome: true).claude == .environmentPath)
        #expect(plan(try development(), testHome: false).claude == .loginShell)
        for testHome in [true, false] {
            #expect(plan(try release(), testHome: testHome).claude == .loginShell)
        }
    }

    // The plan does not trust its caller: the folders of another identity give no test port.
    // The plan uses the folders of the identity for the stores.
    @Test func theFoldersOfAnotherIdentityGiveTheStoresOfTheIdentity() throws {
        let identity = try development()
        let other = DataFolders(identity: try release(), home: home)
        let plan = plan(identity, testHome: true, folders: other)
        #expect(plan.testPort == nil)
        let support = "/tmp/x/Library/Application Support/Bifrost Native Dev"
        #expect(plan.settingsFile.path == "\(support)/settings.json")
        #expect(plan.registryFile.path == "\(support)/registry.json")
    }

    // The reviews folder of the development app and the reviews
    // folder of the Electron app, where a PR session can write, in the home and in the real home.
    @Test func branchSkipsBothReviewsFolders() throws {
        let own = "/tmp/x/.bifrost-native-dev/reviews/repos"
        let electron = "/tmp/x/.bifrost/reviews/repos"
        for identity in [try development(), try release()] {
            #expect(plan(identity, testHome: false).branchSkipRoots == [own, electron])
        }
        // A test home also skips the folders of the real home: the claude of a test home can
        // list the real sessions.
        let roots = plan(try development(), testHome: true).branchSkipRoots
        #expect(
            roots == [
                own, electron, "/Users/someone/.bifrost-native-dev/reviews/repos",
                "/Users/someone/.bifrost/reviews/repos",
            ])
        #expect(Set(roots).count == roots.count)
    }

    // The sandbox of a request session of Reviews refuses the secret paths of the real home, also
    // with a test home.
    @Test func theRealHomeIsTheHomeOfTheUser() throws {
        #expect(plan(try development(), testHome: true).realHome.path == "/Users/someone")
        #expect(plan(try release(), testHome: false).realHome.path == "/tmp/x")
    }

    @Test func theStoresAreInTheDevelopmentSupportFolder() throws {
        let plan = plan(try development(), testHome: true)
        let support = "/tmp/x/Library/Application Support/Bifrost Native Dev"
        #expect(plan.settingsFile.path == "\(support)/settings.json")
        #expect(plan.registryFile.path == "\(support)/registry.json")
        #expect(plan.usageAlertsFile.path == "\(support)/usage-alerts.json")
    }

    // The services that the app makes for a test home record the notifications and have no
    // account usage poller. The services do not start, so they read no file and run no program.
    @MainActor
    @Test func theAppServicesOfATestHomeRecordAndHaveNoPoller() throws {
        let plan = plan(try development(), testHome: true)
        // The full name picks the init of the app, not the init of the tests, whose defaults
        // give the same values.
        let make = AppServices.init(plan:home:environment:)
        let services = make(plan, home, [:])
        #expect(services.notifier is RecordingNotifier)
        #expect(services.poller == nil)
    }

    // The release notes read github-releases.json of a test home in place of GitHub. Only the
    // release app can open What's new by itself, and its state is release-notes.json in the
    // support folder (docs/behaviour/updates.md).
    @Test func theReleaseNotesFollowTheHomeAndTheVariant() throws {
        let test = plan(try development(), testHome: true)
        #expect(test.releasesFile == home.appendingPathComponent("github-releases.json"))
        #expect(!test.opensWhatsNew)
        let dev = plan(try development(), testHome: false)
        #expect(dev.releasesFile == nil)
        #expect(!dev.opensWhatsNew)
        for testHome in [true, false] {
            let rel = plan(try release(), testHome: testHome)
            #expect(rel.releasesFile == nil)
            #expect(rel.opensWhatsNew)
        }
        let folders = DataFolders(identity: try release(), home: home)
        let rel = plan(try release(), testHome: false, folders: folders)
        let notes = folders.support.appendingPathComponent("release-notes.json")
        #expect(rel.releaseNotesFile == notes)
    }

    // A test home records each notification and shows none, and it has no account poller, so a
    // test run never shows a notification, reads the Keychain or reaches the network. Each other
    // start shows the notifications and can poll. A release ignores a test home.
    @Test func onlyATestHomeRecordsTheNotificationsAndHasNoPoller() throws {
        let test = plan(try development(), testHome: true)
        #expect(test.recordsNotifications)
        #expect(!test.pollsAccount)
        // A test home also checks no status page and measures no network for Performance.
        #expect(!test.checksServiceStatus)
        #expect(!test.measuresNetwork)
        let dev = try development()
        let rel = try release()
        for (identity, testHome) in [(dev, false), (rel, true), (rel, false)] {
            let plan = plan(identity, testHome: testHome)
            #expect(!plan.recordsNotifications)
            #expect(plan.pollsAccount)
            #expect(plan.checksServiceStatus)
            #expect(plan.measuresNetwork)
        }
    }

    // health.log goes to the logs folder of the app in the home of the plan, so a test home writes
    // it in the test home.
    @Test func theHealthLogIsInTheLogsFolderOfTheHome() throws {
        let identity = try development()
        let test = plan(identity, testHome: true)
        let folders = DataFolders(identity: identity, home: URL(fileURLWithPath: "/tmp/x"))
        #expect(test.healthLogFolder == folders.logs)
        #expect(test.healthLogFolder.path.hasPrefix("/tmp/x/Library/Logs/"))
    }

    // The debug test port can type into a session, so it listens only with a
    // test home, in the dot folder of the development app.
    @Test func noTestPortWithoutATestHome() throws {
        #expect(plan(try development(), testHome: false).testPort == nil)
        let plan = plan(try development(), testHome: true)
        #expect(plan.testPort == "/tmp/x/.bifrost-native-dev/test.sock")
    }

    // A Release build never has a test port, also when a caller says that it has a test home.
    // The folders of another identity give no test port either.
    @Test func noTestPortInARelease() throws {
        for testHome in [true, false] {
            #expect(plan(try release(), testHome: testHome).testPort == nil)
        }
        let other = DataFolders(identity: try release(), home: home)
        #expect(plan(try development(), testHome: true, folders: other).testPort == nil)
    }

    // The test port is never in the real home, never in a folder of the Electron app and never
    // in the folder of the shared Live socket: for each identity, each home, each test home value
    // and the folders of each identity. A "test home" that is the real home gives no test port.
    @Test func theTestPortIsNeverInTheRealHome() throws {
        let identities = [try development(), try release()]
        var ports: [String] = []
        for identity in identities {
            for home in [home, someRealHome] {
                for testHome in [true, false] {
                    for folders in identities.map({ DataFolders(identity: $0, home: home) }) {
                        let plan = StartPlan(
                            identity: identity, home: home, realHome: someRealHome,
                            testHome: testHome, folders: folders)
                        guard let port = plan.testPort else { continue }
                        ports.append(port)
                        #expect(!port.hasPrefix(someRealHome.path + "/"), "\(port)")
                        for owner in [home, someRealHome] {
                            let shared = SharedClaudeState(home: owner)
                            let sharedFolder = shared.liveSocket.deletingLastPathComponent().path
                            #expect(!port.hasPrefix(sharedFolder + "/"), "\(port)")
                        }
                    }
                }
            }
        }
        // Only the development identity with a test home that is not the real home, and its own
        // folders, has a test port.
        #expect(ports == ["/tmp/x/.bifrost-native-dev/test.sock"])
    }

    // The shared home is the home that the plan gets (the resolved home), for each identity,
    // each home and each test home value. It is never the real home of a plan with a test home.
    @Test func theSharedHomeIsTheResolvedHome() throws {
        for identity in [try development(), try release()] {
            for home in [home, someRealHome] {
                for testHome in [true, false] {
                    let plan = plan(identity, home: home, testHome: testHome)
                    #expect(plan.sharedHome == home)
                }
            }
        }
        let plan = plan(try development(), testHome: true)
        #expect(plan.sharedHome.path == "/tmp/x")
    }

    // A test home gives no real shared path: the plan and the services give each shared path
    // under the test home, and no path under the real home. The services do not start, so they
    // read no file and run no program.
    @MainActor
    @Test func aTestHomeNeverGivesARealPath() throws {
        let plan = plan(try development(), testHome: true)
        let services = AppServices(
            plan: plan, home: home, environment: [:], processes: FakeProcessInspector(),
            speechEngine: { _ in FakeSpeechEngine() })
        #expect(services.sharedState == SharedClaudeState(home: plan.sharedHome))
        let paths = Mirror(reflecting: services.sharedState).children.compactMap {
            ($0.value as? URL)?.path
        }
        #expect(paths.count == 10)
        for path in paths {
            #expect(path.hasPrefix("/tmp/x/"), "\(path)")
            #expect(!path.hasPrefix(someRealHome.path), "\(path)")
        }
    }

    // The UI stores are in the support folder, with the names of the
    // Electron app. The folders of another identity do not change them.
    @Test func theUIStoresAreInTheDevelopmentSupportFolder() throws {
        let support = "/tmp/x/Library/Application Support/Bifrost Native Dev"
        let other = DataFolders(identity: try release(), home: home)
        for folders in [nil, other] {
            let plan = plan(try development(), testHome: true, folders: folders)
            #expect(plan.uiStateFile.path == "\(support)/ui-state.json")
            #expect(plan.windowStateFile.path == "\(support)/window-state.json")
        }
    }

    // The run folder of Open in terminal is in the dot folder of the identity, also with the
    // folders of another identity. So the development app never uses ~/.bifrost/run, and only
    // the release app uses it, as the Electron app does.
    @Test func theRunFolderIsInTheOwnDotFolder() throws {
        let other = DataFolders(identity: try release(), home: home)
        for folders in [nil, other] {
            let plan = plan(try development(), testHome: true, folders: folders)
            #expect(plan.runFolder.path == "/tmp/x/.bifrost-native-dev/run")
        }
        #expect(plan(try release(), testHome: false).runFolder.path == "/tmp/x/.bifrost/run")
    }
}

// MARK: - The branch reader and the plan

// A repo folder whose HEAD file holds no branch. The branch reader then asks git.
private func makeRepo(_ path: String) throws {
    try FileManager.default.createDirectory(
        atPath: "\(path)/.git", withIntermediateDirectories: true)
    try "not a ref\n".write(toFile: "\(path)/.git/HEAD", atomically: true, encoding: .utf8)
}

@Suite("start plan and branch reader", .testTimeLimit)
struct StartPlanBranchTests {
    // Make a repo, a worktree folder in it, and a .git file outside that points into it, in each
    // reviews folder of the home. Each HEAD file holds no branch, so a reader without the skip
    // asks git. The result is the folders that the reader must skip.
    private func makeReviewFolders(_ home: String) throws -> [String] {
        var folders: [String] = []
        for dot in [".bifrost", ".bifrost-native-dev"] {
            let repo = "\(home)/\(dot)/reviews/repos/acme/api"
            try makeRepo(repo)
            try FileManager.default.createDirectory(
                atPath: "\(repo)/.bifrost-worktrees/9", withIntermediateDirectories: true)
            let outside = "\(home)/elsewhere\(dot)"
            try FileManager.default.createDirectory(
                atPath: outside, withIntermediateDirectories: true)
            try "gitdir: \(repo)/.git\n".write(
                toFile: "\(outside)/.git", atomically: true, encoding: .utf8)
            folders += [repo, "\(repo)/.bifrost-worktrees/9", outside]
        }
        return folders
    }

    // The registry of the plan reads no HEAD file and runs no git in the skipped folders. A
    // folder outside them still gets git, so the test can see a git call.
    private func expectNoGit(in skipped: [String], plan: StartPlan, control: String) async throws {
        let runner = FakeRunner(ExecResult(.exited(0), stdout: "main\n"))
        let deps = RegistrySystemDeps(
            claude: nil, runner: runner, skipRoots: plan.branchSkipRoots, saver: .noFile)
        for cwd in skipped {
            #expect(try await deps.readBranch(cwd) == nil, "\(cwd)")
        }
        #expect(runner.calls.isEmpty)

        // The same repos in memory: the reader reads no HEAD file there.
        let repos = skipped.filter { $0.hasSuffix("/acme/api") }
        let fs = MemoryFileSystem(
            files: Dictionary(
                uniqueKeysWithValues: repos.map { ("\($0)/.git/HEAD", "ref: refs/heads/fix\n") }),
            folders: repos.map { "\($0)/.git" })
        let reader = BranchReader(runner: runner, fileSystem: fs, skipRoots: plan.branchSkipRoots)
        for repo in repos {
            #expect(await reader.read(repo) == nil)
        }
        #expect(fs.reads.isEmpty)
        #expect(runner.calls.isEmpty)

        try makeRepo(control)
        #expect(try await deps.readBranch(control) == "main")
        #expect(runner.calls.count == 1)
    }

    // The Electron reviews folder and the reviews folder of the development app.
    @Test func theBranchReaderRunsNoGitInTheReviewsFolderOfTheSharedHome() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let dir = temp.realPath
        let plan = plan(try development(), home: URL(fileURLWithPath: dir), testHome: false)
        let skipped = try makeReviewFolders(dir)
        try await expectNoGit(in: skipped, plan: plan, control: "\(dir)/normal")
    }

    // A run with a test home skips the reviews folders of the real home too. Here a
    // temp folder stands in for the real home.
    @Test func aTestHomeRunSkipsTheReviewsFoldersOfTheRealHome() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let dir = temp.realPath
        let testHome = "\(dir)/test-home"
        let realHome = "\(dir)/real-home"
        let plan = plan(
            try development(), home: URL(fileURLWithPath: testHome),
            realHome: URL(fileURLWithPath: realHome), testHome: true)
        let skipped = try makeReviewFolders(realHome) + makeReviewFolders(testHome)
        try await expectNoGit(in: skipped, plan: plan, control: "\(realHome)/normal")
    }
}

// The speech engine of a start: the fake engine only for a development app with a test home.
@Suite("the speech engine of a start", .testTimeLimit)
@MainActor
struct StartSpeechEngineTests {
    // The dictation start test of the plan: a development app with a test
    // home uses the fake engine.
    @Test func aTestHomeUsesTheFakeEngine() throws {
        let identity = try #require(AppIdentity(bundleID: "com.example.app.native-dev"))
        let home = URL(fileURLWithPath: "/tmp/bk-test-home")
        let plan = StartPlan(
            identity: identity, home: home, realHome: URL(fileURLWithPath: "/Users/someone"),
            testHome: true, folders: DataFolders(identity: identity, home: home))
        #expect(plan.fakeSpeech)
        #expect(AppServices.speechEngine(for: plan) is FakeSpeechEngine)
    }

    // The plan value only: no test makes the real engine. A release identity and a development
    // app with no test home use the real engine.
    @Test func aReleaseUsesTheRealEngine() throws {
        let home = URL(fileURLWithPath: "/Users/someone")
        for (bundleID, testHome) in [
            ("com.example.app", true), ("com.example.app", false),
            ("com.example.app.native-dev", false),
        ] {
            let identity = try #require(AppIdentity(bundleID: bundleID))
            let plan = StartPlan(
                identity: identity, home: home, realHome: home, testHome: testHome,
                folders: DataFolders(identity: identity, home: home))
            #expect(!plan.fakeSpeech, "\(bundleID)")
        }
    }
}
