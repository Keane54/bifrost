import BifrostSessions

// The texts and the rules of Settings > Live details, of the warning dot of the side bar and of
// the Setup dialog (docs/behaviour/live.md, "Settings > Live details"). The rules are pure, so
// the tests can check each one.

// The state of Live details for the user. A status that Bifrost has not read yet is loading.
package enum LiveNotice: Sendable, Equatable {
    case loading, notInstalled, off
    // The plugin is on, Bifrost listens, and the mod folder has the files of the app.
    case on(sessions: Int)
    // Bifrost cannot read the plugin state, or the plugin is on with no listener or with other
    // files. The text tells why.
    case problem(String)

    package static func of(_ status: LiveStatus?) -> LiveNotice {
        guard let status else { return .loading }
        switch status.plugin {
        case .unknown: return .problem(status.error ?? LiveTexts.notChecked)
        case .notInstalled: return .notInstalled
        case .disabled: return .off
        case .enabled:
            if !status.listening { return .problem(status.error ?? LiveTexts.notReceiving) }
            if !status.modCurrent { return .problem(LiveTexts.filesDiffer) }
            return .on(sessions: status.liveSessions)
        }
    }

    // The state line of the Live details section.
    package var stateLine: String {
        switch self {
        case .loading: "Checking Live details..."
        case .notInstalled: "Not installed."
        case .off: "Off."
        case .on(let sessions):
            sessions == 1
                ? "On. 1 session is sending live details."
                : "On. \(sessions) sessions are sending live details."
        case .problem(let message): message
        }
    }

    package var isProblem: Bool {
        if case .problem = self { return true }
        return false
    }

    // True when Live details is on. The hint of an empty Event log shows while it is false.
    package var isOn: Bool {
        if case .on = self { return true }
        return false
    }
}

// The texts of Live details. The Setup dialog and the Live details section share them.
package enum LiveTexts {
    // The note after a good Install or Turn on of Live details or of the skills.
    package static let reloadNote =
        "Sessions that run now get the change after /reload-plugins or a restart."
    package static let withoutLive =
        "Without Live details, Bifrost still lists your sessions and shows their boxes from the "
        + "session list, a little later, but with no model, context % or cost. You can turn it on "
        + "later in Settings > Live details."
    // What Live details does. The Setup dialog shows it, also when it opens again.
    package static let about =
        "Live details lets Bifrost see each session as it happens: a box the moment Claude "
        + "finishes or needs you, plus the model, context % and cost. It's a small Claude Code "
        + "plugin that sends events to Bifrost on this Mac."
    package static let setupIntro = about + " Bifrost makes these changes only if you turn it on:"
    // The note of the Setup dialog when it opens again and Live details is installed.
    package static let introChangeNote = "You can change this in Settings > Live details."
    package static let removeConfirm = ConfirmText(
        title: "Remove Live details",
        body: "Bifrost turns off Live details, removes the plugin and the folder ~/.bifrost/mod, "
            + "and removes any old Bifrost hooks (with a backup first).",
        confirm: "Remove")
    // The note for a Claude Code that is older than the minimum of Live details.
    package static let liveVersionNote =
        "Live details needs Claude Code \(ClaudeVersionCheck.liveMinimum) or later."
    package static let versionCheckFailed = "Bifrost couldn't check the Claude Code version."
    // The line above the steps of Install. The Skills section uses it too.
    package static let installLead = "Install makes these changes:"

    static let notChecked = "Bifrost couldn't check Live details."
    static let notReceiving =
        "Live details is on, but Bifrost isn't receiving it. Try Turn off, then Turn on."
    static let filesDiffer =
        "Live details uses files that don't match this Bifrost. Remove it, then install it again."
    static let oldInstall =
        "Bifrost found its old hooks in ~/.claude/settings.json. Install or Turn on removes them "
        + "first and saves a backup."
    static let stepOldHooks =
        "Remove Bifrost's old hooks and statusLine wrapper from ~/.claude/settings.json. Your "
        + "other hooks stay, and Bifrost saves a backup first."
    static let stepCopy = "Copy the Live details plugin files to the folder ~/.bifrost/mod."
    static let stepPlugin =
        #"Add that folder as the plugin marketplace "bifrost-local", then install the plugin "#
        + #""bifrost-live" for your user with claude plugin."#
}

// The buttons of the Live details section and of the Skills section. retry reads the status
// again.
package enum LiveActionID: String, Sendable, CaseIterable {
    case install, enable, disable, remove, retry

    // The label of the button. The search of Settings also reads it.
    package var label: String {
        switch self {
        case .install: "Install"
        case .enable: "Turn on"
        case .disable: "Turn off"
        case .remove: "Remove"
        case .retry: "Try again"
        }
    }

    // The action of the control, or nil for retry.
    package var action: LiveAction? {
        switch self {
        case .install: .install
        case .enable: .enable
        case .disable: .disable
        case .remove: .uninstall
        case .retry: nil
        }
    }
}

// first: the Setup dialog at the first start. again: the dialog from the Introduction row of
// Settings > General.
package enum SetupMode: Sendable {
    case first, again
}

// The phase of the Setup dialog: the choice, the skills step, or the end after an install.
package enum SetupPhase: Sendable {
    case ask, skills, done
}

