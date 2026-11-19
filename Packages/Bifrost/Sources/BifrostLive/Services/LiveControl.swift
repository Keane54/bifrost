import BifrostFoundation
import BifrostSessions
import Foundation
import Observation

// The state of a plugin of Bifrost in the plugin list of Claude Code: the Live details plugin or
// the skills plugin.
package enum LivePluginState: String, Sendable {
    case notInstalled = "not-installed", enabled, disabled, unknown
}

// The status of Live details that Settings shows.
package struct LiveStatus: Sendable, Equatable {
    // The plugin in the plugin list. unknown when Bifrost cannot read the list.
    package var plugin: LivePluginState
    // True when the mod folder has the bytes of the mod of the app, and the plugin reads that
    // folder (or the list gives no folder).
    package var modCurrent: Bool
    // True when the Claude Code settings still have the old hook install.
    package var oldInstall: Bool
    package var listening: Bool
    // The number of rows that are live and not parked.
    package var liveSessions: Int
    // The version of claude, or nil when the check got none.
    package var claudeVersion: String?
    package var versionOk: Bool
    // The errors of the plugin list, of the settings read and of the server, with a space between
    // them, or nil.
    package var error: String?

    package init(
        plugin: LivePluginState, modCurrent: Bool, oldInstall: Bool, listening: Bool,
        liveSessions: Int, claudeVersion: String?, versionOk: Bool, error: String?
    ) {
        self.plugin = plugin
        self.modCurrent = modCurrent
        self.oldInstall = oldInstall
        self.listening = listening
        self.liveSessions = liveSessions
        self.claudeVersion = claudeVersion
        self.versionOk = versionOk
        self.error = error
    }
}

// The actions of the Live details section and of the Skills section. The debug test port of the
// app target takes an action by its raw value, so the type is public.
public enum LiveAction: String, Sendable {
    case install, enable, disable, uninstall
}

