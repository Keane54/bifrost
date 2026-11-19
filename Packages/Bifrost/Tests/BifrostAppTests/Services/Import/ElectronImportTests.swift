import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostApp
@testable import BifrostDailyUpdate
@testable import BifrostDictation
@testable import BifrostFoundation
@testable import BifrostKeyboard
@testable import BifrostLayout
@testable import BifrostSessions
@testable import BifrostSettings
@testable import BifrostWindows

// The one-time import of the Electron data. Each test has its own home in a TemporaryFolder, with
// the Electron folder and the support folder of the development app in it, so no test reads or
// writes a real folder. The fixtures (Fixtures/electron-support) have one file of each store with
// each field and an unknown field. They are written by hand and hold no private data.

// The log of the import in a test.
extension Recorder: ImportLog where Value == ImportEvent {}

// The time of the import in the tests, and its form in the report.
private let importTime = Date(timeIntervalSince1970: 1_793_900_000)
private let importMilliseconds = 1_793_900_000_000

private let allNames = ImportedStore.allCases.map(\.rawValue)

private func development() throws -> AppIdentity {
    try #require(AppIdentity(bundleID: "com.example.app.native-dev"))
}

// The bytes of the fixture of a store.
private func fixture(_ store: ImportedStore) throws -> Data {
    let folder = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    return try Data(contentsOf: folder.appending(path: "electron-support/\(store.rawValue)"))
}

// The JSON object of the fixture of a store.
private func fixtureFields(_ store: ImportedStore) throws -> [String: JSONValue] {
    guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: fixture(store))
    else {
        Issue.record("The fixture \(store.rawValue) is not an object.")
        return [:]
    }
    return fields
}

// The modification time of a file or a folder, in seconds and nanoseconds.
private func modified(_ path: String) -> [Int] {
    var info = stat()
    guard lstat(path, &info) == 0 else { return [] }
    return [info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec]
}

private func mode(_ path: String) -> mode_t {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0
}

// One home of a test: the Electron folder and the support folder of the development app.
private struct TestHome {
    let folder: TemporaryFolder
    let electron: ElectronStores
    let support: URL

    init() throws {
        folder = try TemporaryFolder()
        electron = ElectronStores(home: folder.url)
        support = DataFolders(identity: try development(), home: folder.url).support
    }

    var home: URL { folder.url }

    // A file of the Electron folder.
    func electronFile(_ name: String) -> URL { electron.folder.appending(path: name) }

    // A file of the support folder of the development app.
    func supportFile(_ name: String) -> URL { support.appending(path: name) }

    // Copy the fixtures of the stores to the Electron folder.
    func addFixtures(_ stores: [ImportedStore] = ImportedStore.allCases) throws {
        for store in stores { try writeElectron(try fixture(store), store.rawValue) }
    }

    func writeElectron(_ data: Data, _ name: String) throws {
        try FileManager.default.createDirectory(
            at: electron.folder, withIntermediateDirectories: true)
        try data.write(to: electronFile(name))
    }

    func writeSupport(_ text: String, _ name: String) throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: supportFile(name))
    }

    func supportText(_ name: String) throws -> String {
        try String(contentsOf: supportFile(name), encoding: .utf8)
    }

    func runImport(log: Recorder<ImportEvent> = Recorder()) async -> ImportReport? {
        await ElectronImport.runOnce(from: electron, to: support, now: importTime, log: log)
    }

    // Give the owner the rights on the two folders and their files again, then remove the home.
    func remove() {
        for folder in [electron.folder, support] {
            chmod(path(folder), 0o700)
            for name in (try? names(folder)) ?? [] { chmod(path(folder) + "/" + name, 0o600) }
        }
        folder.remove()
    }
}

