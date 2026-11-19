import AppKit
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostLive
@testable import BifrostSettings

// Settings > Skills (docs/behaviour/skills.md, "Settings > Skills"): the state line and the
// buttons, the steps before Install, Remove with its confirm, the reload note after a change, the
// skills of the app with their group labels and the hint (also with no claude), the one status
// read for each open of Settings, the buttons that are off while Live details is busy, and the
// words of the search. The controls are the real controls in a test home, with plugin commands
// that run no program (LiveParts).

// The skills of the bundled skills folder of the repo, by name.
private let bundledSkills = [
    "bifrost-daily-update", "bifrost-grill", "bifrost-hand-over", "bifrost-humanise",
    "bifrost-resolve-comments", "bifrost-review",
]

@MainActor
@Suite("Settings > Skills", .serialized, .timeLimit(.minutes(1)), .tags(.window))
struct SkillsSectionTests {
    @Test func beforeTheControlsTheSectionChecks() async throws {
        let p = try await SettingsParts()
        let section = SkillsSection(model: p.model)
        #expect(section.content.stateLine == "Checking the skills...")
        #expect(section.content.buttons == [])
        #expect(section.skills == [])
        #expect(section.groupHint == nil)
    }

    // The skills of the app show with their group labels and the hint, also while the plugin is
    // not installed.
    @Test func theSkillsShowWithTheirGroupLabelsAndTheHint() async throws {
        let l = try LiveParts()
        defer { l.finish() }
        let p = try await SettingsParts(live: l.model)
        await l.attach()
        let section = SkillsSection(model: p.model)
        #expect(section.content.stateLine == "Not installed.")
        #expect(section.content.without == SkillsNotice.withoutSkills)
        #expect(section.content.buttons == [.install])
        #expect(section.skills.map(\.name) == bundledSkills)
        #expect(section.groupHint == SkillsNotice.groupHint)
        // Both groups are in the list of the app, each with its label.
        let groups = Set(section.skills.map(\.group))
        #expect(groups == [.listed, .calledByName])
        #expect(section.skills.allSatisfy { !$0.description.isEmpty })
    }

    // With no claude there is no control, but the section still lists the skills of the bundled
    // folder under "claude was not found.". A folder that Bifrost can't read adds its text.
    @Test func withNoClaudeTheSectionListsTheBundledSkills() async throws {
        let p = try await SettingsParts()
        let folder = try Repo.root().appending(path: "App/Bifrost/Resources/bifrost-skills")
        p.model.live.attach(nil, skillsFolder: folder)
        let section = SkillsSection(model: p.model)
        #expect(section.content.stateLine == "claude was not found.")
        await p.model.live.firstReads?.value
        #expect(section.content.stateLine == "claude was not found.")
        #expect(section.content.buttons == [.retry])
        #expect(section.skills.map(\.name) == bundledSkills)
        #expect(section.groupHint == SkillsNotice.groupHint)
        let other = try await SettingsParts()
        other.model.live.attach(
            nil, skillsFolder: URL(fileURLWithPath: "/nonexistent-bifrost-test/bifrost-skills"))
        await other.model.live.firstReads?.value
        let line = SkillsSection(model: other.model).content.stateLine
        #expect(line.hasPrefix("claude was not found. Bifrost couldn't read its skills. "))
        #expect(SkillsSection(model: other.model).skills == [])
    }

    // The view draws the list of the skills when the status has them.
    @Test func theViewDrawsTheListOfTheSkills() async throws {
        let l = try LiveParts()
        defer { l.finish() }
        let p = try await SettingsParts(live: l.model)
        let section = SkillsSection(model: p.model)
        let checking = fittingHeight(section)
        await l.attach()
        #expect(fittingHeight(section) > checking + 100)
    }

