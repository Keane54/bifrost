import AppKit
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostSessions
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostLive
@testable import BifrostSettings
@testable import BifrostWindows

// The Setup dialog (docs/behaviour/live.md, "The Setup dialog"): the open at a first start with
// no plugin, the steps of Live details and of the skills, Skip, the introduction again from
// Settings > General, the reason of a failed step, and Esc and a click outside that do nothing.
// The controls are the real controls in a test home, with plugin commands that run no program
// (LiveParts), and the dialog shows in a real dialog layer (DialogHost).
//
// A test that checks that the dialog did not open by itself asks for the introduction after the
// first reads. The dialog follows the state in order, so a dialog of the first start would show
// before that request, and the dialog that opens would be the first-start dialog.

@MainActor
@Suite("the Setup dialog", .serialized, .testTimeLimit, .tags(.window))
struct SetupDialogTests {
    @Test func theDialogOpensAtTheFirstStartWithNoPlugin() async throws {
        let s = try await SetupParts()
        defer { s.finish() }
        // Before the first reads there is no status, so nothing opens.
        #expect(!s.host.isOpen)
        await s.live.attach()
        let model = try await s.shown()
        #expect(model.mode == .first)
        #expect(model.view == .ask)
        // The ask view lists each change before Bifrost makes it.
        let content = model.content
        #expect(content.intro == LiveTexts.setupIntro)
        #expect(
            content.intro.hasSuffix(" Bifrost makes these changes only if you turn it on:"))
        #expect(
            content.steps == [
                "Copy the Live details plugin files to the folder ~/.bifrost/mod.",
                #"Add that folder as the plugin marketplace "bifrost-local", then install the "#
                    + #"plugin "bifrost-live" for your user with claude plugin."#,
            ])
        #expect(content.lines == [])
        #expect(content.problem == nil)
        #expect(content.note == LiveTexts.withoutLive)
        #expect(content.error == nil)
        #expect(content.buttons == [.skip, .turnOn])
        #expect(content.buttons.map(\.label) == ["Skip", "Turn on Live details"])
        #expect(SetupDialogModel.title == "Set up Bifrost")
        #expect(!model.isOff(.turnOn))
        #expect(s.live.livePlugins.writes == [])
        #expect(!s.settings.store.settings.setupDone)
    }

    // The dialog opens by itself only at a first start with no saved choice, and with a test
    // home only when the test asks for it.
    @Test func theDialogOpensByItselfOnlyWhenTheStartAllowsIt() async throws {
        #expect(SetupDialog.opensAtStart(testHome: false, environment: [:]))
        #expect(!SetupDialog.opensAtStart(testHome: true, environment: [:]))
        #expect(!SetupDialog.opensAtStart(testHome: true, environment: ["BIFROST_TEST_SETUP": "0"]))
        #expect(SetupDialog.opensAtStart(testHome: true, environment: ["BIFROST_TEST_SETUP": "1"]))
        for (atStart, setupDone) in [(false, false), (true, true)] {
            let s = try await SetupParts(atStart: atStart)
            defer { s.finish() }
            if setupDone { try await s.settings.store.edit { $0.setupDone = true } }
            await s.live.attach()
            s.settings.model.showIntroduction()
            #expect(try await s.shown().mode == .again)
        }
    }

    // Turn on installs Live details and saves the choice. The skills step comes next, because
    // the skills are not installed, and Install skills installs them. The done view then shows
    // both states and the reload note, and Done closes the dialog.
    @Test func turnOnInstallsThenOffersTheSkills() async throws {
        let s = try await SetupParts()
        defer { s.finish() }
        await s.live.attach()
        let model = try await s.shown()
        await model.press(.turnOn)
        #expect(
            s.live.livePlugins.writes == [
                "marketplace add \(s.live.modFolder)", "install bifrost-live@bifrost-local",
            ])
        await model.saving?.value
        #expect(s.settings.store.settings.setupDone)
        #expect(model.installed == SetupInstalled(live: true, skills: false))
        #expect(model.view == .skills)
        let skills = model.content
        #expect(skills.intro == SkillsNotice.setupIntro)
        #expect(
            skills.intro.hasSuffix(" Bifrost makes these changes only if you install them:"))
        #expect(skills.steps == SkillsNotice.steps)
        #expect(skills.note == SkillsNotice.withoutSkills)
        #expect(skills.buttons == [.skipSkills, .installSkills])
        #expect(skills.buttons.map(\.label) == ["Skip", "Install skills"])
        #expect(s.live.skillsPlugins.writes == [])
        // The Live details section shows the same state and the reload note.
        #expect(LiveSection(model: s.settings.model).content.notes == [LiveTexts.reloadNote])
        await model.press(.installSkills)
        #expect(
            s.live.skillsPlugins.writes == [
                "marketplace add \(s.live.folder.appending(".bifrost/skills"))",
                "install bifrost@bifrost-skills",
            ])
        #expect(model.view == .done)
        let done = model.content
        #expect(done.intro == "Live details: On. 0 sessions are sending live details.")
        #expect(done.lines == ["Skills: On.", LiveTexts.reloadNote])
        #expect(done.buttons == [.done])
        await model.press(.done)
        #expect(model.isClosed)
        #expect(!s.host.isOpen)
        // The dialog does not open again by itself.
        s.settings.model.showIntroduction()
        #expect(try await s.shown().mode == .again)
    }

    // At the first start, Skip saves the choice, so the dialog does not show at the next start.
    // When the dialog opens again, Skip only closes it and saves nothing.
    @Test func skipSavesTheChoiceOnlyAtTheFirstStart() async throws {
        let s = try await SetupParts()
        defer { s.finish() }
        await s.live.attach()
        let first = try await s.shown()
        await first.press(.skip)
        await first.saving?.value
        #expect(s.settings.store.settings.setupDone)
        // The skills are not installed, so their step comes next. Its Skip with nothing
        // installed closes the dialog.
        #expect(first.view == .skills)
        await first.press(.skipSkills)
        #expect(first.isClosed)
        #expect(!s.host.isOpen)
        #expect(s.live.livePlugins.writes == [])
        #expect(s.live.skillsPlugins.writes == [])

        try await s.settings.store.edit { $0.setupDone = false }
        s.settings.model.showIntroduction()
        let again = try await s.shown()
        #expect(again.mode == .again)
        #expect(again.view == .ask)
        await again.press(.skip)
        await again.press(.skipSkills)
        #expect(again.isClosed)
        #expect(again.saving == nil)
        await s.settings.store.waitForWrites()
        #expect(!s.settings.store.settings.setupDone)
    }

    // An installed plugin, on or off, is already a choice: the start saves it with no dialog.
    // Show introduction in Settings > General opens the dialog again with the state of the
    // plugin and Done.
    @Test func showIntroductionOpensItAgainWithTheState() async throws {
        let s = try await SetupParts(
            live: FakePlugins(.live, installed: true, enabled: false),
            skills: FakePlugins(.skills, installed: true, enabled: true))
        defer { s.finish() }
        await s.live.attach()
        await waitUntil { s.settings.store.settings.setupDone }
        // The Introduction row of General asks for the introduction.
        #expect(GeneralSection.rows.last == .introduction)
        s.settings.model.showIntroduction()
        let model = try await s.shown()
        #expect(model.mode == .again)
        #expect(model.view == .installed)
        let content = model.content
        #expect(content.intro == LiveTexts.about)
        #expect(content.steps == [])
        #expect(content.lines == ["Live details: Off."])
        #expect(content.note == "You can change this in Settings > Live details.")
        #expect(content.buttons == [.done])
        // The skills are installed, so Done closes the dialog.
        await model.press(.done)
        #expect(model.isClosed)
        #expect(!s.host.isOpen)
        #expect(s.live.livePlugins.writes == [])
        // A second request opens a new dialog.
        s.settings.model.showIntroduction()
        #expect(try await s.shown() !== model)
    }

    // Esc and a click on the backdrop do nothing: only Skip and Done close the dialog. The
    // dialog layer has the focus while it shows.
    @Test func escAndAClickOutsideDoNothing() async throws {
        let s = try await SetupParts()
        defer { s.finish() }
        UITestApp.prepare()
        let window = KeyTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = content
        let other = FocusView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        content.addSubview(other)
        s.host.view.frame = content.bounds
        content.addSubview(s.host.view)
        #expect(window.makeFirstResponder(other))
        await s.live.attach()
        let model = try await s.shown()
        #expect(window.firstResponder === s.host.view)
        let esc = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(esc)
        s.host.view.cancelOperation(nil)
        s.host.escape()
        s.host.backdropClick()
        #expect(s.host.isOpen)
        #expect(!model.isClosed)
        #expect(model.view == .ask)
        // Skip, then Skip of the skills step, closes it, and the focus goes back.
        await model.press(.skip)
        await model.press(.skipSkills)
        #expect(!s.host.isOpen)
        #expect(window.firstResponder === other)
    }

    // A failed step shows its reason in the dialog, not in the section, and keeps its buttons,
    // so the user can try again or skip. A status that Bifrost cannot read shows its problem
    // with Try again.
    @Test func anErrorShowsInTheDialog() async throws {
        let plugins = FakePlugins(.live)
        plugins.change {
            $0.listFails = true
            $0.failing = "install"
        }
        let skills = FakePlugins(.skills)
        skills.change { $0.failing = "install" }
        let s = try await SetupParts(live: plugins, skills: skills)
        defer { s.finish() }
        await s.live.attach()
        let model = try await s.shown()
        #expect(model.view == .ask)
        let problem = try #require(model.content.problem)
        #expect(problem.contains("the list failed"))
        #expect(model.content.steps == LiveRules.steps(try #require(s.live.model.status)))
        plugins.change { $0.listFails = false }
        await model.press(.retry)
        #expect(model.content.problem == nil)
        #expect(s.live.model.notice == .notInstalled)
        // The box draws the reason under the note.
        let style = PanelStyle(look: PanelLook())
        let box = { fittingHeight(SetupDialogView(model: model, style: style)) }
        let plain = box()

        await model.press(.turnOn)
        #expect(model.content.error == "boom")
        #expect(box() > plain)
        #expect(model.view == .ask)
        #expect(model.content.buttons == [.skip, .turnOn])
        #expect(model.installed == SetupInstalled())
        #expect(model.saving == nil)
        #expect(LiveSection(model: s.settings.model).content.error == nil)
        // A second try works, and the reason goes.
        plugins.change { $0.failing = nil }
        await model.press(.turnOn)
        #expect(model.content.error == nil)
        #expect(model.view == .skills)

        await model.press(.installSkills)
        #expect(model.content.error == "boom")
        #expect(model.view == .skills)
        #expect(SkillsSection(model: s.settings.model).content.error == nil)
        // Skip of the skills step goes on: Live details is installed, so the done view shows.
        await model.press(.skipSkills)
        #expect(model.view == .done)
        #expect(model.content.error == nil)
        #expect(
            model.content.intro == "Live details: On. 0 sessions are sending live details.")
        #expect(model.content.lines == [LiveTexts.reloadNote])
    }

    // At the first start, a dialog that shows keeps the Setup dialog back until it closes.
    @Test func theFirstStartDialogWaitsForAnotherDialog() async throws {
        let s = try await SetupParts()
        defer { s.finish() }
        let confirm = ConfirmText(title: "Stop session", body: "b", confirm: "Stop")
        let host = s.host
        let asked = Task { await host.confirm(confirm, openFolder: nil, onBusy: {}) }
        await waitUntil { host.isOpen }
        await s.live.attach()
        // The Setup dialog is due and saw the other dialog.
        await waitUntil { s.setup.waitsForDialog }
        guard case .confirm(let other) = host.dialog else {
            Issue.record("The confirmation does not show.")
            return
        }
        other.cancel()
        #expect(await asked.value == false)
        #expect(try await s.shown().mode == .first)
        #expect(!s.setup.waitsForDialog)
    }

    // A press of a button that is off, or of a button of an earlier view, does nothing. While
    // Turn on runs, Skip and Turn on are off. A late press after the step finds the skills view
    // and changes nothing. Done of the installed view, pressed two times, shows the skills step
    // and does not close the dialog.
    @Test func aBusyOrLatePressDoesNothing() async throws {
        let s = try await SetupParts()
        defer { s.finish() }
        await s.live.attach()
        let model = try await s.shown()
        let plugins = s.live.livePlugins
        plugins.hold(true)
        let first = Task { await model.press(.turnOn) }
        #expect(await plugins.gate.waitUntilHolding())
        #expect(model.isOff(.turnOn))
        #expect(model.isOff(.skip))
        await model.press(.skip)
        await model.press(.turnOn)
        #expect(plugins.writes == [])
        #expect(model.view == .ask)
        #expect(model.saving == nil)
        plugins.hold(false)
        await first.value
        #expect(model.view == .skills)
        let writes = plugins.writes
        #expect(writes.count == 2)
        await model.press(.turnOn)
        await model.press(.skip)
        #expect(model.view == .skills)
        #expect(plugins.writes == writes)
        #expect(!model.isClosed)

        // The again dialog with Live details installed and the skills not installed.
        await model.press(.skipSkills)
        #expect(model.view == .done)
        await model.press(.done)
        s.settings.model.showIntroduction()
        let again = try await s.shown()
        #expect(again.view == .installed)
        await again.press(.done)
        await again.press(.done)
        #expect(again.view == .skills)
        #expect(!again.isClosed)
        #expect(s.host.isOpen)
    }

    // An again dialog that opens before the first reads offers Skip, and Turn on waits for the
    // status.
    @Test func turnOnWaitsForTheFirstRead() async throws {
        let s = try await SetupParts()
        defer { s.finish() }
        s.settings.model.showIntroduction()
        let model = try await s.shown()
        #expect(model.mode == .again)
        #expect(model.view == .ask)
        #expect(model.content.steps == [])
        #expect(model.isOff(.turnOn))
        #expect(!model.isOff(.skip))
        await model.press(.turnOn)
        #expect(s.live.livePlugins.writes == [])
        await s.live.attach()
        #expect(!model.isOff(.turnOn))
    }

    // With no claude there is no control: the first-start dialog shows "claude was not found.",
    // Turn on fails with that text in the dialog only, and Skip closes the dialog.
    @Test func withNoClaudeTheDialogShowsClaudeNotFound() async throws {
        let s = try await SetupParts()
        defer { s.finish() }
        s.live.model.attach(nil)
        let model = try await s.shown()
        #expect(model.mode == .first)
        #expect(model.view == .ask)
        #expect(model.content.problem == "claude was not found.")
        await model.press(.turnOn)
        #expect(model.content.error == "claude was not found.")
        #expect(LiveSection(model: s.settings.model).content.error == nil)
        #expect(model.saving == nil)
        // Try again keeps the reason, and the next step ends it.
        await model.press(.retry)
        #expect(model.content.error == "claude was not found.")
        await model.press(.skip)
        #expect(model.isClosed)
        #expect(!s.host.isOpen)
        await model.saving?.value
        #expect(s.settings.store.settings.setupDone)
    }
}

