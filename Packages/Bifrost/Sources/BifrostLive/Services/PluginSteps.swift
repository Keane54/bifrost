import Foundation

// The steps of one action of the Live details control or of the skills control, in the lock of
// the plugin changes (docs/behaviour/live.md, The actions). This is the one place of the rule of
// a cancel: before the first plugin write, a stop of the app or a cancel of the caller ends the
// action between two steps with cancelled. From the first write on (beginWrite), only the stop of
// the app ends it, at its next step: the plugin state changed, so the action runs to its end.
@MainActor
struct PluginSteps {
    private let cli: PluginCLI?
    private let cancel: ActionCancel
    private let stopped: () -> Bool

    // cli: the plugin commands of the action, or nil when the app has no claude. cancel: the
    // cancel of the caller (ActionCancel.run). stopped: true after the stop of the control.
    init(cli: PluginCLI?, cancel: ActionCancel, stopped: @escaping () -> Bool) {
        self.cli = cli
        self.cancel = cancel
        self.stopped = stopped
    }

    // The plugin commands. With no claude, the action rejects with claudeNotFound.
    var plugins: PluginCLI {
        get throws(PluginFailure) {
            guard let cli else { throw .claudeNotFound }
            return cli
        }
    }

    // End the action between two steps after a stop, or after a cancel of the caller that came
    // before the first write.
    func checkCancel() throws(PluginFailure) {
        if stopped() || cancel.isCancelled { throw .cancelled }
    }

    // Check for a cancel, then mark the first plugin write of the action in the same step. From
    // then on, only the stop of the app ends the action.
    func beginWrite() throws(PluginFailure) {
        if stopped() || !cancel.beginWrite() { throw .cancelled }
    }

    // Refuse a plugin that the plugin list does not have.
    func requireInstalled() async throws(PluginFailure) {
        let plugins = try plugins
        guard try await plugins.plugin() != nil else { throw .notInstalled(plugins.ids) }
        try checkCancel()
    }

    // Add the folder as the marketplace when the list has no marketplace with its name (market
    // is nil), install the plugin when the list does not have it, then turn the plugin on when
    // it is off. The last write has no check after it: the caller decides.
    func installAndEnable(market: MarketplaceEntry?, folder: URL) async throws(PluginFailure) {
        let plugins = try plugins
        if market == nil {
            try beginWrite()
            try await plugins.addMarketplace(folder)
            try checkCancel()
        }
        var entry = try await plugins.plugin()
        try checkCancel()
        if entry == nil {
            try beginWrite()
            try await plugins.install()
            try checkCancel()
            // If the install leaves the plugin off, the next step turns it on.
            entry = try await plugins.plugin()
            try checkCancel()
        }
        if let entry, !entry.enabled {
            try beginWrite()
            try await plugins.enable()
        }
    }

    // Turn the plugin on.
    func enable() async throws(PluginFailure) {
        let plugins = try plugins
        try beginWrite()
        try await plugins.enable()
    }

    // Turn off the plugin when the list has it.
    func disableIfInstalled() async throws(PluginFailure) {
        let plugins = try plugins
        guard try await plugins.plugin() != nil else { return }
        try beginWrite()
        try await plugins.disable()
    }

    // Uninstall the plugin when the list has it.
    func uninstallIfInstalled() async throws(PluginFailure) {
        let plugins = try plugins
        guard try await plugins.plugin() != nil else { return }
        try beginWrite()
        try await plugins.uninstall()
    }

    // Remove the marketplace of Bifrost. The caller checked that it is Bifrost's.
    func removeMarketplace() async throws(PluginFailure) {
        let plugins = try plugins
        try beginWrite()
        try await plugins.removeMarketplace()
    }
}

// The state of a plugin of Bifrost in the plugin list of Claude Code, its entry, and the text of
// a failed read.
struct PluginRead: Sendable {
    var state: LivePluginState
    var entry: PluginEntry?
    var error: String?

    // Read the plugin list. With no claude (nil), the state is unknown with the text of
    // claudeNotFound.
    static func of(_ cli: PluginCLI?) async -> PluginRead {
        guard let cli else {
            return PluginRead(state: .unknown, error: PluginFailure.claudeNotFound.message)
        }
        do throws(PluginFailure) {
            guard let entry = try await cli.plugin() else {
                return PluginRead(state: .notInstalled)
            }
            return PluginRead(state: entry.enabled ? .enabled : .disabled, entry: entry)
        } catch {
            return PluginRead(state: .unknown, error: error.message)
        }
    }
}
