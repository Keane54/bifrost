import BifrostSessions
import Testing

@testable import BifrostLive

// The texts and the rules of Settings > Live details and of the Setup dialog
// (docs/behaviour/live.md, "Settings > Live details"): the notice, the state line, the buttons,
// the notes, the version lines, the warning and the views of the Setup dialog.

// A status of a plugin that is on, listens and has the files of the app. Each test changes the
// values that it needs.
private func status(
    plugin: LivePluginState = .enabled, modCurrent: Bool = true, oldInstall: Bool = false,
    listening: Bool = true, liveSessions: Int = 0, claudeVersion: String? = "2.1.300",
    versionOk: Bool = true, error: String? = nil
) -> LiveStatus {
    LiveStatus(
        plugin: plugin, modCurrent: modCurrent, oldInstall: oldInstall, listening: listening,
        liveSessions: liveSessions, claudeVersion: claudeVersion, versionOk: versionOk,
        error: error)
}

private let good = ClaudeVersionCheck(version: "2.1.300", ok: true, minimum: "2.1.281")
private let tooOld = ClaudeVersionCheck(version: "2.1.200", ok: false, minimum: "2.1.281")
private let missing = ClaudeVersionCheck(version: nil, ok: false, minimum: "2.1.281")

private let oldStep =
    "Remove Bifrost's old hooks and statusLine wrapper from ~/.claude/settings.json. Your other "
    + "hooks stay, and Bifrost saves a backup first."
private let copyStep = "Copy the Live details plugin files to the folder ~/.bifrost/mod."
private let pluginStep =
    #"Add that folder as the plugin marketplace "bifrost-local", then install the plugin "#
    + #""bifrost-live" for your user with claude plugin."#

