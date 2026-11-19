import BifrostFoundation
import Foundation
import Observation

// The status of the Bifrost skills that Settings shows.
package struct SkillsStatus: Sendable, Equatable {
    // The plugin in the plugin list. unknown when Bifrost cannot read the list.
    package var plugin: LivePluginState
    // True when the skills folder has the files of the skills folder of the app, and the plugin
    // reads that folder (or the list gives no folder).
    package var folderCurrent: Bool
    // The skills of the skills folder of the app, sorted by name. Empty when Bifrost cannot read
    // them.
    package var skills: [SkillInfo]
    // The errors of the plugin list, of the read of the skills and of a marketplace of another
    // program, with a space between them, or nil.
    package var error: String?

    package init(plugin: LivePluginState, folderCurrent: Bool, skills: [SkillInfo], error: String?)
    {
        self.plugin = plugin
        self.folderCurrent = folderCurrent
        self.skills = skills
        self.error = error
    }
}

// The skills control (docs/behaviour/skills.md, The skills control): the start rule, the four
// actions (Install, Turn on, Turn off and Remove) and the status of the Bifrost skills plugin. It
// follows the Live details control (LiveControl), with no server and no old hook data, and it
// shares the one lock of the plugin changes with that control.
//
// Bifrost changes only its own marketplace. A marketplace with the name of the marketplace of
// Bifrost and another path, or with no path, belongs to another program.
//
// - start() runs the start rule as one task in the lock (SerialLock.first). The app calls it after
//   the start of the Live details control, so it runs after that start. With an installed plugin,
//   on or off, it syncs the skills folder. A marketplace of another program stops it with no write
//   and no log line. Each failure goes to the log, and the start never rejects.
// - stop() cancels the start task. After a stop, no action runs, and a start that a stop came
//   before does nothing.
// - run(_:) runs an action in the lock, in a task of its own (ActionCancel.run). Each action first
//   refuses a marketplace of another program, before the step that would change something. A
//   second action during an action rejects with busy. An action that comes during the start
//   waits for it. Between two steps an action checks for a stop, and before its first plugin
//   write also for a cancel of its caller, and rejects with cancelled. After the first plugin
//   write, only a stop ends it.
// - Each sync and each removal of the skills folder runs in the lock: in the start or in an
//   action.
// - status() waits for the start (SerialLock.afterFirst) and takes no lock.
@MainActor
@Observable
package final class SkillsControl {
    @ObservationIgnored private let paths: SharedClaudeState
    @ObservationIgnored private let cli: () -> PluginCLI?
    @ObservationIgnored private let source: URL
    @ObservationIgnored private let lock: SerialLock
    @ObservationIgnored private let log: any LiveLog
    // The phase of the control: before the start, after the start (with the task of the start,
    // which stop() cancels), or after the stop.
    private enum Phase: Equatable {
        case waiting
        case started(Task<Void, Never>)
        case stopped
    }

    @ObservationIgnored private var phase = Phase.waiting

    // paths: the shared paths of the home. cli: the plugin commands of the skills plugin, or nil
    // when the app has no claude. source: the skills folder of the app. lock: the one lock of the
    // plugin changes, which the Live details control shares.
    package init(
        paths: SharedClaudeState, cli: @escaping () -> PluginCLI?, source: URL, lock: SerialLock,
        log: any LiveLog
    ) {
        self.paths = paths
        self.cli = cli
        self.source = source
        self.lock = lock
        self.log = log
    }

    // MARK: - The start and the stop

    // Run the start rule in the lock, one time, as a task. The start counts in the lock from this
    // call (SerialLock.first), so a status read or an action after it waits for it. A call after
    // stop() does nothing.
    package func start() {
        guard phase == .waiting else { return }
        phase = .started(lock.first { await self.boot() })
    }

    // Cancel the start. An action that runs now ends at its next step.
    package func stop() {
        if case .started(let task) = phase { task.cancel() }
        phase = .stopped
    }

    // The start rule: sync the folder of an installed plugin, on or off. A failure goes to the
    // log. A start that a stop came before does nothing.
    private func boot() async {
        if phase == .stopped { return }
        do throws(PluginFailure) {
            guard let plugins = cli() else { throw .claudeNotFound }
            // A marketplace of another program is not Bifrost's. Write nothing and do not log.
            if let market = try await plugins.marketplace(), foreign(market) != nil { return }
            guard try await plugins.plugin() != nil, phase != .stopped else { return }
            try await syncFolder()
        } catch {
            // A stop cancels the read of a list.
            if phase == .stopped { return }
            log.record(.skillsStartFailed(error))
        }
    }

    // MARK: - The status

    // The status after the start. It takes no lock, so it runs next to an action.
    package func status() async -> SkillsStatus {
        await lock.afterFirst { await read() }
    }

    // Read the plugin, the skills folder, the skills of the app and the marketplace at the same
    // time.
    private func read() async -> SkillsStatus {
        let plugins = cli()
        let (source, dest) = (source, paths.skillsFolder)
        async let plugin = PluginRead.of(plugins)
        async let folderCurrent = FolderSync.skillsCurrent(source: source, dest: dest)
        async let skills = Self.readSkills(source)
        async let market = Self.readMarketplace(plugins)
        let read = await plugin
        let current = await folderCurrent
        let (list, listError) = await skills
        let found = await market
        // Only an installed plugin shows a marketplace of another program.
        let foreignError = read.entry == nil ? nil : found.flatMap { foreign($0)?.message }
        let errors = [read.error, listError, foreignError].compactMap { $0 }.filter { !$0.isEmpty }
        return SkillsStatus(
            plugin: read.state,
            folderCurrent: current && (read.entry?.reads(dest) ?? true),
            skills: list, error: errors.isEmpty ? nil : errors.joined(separator: " "))
    }

    // The skills of the app, or no skills and the text of a failed read. Settings uses it also
    // with no claude, when no control exists.
    nonisolated package static func readSkills(_ source: URL) async -> ([SkillInfo], String?) {
        do throws(SyncFailure) {
            return (try await SkillsList.list(source), nil)
        } catch {
            return ([], "Bifrost couldn't read its skills. \(error.message)")
        }
    }

    // The marketplace with the name of the marketplace of Bifrost, or nil. A failed read gives
    // nil, because the read of the plugin gives the text of a failed list.
    nonisolated private static func readMarketplace(_ cli: PluginCLI?) async -> MarketplaceEntry? {
        guard let cli else { return nil }
        do throws(PluginFailure) {
            return try await cli.marketplace()
        } catch {
            return nil
        }
    }

    // MARK: - The actions

    // Run the action in the lock, and give the status after it. The action runs in a task of its
    // own. A cancel of the caller ends the action only before its first plugin write: then it
    // also stops a list read at once. From the first write on, the action runs to its end, and
    // only the stop of the app ends it, at its next step (PluginSteps).
    package func run(_ action: LiveAction) async throws(PluginFailure) -> SkillsStatus {
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

    // Install: refuse a marketplace of another program, then sync the skills folder, add the
    // marketplace (unless it is already Bifrost's), install the plugin and turn it on. The sync
    // comes before the add, because claude reads the manifest of the marketplace in the folder.
    private func install(_ steps: PluginSteps) async throws(PluginFailure) {
        let plugins = try steps.plugins
        try steps.checkCancel()
        let market = try await ownMarketplace(plugins)
        try steps.checkCancel()
        try await syncFolder()
        try steps.checkCancel()
        try await steps.installAndEnable(market: market, folder: paths.skillsFolder)
    }

    // Turn on: refuse a marketplace of another program and a plugin that is not installed, then
    // sync the skills folder and turn the plugin on.
    private func enable(_ steps: PluginSteps) async throws(PluginFailure) {
        let plugins = try steps.plugins
        try steps.checkCancel()
        _ = try await ownMarketplace(plugins)
        try steps.checkCancel()
        try await steps.requireInstalled()
        try await syncFolder()
        try await steps.enable()
    }

    // Turn off: refuse a marketplace of another program, then turn off an installed plugin.
    private func disable(_ steps: PluginSteps) async throws(PluginFailure) {
        let plugins = try steps.plugins
        try steps.checkCancel()
        _ = try await ownMarketplace(plugins)
        try steps.checkCancel()
        try await steps.disableIfInstalled()
    }

    // Remove: refuse a marketplace of another program, then uninstall the plugin, remove the
    // marketplace of Bifrost and remove the skills folder.
    private func uninstall(_ steps: PluginSteps) async throws(PluginFailure) {
        let plugins = try steps.plugins
        try steps.checkCancel()
        let market = try await ownMarketplace(plugins)
        try steps.checkCancel()
        try await steps.uninstallIfInstalled()
        try steps.checkCancel()
        if market != nil {
            try await steps.removeMarketplace()
            try steps.checkCancel()
        }
        do throws(SyncFailure) {
            try await FolderSync.remove(paths.skillsFolder)
        } catch {
            throw .folder(error)
        }
    }

    // MARK: - The steps

    // The marketplace of Bifrost, or nil when the list has no marketplace with its name. A
    // marketplace of another program rejects.
    private func ownMarketplace(_ plugins: PluginCLI) async throws(PluginFailure)
        -> MarketplaceEntry?
    {
        guard let market = try await plugins.marketplace() else { return nil }
        if let failure = foreign(market) { throw failure }
        return market
    }

    // The refusal of a marketplace of another program, or nil for the marketplace of Bifrost:
    // the marketplace whose path is the skills folder.
    private func foreign(_ market: MarketplaceEntry) -> PluginFailure? {
        market.foreignRefusal(.skills, folder: paths.skillsFolder)
    }

    // Sync the skills folder. The caller holds the lock.
    private func syncFolder() async throws(PluginFailure) {
        do throws(SyncFailure) {
            try await FolderSync.syncSkills(source: source, dest: paths.skillsFolder)
        } catch {
            throw .folder(error)
        }
    }
}
