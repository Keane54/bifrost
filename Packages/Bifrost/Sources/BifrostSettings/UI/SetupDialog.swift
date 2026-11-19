// The Setup dialog (docs/behaviour/live.md, "The Setup dialog"): the steps at the first start
// that turn on Live details and install the skills, and the introduction again from the
// Introduction row of Settings > General.
//
// - SetupDialog opens the dialog. At a start it opens one dialog when the rule of the start
//   allows it (LiveRules.shouldShowSetup, after the first reads of the Live details status and of
//   the skills status). It waits while another dialog shows. After any open of the dialog, the
//   dialog does not open again by itself. Each request of the Introduction row opens a new
//   dialog. An installed plugin, on or off, is already a choice, so then SetupDialog saves the
//   choice and opens nothing.
// - SetupDialogModel is one open of the dialog: its phase (ask, skills, done), what each view
//   shows, the reason of the last failed step, and the buttons. Each step acts through the live
//   model (LiveModel), so the sections of Settings show the same state. A failed step keeps its
//   buttons, so the user can try again or skip.
// - Only Skip and Done close the dialog. Esc and a click outside do nothing (DialogHost).
//
// The shell shows each dialog in the dialog layer of the window (DialogHost.setup). With a test
// home, the dialog does not open by itself unless the test asks (opensAtStart).
import BifrostFoundation
import BifrostLive
import Observation
import OSLog

// What the user installed in one open of the Setup dialog.
package struct SetupInstalled: Sendable, Equatable {
    package var live = false
    package var skills = false

    package init(live: Bool = false, skills: Bool = false) {
        self.live = live
        self.skills = skills
    }
}

// A button of the Setup dialog. retry is the Try again button beside a problem of the Live
// details status.
package enum SetupButton: Sendable, Hashable {
    case skip, turnOn, retry, skipSkills, installSkills, done

    package var label: String {
        switch self {
        case .skip, .skipSkills: "Skip"
        case .turnOn: "Turn on Live details"
        case .retry: LiveActionID.retry.label
        case .installSkills: "Install skills"
        case .done: "Done"
        }
    }
}

// What a view of the Setup dialog shows under the title, from the top to the buttons.
package struct SetupContent: Sendable, Equatable {
    // The text under the title.
    package var intro: String
    // The changes of the step, in the order that the step makes them. Empty in a view with no
    // step.
    package var steps: [String] = []
    // The lines under the steps: the version notes of the ask view, the state line of the
    // installed view, and the state lines and the reload note of the done view.
    package var lines: [String] = []
    // The problem of the Live details status, with Try again beside it, or nil.
    package var problem: String?
    // The dim note above the buttons, or nil.
    package var note: String?
    // The reason of the last failed step, or nil.
    package var error: String?
    // The buttons at the bottom, in their order.
    package var buttons: [SetupButton]
}