@Suite("the import of the Electron data", .timeLimit(.minutes(1)))
struct ElectronImportTests {
    // Review Focus 2: the folder at mode 0500 and its files at 0400, so each write in the folder
    // fails. After the import, each file has the same bytes, mode and modification time, and the
    // folder has the same names and modification time.
    @Test func theImportOnlyReadsTheElectronFolder() async throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.addFixtures()
        let folder = path(home.electron.folder)
        for name in allNames { #expect(chmod(path(home.electronFile(name)), 0o400) == 0) }
        #expect(chmod(folder, 0o500) == 0)
        let bytes = try allNames.map { try Data(contentsOf: home.electronFile($0)) }
        let times = allNames.map { modified(path(home.electronFile($0))) }
        let folderTime = modified(folder)
        let before = try names(home.electron.folder)

        let report = try #require(await home.runImport())

        #expect(report.imported == allNames)
        #expect(try names(home.electron.folder) == before)
        #expect(modified(folder) == folderTime)
        #expect(mode(folder) == 0o500)
        for (index, name) in allNames.enumerated() {
            let file = home.electronFile(name)
            #expect(try Data(contentsOf: file) == bytes[index], "\(name)")
            #expect(modified(path(file)) == times[index], "\(name)")
            #expect(mode(path(file)) == 0o400, "\(name)")
            #expect(try Data(contentsOf: home.supportFile(name)) == bytes[index], "\(name)")
        }
    }

    // A development file gets the name <name>.before-import, and the Electron bytes take its
    // place with the mode 0600.
    @Test func anExistingDevFileIsKeptBeforeTheImport() async throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.addFixtures()
        for name in allNames { try home.writeSupport("{\"dev\":\"\(name)\"}\n", name) }
        let log = Recorder<ImportEvent>()

        let report = try #require(await home.runImport(log: log))

