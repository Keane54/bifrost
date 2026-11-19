// The installed apps of the action runner: a find at the start and after each change of the
// Terminal app setting. The search is a fake, so no test reads the folders of the apps.
import BifrostFoundation
import BifrostSessions
import BifrostSettings
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostApp

private func app(_ id: ProjectAppID) -> InstalledApp {
    InstalledApp(app: ProjectApp(id: id, label: id.name), path: "/Apps/\(id.name).app")
}

@Suite("installed app list", .timeLimit(.minutes(1)))
@MainActor
struct InstalledAppListTests {
    // The list is empty until the first find. Then it has the apps of the Terminal app setting
    // of now, and it follows each change of the setting.
    @Test func theListFollowsTheTerminalAppSetting() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = await SettingsStore.open(
            file: folder.url.appending(path: "settings.json"), log: Recorder<StoreEvent>())
        let list = InstalledAppList { terminal in
            [app(.finder)] + (terminal.map { [app(ProjectAppID(terminal: $0))] } ?? [])
        }
        #expect(list.apps.isEmpty)
        let following = list.follow(store)
        #expect(list.follow(store) == following)
        await waitUntil { list.apps == [app(.finder)] }
        try await store.edit { $0.terminalApp = .iterm2 }
        await waitUntil { list.apps == [app(.finder), app(.iterm2)] }
        #expect(list.apps == [app(.finder), app(.iterm2)])
    }

    // A change of another setting gives the same Terminal app value, so it runs no search. A
    // new value runs one.
    @Test func anotherSettingRunsNoSearch() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = await SettingsStore.open(
            file: folder.url.appending(path: "settings.json"), log: Recorder<StoreEvent>())
        let searches = Mutex<[TerminalAppID?]>([])
        let list = InstalledAppList { terminal in
            searches.withLock { $0.append(terminal) }
            return [app(.finder)] + (terminal.map { [app(ProjectAppID(terminal: $0))] } ?? [])
        }
        await list.find(nil)
        await list.find(nil)
        #expect(searches.withLock { $0 } == [nil])
        list.follow(store)
        _ = try await store.edit { $0.interfaceScale = 120 }
        _ = try await store.edit { $0.terminalApp = .warp }
        await waitUntil { list.apps == [app(.finder), app(.warp)] }
        #expect(searches.withLock { $0 } == [nil, .warp])
    }
}