// One open of the Setup dialog.
@MainActor
@Observable
package final class SetupDialogModel {
    package static let title = "Set up Bifrost"
    private static let logger = Logger(bifrost: "setup")

    package let mode: SetupMode
    package private(set) var phase = SetupPhase.ask
    // The reason of the last failed step. It stays until the next step: Skip, Turn on or
    // Install skills. Try again keeps it.
    package private(set) var error: String?
    package private(set) var installed = SetupInstalled()
    // True after Skip or Done closed the dialog. A closed dialog does nothing.
    package private(set) var isClosed = false
    // The save of the end of the setup that a press started last, or nil. A test waits for it.
    @ObservationIgnored package private(set) var saving: Task<Void, Never>?
    // The dialog layer sets this when it shows the dialog. The close of the dialog calls it.
    @ObservationIgnored package var onClose: @MainActor (SetupDialogModel) -> Void = { _ in }
    @ObservationIgnored private let live: LiveModel
    @ObservationIgnored private let store: SettingsStore

    package init(mode: SetupMode, live: LiveModel, store: SettingsStore) {
        self.mode = mode
        self.live = live
        self.store = store
    }

    // MARK: - What the dialog shows

    package var view: SetupView { LiveRules.setupView(mode, phase, live.status) }

    package var content: SetupContent {
        switch view {
        case .ask:
            let status = live.status
            let notes = [
                LiveRules.claudeVersionNotice(live.version, failed: false),
                LiveRules.liveVersionNote(status),
            ]
            var problem: String?
            if case .problem(let message) = live.notice { problem = message }
            return SetupContent(
                intro: LiveTexts.setupIntro, steps: status.map(LiveRules.steps) ?? [],
                lines: notes.compactMap(\.self), problem: problem, note: LiveTexts.withoutLive,
                error: error, buttons: [.skip, .turnOn])
        case .installed:
            return SetupContent(
                intro: LiveTexts.about, lines: [LiveRules.introStateLine(live.notice)],
                note: LiveTexts.introChangeNote, buttons: [.done])
        case .skills:
            return SetupContent(
                intro: SkillsNotice.setupIntro, steps: SkillsNotice.steps,
                note: SkillsNotice.withoutSkills, error: error,
                buttons: [.skipSkills, .installSkills])
        case .done:
            let skillsLine = live.skillsNotice.doneLine
            let first = installed.live ? LiveRules.introStateLine(live.notice) : skillsLine
            let second = installed.live && installed.skills ? [skillsLine] : []
            return SetupContent(
                intro: first, lines: second + [LiveTexts.reloadNote], buttons: [.done])
        }
    }

    // True when the button is off. The buttons of a step are off while its part of the live
    // model is busy, so one plugin change runs at a time. Turn on also waits for the first read
    // of the status, as the Live details section shows no button until then.
    package func isOff(_ button: SetupButton) -> Bool {
        switch button {
        case .skip, .retry: live.isBusy(.live)
        case .turnOn: live.isBusy(.live) || live.status == nil
        case .skipSkills, .installSkills: live.isBusy(.skills)
        case .done: false
        }
    }

    // MARK: - The presses

    // A press of a button that shows and is on. The task of the caller ends with the step.
    package func press(_ button: SetupButton) async {
        guard !isClosed, shows(button), !isOff(button) else { return }
        switch button {
        case .skip:
            // At the first start, Skip saves the choice. A failed save does not keep the dialog
            // open, and the dialog then shows again at the next start.
            if LiveRules.skipSavesChoice(mode) { saving = Self.saveDone(store) }
            advance(from: .live)
        case .turnOn:
            await turnOn()
        case .retry:
            await live.press(.retry, .live, confirm: nil)
        case .skipSkills:
            advance(from: .skills)
        case .installSkills:
            await installSkills()
        case .done:
            // Done of the installed view ends the Live details step. Done of the done view
            // closes the dialog.
            if view == .installed { advance(from: .live) } else { close() }
        }
    }

    // A press that a task sends late, for example the second click of a double click, finds the
    // button of an earlier view. Only the buttons of the view of now act.
    private func shows(_ button: SetupButton) -> Bool {
        let content = content
        return button == .retry ? content.problem != nil : content.buttons.contains(button)
    }

    // Install Live details, then save the choice. A failure keeps the buttons and shows its
    // reason.
    private func turnOn() async {
        error = nil
        if let failure = await live.setupInstall(.live) {
            if !isClosed { error = failure.message }
            return
        }
        guard !isClosed else { return }
        saving = Self.saveDone(store)
        installed.live = true
        advance(from: .live)
    }

    // Install the skills. A failure keeps the buttons and shows its reason.
    private func installSkills() async {
        error = nil
        if let failure = await live.setupInstall(.skills) {
            if !isClosed { error = failure.message }
            return
        }
        guard !isClosed else { return }
        installed.skills = true
        advance(from: .skills)
    }

    // The step after the Live details step or the skills step. The dialog stays open for the
    // next step and for the done view.
    private func advance(from step: SetupStep) {
        error = nil
        let now = (live: installed.live, skills: installed.skills)
        switch SkillsNotice.nextSetupPhase(from: step, live.skillsStatus, installed: now) {
        case .skills: phase = .skills
        case .done: phase = .done
        case .close: close()
        }
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        onClose(self)
    }

    // Save the end of the setup (Settings.setupDone). A failed save goes to the log.
    static func saveDone(_ store: SettingsStore) -> Task<Void, Never> {
        Task {
            do throws(SettingsError) {
                try await store.edit { $0.setupDone = true }
            } catch {
                Self.logger.error(
                    "Bifrost can't save the end of the setup: \(error.message, privacy: .private)")
            }
        }
    }
}