    // Install shows the steps first, then installs, and the reload note shows after the change.
    @Test func installShowsTheStepsThenTheReloadNote() async throws {
        let l = try LiveParts()
        defer { l.finish() }
        let p = try await SettingsParts(live: l.model)
        await l.attach()
        let section = SkillsSection(model: p.model)
        await section.press(.install).value
        #expect(section.content.steps == SkillsNotice.steps)
        #expect(section.content.buttons == [])
        section.cancelInstall()
        #expect(section.content.steps == nil)
        await section.press(.install).value
        await section.install().value
        #expect(l.skillsPlugins.writes.first?.hasPrefix("marketplace add ") == true)
        #expect(l.skillsPlugins.writes.contains("install bifrost@bifrost-skills"))
        #expect(section.content.stateLine == "On.")
        #expect(section.content.notes == [LiveTexts.reloadNote])
        #expect(section.content.buttons == [.disable, .remove])
    }

    @Test func removeAsksFirstWithTheRemoveText() async throws {
        let l = try LiveParts(skills: FakePlugins(.skills, installed: true, enabled: false))
        defer { l.finish() }
        let p = try await SettingsParts(live: l.model)
        await l.attach()
        let section = SkillsSection(model: p.model)
        #expect(section.content.buttons == [.enable, .remove])
        #expect(PluginBlock.isOff(p.model, .skills, .remove))
        let asked = Asked()
        p.model.links.confirm = { text in
            asked.texts.append(text)
            return asked.answer
        }
        await section.press(.remove).value
        #expect(asked.texts == [SkillsNotice.removeConfirm])
        #expect(l.skillsPlugins.writes == [])
        asked.answer = true
        await section.press(.remove).value
        #expect(l.skillsPlugins.writes == ["uninstall bifrost@bifrost-skills"])
        #expect(section.content.stateLine == "Not installed.")
    }

    // One plugin change runs at a time, so the Skills buttons are off while Live details is
    // busy.
    @Test func theButtonsAreOffWhileLiveDetailsIsBusy() async throws {
        let live = FakePlugins(.live, installed: true, enabled: false)
        let l = try LiveParts(live: live, skills: FakePlugins(.skills, installed: true))
        defer { l.finish() }
        let p = try await SettingsParts(live: l.model)
        await l.attach()
        live.hold(true)
        defer { live.hold(false) }
        let enable = LiveSection(model: p.model).press(.enable)
        #expect(await live.gate.waitUntilHolding(1))
        #expect(l.model.isBusy(.live))
        #expect(l.model.isBusy(.skills))
        #expect(PluginBlock.isOff(p.model, .skills, .enable))
        live.hold(false)
        await enable.value
        #expect(!l.model.isBusy(.skills))
        #expect(!PluginBlock.isOff(p.model, .skills, .enable))
    }

    @Test func theSkillsStatusReadsOncePerOpenOfSettings() async throws {
        let l = try LiveParts()
        defer { l.finish() }
        let p = try await SettingsParts(live: l.model)
        await l.attach()
        #expect(l.skillsPlugins.lists == 1)
        await l.model.readOnce(.skills)?.value
        #expect(l.skillsPlugins.lists == 2)
        #expect(l.model.readOnce(.skills) == nil)
        p.model.panelClosed()
        await l.model.readOnce(.skills)?.value
        #expect(l.skillsPlugins.lists == 3)
        // The read of Skills does not read Live details.
        #expect(l.livePlugins.lists == 1)
    }

    @Test func theSearchFindsTheSkillsByTheNameOfASkill() async throws {
        let l = try LiveParts()
        defer { l.finish() }
        let p = try await SettingsParts(live: l.model)
        await l.attach()
        #expect(
            l.model.words(.skills)
                == ["Skills", "plugin", "Not installed.", "Install"] + bundledSkills)
        p.model.query = "hand-over"
        #expect(p.model.hits?.map(\.id) == [.skills])
        p.model.query = "skills"
        #expect(p.model.hits?.first(where: { $0.id == .skills })?.whole == true)
    }
}
