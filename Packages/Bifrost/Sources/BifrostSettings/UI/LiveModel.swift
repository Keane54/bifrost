// The state of Live details and of the Bifrost skills for the app (docs/behaviour/live.md,
// "Settings > Live details", and docs/behaviour/skills.md, "Settings > Skills"): the two status
// values, the version of Claude Code, the warning of the side bar, the new reads while a warning
// shows (LiveRetry), and the actions of the two sections. Settings > Live details, Settings >
// Skills, the side bar and the Setup dialog read it.
//
// - The model starts with no status: each section says that it checks. The shell gives the
//   controls when they exist (attach(_:skillsFolder:)). With no claude there is no control, and
//   the two sections show "claude was not found.". Skills then still lists the skills of the
//   bundled skills folder of the app, which the shell gives.
// - After the attach, the model reads the Live details status, the version and the skills status
//   one time, with no busy state. A read with no busy state drops its answer when an action or a
//   read with the busy state of its section started during it.
// - A section that shows reads its status with the busy state one time for each open of
//   Settings (readOnce(_:)). So a search that shows the section at many queries does not run
//   claude plugin list again. Before the attach, that read waits for the controls.
// - The status reads go through the controls and take no lock. The actions go through run of
//   the controls, and one action or busy read runs at a time in each section. An action that
//   fails reads the status again, because it can change something before it fails, and then the
//   section shows the text of the failure. An Install of the Setup dialog gives its failure to
//   the dialog (setupInstall(_:)).
// - While a warning shows, LiveRetry reads the Live details status again on its back-off, and
//   the version too when it is not good. A read of Live details with the busy state counts as a
//   read for the back-off.
//
// The version check never fails: a run that fails gives no version. So the model gives false as
// the failed check of the rules.
import BifrostFoundation
import BifrostLive
import BifrostSessions
import Foundation
import Observation