// The view of the Setup dialog. installed: the state of an installed plugin, with Done.
package enum SetupView: Sendable {
    case ask, installed, skills, done
}

package enum LiveRules {
    // The status when the status read fails. The notice then shows the reason, with Try again.
    package static func unknownStatus(_ message: String) -> LiveStatus {
        LiveStatus(
            plugin: .unknown, modCurrent: false, oldInstall: false, listening: false,
            liveSessions: 0, claudeVersion: nil, versionOk: false, error: message)
    }

    // The note for an old hook install, or nil.
    package static func oldInstallNote(_ status: LiveStatus?) -> String? {
        status?.oldInstall == true ? LiveTexts.oldInstall : nil
    }

    // The changes of Install, in the order that Install makes them.
    package static func steps(_ status: LiveStatus) -> [String] {
        (status.oldInstall ? [LiveTexts.stepOldHooks] : []) + [
            LiveTexts.stepCopy, LiveTexts.stepPlugin,
        ]
    }

    // The general notice about the version of Claude Code, or nil. A version that Bifrost has not
    // read yet gives nil.
    package static func versionNotice(_ version: ClaudeVersionCheck?) -> String? {
        guard let version, !version.ok else { return nil }
        guard let found = version.version else { return ActionRefusal.claudeNotFound.message }
        return "Claude Code \(found) is older than \(version.minimum), which Bifrost needs. "
            + "Please update Claude Code."
    }

    // The general notice about the version, also for a failed check. Settings > General shows
    // it at the top, and the Live details section under the Claude Code line.
    package static func claudeVersionNotice(_ version: ClaudeVersionCheck?, failed: Bool)
        -> String?
    {
        failed ? LiveTexts.versionCheckFailed : versionNotice(version)
    }

    // The Claude Code line of the Live details section, or nil. A failed check and a missing
    // claude give nil, because the notice gives the reason.
    package static func claudeVersionLine(_ version: ClaudeVersionCheck?, failed: Bool) -> String? {
        guard let version else { return failed ? nil : "Checking Claude Code..." }
        return version.version.map { "Claude Code \($0)" }
    }

    // The note for a Claude Code that is too old for Live details, or nil. With no version, the
    // version notice already says that Bifrost can't find Claude Code.
    package static func liveVersionNote(_ status: LiveStatus?) -> String? {
        guard let status, !status.versionOk, status.claudeVersion != nil else { return nil }
        return LiveTexts.liveVersionNote
    }

    // True when Bifrost has a warning about Live details or Claude Code: the side bar Settings
    // button and the Live details tab then show a dot. A failed version check is a warning too. A
    // version that is too old for Live details counts only while the plugin is installed, because
    // after Skip, Live details off is the choice of the user.
    package static func hasWarning(
        _ status: LiveStatus?, _ version: ClaudeVersionCheck?, versionFailed: Bool
    ) -> Bool {
        if LiveNotice.of(status).isProblem { return true }
        if oldInstallNote(status) != nil { return true }
        if claudeVersionNotice(version, failed: versionFailed) != nil { return true }
        return setupChosen(status) && liveVersionNote(status) != nil
    }

    // The buttons of the Live details section.
    package static func actions(_ status: LiveStatus?) -> [LiveActionID] {
        guard let status else { return [] }
        switch status.plugin {
        case .unknown: return [.retry]
        case .notInstalled: return [.install]
        case .disabled: return [.enable, .remove]
        case .enabled:
            if case .on = LiveNotice.of(status) { return [.disable, .remove] }
            return [.disable, .enable, .remove]
        }
    }

    // The Setup dialog shows before the first choice, when the plugin is not installed or its
    // state is unknown. An unknown state shows the dialog with the problem.
    package static func shouldShowSetup(setupDone: Bool, _ status: LiveStatus?) -> Bool {
        guard !setupDone, let status else { return false }
        return status.plugin == .notInstalled || status.plugin == .unknown
    }

    // An installed plugin, on or off, is already a choice. Then the setup is done with no dialog.
    package static func setupChosen(_ status: LiveStatus?) -> Bool {
        status?.plugin == .enabled || status?.plugin == .disabled
    }

    // The view of the Setup dialog. At the first start, the dialog keeps its choice until Skip or
    // Done, also when the status changes. When it opens again, it does not offer an install that
    // already happened: an installed plugin, on or off, gives its state and Done.
    package static func setupView(_ mode: SetupMode, _ phase: SetupPhase, _ status: LiveStatus?)
        -> SetupView
    {
        switch phase {
        case .skills: return .skills
        case .done: return .done
        case .ask: return mode == .again && setupChosen(status) ? .installed : .ask
        }
    }

    // Skip saves the choice only at the first start. When the dialog opens again, Skip only
    // closes it, so the open never changes the saved choice by itself.
    package static func skipSavesChoice(_ mode: SetupMode) -> Bool {
        mode == .first
    }

    // The state line of the Setup dialog for an installed plugin. A problem text names Live
    // details itself.
    package static func introStateLine(_ notice: LiveNotice) -> String {
        notice.isProblem ? notice.stateLine : "Live details: \(notice.stateLine)"
    }
}