        let kept = allNames.map { "\($0).before-import" }
        #expect(
            report
                == ImportReport(
                    at: importMilliseconds, imported: allNames, kept: kept, skipped: [:]))
        for (store, name) in zip(ImportedStore.allCases, allNames) {
            #expect(try home.supportText("\(name).before-import") == "{\"dev\":\"\(name)\"}\n")
            #expect(try Data(contentsOf: home.supportFile(name)) == fixture(store))
            #expect(mode(path(home.supportFile(name))) == 0o600, "\(name)")
        }
        let events = ImportedStore.allCases.map {
            ImportEvent.imported($0, kept: "\($0.rawValue).before-import")
        }
        #expect(log.values == events)
    }

    // A used name gets the next number: -2 after .before-import, -3 after -2.
    @Test func aSecondBeforeImportNameGetsANumber() async throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.addFixtures([.settings, .registry])
        try home.writeSupport("dev settings", "settings.json")
        try home.writeSupport("first", "settings.json.before-import")
        try home.writeSupport("dev registry", "registry.json")
        try home.writeSupport("first", "registry.json.before-import")
        try home.writeSupport("second", "registry.json.before-import-2")

        let report = try #require(await home.runImport())

        #expect(report.kept == ["settings.json.before-import-2", "registry.json.before-import-3"])
        #expect(try home.supportText("settings.json.before-import") == "first")
        #expect(try home.supportText("settings.json.before-import-2") == "dev settings")
        #expect(try home.supportText("registry.json.before-import") == "first")
        #expect(try home.supportText("registry.json.before-import-2") == "second")
        #expect(try home.supportText("registry.json.before-import-3") == "dev registry")
        #expect(try Data(contentsOf: home.supportFile("settings.json")) == fixture(.settings))
        #expect(try Data(contentsOf: home.supportFile("registry.json")) == fixture(.registry))
    }

    // The marker import.json has the report with the version 1. While it exists, the import
    // does nothing: a changed Electron file does not come in again.
    @Test func theImportRunsOnce() async throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.addFixtures()

        let report = try #require(await home.runImport())

        let marker = home.supportFile(ElectronImport.markerName)
        #expect(mode(path(marker)) == 0o600)
        let saved = try Data(contentsOf: marker)
        #expect(try JSONDecoder().decode(ImportReport.self, from: saved) == report)
        guard case .object(let fields) = try readSaved(marker) else {
            Issue.record("The marker is not an object.")
            return
        }
        #expect(fields["version"] == 1)
        #expect(fields["at"] == .int(importMilliseconds))

        try home.writeElectron(Data("{\"version\":1,\"rowFlash\":true}".utf8), "settings.json")
        let before = try names(home.support)
        let log = Recorder<ImportEvent>()
        #expect(await home.runImport(log: log) == nil)
        #expect(try Data(contentsOf: home.supportFile("settings.json")) == fixture(.settings))
        #expect(try names(home.support) == before)
        #expect(try Data(contentsOf: marker) == saved)
        #expect(log.values.isEmpty)
    }

    // A settings file with no version, bad JSON, a UI state file of version 2 and an array: the
    // development file stays, no copy is made, and the report gives the reason. The good file
    // comes in, and the marker comes last.
    @Test func aDamagedElectronFileIsSkipped() async throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.writeElectron(Data("{\"rowFlash\":false}".utf8), "settings.json")
        try home.writeElectron(Data("{\"aliases\":".utf8), "registry.json")
        try home.writeElectron(Data("{\"version\":2,\"layouts\":[]}".utf8), "ui-state.json")
        try home.writeElectron(Data("[1, 2]".utf8), "window-state.json")
        try home.addFixtures([.usageAlerts])
        for name in allNames { try home.writeSupport("dev \(name)", name) }
        let log = Recorder<ImportEvent>()

        let report = try #require(await home.runImport(log: log))

        #expect(report.imported == ["usage-alerts.json"])
        #expect(report.kept == ["usage-alerts.json.before-import"])
        #expect(
            report.skipped == [
                "settings.json": "not version 1", "registry.json": "not JSON",
                "ui-state.json": "version 2", "window-state.json": "not an object",
            ])
        for name in allNames.dropLast() {
            #expect(try home.supportText(name) == "dev \(name)")
        }
        #expect(
            try names(home.support) == [
                "import.json", "registry.json", "settings.json", "ui-state.json",
                "usage-alerts.json", "usage-alerts.json.before-import", "window-state.json",
            ])
        #expect(
            log.values == [
                .skipped(.settings, .version(nil)), .skipped(.registry, .notJSON),
                .skipped(.uiState, .version(2)), .skipped(.windowState, .notAnObject),
                .imported(.usageAlerts, kept: "usage-alerts.json.before-import"),
            ])
    }

    // A FIFO or a folder at the path of a store is not a file, and the read does not wait for a
    // writer of the FIFO. A file that cannot be read gives the error. Each development file
    // stays, and the marker comes.
    @Test func aFIFOAFolderOrAnUnreadableFileIsSkipped() async throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.addFixtures([.windowState])
        let fifo = path(home.electronFile("registry.json"))
        #expect(mkfifo(fifo, 0o600) == 0)
        try FileManager.default.createDirectory(
            at: home.electronFile("settings.json"), withIntermediateDirectories: false)
        let unreadable = path(home.electronFile("window-state.json"))
        #expect(chmod(unreadable, 0o000) == 0)
        try home.writeSupport("dev registry", "registry.json")
        let log = Recorder<ImportEvent>()

        let report = try #require(await home.runImport(log: log))

        let denied = "Cannot read \(unreadable): Permission denied."
        #expect(report.imported == [])
        #expect(
            report.skipped == [
                "settings.json": "not a file", "registry.json": "not a file",
                "ui-state.json": "missing", "window-state.json": denied,
                "usage-alerts.json": "missing",
            ])
        #expect(try home.supportText("registry.json") == "dev registry")
        #expect(fileExists(path(home.supportFile(ElectronImport.markerName))))
        #expect(
            log.values == [
                .skipped(.settings, .notAFile), .skipped(.registry, .notAFile),
                .skipped(.uiState, .missing),
                .skipped(.windowState, .unreadable(.system(.read, path: unreadable, code: EACCES))),
                .skipped(.usageAlerts, .missing),
            ])
    }

    // The write of the Electron bytes fails after the rename of the development file. The file
    // gets its name back, so its store does not open empty, and no marker comes. The next run
    // imports the store.
    @Test func aFailedWriteGivesTheDevFileItsNameBack() async throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.addFixtures([.settings, .registry])
        try home.writeSupport("dev settings", "settings.json")
        try home.writeSupport("dev registry", "registry.json")
        let file = path(home.supportFile("settings.json"))
        let system = WriteSteps.system
        // The last step of the safe write of settings.json fails. The other writes work.
        let steps = WriteSteps(
            sync: system.sync,
            rename: { from, to in
                if to == file { throw POSIXError(.EIO) }
                try system.rename(from, to)
            })
        let log = Recorder<ImportEvent>()

        let failed = try #require(
            await ElectronImport.runOnce(
                from: home.electron, to: home.support, now: importTime, log: log, steps: steps))

        let failure = FileError.system(.save, path: file, code: EIO)
        #expect(failed.imported == ["registry.json"])
        #expect(failed.kept == ["registry.json.before-import"])
        #expect(
            failed.skipped == [
                "settings.json": failure.message, "ui-state.json": "missing",
                "window-state.json": "missing", "usage-alerts.json": "missing",
            ])
        #expect(log.values.first == .skipped(.settings, .notWritten(failure)))
        #expect(try home.supportText("settings.json") == "dev settings")
        #expect(!fileExists(file + ".before-import"))
        #expect(!fileExists(path(home.supportFile(ElectronImport.markerName))))

        let again = try #require(await home.runImport())
        #expect(again.imported == ["settings.json", "registry.json"])
        #expect(again.kept == ["settings.json.before-import", "registry.json.before-import-2"])
        #expect(try home.supportText("settings.json.before-import") == "dev settings")
        #expect(try Data(contentsOf: home.supportFile("settings.json")) == fixture(.settings))
        #expect(fileExists(path(home.supportFile(ElectronImport.markerName))))
    }

    // A development store file that is a link: the rename moves the link, and its target keeps
    // its bytes. The imported file is a regular file.
    @Test func aDevStoreFileThatIsALinkKeepsItsTarget() async throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.addFixtures([.settings])
        let target = home.home.appending(path: "own-settings.json")
        try Data("own settings".utf8).write(to: target)
        try FileManager.default.createDirectory(at: home.support, withIntermediateDirectories: true)
        let link = path(home.supportFile("settings.json"))
        #expect(symlink(path(target), link) == 0)

        let report = try #require(await home.runImport())

        #expect(report.kept == ["settings.json.before-import"])
        let kept = link + ".before-import"
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: kept) == path(target))
        #expect(try String(contentsOf: target, encoding: .utf8) == "own settings")
        var info = stat()
        #expect(lstat(link, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFREG)
        #expect(try Data(contentsOf: home.supportFile("settings.json")) == fixture(.settings))
    }

    // An error of the check of the marker, other than a missing item, stops the import with one
    // log event. Nothing comes in.
    @Test func aMarkerThatCannotBeCheckedStopsTheImport() async throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.addFixtures()
        try FileManager.default.createDirectory(at: home.support, withIntermediateDirectories: true)
        #expect(chmod(path(home.support), 0o000) == 0)
        let log = Recorder<ImportEvent>()

        #expect(await home.runImport(log: log) == nil)

        let marker = path(home.supportFile(ElectronImport.markerName))
        #expect(log.values == [.markerNotChecked(.system(.check, path: marker, code: EACCES))])
        #expect(chmod(path(home.support), 0o700) == 0)
        #expect(try names(home.support) == [])
    }

    // With no Electron folder, each store is missing, the development files stay, and the
    // marker comes. The import makes no Electron folder.
    @Test func aMissingElectronFolderImportsNothingAndWritesTheMarker() async throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.writeSupport("dev settings", "settings.json")
        let log = Recorder<ImportEvent>()

        let report = try #require(await home.runImport(log: log))

        let missing = Dictionary(uniqueKeysWithValues: allNames.map { ($0, "missing") })
        let expected = ImportReport(
            at: importMilliseconds, imported: [], kept: [], skipped: missing)
        #expect(report == expected)
        #expect(try names(home.support) == ["import.json", "settings.json"])
        #expect(try home.supportText("settings.json") == "dev settings")
        #expect(!fileExists(path(home.electron.folder)))
        #expect(log.values == ImportedStore.allCases.map { .skipped($0, .missing) })
    }

    // A rename that fails leaves the development file and writes no marker, so the next start
    // imports the store.
    @Test func aFailedRenameWritesNoMarkerSoTheImportRunsAgain() async throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.addFixtures([.settings])
        try home.writeSupport("dev settings", "settings.json")
        #expect(chmod(path(home.support), 0o500) == 0)

        let failed = try #require(await home.runImport())

        let file = path(home.supportFile("settings.json"))
        #expect(failed.imported == [])
        #expect(
            failed.skipped["settings.json"]
                == "Cannot rename \(file) to \(file).before-import: Permission denied.")
        #expect(try home.supportText("settings.json") == "dev settings")
        #expect(!fileExists(path(home.supportFile(ElectronImport.markerName))))

        #expect(chmod(path(home.support), 0o700) == 0)
        let again = try #require(await home.runImport())
        #expect(again.imported == ["settings.json"])
        #expect(again.kept == ["settings.json.before-import"])
        #expect(try home.supportText("settings.json.before-import") == "dev settings")
        #expect(fileExists(path(home.supportFile(ElectronImport.markerName))))
    }

    // Each imported file opens in its store with each value of the Electron file: the settings
    // with the raw keys and Daily update, the registry with the local names, the priorities and
    // the watchlist, the UI state with the layouts and the raw Overviews and history, and the
    // window state with the bounds. No store logs a value that it cannot use.
    @MainActor
    @Test func theImportedStoresLoadWithAllValues() async throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.addFixtures()
        _ = try #require(await home.runImport())
        let storeLog = Recorder<StoreEvent>()

        let settingsStore = await SettingsStore.open(
            file: home.supportFile("settings.json"), log: storeLog)
        let settings = settingsStore.settings
        let settingsFields = try fixtureFields(.settings)
        #expect(settings.accountUsage)
        #expect(settings.labels == .space)
        #expect(settings.terminalApp == .ghostty)
        #expect(settings.projectApp == .zed)
        #expect(settings.escalationMinutes == 25)
        #expect(!settings.rowFlash && !settings.notifications && !settings.redBoxSound)
        #expect(settings.startAtLogin)
        #expect(settings.pollSeconds == 5)
        #expect(settings.snapDistance == 12)
        #expect(settings.panelTransparency == 30)
        #expect(settings.interfaceScale == 120)
        #expect(!settings.animatedBackground && !settings.autoUpdate)
        #expect(settings.slashCommands == ["/compact", "/review", "/cost"])
        #expect(settings.reviewsWatch && !settings.reviewsAutoFix && !settings.reviewsTeamRequests)
        #expect(settings.reviewsMaxSessions == 5)
        #expect(settings.reviewsPauseMinutes == 120)
        #expect(settings.reviewsPollMinutes == 5)
        #expect(settings.reviewsRequestModel == .opus)
        #expect(settings.reviewsReviewModel == .sonnet)
        #expect(settings.reviewsSignedCommits)
        #expect(settings.reviewsIgnore == ["example-org/docs", "sandbox/*"])
        #expect(settings.terminalFont == TerminalFont(family: "Menlo", size: 14))
        #expect(settings.keys == ["interrupt": .null, "new-session": "Mod+Shift+N"])
        #expect(
            settings.dailyUpdate
                == settingsFields["dailyUpdate"].flatMap(DailySettings.init(json:)))
        #expect(settings.dailyUpdate != nil)
        #expect(settings.setupDone)

        let registry = StoreFile.open(path: path(home.supportFile("registry.json")), log: storeLog)
            .store
        let search = "11111111-1111-4111-8111-111111111111"
        let notes = "22222222-2222-4222-8222-222222222222"
        let review = "33333333-3333-4333-8333-333333333333"
        #expect(registry.aliases == [search: "Search fix", notes: "Notes"])
        #expect(registry.priorities == [search: .p1, notes: .p4])
        #expect(registry.watch == [WatchEntry(notes, .red), WatchEntry(search, .lightBlue)])
        #expect(registry.names == [search: "fix-search", notes: "notes", review: "app-7-review"])
        #expect(registry.current == [search: "55555555-5555-4555-8555-555555555555"])
        let jobs: [String: ShortID] = [search: "11111111", review: "33333333"]
        #expect(registry.jobs == jobs)
        #expect(registry.lastActive == [search])
        #expect(registry.started == [search, review])
        #expect(registry.prSessions == [review])
        #expect(registry.prNames == ["app-7-review"])
        let worktree = "/Users/user/Developer/app/.claude/worktrees/fix-search"
        #expect(registry.worktrees == [search: worktree])
        #expect(registry.deferred.map(\.sessionId) == ["66666666-6666-4666-8666-666666666666"])

        let uiStore = await UIStateStore.open(
            file: home.supportFile("ui-state.json"), clock: ManualClock(), log: storeLog)
        let ui = uiStore.state
        let uiFields = try fixtureFields(.uiState)
        let chat = panel("chat:11111111-1111-4111-8111-111111111111")
        #expect(
            ui.current
                == LayoutSnapshot(
                    frames: [
                        SavedFrame(
                            panels: [panel("overview:1")], active: panel("overview:1"),
                            rect: rect(40, 40, 760, 360), minimised: false, locked: false),
                        SavedFrame(
                            panels: [chat, panel("watchlist")], active: panel("watchlist"),
                            rect: rect(820, 40, 720, 480), minimised: false, locked: true),
                    ],
                    memory: [panel("settings"): rect(100, 80, 720, 540)]))
        #expect(ui.layouts.map(\.name) == ["Focus", "Review"])
        #expect(
            ui.layouts.first?.snapshot.frames
                == [
                    SavedFrame(
                        panels: [panel("overview:1")], active: panel("overview:1"),
                        rect: rect(0, 0, 600, 300), minimised: true, locked: false)
                ])
        #expect(ui.layouts.last?.snapshot.memory == [panel("watchlist"): rect(10, 20, 320, 280)])
        let savedOverviews = try #require(uiFields["overviews"]?.object)
        #expect(
            Dictionary(uniqueKeysWithValues: ui.overviews.map { ($0.key.text, $0.value) })
                == savedOverviews)
        #expect(!ui.overviews.isEmpty)
        let overview = ui.overviewConfig(panel("overview:1"))
        #expect(overview.name == "Overview")
        #expect(overview.tabs.first?.name == "Live")
        #expect(ui.history == uiFields["history"])
        #expect(
            ui.dialogHistory
                == History(
                    recentDirs: ["/Users/user/Developer/app", "/Users/user/Developer/docs"],
                    model: .opus, permissionMode: .plan, recentSlash: ["/compact", "/review"]))
        #expect(ui.performance == uiFields["performance"])

        let windowStore = await WindowStateStore.open(
            file: home.supportFile("window-state.json"), log: storeLog)
        #expect(windowStore.state.mode == .borderless)
        #expect(
            windowStore.state.bounds == WindowBounds(x: 120, y: 60, width: 1400, height: 860))

        #expect(storeLog.values.isEmpty)
    }

    // Each field survives in both directions: the import writes the Electron bytes as they are,
    // and the first save of each store writes the unknown field again.
    @MainActor
    @Test func anUnknownFieldOfEachStoreSurvives() async throws {
        let home = try TestHome()
        defer { home.remove() }
        try home.addFixtures()
        _ = try #require(await home.runImport())
        for store in ImportedStore.allCases {
            #expect(try Data(contentsOf: home.supportFile(store.rawValue)) == fixture(store))
        }

        let settings = await SettingsStore.open(file: home.supportFile("settings.json"))
        try await settings.edit { $0.rowFlash = true }
        let (registry, saver) = StoreFile.open(path: path(home.supportFile("registry.json")))
        var changed = registry
        changed.prNames.insert("app-8-review")
        try saver.save(changed)
        let uiState = await UIStateStore.open(
            file: home.supportFile("ui-state.json"), clock: ManualClock())
        uiState.change { _ = $0.saveLayout("Later", LayoutSnapshot(frames: [], memory: [:])) }
        await uiState.saveNow()
        let windowState = await WindowStateStore.open(file: home.supportFile("window-state.json"))
        await windowState.update(mode: .window)

        for store in ImportedStore.allCases {
            guard case .object(let fields) = try readSaved(home.supportFile(store.rawValue)) else {
                Issue.record("\(store.rawValue) is not an object.")
                continue
            }
            #expect(fields["futureField"] == ["level": 3, "tags": ["a", true, .null]])
        }
        #expect(try home.supportText("settings.json").contains("\"rowFlash\" : true"))
    }

    // Only a development identity imports. The release app uses the Electron folder as its own
    // support folder: its plan has no Electron folder, its UI stores open with no import, and a
    // call with one folder for both sides imports nothing either.
    @MainActor
    @Test func aReleaseIdentityNeverImports() async throws {
        let home = try TestHome()
        defer { home.remove() }
        let release = try #require(AppIdentity(bundleID: "com.example.app"))
        let folders = DataFolders(identity: release, home: home.home)
        #expect(path(folders.support) == path(home.electron.folder))
        try folders.create()
        try home.addFixtures()
        let before = try names(home.electron.folder)
        let bytes = try allNames.map { try Data(contentsOf: home.electronFile($0)) }
        let plan = StartPlan(
            identity: release, home: home.home, realHome: home.home, testHome: false,
            folders: folders)
        #expect(plan.electronSupport == nil)
        let identity = try development()
        let developmentPlan = StartPlan(
            identity: identity, home: home.home, realHome: home.home, testHome: false,
            folders: DataFolders(identity: identity, home: home.home))
        #expect(developmentPlan.electronSupport.map(path) == path(home.electron.folder))

        let services = AppServices(
            plan: plan, home: home.home, environment: [:], processes: FakeProcessInspector(),
            speechEngine: { _ in FakeSpeechEngine() })
        await services.openUIStores()
        #expect(services.uiState?.state.layouts.map(\.name) == ["Focus", "Review"])
        let log = Recorder<ImportEvent>()
        let same = await ElectronImport.runOnce(
            from: home.electron, to: home.electron.folder, now: importTime, log: log)

        #expect(same == nil)
        #expect(log.values == [.oneFolder(path(home.electron.folder))])
        #expect(try names(home.electron.folder) == before)
        #expect(try allNames.map { try Data(contentsOf: home.electronFile($0)) } == bytes)
    }

    // AppServices with a test home imports in openUIStores, before the UI stores open, and the
    // settings store of start() opens the imported file. The earlier development layout is kept.
    // The env has no PATH, so the start finds no claude and runs no program.
    @MainActor
    @Test func theImportRunsBeforeTheStoresOpen() async throws {
        let home = try TestHome()
        defer { home.remove() }
        let identity = try development()
        let folders = DataFolders(identity: identity, home: home.home)
        try folders.create()
        try home.addFixtures()
        var earlier = UIState()
        _ = earlier.saveLayout("Earlier", LayoutSnapshot(frames: [], memory: [:]))
        let earlierBytes = try JSONFile.encode(earlier)
        try earlierBytes.write(to: home.supportFile("ui-state.json"))
        let plan = StartPlan(
            identity: identity, home: home.home, realHome: URL(filePath: "/Users/someone"),
            testHome: true, folders: folders)
        #expect(plan.electronSupport.map(path) == path(home.electron.folder))
        let services = AppServices(
            plan: plan, home: home.home, environment: [:], processes: FakeProcessInspector(),
            speechEngine: { _ in FakeSpeechEngine() }, now: { importTime })
        defer { services.stop() }

        await services.openUIStores()

        #expect(services.uiState?.state.layouts.map(\.name) == ["Focus", "Review"])
        #expect(services.windowState?.state.mode == .borderless)
        let kept = try Data(contentsOf: home.supportFile("ui-state.json.before-import"))
        #expect(kept == earlierBytes)
        let marker = try Data(contentsOf: home.supportFile(ElectronImport.markerName))
        let report = try JSONDecoder().decode(ImportReport.self, from: marker)
        #expect(report.at == importMilliseconds)
        #expect(report.imported == allNames)
        // The services keep the report of the import of this start for the test port.
        #expect(services.importReport == report)

        await services.start()
        #expect(services.sessions.status == .claudeNotFound)
        #expect(services.settings?.settings.labels == .space)
        #expect(services.settings?.settings.terminalApp == .ghostty)
        #expect(services.importReport == report)

        // A later start finds the marker, so it imports nothing and has no report.
        let later = AppServices(
            plan: plan, home: home.home, environment: [:], processes: FakeProcessInspector(),
            speechEngine: { _ in FakeSpeechEngine() }, now: { importTime })
        defer { later.stop() }
        await later.openUIStores()
        #expect(later.importReport == nil)
        #expect(later.uiState?.state.layouts.map(\.name) == ["Focus", "Review"])
    }

    // A start with no call of openUIStores() first waits for the import too, so the settings
    // store opens the imported file.
    @MainActor
    @Test func aStartWithNoUIStoresImportsFirst() async throws {
        let home = try TestHome()
        defer { home.remove() }
        let identity = try development()
        let folders = DataFolders(identity: identity, home: home.home)
        try folders.create()
        try home.addFixtures()
        let plan = StartPlan(
            identity: identity, home: home.home, realHome: URL(filePath: "/Users/someone"),
            testHome: true, folders: folders)
        let services = AppServices(
            plan: plan, home: home.home, environment: [:], processes: FakeProcessInspector(),
            speechEngine: { _ in FakeSpeechEngine() }, now: { importTime })
        defer { services.stop() }

        await services.start()

        #expect(services.settings?.settings.labels == .space)
        #expect(services.uiState == nil)
        #expect(fileExists(path(home.supportFile(ElectronImport.markerName))))
        #expect(try Data(contentsOf: home.supportFile("registry.json")) == fixture(.registry))
    }
}