@MainActor
@Observable
package final class LiveModel {
    // What the model reads and changes: the Live details control, the skills control, and the
    // version check of Claude Code with the minimum of Bifrost (ClaudeVersionCheck.appMinimum).
    package struct Sources: Sendable {
        package let live: LiveControl
        package let skills: SkillsControl
        package let version: @MainActor @Sendable () async -> ClaudeVersionCheck

        package init(
            live: LiveControl, skills: SkillsControl,
            version: @escaping @MainActor @Sendable () async -> ClaudeVersionCheck
        ) {
            self.live = live
            self.skills = skills
            self.version = version
        }
    }

    // A section of the model: Settings > Live details or Settings > Skills.
    package enum Part: Sendable, CaseIterable {
        case live, skills

        package var section: SettingsSection { self == .live ? .live : .skills }
    }

    // The state of the actions of a section. busy: an action or a busy read runs, so the buttons
    // are off. changed: the last action was a good Install or Turn on, so the section shows the
    // reload note. error: the text of the last failure, until the user closes it. showsSteps:
    // after a click on Install, the section shows the steps of Install with Install and Cancel.
    package struct PartState: Sendable, Equatable {
        package var busy = false
        package var changed = false
        package var error: String?
        package var showsSteps = false
    }

    private enum Phase {
        case waiting
        case ready(Sources)
        case noClaude
        case stopped
    }

    // nil until the first read ends.
    package private(set) var status: LiveStatus? {
        didSet { stateChanged() }
    }
    package private(set) var skillsStatus: SkillsStatus? {
        didSet { stateChanged() }
    }
    // The version of Claude Code for the minimum of Bifrost. nil until the first check ends.
    package private(set) var version: ClaudeVersionCheck? {
        didSet { stateChanged() }
    }
    package private(set) var liveState = PartState()
    package private(set) var skillsState = PartState()

    // Gets the words of a section for the search of Settings after each change of the state.
    // SettingsModel sets it (SettingsModel.extraIndex).
    @ObservationIgnored package var onWords: @MainActor (SettingsSection, [String]) -> Void = {
        _, _ in
    }
    // The task of the first reads after the attach, or nil. A test waits for it.
    @ObservationIgnored package private(set) var firstReads: Task<Void, Never>?

    @ObservationIgnored private var phase = Phase.waiting
    @ObservationIgnored private var retry: LiveRetry?
    // The number of calls with the busy state of each section. A read with no busy state drops
    // its answer when such a call started during it.
    @ObservationIgnored private var busyCalls: [Part: Int] = [:]
    // The sections that read their status in this open of Settings.
    @ObservationIgnored private var readThisOpen: Set<Part> = []
    // The sections that asked for their read before the attach.
    @ObservationIgnored private var owedReads: Set<Part> = []
    // The last read of each section with the busy state, which stop() cancels.
    @ObservationIgnored private var sectionReads: [Part: Task<Void, Never>] = [:]

    // clock: the clock of the back-off of the new reads.
    package init(clock: any Clock<Duration> = ContinuousClock()) {
        retry = LiveRetry(
            clock: clock, read: { [weak self] in await self?.readAgain() },
            readVersion: { [weak self] in await self?.versionAgain() })
    }

    // MARK: - The values

    package var notice: LiveNotice { LiveNotice.of(status) }
    package var skillsNotice: SkillsNotice { SkillsNotice.of(skillsStatus) }

    // True when the side bar Settings button and the Live details tab show the warning dot.
    package var warning: Bool { LiveRules.hasWarning(status, version, versionFailed: false) }

    package func state(_ part: Part) -> PartState {
        part == .live ? liveState : skillsState
    }

    // True while the buttons of the section are off. One plugin change runs at a time, also
    // across the two sections, so the Skills buttons are off while Live details is busy too.
    package func isBusy(_ part: Part) -> Bool {
        part == .live ? liveState.busy : skillsState.busy || liveState.busy
    }

    // The words of the section for the search: the title, "plugin", the state line, the labels of
    // the buttons, and the Claude Code line of Live details or the name of each skill.
    package func words(_ part: Part) -> [String] {
        switch part {
        case .live:
            [SettingsSection.live.title, "plugin", notice.stateLine]
                + LiveRules.actions(status).map(\.label)
                + [LiveRules.claudeVersionLine(version, failed: false) ?? "Claude Code"]
        case .skills:
            [SettingsSection.skills.title, "plugin", skillsNotice.stateLine]
                + SkillsNotice.actions(skillsStatus).map(\.label)
                + (skillsStatus?.skills.map(\.name) ?? [])
        }
    }

    // MARK: - The life of the model

    // The controls exist, or nil when the app found no claude. Only the first call counts. With
    // no claude, the two sections show "claude was not found." with Try again, which reads
    // nothing. skillsFolder is the bundled skills folder of the app: with no claude, the model
    // reads its skills one time, so Settings > Skills still lists them. A failed read adds its
    // text after "claude was not found.", as the status of the skills control does.
    package func attach(_ sources: Sources?, skillsFolder: URL? = nil) {
        guard case .waiting = phase else { return }
        guard let sources else {
            phase = .noClaude
            owedReads = []
            let missing = PluginFailure.claudeNotFound.message
            status = LiveRules.unknownStatus(missing)
            skillsStatus = SkillsStatus(
                plugin: .unknown, folderCurrent: false, skills: [], error: missing)
            version = ClaudeVersionCheck(
                version: nil, ok: false, minimum: ClaudeVersionCheck.appMinimum)
            if let skillsFolder {
                firstReads = Task { await self.readBundledSkills(skillsFolder, missing) }
            }
            return
        }
        phase = .ready(sources)
        let owed = owedReads
        owedReads = []
        firstReads = Task { await self.readFirst(sources, owed: owed) }
    }

    // The window got the focus: a warning can read again (LiveRetry.focus()).
    package func windowFocused() {
        retry?.focus()
    }

    #if DEBUG
    // The task of the last read of LiveRetry, or nil. A test waits for it.
    package var retryReadTask: Task<Void, Never>? { retry?.readTask }
    #endif

    // The app stops. No read and no action starts after this, each read of the model gets a
    // cancel, and no answer that comes later changes the state.
    package func stop() {
        phase = .stopped
        retry?.stop()
        firstReads?.cancel()
        for task in sectionReads.values { task.cancel() }
        sectionReads = [:]
    }

    // MARK: - The sections

    // A section shows. It reads its status with the busy state one time for each open of
    // Settings. Before the attach, the read waits for the controls. The result is the task of
    // the read, or nil when nothing reads now.
    @discardableResult
    package func readOnce(_ part: Part) -> Task<Void, Never>? {
        guard !readThisOpen.contains(part) else { return nil }
        readThisOpen.insert(part)
        switch phase {
        case .waiting:
            owedReads.insert(part)
            return nil
        case .ready:
            let task = Task { await self.refresh(part) }
            sectionReads[part] = task
            return task
        case .noClaude, .stopped:
            return nil
        }
    }

    // A section went away: its error and its steps go, as they do with a new view of the
    // section.
    package func sectionHidden(_ part: Part) {
        update(part) {
            $0.error = nil
            $0.showsSteps = false
        }
    }

    // Settings closed: the next open reads each status again.
    package func panelClosed() {
        readThisOpen = []
        for part in Part.allCases { sectionHidden(part) }
    }

    // A click on a button of the section. Install shows the steps of Install first. Remove asks
    // first with confirm, and does nothing with no confirm dialog. Try again reads the status
    // again. The task of the caller ends with the call.
    package func press(
        _ id: LiveActionID, _ part: Part, confirm: (@MainActor (ConfirmText) async -> Bool)?
    ) async {
        switch id {
        case .install:
            update(part) {
                $0.error = nil
                $0.showsSteps = true
            }
        case .retry:
            update(part) { $0.error = nil }
            await refresh(part)
        case .remove:
            let text = part == .live ? LiveTexts.removeConfirm : SkillsNotice.removeConfirm
            guard let confirm, await confirm(text) else { return }
            update(part) { $0.error = nil }
            await run(part, .uninstall)
        case .enable, .disable:
            update(part) { $0.error = nil }
            if let action = id.action { await run(part, action) }
        }
    }

    // The Install button under the steps. A good install hides the steps.
    package func install(_ part: Part) async {
        update(part) { $0.error = nil }
        if await run(part, .install) { update(part) { $0.showsSteps = false } }
    }

    // The Install of a step of the Setup dialog. It runs as the Install of the section, with the
    // busy state and the reload note of the section, but the dialog shows the failure, so the
    // section gets no error. The result is nil when the install worked, else the failure. With
    // no claude, the failure is claudeNotFound.
    package func setupInstall(_ part: Part) async -> PluginFailure? {
        await runAction(.install, part)
    }

    // Run the action as the button of the section does, with no confirm: the Setup dialog and
    // the debug test port use it. The caller gets the failure, and the section gets no error.
    // The result is nil when the action worked, else the failure. With no claude, the failure is
    // claudeNotFound, and after the stop it is cancelled.
    package func runAction(_ action: LiveAction, _ part: Part) async -> PluginFailure? {
        if case .noClaude = phase { return .claudeNotFound }
        var failure: PluginFailure?
        let worked = await run(part, action) { failure = $0 }
        return worked ? nil : failure ?? .cancelled
    }

    // The Cancel button under the steps.
    package func cancelInstall(_ part: Part) {
        update(part) { $0.showsSteps = false }
    }

    package func closeError(_ part: Part) {
        update(part) { $0.error = nil }
    }

    // MARK: - The reads

    // The first reads after the attach, at the same time. A section that asked for its read
    // before the attach reads with the busy state in place of the first read of its part.
    private func readFirst(_ sources: Sources, owed: Set<Part>) async {
        async let check: Void = readVersion(sources)
        async let live: Void = owed.contains(.live) ? refresh(.live) : readLiveQuietly(sources)
        async let skills: Void =
            owed.contains(.skills) ? refresh(.skills) : readQuietly(.skills, sources)
        _ = await (check, live, skills)
    }

    // The skills of the bundled folder with no claude.
    private func readBundledSkills(_ folder: URL, _ missing: String) async {
        let (skills, failure) = await SkillsControl.readSkills(folder)
        guard case .noClaude = phase else { return }
        let error = [missing, failure].compactMap { $0 }.joined(separator: " ")
        skillsStatus = SkillsStatus(
            plugin: .unknown, folderCurrent: false, skills: skills, error: error)
    }

    private func readLiveQuietly(_ sources: Sources) async {
        await readQuietly(.live, sources)
        retry?.readEnded()
    }

    // Read the status with no busy state. The answer drops when a call with the busy state of
    // the section started during the read, because that call gives a newer status.
    private func readQuietly(_ part: Part, _ sources: Sources) async {
        let calls = busyCalls[part, default: 0]
        switch part {
        case .live:
            let next = await sources.live.status()
            if isReady, busyCalls[part, default: 0] == calls { status = next }
        case .skills:
            let next = await sources.skills.status()
            if isReady, busyCalls[part, default: 0] == calls { skillsStatus = next }
        }
    }

    private func readStatus(_ part: Part, _ sources: Sources) async {
        switch part {
        case .live:
            let next = await sources.live.status()
            if isReady { status = next }
        case .skills:
            let next = await sources.skills.status()
            if isReady { skillsStatus = next }
        }
    }

    private func readVersion(_ sources: Sources) async {
        let next = await sources.version()
        if isReady { version = next }
    }

    // A read with the busy state. During an action it does nothing: the action sets the status
    // when it ends.
    private func refresh(_ part: Part) async {
        guard case .ready(let sources) = phase, !state(part).busy else { return }
        await whileBusy(part) { await self.readStatus(part, sources) }
    }

    // The read of LiveRetry: nothing while Live details is busy.
    private func readAgain() async {
        guard case .ready(let sources) = phase, !liveState.busy else { return }
        await readQuietly(.live, sources)
    }

    // The version read of LiveRetry: only a version that is not good, and nothing while Live
    // details is busy.
    private func versionAgain() async {
        guard case .ready(let sources) = phase, !liveState.busy, version?.ok != true else { return }
        await readVersion(sources)
    }

    // MARK: - The actions

    // Run the action of the control. A failure reads the status again, then failed gets the
    // failure. With no failed, the section shows its text. One action runs at a time in each
    // section, and a second action fails with the busy text. True when the action worked.
    @discardableResult
    private func run(
        _ part: Part, _ action: LiveAction, failed: ((PluginFailure) -> Void)? = nil
    ) async -> Bool {
        guard case .ready(let sources) = phase else { return false }
        let report = failed ?? { [weak self] in self?.showError(part, $0) }
        guard !state(part).busy else {
            report(.busy)
            return false
        }
        var worked = false
        await whileBusy(part) {
            self.update(part) { $0.changed = false }
            do throws(PluginFailure) {
                // An action that ends after the stop changes nothing.
                switch part {
                case .live:
                    let next = try await sources.live.run(action)
                    guard self.isReady else { return }
                    self.status = next
                case .skills:
                    let next = try await sources.skills.run(action)
                    guard self.isReady else { return }
                    self.skillsStatus = next
                }
                worked = true
            } catch {
                await self.readStatus(part, sources)
                report(error)
            }
        }
        if worked, action == .install || action == .enable { update(part) { $0.changed = true } }
        return worked
    }

    private func showError(_ part: Part, _ failure: PluginFailure) {
        update(part) { $0.error = failure.message }
    }

    // Run the work with the busy state of the section. Each caller checks first that the
    // section is not busy, so one such call runs at a time in each section. Each call of Live
    // details ends with a read of the status, so its end counts as a read for the back-off.
    private func whileBusy(_ part: Part, _ work: () async -> Void) async {
        update(part) { $0.busy = true }
        busyCalls[part, default: 0] += 1
        await work()
        update(part) { $0.busy = false }
        if part == .live { retry?.readEnded() }
    }

    // MARK: - The changes

    private var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    private func update(_ part: Part, _ change: (inout PartState) -> Void) {
        switch part {
        case .live:
            var next = liveState
            change(&next)
            if next != liveState { liveState = next }
        case .skills:
            var next = skillsState
            change(&next)
            if next != skillsState { skillsState = next }
        }
    }

    // A status or the version changed: the back-off follows the warning, and the search gets the
    // new words.
    private func stateChanged() {
        if isReady { retry?.warn(warning) }
        for part in Part.allCases { onWords(part.section, words(part)) }
    }
}
