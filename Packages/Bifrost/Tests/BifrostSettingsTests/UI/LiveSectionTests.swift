import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostLive
@testable import BifrostSettings
@testable import BifrostWindows

// Settings > Live details (docs/behaviour/live.md, "Settings > Live details"): the state line and
// the buttons of each status, the steps before Install, Remove with its confirm, the notes, the
// version line, the section with no claude, the one status read for each open of Settings, the
// words of the search, the new reads while a warning shows, and the warning dot of the side bar
// and of the tab. The controls are the real controls in a test home, with plugin commands that
// run no program (LiveParts).

private let scope = " --scope user --json"

@MainActor
@Suite("Settings > Live details", .serialized, .testTimeLimit, .tags(.window))
struct LiveSectionTests {
    // Before the shell gives the controls, the section says that it checks, with no button.
    @Test func beforeTheControlsTheSectionChecks() async throws {
        let p = try await SettingsParts()
        let section = LiveSection(model: p.model)
        #expect(section.content.stateLine == "Checking Live details...")
        #expect(section.content.buttons == [])
        #expect(section.claudeLine == "Checking Claude Code...")
        #expect(section.versionNotice == nil)
        #expect(!p.model.live.warning)
    }

    // With no claude there is no control (row C6 of docs/ports/live): the section says that
    // claude was not found, and Try again reads nothing.
    @Test func withNoClaudeTheSectionShowsClaudeNotFound() async throws {
        let p = try await SettingsParts()
        let live = p.model.live
        live.attach(nil)
        let section = LiveSection(model: p.model)
        #expect(section.content.stateLine == "claude was not found.")
        #expect(section.content.buttons == [.retry])
        #expect(section.claudeLine == nil)
        #expect(
            section.versionNotice
                == "Bifrost can't find Claude Code. Check that the claude command works in a "
                + "terminal.")
        #expect(live.warning)
        #expect(live.readOnce(.live) == nil)
        await section.press(.retry).value
        #expect(section.content.stateLine == "claude was not found.")
        #expect(section.content.error == nil)
        #expect(SkillsSection(model: p.model).content.stateLine == "claude was not found.")
    }

    @Test func aPluginThatIsNotInstalledOffersInstall() async throws {
        let l = try LiveParts()
        defer { l.finish() }
        let p = try await SettingsParts(live: l.model)
        await l.attach()
        let section = LiveSection(model: p.model)
        #expect(section.content.stateLine == "Not installed.")
        #expect(section.content.without == LiveTexts.withoutLive)
        #expect(section.content.buttons == [.install])
        #expect(section.content.notes == [])
        #expect(section.claudeLine == "Claude Code 2.1.300")
        #expect(section.versionNotice == nil)
        #expect(!l.model.warning)
    }

    // Install first shows the changes that it makes, with Install and Cancel. Cancel shows the
    // buttons again. Install then installs, and the reload note shows.
    @Test func installShowsTheStepsFirstThenInstalls() async throws {
        let l = try LiveParts()
        defer { l.finish() }
        let p = try await SettingsParts(live: l.model)
        await l.attach()
        let section = LiveSection(model: p.model)
        await section.press(.install).value
        #expect(
            section.content.steps == [
                "Copy the Live details plugin files to the folder ~/.bifrost/mod.",
                #"Add that folder as the plugin marketplace "bifrost-local", then install the "#
                    + #"plugin "bifrost-live" for your user with claude plugin."#,
            ])
        #expect(section.content.buttons == [])
        #expect(l.livePlugins.writes == [])
        section.cancelInstall()
        #expect(section.content.steps == nil)
        #expect(section.content.buttons == [.install])
        await section.press(.install).value
        await section.install().value
        #expect(
            l.livePlugins.writes == [
                "marketplace add \(l.modFolder)", "install bifrost-live@bifrost-local",
            ])
        #expect(section.content.stateLine == "On. 0 sessions are sending live details.")
        #expect(section.content.steps == nil)
        #expect(section.content.buttons == [.disable, .remove])
        #expect(section.content.notes == [LiveTexts.reloadNote])
        #expect(!l.model.warning)
        // The next action ends the reload note.
        await section.press(.disable).value
        #expect(section.content.stateLine == "Off.")
        #expect(section.content.notes == [])
    }

    // Remove asks first with the Remove text, and a cancel changes nothing. With no confirm
    // dialog, Remove is off.
    @Test func removeAsksFirstWithTheRemoveText() async throws {
        let l = try LiveParts(live: FakePlugins(.live, installed: true, enabled: false))
        defer { l.finish() }
        let p = try await SettingsParts(live: l.model)
        await l.attach()
        let section = LiveSection(model: p.model)
        #expect(section.content.buttons == [.enable, .remove])
        #expect(PluginBlock.isOff(p.model, .live, .remove))
        #expect(!PluginBlock.isOff(p.model, .live, .enable))
        let asked = Asked()
        p.model.links.confirm = { text in
            asked.texts.append(text)
            return asked.answer
        }
        #expect(!PluginBlock.isOff(p.model, .live, .remove))
        await section.press(.remove).value
        #expect(asked.texts == [LiveTexts.removeConfirm])
        #expect(l.livePlugins.writes == [])
        #expect(section.content.stateLine == "Off.")
        asked.answer = true
        await section.press(.remove).value
        #expect(asked.texts.count == 2)
        #expect(l.livePlugins.writes == ["uninstall bifrost-live@bifrost-local"])
        #expect(section.content.stateLine == "Not installed.")
        #expect(section.content.notes == [])
    }

    // A failed action reads the status again, then the section shows the text of the failure
    // until the user closes it.
    @Test func aFailedActionShowsItsTextUntilTheUserClosesIt() async throws {
        let plugins = FakePlugins(.live, installed: true, enabled: false)
        plugins.change { $0.failing = "enable" }
        let l = try LiveParts(live: plugins)
        defer { l.finish() }
        let p = try await SettingsParts(live: l.model)
        await l.attach()
        let section = LiveSection(model: p.model)
        let lists = plugins.lists
        await section.press(.enable).value
        #expect(section.content.error == "boom")
        #expect(plugins.lists > lists + 1)
        #expect(section.content.stateLine == "Off.")
        #expect(section.content.notes == [])
        l.model.closeError(.live)
        #expect(section.content.error == nil)
        // A section that goes away loses its error, as a new view of the section does.
        await section.press(.enable).value
        #expect(section.content.error == "boom")
        l.model.sectionHidden(.live)
        #expect(section.content.error == nil)
    }

    // The notes: a Claude Code that is too old for Live details, and the general version notice
    // under the Claude Code line.
    @Test func theNotesShowAnOldVersionAndTheVersionNotice() async throws {
        let l = try LiveParts(live: FakePlugins(.live, installed: true, enabled: false))
        defer { l.finish() }
        l.liveVersion = "2.1.285"
        l.version = ClaudeVersionCheck(version: "2.1.200", ok: false, minimum: "2.1.281")
        let p = try await SettingsParts(live: l.model)
        await l.attach()
        let section = LiveSection(model: p.model)
        #expect(section.content.notes == ["Live details needs Claude Code 2.1.290 or later."])
        #expect(section.claudeLine == "Claude Code 2.1.200")
        #expect(
            section.versionNotice
                == "Claude Code 2.1.200 is older than 2.1.281, which Bifrost needs. Please update "
                + "Claude Code.")
        #expect(l.model.warning)
    }

    // The section reads its status with the busy state one time for each open of Settings, also
    // when a search shows it at many queries. The next open reads again.
    @Test func theLiveStatusReadsOncePerOpenOfSettings() async throws {
        let l = try LiveParts()
        defer { l.finish() }
        let p = try await SettingsParts(live: l.model)
        await l.attach()
        #expect(l.livePlugins.lists == 1)
        let read = try #require(l.model.readOnce(.live))
        await read.value
        #expect(!l.model.liveState.busy)
        #expect(l.livePlugins.lists == 2)
        #expect(l.model.readOnce(.live) == nil)
        #expect(l.livePlugins.lists == 2)
        p.model.panelClosed()
        await l.model.readOnce(.live)?.value
        #expect(l.livePlugins.lists == 3)
    }

    // A section that shows before the controls come reads when they come, with one read in place
    // of the first read.
    @Test func aReadBeforeTheControlsWaitsForThem() async throws {
        let l = try LiveParts()
        defer { l.finish() }
        _ = try await SettingsParts(live: l.model)
        #expect(l.model.readOnce(.live) == nil)
        #expect(l.livePlugins.lists == 0)
        await l.attach()
        #expect(l.livePlugins.lists == 1)
        #expect(l.model.readOnce(.live) == nil)
        #expect(LiveNotice.of(l.model.status) == .notInstalled)
    }

    // In the panel, the section reads when it shows, and a search that shows it again does not
    // read again. The search for "plugin" also shows Skills for the first time in this open, so
    // its read tells that the views of the hits showed.
    @Test func theSectionReadsWhenItShowsInThePanel() async throws {
        let l = try LiveParts()
        defer { l.finish() }
        let s = try await ShownSettings(live: l.model)
        defer { s.close() }
        await l.attach()
        s.model.showTab(.live)
        #expect(await waitUntil { l.livePlugins.lists == 2 && !l.model.liveState.busy })
        s.model.query = "plugin"
        #expect(s.model.hits?.map(\.id) == [.live, .skills])
        #expect(await waitUntil { l.skillsPlugins.lists == 2 && !l.model.skillsState.busy })
        #expect(l.livePlugins.lists == 2)
        // A new open reads again.
        s.model.close()
        s.panels.releaseBody(for: .settings)
        #expect(l.model.readOnce(.live) != nil)
    }

    @Test func theSearchFindsLiveDetailsByItsButtons() async throws {
        let l = try LiveParts(live: FakePlugins(.live, installed: true, enabled: false))
        defer { l.finish() }
        let p = try await SettingsParts(live: l.model)
        await l.attach()
        #expect(
            l.model.words(.live) == [
                "Live details", "plugin", "Off.", "Turn on", "Remove", "Claude Code 2.1.300",
            ])
        p.model.query = "turn on"
        #expect(p.model.hits?.map(\.id) == [.live])
        #expect(p.model.hits?.first?.rows == ["live"])
        p.model.query = "2.1.300"
        #expect(p.model.hits?.map(\.id) == [.live])
        p.model.query = "sending"
        #expect(p.model.hits == [])
        // The words follow the status.
        await LiveSection(model: p.model).press(.enable).value
        p.model.query = "sending"
        #expect(p.model.hits?.map(\.id) == [.live])
        #expect(p.model.content == .hits(p.model.hits ?? []))
    }

    // While a warning shows, the model reads the status again on the back-off, so a short
    // failure of the first read does not keep the dot.
    @Test func aWarningReadsTheStatusAgainOnTheBackOff() async throws {
        let plugins = FakePlugins(.live)
        plugins.change { $0.listFails = true }
        let l = try LiveParts(live: plugins)
        defer { l.finish() }
        await l.attach()
        #expect(l.model.warning)
        plugins.change { $0.listFails = false }
        await l.clock.waitForSleepers(1)
        l.clock.advance(by: .seconds(60))
        #expect(await waitUntil { !l.model.warning })
        #expect(plugins.lists == 2)
        #expect(LiveNotice.of(l.model.status) == .notInstalled)
    }

    // The Settings button of the side bar and the Live details tab show the dot, with its
    // tooltip, while there is a warning.
    @Test func theDotShowsWhileThereIsAWarning() async throws {
        let plugins = FakePlugins(.live)
        plugins.change { $0.listFails = true }
        let l = try LiveParts(live: plugins)
        defer { l.finish() }
        let p = try await SettingsParts(live: l.model)
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = await UIStateStore.open(
            file: folder.url.appending(path: "ui-state.json"), clock: ManualClock(),
            log: Recorder<StoreEvent>())
        let live = l.model
        let sideBar = SideBarModel(
            layout: p.layout, store: store,
            dot: { panel in
                panel == .settings && live.warning
                    ? SideBarDot(text: SideBarView.settingsAttention) : nil
            })
        let view = SideBarView(model: sideBar, bodies: NoBodies())
        #expect(view.settingsButton.dot == nil)
        #expect(view.settingsButton.tip == "Settings")
        await l.attach()
        #expect(SideBarView.settingsAttention == "Settings - something needs your attention")
        #expect(view.settingsButton.dot == SideBarView.settingsAttention)
        #expect(view.settingsButton.tip == SideBarView.settingsAttention)
        #expect(view.settingsButton.label == "Settings")
        #expect(SettingsPanel.showsDot(.live, p.model))
        #expect(!SettingsPanel.showsDot(.skills, p.model))
        // Try again reads a good status, and the dot goes.
        plugins.change { $0.listFails = false }
        await LiveSection(model: p.model).press(.retry).value
        #expect(view.settingsButton.dot == nil)
        #expect(view.settingsButton.tip == "Settings")
        #expect(!SettingsPanel.showsDot(.live, p.model))
    }

    // The view draws what the model gives: the steps of Install make the section taller, and
    // Cancel takes them away.
    @Test func theViewDrawsTheStepsOfInstall() async throws {
        let l = try LiveParts()
        defer { l.finish() }
        let p = try await SettingsParts(live: l.model)
        await l.attach()
        let section = LiveSection(model: p.model)
        let buttons = fittingHeight(section)
        await section.press(.install).value
        let steps = fittingHeight(section)
        #expect(steps > buttons)
        section.cancelInstall()
        #expect(fittingHeight(section) == buttons)
    }
}

// The confirm texts that a test saw, and the answer that it gives.
@MainActor
final class Asked {
    var texts: [ConfirmText] = []
    var answer = false
}