// The Live details control (docs/behaviour/live.md, The Live details control): the start rule,
// the four actions (Install, Turn on, Turn off and Remove) and the status. Bifrost listens on the
// shared socket only while the plugin is on.
//
// - start() runs the start of the app as one task in the lock (SerialLock.runFirst): first the
//   clean-up of the old hook data, then the start rule. With forceListen, it listens at once.
//   With the plugin on, it syncs the mod folder and listens. A failed sync still listens,
//   because the old mod files still send lines. When the plugin list fails, it listens only when
//   the mod manifest exists.
// - stop() cancels the start task and stops the server. After a stop, nothing listens again and
//   no action runs. A start that a stop came before does nothing. The check for a stop and the
//   start of the server are in one turn of the main actor, so a stop always comes before the
//   start of the server or cancels it.
// - run(_:) runs an action in the lock. A second action during an action rejects with busy. An
//   action that comes during the start waits for it. Between two steps an action checks for a
//   stop, and before its first plugin write also for a cancel of its caller, and rejects with
//   cancelled. After the first plugin write, only a stop ends it. A refusal comes before the step
//   that would change something.
// - Turn off and Remove stop the server first, then end the live flag of each row, so no line
//   comes after the change and the status shows 0 live sessions at once.
// - status() waits for the start (SerialLock.afterFirst) and takes no lock.
// - The health log of the app (HealthReporter) gets the result of each start of the server: a
//   good start, or the reason of a start that did not listen. Turn off and Remove tell it that
//   Live details does not listen now, so an old failure no longer applies.
@MainActor
@Observable
package final class LiveControl {
    // The server on the shared socket of the home (SharedClaudeState.liveSocket).
    package let server: LiveServer
    @ObservationIgnored private let paths: SharedClaudeState
    @ObservationIgnored private let cli: () -> PluginCLI?
    @ObservationIgnored private let version: () async -> ClaudeVersionCheck
    @ObservationIgnored private let registry: RegistryService?
    @ObservationIgnored private let modSource: URL
    @ObservationIgnored private let lock: SerialLock
    @ObservationIgnored private let forceListen: Bool
    @ObservationIgnored private let log: any LiveLog
    @ObservationIgnored private let health: HealthReporter
    @ObservationIgnored private let now: @Sendable () -> Date
    // The phase of the control: before the start, after the start (with the task of the start,
    // which stop() cancels), or after the stop.
    private enum Phase: Equatable {
        case waiting
        case started(Task<Void, Never>)
        case stopped
    }

    @ObservationIgnored private var phase = Phase.waiting

    // paths: the shared paths of the home. cli: the plugin commands of Live details, or nil when
    // the app has no claude. version: the version check of claude with the normal runner.
    // server: makes the server on a socket path. registry: the live count and the live flags.
    // modSource: the mod folder of the app. lock: the one lock of the plugin changes, which the
    // skills control shares. forceListen: listen at the start with no plugin check (only a
    // development app with a test home, StartPlan.forceListen). now: the wall time of a backup
    // name of the settings file. health: the results of the starts of the server.
    package init(
        paths: SharedClaudeState, cli: @escaping () -> PluginCLI?,
        version: @escaping () async -> ClaudeVersionCheck,
        server: (URL) -> LiveServer, registry: RegistryService?, modSource: URL,
        lock: SerialLock, forceListen: Bool, log: any LiveLog,
        now: @escaping @Sendable () -> Date = Date.init, health: HealthReporter = .none
    ) {
        self.paths = paths
        self.cli = cli
        self.version = version
        self.server = server(paths.liveSocket)
        self.registry = registry
        self.modSource = modSource
        self.lock = lock
        self.forceListen = forceListen
        self.log = log
        self.now = now
        self.health = health
    }

    // MARK: - The start and the stop

    // Run the start of the app in the lock, one time, as a task. The start counts in the lock
    // from this call (SerialLock.first), so a status read or an action after it waits for it. A
    // call after stop() does nothing.
    package func start() {
        guard phase == .waiting else { return }
        phase = .started(lock.first { await self.boot() })
    }

    // Cancel the start and stop the server. A start, Install or Turn on that runs now then does
    // not listen, and an action ends at its next step.
    package func stop() {
        if case .started(let task) = phase { task.cancel() }
        phase = .stopped
        server.stop()
    }

    // The start: the clean-up of the old hook data, then the start rule. Each failure goes to
    // the log, and the start goes on. A start that a stop came before does nothing.
    private func boot() async {
        if phase == .stopped { return }
        let old = await ClaudeSettingsFile.oldInstall(paths)
        await OldHookData.remove(
            paths.bifrostHome, keepScripts: ClaudeSettingsFile.keepOldScripts(old))
        if phase == .stopped { return }
        if forceListen {
            await listen()
            return
        }
        let entry: PluginEntry?
        do throws(PluginFailure) {
            guard let plugins = cli() else { throw .claudeNotFound }
            entry = try await plugins.plugin()
        } catch {
            // A stop cancels the read of the list.
            if phase == .stopped { return }
            log.record(.pluginListUnreadable(error))
            if hasModManifest() { await listen() }
            return
        }
        guard entry?.enabled == true, phase != .stopped else { return }
        do throws(SyncFailure) {
            // A current mod folder gets no copy.
            try await FolderSync.syncMod(source: modSource, dest: paths.modFolder)
        } catch {
            // The old mod files still send lines, so the start listens also after a failed copy.
            log.record(.modCopyFailed(error))
        }
        await listen()
    }

    // True when the manifest of the mod is in the mod folder.
    private func hasModManifest() -> Bool {
        let manifest = paths.modFolder.appending(path: ".claude-plugin/plugin.json")
        return FileManager.default.fileExists(atPath: manifest.path(percentEncoded: false))
    }

    // Start the server, unless a stop came. The check and the start of the start task of the
    // server are in one turn of the main actor, so a later stop cancels that task. The health log
    // gets the result. A start that a stop or Turn off ended gives no result.
    private func listen() async {
        guard phase != .stopped else { return }
        let state = await server.start()
        guard phase != .stopped else { return }
        if state.listening {
            health.record(.liveStart(failed: nil))
        } else if let reason = state.error {
            health.record(.liveStart(failed: reason))
        }
    }

    // Stop the server and end the live flags at once. No line can come after the stop. So the
    // yellow box of the poll applies again at once, and the status gives 0 live sessions. Live
    // details does not listen now, so the health log drops an old failed start.
    private func haltAndClear() {
        server.stop()
        registry?.clearLive()
        health.record(.liveStart(failed: nil))
    }

    // MARK: - The status

    // The status after the start. It takes no lock, so it runs next to an action.
    package func status() async -> LiveStatus {
        await lock.afterFirst { await read() }
    }

    // Read the plugin, the mod folder, the old install and the version at the same time, then the
    // server and the live count.
    private func read() async -> LiveStatus {
        let plugins = cli()
        let (source, dest) = (modSource, paths.modFolder)
        async let plugin = PluginRead.of(plugins)
        async let folderCurrent = FolderSync.modCurrent(source: source, dest: dest)
        async let old = ClaudeSettingsFile.oldInstall(paths)
        let check = await version()
        let read = await plugin
        let current = await folderCurrent
        let oldInstall = await old
        let oldError: String? =
            if case .failure(let failure) = oldInstall { failure.message } else { nil }
        let server = self.server.state
        let errors = [read.error, oldError, server.error].compactMap { $0 }.filter { !$0.isEmpty }
        return LiveStatus(
            plugin: read.state, modCurrent: current && (read.entry?.reads(dest) ?? true),
            oldInstall: (try? oldInstall.get()) == true, listening: server.listening,
            liveSessions: registry?.liveCount ?? 0, claudeVersion: check.version?.description,
            versionOk: check.ok, error: errors.isEmpty ? nil : errors.joined(separator: " "))
    }

    // MARK: - The actions

    // Run the action in the lock, and give the status after it. The action runs in a task of its
    // own. A cancel of the caller ends the action only before its first plugin write: then it
    // also stops a list read at once. From the first write on, the action runs to its end, and
    // only the stop of the app ends it, at its next step (PluginSteps).
    package func run(_ action: LiveAction) async throws(PluginFailure) -> LiveStatus {
        guard phase != .stopped else { throw .cancelled }
        return try await ActionCancel.run(in: lock) { cancel throws(PluginFailure) in
            let steps = PluginSteps(cli: self.cli(), cancel: cancel) { self.phase == .stopped }
            switch action {
            case .install: try await self.install(steps)
            case .enable: try await self.enable(steps)
            case .disable: try await self.disable(steps)
            case .uninstall: try await self.uninstall(steps)
            }
            return await self.read()
        }
    }

    // Install: refuse a version below the minimum and the marketplace of another program, then
    // remove an old hook install, sync the mod, add the marketplace, install the plugin, turn it
    // on and listen.
    private func install(_ steps: PluginSteps) async throws(PluginFailure) {
        try await checkVersion(steps)
        let plugins = try steps.plugins
        try steps.checkCancel()
        let market = try await plugins.marketplace()
        if let failure = market?.foreignRefusal(.live, folder: paths.modFolder) { throw failure }
        try steps.checkCancel()
        try await removeOldInstall(keptOldHooks: false)
        try steps.checkCancel()
        try await syncMod()
        try await steps.installAndEnable(market: market, folder: paths.modFolder)
        try steps.checkCancel()
        await listen()
    }

    // Turn on: refuse a version below the minimum and a plugin that is not installed, then
    // remove an old hook install, sync the mod, turn the plugin on and listen.
    private func enable(_ steps: PluginSteps) async throws(PluginFailure) {
        try await checkVersion(steps)
        _ = try steps.plugins
        try steps.checkCancel()
        try await steps.requireInstalled()
        try await removeOldInstall(keptOldHooks: false)
        try steps.checkCancel()
        try await syncMod()
        try await steps.enable()
        try steps.checkCancel()
        await listen()
    }

    // Turn off: the server is the switch that acts at once, so it stops before the plugin
    // command. A later failure rejects, and the server stays stopped.
    private func disable(_ steps: PluginSteps) async throws(PluginFailure) {
        haltAndClear()
        _ = try steps.plugins
        try steps.checkCancel()
        try await steps.disableIfInstalled()
    }

    // Remove: stop the server, uninstall the plugin, remove the marketplace of Bifrost (never a
    // marketplace with another path) and the mod folder. The old hook install goes last, so
    // settings that Bifrost cannot read reject after the plugin steps, and the user sees why the
    // old hooks can stay.
    private func uninstall(_ steps: PluginSteps) async throws(PluginFailure) {
        haltAndClear()
        let plugins = try steps.plugins
        try steps.checkCancel()
        try await steps.uninstallIfInstalled()
        try steps.checkCancel()
        if try await plugins.marketplace()?.isAt(paths.modFolder) == true {
            try await steps.removeMarketplace()
        }
        try steps.checkCancel()
        do throws(SyncFailure) {
            try await FolderSync.remove(paths.modFolder)
        } catch {
            throw .folder(error)
        }
        try steps.checkCancel()
        try await removeOldInstall(keptOldHooks: true)
    }

    // MARK: - The steps

    // A cancel also stops the run of the check, so a cancel rejects with cancelled, not with the
    // text of the version.
    private func checkVersion(_ steps: PluginSteps) async throws(PluginFailure) {
        try steps.checkCancel()
        let check = await version()
        try steps.checkCancel()
        if !check.ok { throw .liveVersionTooOld(found: check.version) }
    }

    private func syncMod() async throws(PluginFailure) {
        do throws(SyncFailure) {
            try await FolderSync.syncMod(source: modSource, dest: paths.modFolder)
        } catch {
            throw .folder(error)
        }
    }

    // Remove an old hook install. Settings that Bifrost cannot read reject with the text of the
    // read. A failed removal rejects too.
    private func removeOldInstall(keptOldHooks: Bool) async throws(PluginFailure) {
        switch await ClaudeSettingsFile.oldInstall(paths) {
        case .failure(let failure):
            throw .unreadableSettings(reason: failure.message, keptOldHooks: keptOldHooks)
        case .success(false):
            return
        case .success(true):
            break
        }
        do throws(IntegrationFailure) {
            try await ClaudeSettingsFile.uninstall(paths, now: now())
        } catch {
            throw .settingsEdit(error)
        }
    }
}