// Opens the Setup dialog: one time at a start, and at each request of the Introduction row.
@MainActor
package final class SetupDialog {
    // The env key with which a test home asks for the dialog at the start.
    package static let testKey = "BIFROST_TEST_SETUP"

    // True when the dialog can open by itself at the start: always with no test home, and with
    // a test home only when the env has BIFROST_TEST_SETUP=1. So the dialog never covers the
    // window of a test that does not ask for it.
    package static func opensAtStart(testHome: Bool, environment: [String: String]) -> Bool {
        !testHome || environment[testKey] == "1"
    }

    // The values that the rules read, in one turn of the main actor.
    private struct State: Sendable {
        var status: LiveStatus?
        var skillsRead: Bool
        var setupDone: Bool
        var dialogShows: Bool

        @MainActor
        init(_ settings: SettingsModel) {
            status = settings.live.status
            skillsRead = settings.live.skillsStatus != nil
            setupDone = settings.store.settings.setupDone
            dialogShows = settings.links.dialogShows()
        }
    }

    private let settings: SettingsModel
    private let atStart: Bool
    private let show: @MainActor (SetupDialogModel) -> Bool
    // True after the dialog of the start opened, or after any other open of the dialog. Then
    // the dialog does not open again by itself.
    private var startHandled = false
    // True after the save of an installed plugin as the choice started.
    private var choiceSaved = false
    private var follow: Task<Void, Never>?
    // True while the dialog of the start is due but another dialog shows. A test waits for it.
    package private(set) var waitsForDialog = false

    // settings: the model of the Settings panel, with its live model and its state of the
    // dialogs (SettingsLinks.dialogShows), which the shell gives at its init. The dialog links
    // itself to the model for the Introduction row. atStart: the dialog can open by itself at
    // this start (opensAtStart). show: show the dialog in the dialog layer; false when another
    // dialog shows.
    package init(
        settings: SettingsModel, atStart: Bool,
        show: @escaping @MainActor (SetupDialogModel) -> Bool
    ) {
        self.settings = settings
        self.atStart = atStart
        self.show = show
        settings.setup = self
        let changes = Observations { [settings] in State(settings) }
        follow = Task { [weak self] in
            for await state in changes { self?.check(state) }
        }
    }

    isolated deinit {
        follow?.cancel()
    }

    // The Introduction row of Settings > General: a new dialog shows the introduction again.
    // While another dialog shows, nothing opens.
    func showIntroduction() {
        open(.again)
    }

    // The rules, in order: the save of an installed plugin as the choice, then the open at the
    // start.
    private func check(_ state: State) {
        if !state.setupDone, !choiceSaved, LiveRules.setupChosen(state.status) {
            choiceSaved = true
            _ = SetupDialogModel.saveDone(settings.store)
        }
        if atStart, !startHandled, state.skillsRead,
            LiveRules.shouldShowSetup(setupDone: state.setupDone, state.status)
        {
            if !state.dialogShows { open(.first) }
            waitsForDialog = !startHandled
        } else {
            waitsForDialog = false
        }
    }

    private func open(_ mode: SetupMode) {
        let model = SetupDialogModel(mode: mode, live: settings.live, store: settings.store)
        if show(model) { startHandled = true }
    }
}
