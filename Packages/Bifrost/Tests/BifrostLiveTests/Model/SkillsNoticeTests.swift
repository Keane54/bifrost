import BifrostSessions
import Testing

@testable import BifrostLive

// The texts and the rules of Settings > Skills and of the skills step of the Setup dialog
// (docs/behaviour/skills.md, "Settings > Skills").

// A status of a skills plugin that is on and reads the folder of the app.
private func status(
    plugin: LivePluginState = .enabled, folderCurrent: Bool = true, error: String? = nil
) -> SkillsStatus {
    SkillsStatus(plugin: plugin, folderCurrent: folderCurrent, skills: [], error: error)
}

@Suite("the skills notice and rules")
struct SkillsNoticeTests {
    @Test func theTextsAreTheTextsOfTheElectronApp() {
        #expect(
            SkillsNotice.about
                == "Bifrost skills give Claude tested steps for common jobs: review a PR, resolve "
                + "PR comments, humanise text, grill a plan and hand over a session. Start one by "
                + "typing its name in a chat, for example /bifrost-review. They're a small Claude "
                + "Code plugin that Bifrost keeps up to date.")
        #expect(
            SkillsNotice.setupIntro
                == SkillsNotice.about + " Bifrost makes these changes only if you install them:")
        #expect(
            SkillsNotice.steps == [
                "Copy the skills plugin files to the folder ~/.bifrost/skills.",
                #"Add that folder as the plugin marketplace "bifrost-skills", then install the "#
                    + #"plugin "bifrost" for your user with claude plugin."#,
            ])
        #expect(
            SkillsNotice.withoutSkills
                == "You can install the skills later in Settings > Skills. The Hand over button "
                + "works without them.")
        #expect(
            SkillsNotice.removeConfirm
                == ConfirmText(
                    title: "Remove skills",
                    body: #"Bifrost turns off its skills, removes the plugin "bifrost" and the "#
                        + #"marketplace "bifrost-skills", and deletes the folder "#
                        + "~/.bifrost/skills.",
                    confirm: "Remove"))
        #expect(SkillsNotice.groupLabel(.calledByName) == "Called by name")
        #expect(SkillsNotice.groupLabel(.listed) == "Listed")
        #expect(
            SkillsNotice.groupHint
                == "Listed skills are in Claude's skill list, so Claude can start them by itself. "
                + "Skills called by name cost no context until you type their name.")
    }

    @Test func eachKindHasItsExactLine() {
        #expect(SkillsNotice.of(nil) == .loading)
        #expect(SkillsNotice.loading.stateLine == "Checking the skills...")
        #expect(SkillsNotice.of(status(plugin: .notInstalled)) == .notInstalled)
        #expect(SkillsNotice.notInstalled.stateLine == "Not installed.")
        #expect(SkillsNotice.of(status(plugin: .disabled)) == .off)
        #expect(SkillsNotice.off.stateLine == "Off.")
        #expect(SkillsNotice.of(status()) == .on)
        #expect(SkillsNotice.on.stateLine == "On.")
    }

    @Test func anUnknownStateIsAProblemWithTheErrorOrADefault() {
        #expect(
            SkillsNotice.of(status(plugin: .unknown, error: "claude failed"))
                == .problem("claude failed"))
        #expect(
            SkillsNotice.of(status(plugin: .unknown))
                == .problem("Bifrost couldn't check the skills."))
        #expect(SkillsNotice.problem("x").stateLine == "x")
    }

    @Test func filesThatDoNotMatchAreAProblem() {
        #expect(
            SkillsNotice.of(status(folderCurrent: false))
                == .problem(
                    "The skills use files that don't match this Bifrost. Turn them off, then on "
                        + "again."))
    }

    // A problem text of the control, for example a marketplace of another program, comes before
    // the text of the files.
    @Test func aForeignMarketplaceShowsItsTextNotTheFilesText() {
        let error = "A marketplace with the name bifrost-skills already exists at /other."
        #expect(SkillsNotice.of(status(folderCurrent: false, error: error)) == .problem(error))
    }

    @Test func theDoneLineNamesTheSkillsExceptInAProblem() {
        #expect(SkillsNotice.on.doneLine == "Skills: On.")
        #expect(SkillsNotice.problem("bad").doneLine == "bad")
    }

    @Test func theButtonsFollowTheTableOfLiveDetails() {
        #expect(SkillsNotice.actions(nil) == [])
        #expect(SkillsNotice.actions(status(plugin: .unknown)) == [.retry])
        #expect(SkillsNotice.actions(status(plugin: .notInstalled)) == [.install])
        #expect(SkillsNotice.actions(status(plugin: .disabled)) == [.enable, .remove])
        #expect(SkillsNotice.actions(status()) == [.disable, .remove])
        #expect(SkillsNotice.actions(status(folderCurrent: false)) == [.disable, .enable, .remove])
    }

    @Test func theSkillsStepIsNeededOnlyWhenThePluginIsNotInstalled() {
        #expect(SkillsNotice.stepNeeded(status(plugin: .notInstalled)))
        for plugin in [LivePluginState.enabled, .disabled, .unknown] {
            #expect(!SkillsNotice.stepNeeded(status(plugin: plugin)), "\(plugin)")
        }
        #expect(!SkillsNotice.stepNeeded(nil))
    }

    @Test func fromLiveTheSetupGoesToTheSkillsStepWhenTheSkillsAreNotInstalled() {
        let missing = status(plugin: .notInstalled)
        #expect(
            SkillsNotice.nextSetupPhase(from: .live, missing, installed: (false, false)) == .skills)
        #expect(
            SkillsNotice.nextSetupPhase(from: .live, missing, installed: (true, false)) == .skills)
    }

    @Test func fromLiveTheSetupGoesToDoneAfterAnInstallElseItCloses() {
        #expect(
            SkillsNotice.nextSetupPhase(from: .live, status(), installed: (true, false)) == .done)
        #expect(
            SkillsNotice.nextSetupPhase(from: .live, status(), installed: (false, false))
                == .close)
        let unknown = status(plugin: .unknown)
        #expect(
            SkillsNotice.nextSetupPhase(from: .live, unknown, installed: (false, false)) == .close)
        #expect(SkillsNotice.nextSetupPhase(from: .live, nil, installed: (false, false)) == .close)
    }

    @Test func fromSkillsTheSetupGoesToDoneAfterAnInstallElseItCloses() {
        let missing = status(plugin: .notInstalled)
        #expect(
            SkillsNotice.nextSetupPhase(from: .skills, missing, installed: (false, false))
                == .close)
        #expect(
            SkillsNotice.nextSetupPhase(from: .skills, missing, installed: (true, false)) == .done)
        #expect(
            SkillsNotice.nextSetupPhase(from: .skills, status(), installed: (false, true)) == .done)
        #expect(
            SkillsNotice.nextSetupPhase(from: .skills, status(), installed: (true, true)) == .done)
    }
}