// The live parts, the Settings parts on their live model, a dialog layer, and the Setup dialog,
// which shows its dialogs in that layer. The Settings model gets the state of the layer, as the
// shell links it.
@MainActor
private final class SetupParts {
    let live: LiveParts
    let settings: SettingsParts
    let host = DialogHost(look: PanelLook(), clock: ManualClock())
    let setup: SetupDialog

    init(live plugins: FakePlugins? = nil, skills: FakePlugins? = nil, atStart: Bool = true)
        async throws
    {
        live = try LiveParts(live: plugins, skills: skills)
        settings = try await SettingsParts(live: live.model)
        let host = host
        settings.model.links.dialogShows = { host.isOpen }
        setup = SetupDialog(settings: settings.model, atStart: atStart) { host.setup($0) }
    }

    // The model of the Setup dialog, after it shows.
    func shown(sourceLocation: SourceLocation = #_sourceLocation) async throws -> SetupDialogModel
    {
        await waitUntil(sourceLocation: sourceLocation) {
            if case .setup = self.host.dialog { return true }
            return false
        }
        guard case .setup(let model) = host.dialog else { throw SetupPartsError.noDialog }
        return model
    }

    func finish() {
        live.finish()
    }

    enum SetupPartsError: Error {
        case noDialog
    }
}

// A view outside the dialog layer that can take the focus.
private final class FocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
