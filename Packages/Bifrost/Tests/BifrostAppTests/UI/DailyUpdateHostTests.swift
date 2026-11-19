import AppKit
import BifrostDailyUpdate
import BifrostDictation
import BifrostFoundation
import BifrostHealth
import BifrostLayout
import BifrostLook
import BifrostSessions
import BifrostSettings
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostApp
@testable import BifrostWindows


// The environment of the Daily update in a test: no reminder shows, the Dock does not bounce, and
// the wall time is a Saturday, so no reminder is due.
@MainActor
private func dailyEnvironment(_ clock: ManualClock) -> DailyEnvironment {
    let saturday = Date(timeIntervalSince1970: 1_700_000_000 + 4 * 86400)
    return DailyEnvironment(
        health: .none, eventLog: EventLogModel(clock: clock, now: Date.init),
        notifier: RecordingNotifier(), skills: URL(filePath: "/nonexistent-bifrost-test"),
        clock: clock, now: { saturday }, bouncesDock: false)
}

// The skill export of the Daily update follows the settings (docs/behaviour/daily-update.md,
// "The run"). Safety: the Daily update folder is in a temporary folder.
@MainActor
@Suite("the Daily update skill export", .timeLimit(.minutes(1)), .tags(.window))
struct DailySkillExportTests {
    // The value of the export file at the key path, or nil while the file is not there.
    private func exported(_ layout: DailyLayout, _ key: String) -> JSONValue? {
        guard let data = try? Data(contentsOf: layout.exportFile),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return value.object?[key]
    }

    @Test func theExportFollowsTheDailyUpdateSettings() async throws {
        UITestApp.prepare()
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let layout = DailyLayout(folder: folder.url.appending(path: "daily-update"))
        let clock = ManualClock()
        let host = DailyUpdateHost(layout: layout, clock: clock, now: Date.init)
        let store = await SettingsStore.open(
            file: folder.url.appending(path: "settings.json"), log: Recorder<StoreEvent>())
        #expect(store.settings.dailyUpdate == nil)
        // The store opens with no other copy, so the export follows the settings, also before
        // claude is found.
        host.start(settings: store, environment: dailyEnvironment(clock), showPanel: {})
        // With no block, the export has the defaults.
        await waitUntil { exported(layout, "you") == "" }
        var daily = DailySettings.defaults
        daily.you = "sam@example.com"
        try await store.edit { $0.dailyUpdate = daily }
        await waitUntil { exported(layout, "you") == "sam@example.com" }
        await host.close()
    }
}

// The start of the Daily update service in its host: the lock decides, and the quit frees it. The
// wall time is a Saturday, so no reminder is due and no draft runs. Safety: the files are in a
// temporary folder, and claude and gh are fakes that run no program.
@MainActor
@Suite("the Daily update start", .serialized, .timeLimit(.minutes(1)), .tags(.window))
struct DailyUpdateStartTests {
    @MainActor
    private struct Home {
        let folder: TemporaryFolder
        let layout: DailyLayout
        let host: DailyUpdateHost
        let store: SettingsStore
        let environment: DailyEnvironment
        let clock = ManualClock()

        init() async throws {
            UITestApp.prepare()
            folder = try TemporaryFolder()
            layout = DailyLayout(folder: folder.url.appending(path: "daily-update"))
            host = DailyUpdateHost(layout: layout, clock: clock, now: Date.init)
            store = await SettingsStore.open(
                file: folder.url.appending(path: "settings.json"), log: Recorder<StoreEvent>())
            let saturday = Date(timeIntervalSince1970: 1_700_000_000 + 4 * 86400)
            environment = DailyEnvironment(
                health: .none, eventLog: EventLogModel(clock: clock, now: Date.init),
                notifier: RecordingNotifier(), skills: folder.url, clock: clock,
                now: { saturday }, bouncesDock: false)
        }

        // The services found claude. Both claude and gh are fakes that run no program.
        func claudeFound() {
            let runner = FakeRunner(ExecResult(.exited(0)))
            host.claudeFound(
                ClaudeRunner(
                    path: "/nonexistent-bifrost-test/claude", baseEnvironment: [:],
                    runner: runner),
                gh: GHCommand(
                    path: "gh", environment: [:], folder: layout.runsFolder, runner: runner))
        }
    }

    @Test func anotherCopyStopsTheServiceAndTheExport() async throws {
        let home = try await Home()
        defer { home.folder.remove() }
        try FileManager.default.createDirectory(
            at: home.layout.folder, withIntermediateDirectories: true)
        let lock = try FileLock.take(home.layout.lockFile)
        defer { lock.release() }
        home.host.start(settings: home.store, environment: home.environment, showPanel: {})
        home.claudeFound()
        await waitUntil { home.host.notice != nil }
        #expect(home.host.notice == DailyStoreError.otherCopy.message)
        #expect(home.host.unavailable == DailyStoreError.otherCopy.message)
        #expect(home.host.service == nil)
        // A late claude starts nothing.
        home.claudeFound()
        #expect(home.host.service == nil)
        #expect(!FileManager.default.fileExists(atPath: home.layout.exportFile.path))
        await home.host.close()
    }

    @Test func theQuitFreesTheLock() async throws {
        let home = try await Home()
        defer { home.folder.remove() }
        home.host.start(settings: home.store, environment: home.environment, showPanel: {})
        home.claudeFound()
        await waitUntil { home.host.service != nil }
        #expect(home.host.notice == nil)
        // The service owns one timer, for the next date.
        await home.clock.waitForSleepers(1)
        await home.host.close()
        let lock = try FileLock.take(home.layout.lockFile)
        lock.release()
        // The stop is final: the service and its timer are gone, and a late claude starts
        // nothing.
        #expect(home.host.service == nil)
        await home.clock.waitUntilNoSleepers()
        home.claudeFound()
        #expect(home.host.service == nil)
    }

    // A stop during the open of the store starts nothing, and the close still frees the lock.
    @Test func aStopDuringTheOpenStartsNothingAndFreesTheLock() async throws {
        let home = try await Home()
        defer { home.folder.remove() }
        home.claudeFound()
        home.host.start(settings: home.store, environment: home.environment, showPanel: {})
        home.host.stop()
        await home.host.close()
        #expect(home.host.service == nil)
        let lock = try FileLock.take(home.layout.lockFile)
        lock.release()
        #expect(!FileManager.default.fileExists(atPath: home.layout.exportFile.path))
    }
}