@Suite("the Live details notice and rules")
struct LiveNoticeTests {
    @Test func theTextsAreTheTextsOfTheElectronApp() {
        #expect(
            LiveTexts.reloadNote
                == "Sessions that run now get the change after /reload-plugins or a restart.")
        #expect(
            LiveTexts.withoutLive
                == "Without Live details, Bifrost still lists your sessions and shows their boxes "
                + "from the session list, a little later, but with no model, context % or cost. "
                + "You can turn it on later in Settings > Live details.")
        #expect(
            LiveTexts.setupIntro
                == "Live details lets Bifrost see each session as it happens: a box the moment "
                + "Claude finishes or needs you, plus the model, context % and cost. It's a small "
                + "Claude Code plugin that sends events to Bifrost on this Mac. Bifrost makes "
                + "these changes only if you turn it on:")
        #expect(
            LiveTexts.removeConfirm
                == ConfirmText(
                    title: "Remove Live details",
                    body: "Bifrost turns off Live details, removes the plugin and the folder "
                        + "~/.bifrost/mod, and removes any old Bifrost hooks (with a backup "
                        + "first).",
                    confirm: "Remove"))
        #expect(LiveTexts.installLead == "Install makes these changes:")
    }

    @Test func theButtonLabelsAreTheLabelsOfTheElectronApp() {
        let labels = LiveActionID.allCases.map(\.label)
        #expect(labels == ["Install", "Turn on", "Turn off", "Remove", "Try again"])
        #expect(LiveActionID.allCases.map(\.rawValue) == [
            "install", "enable", "disable", "remove", "retry",
        ])
        #expect(LiveActionID.remove.action == .uninstall)
        #expect(LiveActionID.install.action == .install)
        #expect(LiveActionID.retry.action == nil)
    }

    @Test func theNoticeGivesLoadingNotInstalledOffAndOn() {
        #expect(LiveNotice.of(nil) == .loading)
        #expect(LiveNotice.of(status(plugin: .notInstalled)) == .notInstalled)
        #expect(LiveNotice.of(status(plugin: .disabled, listening: false)) == .off)
        #expect(LiveNotice.of(status(liveSessions: 2)) == .on(sessions: 2))
    }

    // Only the notice on counts as on: a notice that loads, is off or has a problem does not.
    @Test func onlyTheNoticeOnIsOn() {
        #expect(LiveNotice.on(sessions: 0).isOn)
        let others: [LiveNotice] = [.loading, .notInstalled, .off, .problem("x")]
        #expect(others.allSatisfy { !$0.isOn })
    }

    @Test func theNoticeGivesAProblemForUnknownNoListenerAndOtherFiles() {
        let failed = status(plugin: .unknown, error: "claude plugin list failed: x")
        #expect(LiveNotice.of(failed) == .problem("claude plugin list failed: x"))
        #expect(
            LiveNotice.of(status(plugin: .unknown))
                == .problem("Bifrost couldn't check Live details."))
        let other = "Another program listens on /h/.bifrost/live.sock."
        #expect(LiveNotice.of(status(listening: false, error: other)) == .problem(other))
        #expect(
            LiveNotice.of(status(listening: false))
                == .problem(
                    "Live details is on, but Bifrost isn't receiving it. Try Turn off, then Turn "
                        + "on."))
        // The text of the files comes first, also when the status has an error.
        #expect(
            LiveNotice.of(status(modCurrent: false, error: "x"))
                == .problem(
                    "Live details uses files that don't match this Bifrost. Remove it, then "
                        + "install it again."))
    }

    @Test func anUnknownStatusGivesItsReasonAndTryAgain() {
        let failed = LiveRules.unknownStatus("Bifrost cannot read the status.")
        #expect(LiveNotice.of(failed) == .problem("Bifrost cannot read the status."))
        #expect(LiveRules.actions(failed) == [.retry])
        #expect(LiveRules.liveVersionNote(failed) == nil)
        #expect(LiveRules.oldInstallNote(failed) == nil)
        #expect(!failed.listening && !failed.modCurrent && !failed.versionOk)
        #expect(failed.claudeVersion == nil && failed.liveSessions == 0)
    }

    @Test func theOldInstallNoteShowsOnlyForAnOldHookInstall() {
        #expect(
            LiveRules.oldInstallNote(status(oldInstall: true))
                == "Bifrost found its old hooks in ~/.claude/settings.json. Install or Turn on "
                + "removes them first and saves a backup.")
        #expect(LiveRules.oldInstallNote(status(oldInstall: false)) == nil)
        #expect(LiveRules.oldInstallNote(nil) == nil)
    }

    @Test func theStepsListTheOldHookRemovalOnlyForAnOldInstall() {
        let old = status(plugin: .notInstalled, oldInstall: true)
        #expect(LiveRules.steps(old) == [oldStep, copyStep, pluginStep])
        let clean = status(plugin: .notInstalled, oldInstall: false)
        #expect(LiveRules.steps(clean) == [copyStep, pluginStep])
    }

    @Test func theVersionNoticeGivesTheTwoWarnings() {
        #expect(ClaudeVersionCheck.appMinimum == "2.1.281")
        #expect(
            LiveRules.versionNotice(tooOld)
                == "Claude Code 2.1.200 is older than 2.1.281, which Bifrost needs. Please "
                + "update Claude Code.")
        #expect(
            LiveRules.versionNotice(missing)
                == "Bifrost can't find Claude Code. Check that the claude command works in a "
                + "terminal.")
        #expect(LiveRules.versionNotice(good) == nil)
        // The version is not read yet.
        #expect(LiveRules.versionNotice(nil) == nil)
    }

    @Test func aFailedVersionCheckGivesItsOwnNoticeAndAWarning() {
        #expect(LiveTexts.versionCheckFailed == "Bifrost couldn't check the Claude Code version.")
        #expect(LiveRules.claudeVersionNotice(nil, failed: true) == LiveTexts.versionCheckFailed)
        #expect(LiveRules.claudeVersionNotice(nil, failed: false) == nil)
        #expect(LiveRules.claudeVersionNotice(good, failed: false) == nil)
        #expect(
            LiveRules.claudeVersionNotice(tooOld, failed: false) == LiveRules.versionNotice(tooOld))
        #expect(LiveRules.hasWarning(status(), nil, versionFailed: true))
        #expect(!LiveRules.hasWarning(status(), nil, versionFailed: false))
    }

    @Test func theClaudeLineGivesTheVersionACheckLineOrNothing() {
        #expect(LiveRules.claudeVersionLine(good, failed: false) == "Claude Code 2.1.300")
        #expect(LiveRules.claudeVersionLine(nil, failed: false) == "Checking Claude Code...")
        // A failed check does not say "Checking" for ever: the notice gives the reason.
        #expect(LiveRules.claudeVersionLine(nil, failed: true) == nil)
        // With no version, the version notice says that Bifrost can't find Claude Code.
        #expect(LiveRules.claudeVersionLine(missing, failed: false) == nil)
    }

    @Test func theLiveVersionNoteShowsForAClaudeCodeThatIsTooOld() {
        #expect(LiveTexts.liveVersionNote == "Live details needs Claude Code 2.1.290 or later.")
        let old = status(claudeVersion: "2.1.285", versionOk: false)
        #expect(LiveRules.liveVersionNote(old) == LiveTexts.liveVersionNote)
        #expect(LiveRules.liveVersionNote(status(claudeVersion: "2.1.290")) == nil)
        // With no version, the version notice already says that Bifrost can't find Claude Code.
        #expect(LiveRules.liveVersionNote(status(claudeVersion: nil, versionOk: false)) == nil)
        #expect(LiveRules.liveVersionNote(nil) == nil)
    }

    @Test func theWarningIsOnForAProblemAnOldInstallAVersionNoticeOrAnOldVersion() {
        func warns(_ status: LiveStatus?, _ version: ClaudeVersionCheck?) -> Bool {
            LiveRules.hasWarning(status, version, versionFailed: false)
        }
        #expect(!warns(nil, nil))
        #expect(!warns(nil, good))
        #expect(!warns(status(), good))
        #expect(!warns(status(plugin: .notInstalled), good))
        #expect(!warns(status(plugin: .disabled), good))
        #expect(warns(status(plugin: .unknown), good))
        #expect(warns(status(listening: false), good))
        #expect(warns(status(modCurrent: false), good))
        #expect(warns(status(plugin: .notInstalled, oldInstall: true), good))
        #expect(warns(nil, tooOld))
        #expect(warns(nil, missing))
        // A version that is too old for Live details warns only while the plugin is installed:
        // after Skip, Live details off is the choice of the user.
        #expect(warns(status(plugin: .enabled, claudeVersion: "2.1.285", versionOk: false), good))
        #expect(
            warns(
                status(
                    plugin: .disabled, listening: false, claudeVersion: "2.1.285",
                    versionOk: false), good))
        #expect(
            !warns(status(plugin: .notInstalled, claudeVersion: "2.1.285", versionOk: false), good))
    }

    @Test func theStateLineOfEachNotice() {
        #expect(LiveNotice.loading.stateLine == "Checking Live details...")
        #expect(LiveNotice.notInstalled.stateLine == "Not installed.")
        #expect(LiveNotice.off.stateLine == "Off.")
        #expect(LiveNotice.on(sessions: 0).stateLine == "On. 0 sessions are sending live details.")
        #expect(LiveNotice.on(sessions: 1).stateLine == "On. 1 session is sending live details.")
        #expect(LiveNotice.on(sessions: 3).stateLine == "On. 3 sessions are sending live details.")
        #expect(LiveNotice.problem("m").stateLine == "m")
    }

    @Test func theButtonsOfEachState() {
        #expect(LiveRules.actions(nil) == [])
        #expect(LiveRules.actions(status(plugin: .notInstalled)) == [.install])
        let off = status(plugin: .disabled, listening: false)
        #expect(LiveRules.actions(off) == [.enable, .remove])
        #expect(LiveRules.actions(status()) == [.disable, .remove])
        #expect(LiveRules.actions(status(plugin: .unknown)) == [.retry])
        #expect(LiveRules.actions(status(listening: false)) == [.disable, .enable, .remove])
        #expect(LiveRules.actions(status(modCurrent: false)) == [.disable, .enable, .remove])
    }

    @Test func theSetupShowsOnlyBeforeTheChoiceForNotInstalledAndUnknown() {
        #expect(LiveRules.shouldShowSetup(setupDone: false, status(plugin: .notInstalled)))
        #expect(LiveRules.shouldShowSetup(setupDone: false, status(plugin: .unknown)))
        #expect(!LiveRules.shouldShowSetup(setupDone: false, status(plugin: .enabled)))
        #expect(!LiveRules.shouldShowSetup(setupDone: false, status(plugin: .disabled)))
        #expect(!LiveRules.shouldShowSetup(setupDone: false, nil))
        #expect(!LiveRules.shouldShowSetup(setupDone: true, status(plugin: .notInstalled)))
        #expect(!LiveRules.shouldShowSetup(setupDone: true, status(plugin: .unknown)))
    }

    @Test func anInstalledPluginIsAChoice() {
        #expect(LiveRules.setupChosen(status(plugin: .enabled)))
        #expect(LiveRules.setupChosen(status(plugin: .disabled)))
        #expect(!LiveRules.setupChosen(status(plugin: .notInstalled)))
        #expect(!LiveRules.setupChosen(status(plugin: .unknown)))
        #expect(!LiveRules.setupChosen(nil))
    }

    // MARK: - The introduction again

    @Test func theIntroTextStartsWithTheTextAboutLiveDetails() {
        #expect(
            LiveTexts.about
                == "Live details lets Bifrost see each session as it happens: a box the moment "
                + "Claude finishes or needs you, plus the model, context % and cost. It's a small "
                + "Claude Code plugin that sends events to Bifrost on this Mac.")
        #expect(LiveTexts.setupIntro.hasPrefix(LiveTexts.about + " "))
        #expect(LiveTexts.introChangeNote == "You can change this in Settings > Live details.")
    }

    @Test func atTheFirstStartTheDialogKeepsItsChoice() {
        #expect(LiveRules.setupView(.first, .ask, status(plugin: .notInstalled)) == .ask)
        #expect(LiveRules.setupView(.first, .ask, status(plugin: .enabled)) == .ask)
        #expect(LiveRules.setupView(.first, .done, status()) == .done)
        #expect(LiveRules.setupView(.first, .skills, status()) == .skills)
        #expect(LiveRules.setupView(.again, .skills, status(plugin: .enabled)) == .skills)
    }

    @Test func againAnInstalledPluginGivesItsStateAndDone() {
        #expect(LiveRules.setupView(.again, .ask, status(plugin: .enabled)) == .installed)
        let off = status(plugin: .disabled, listening: false)
        #expect(LiveRules.setupView(.again, .ask, off) == .installed)
        #expect(LiveRules.setupView(.again, .ask, status(plugin: .notInstalled)) == .ask)
        #expect(LiveRules.setupView(.again, .ask, status(plugin: .unknown)) == .ask)
        #expect(LiveRules.setupView(.again, .ask, nil) == .ask)
        #expect(LiveRules.setupView(.again, .done, status()) == .done)
    }

    @Test func skipSavesTheChoiceOnlyAtTheFirstStart() {
        #expect(LiveRules.skipSavesChoice(.first))
        #expect(!LiveRules.skipSavesChoice(.again))
    }

    @Test func theIntroStateLineNamesLiveDetailsExceptInAProblem() {
        #expect(
            LiveRules.introStateLine(.on(sessions: 2))
                == "Live details: On. 2 sessions are sending live details.")
        #expect(LiveRules.introStateLine(.off) == "Live details: Off.")
        #expect(LiveRules.introStateLine(.problem("m")) == "m")
    }
}
