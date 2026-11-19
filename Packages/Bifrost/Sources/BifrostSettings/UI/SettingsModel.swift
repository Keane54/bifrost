// The model of the Settings panel (docs/behaviour/settings.md): the section, the search, the saves
// of the rows with their errors, the drafts and the Save button. The panel body, its rows and the
// sections read it. It keeps the one save tracker of the panel, and it obeys the owner rules of
// SaveTracker.
//
// Each change of a row saves at once (save(_:_:)). The tracker counts the save before the first
// await. A failed save shows its reason on its row until the user closes it or a later save of
// the row works. A row that goes away drops its save state and its error: a search hides it, a
// tab change hides its section, or the panel closes.
//
// Save (saveAndClose()) first ends the edit of the focused text field, so that its text saves as
// at a blur. Then it saves each draft with text and waits for each save that runs. It closes
// Settings only when no row has a failed save. One Save runs at a time. While it runs, the Save
// button, the tabs, the search field and the draft fields are off, so no draft comes and no row
// goes away during the wait. A draft that Enter saves is out of the drafts of Save until that
// save ends, so Save does not save it a second time.
//
// Settings > General also shows values that the settings file does not keep: the display mode of
// the window, the installed apps, why the last change of the login item failed and the version of
// the app. The shell gives them at the init, in the links of the model (SettingsLinks,
// Shell.settingsLinks). Each link has a default that does nothing, so a test that does not give a
// link opens no app and changes no window. The confirm dialog of Reset all keys, the state of the
// dialogs and the hook of each open of the panel come the same way. With no confirm dialog, Reset
// all keys is off. While a dialog shows, Save is off.
//
// Settings > Keys keeps its state here: the recording (its slot and the refusal of the recorder)
// and the slot of the last key save. So the state stays when SwiftUI makes the views of the
// section again, for example at each change of the search.
//
// Settings > Live details and Settings > Skills read the state of Live details and of the skills
// from the live model (LiveModel). The model gives the words of the two sections to the search
// after each change (extraIndex(_:words:)), and each close of the panel lets the next open read
// each status again.
import AppKit
import BifrostFoundation
import BifrostKeyboard
import BifrostLayout
import BifrostSessions
import Observation

// What the text of a draft or of a text field saves: an edit of the settings, or the reason why
// the text is refused before a save starts.
package enum TextSave {
    case edit((inout Settings) -> Void)
    case refused(String)
}

// What the scroll area of the panel shows.
package enum SettingsContent: Sendable, Equatable {
    // No search: the section of the active tab.
    case section(SettingsSection)
    // A search with matches: the hits, section by section.
    case hits([SearchHit])
    // A search with no match: the line that tells it.
    case noMatch(String)
}

// The values and the actions of the window and of the services that the Settings panel shows and
// uses, but that the settings file does not keep. The shell gives them at the init of the model.
// The links are an observed value of the model, so a view that reads a link follows a new value
// of the links, and each closure that reads an observed value gives its changes too.
@MainActor
package struct SettingsLinks {
    // Ask the user to confirm, for example before Reset all keys. The shell shows the confirm
    // dialog of Bifrost. True: the user confirmed. nil: Reset all keys is off.
    package var confirm: (@MainActor (ConfirmText) async -> Bool)?
    // True while a dialog of the window shows, for example the confirm dialog of Reset all keys.
    // Save is off then, so a reset that the user confirms later cannot save after Settings
    // closed.
    package var dialogShows: @MainActor () -> Bool
    // The display mode of the window. The window keeps it, not the settings file.
    package var displayMode: @MainActor () -> DisplayMode
    package var requestDisplayMode: @MainActor (DisplayMode) -> Void
    // Find the installed apps for a Terminal app setting. It reads the file system, so the model
    // runs it on the blocking executor. nil: the app selects offer only Automatic.
    package var appFinder: (@Sendable (TerminalAppID?) -> GeneralApps)?
    // Why the last change of the login item failed, or nil.
    package var loginItemProblem: @MainActor () -> LoginItemError?
    // Open the Login Items of System Settings, where the user allows a login item that waits.
    package var openLoginItems: @MainActor () -> Void
    // Runs at each open of the panel (SettingsPanels), for example to read the state of the login
    // item again.
    package var onPanelOpen: @MainActor () -> Void
    // The version of the app (CFBundleShortVersionString), or nil. The last line of General shows
    // it.
    package var appVersion: String?
    // The actions of Settings > Reviews that reach the Reviews services (ReviewsLinks).
    package var reviews: ReviewsLinks
    // The updater: the version, the last check, Check now and the release notes.
    package var updates: UpdatesLinks
    // The Daily update: the read of the MCP servers, why it does not run, and the open of its
    // panel.
    package var dailyUpdate: DailyUpdateLinks

    @MainActor
    package init(
        confirm: (@MainActor (ConfirmText) async -> Bool)? = nil,
        dialogShows: @escaping @MainActor () -> Bool = { false },
        displayMode: @escaping @MainActor () -> DisplayMode = { .window },
        requestDisplayMode: @escaping @MainActor (DisplayMode) -> Void = { _ in },
        appFinder: (@Sendable (TerminalAppID?) -> GeneralApps)? = nil,
        loginItemProblem: @escaping @MainActor () -> LoginItemError? = { nil },
        openLoginItems: @escaping @MainActor () -> Void = {},
        onPanelOpen: @escaping @MainActor () -> Void = {},
        appVersion: String? = nil, reviews: ReviewsLinks = ReviewsLinks(),
        updates: UpdatesLinks = UpdatesLinks(),
        dailyUpdate: DailyUpdateLinks = DailyUpdateLinks()
    ) {
        self.confirm = confirm
        self.dialogShows = dialogShows
        self.displayMode = displayMode
        self.requestDisplayMode = requestDisplayMode
        self.appFinder = appFinder
        self.loginItemProblem = loginItemProblem
        self.openLoginItems = openLoginItems
        self.onPanelOpen = onPanelOpen
        self.appVersion = appVersion
        self.reviews = reviews
        self.updates = updates
        self.dailyUpdate = dailyUpdate
    }
}

@MainActor
@Observable
package final class SettingsModel {
    // The sections that show their rows. Each other section shows the later text, and the search
    // does not look at it.
    package static let built: Set<SettingsSection> = [
        .general, .slash, .keys, .reviews, .dailyUpdate, .live, .skills, .updates,
    ]

    // A draft of a text field (SaveTracker.Draft): its row, and what its text saves.
    private struct DraftSaver {
        let row: SettingsRowID
        let save: (String) -> TextSave
    }

    // The result of one save, for its end.
    private enum SaveOutcome: Equatable {
        case saved
        case failed(String)
    }

    @ObservationIgnored package let store: SettingsStore
    @ObservationIgnored private let layout: WindowLayoutModel
    // The state of Live details and of the skills, which the side bar and the Setup dialog read
    // too.
    @ObservationIgnored package let live: LiveModel

    // The section of the active tab. It stays when Settings closes.
    package var section = SettingsSection.general {
        didSet { dropHiddenRows() }
    }
    // The text of the search field. During a Save it does not change, so no row goes away.
    package var query: String {
        get { searchText }
        set {
            guard !isSaving else { return }
            searchText = newValue
            queryChanged()
        }
    }
    private var searchText = ""
    // True while Save runs.
    package private(set) var isSaving = false
    // The Setup dialog, which shows the introduction again for the Introduction row. It links
    // itself at its init (SetupDialog).
    @ObservationIgnored package weak var setup: SetupDialog?
    // The text of each draft, by the ID of the draft.
    package private(set) var draftTexts: [Int: String] = [:]
    // The reason of the failed save of each row.
    private var errors: [SettingsRowID: String] = [:]
    // The words of the sections that give their own words to the search (extraIndex).
    private var extraWords: [SettingsSection: [String]] = [:]
    // The state of Settings > Daily update that the settings file does not keep: the servers of
    // the last read and the proposal of the tools.
    @ObservationIgnored package let dailyUpdate = DailyUpdateSectionState()

    // The host of the panel sets this: it ends the edit of the focused text field of the panel,
    // and the end of the edit saves the text before the call returns.
    @ObservationIgnored package var endEditing: () -> Void = {}
    // Tells the number of matches to a screen reader. A test records the texts.
    @ObservationIgnored package var announce: @MainActor (String) -> Void = announceToVoiceOver
    // The values and the actions of the window and of the services (SettingsLinks).
    package var links: SettingsLinks
    // The installed apps of the app selects of General, after the last find. nil before the
    // first find.
    package private(set) var apps: GeneralApps?
    // The notice about the version of Claude Code at the top of General, or nil for no notice.
    // The shell gives the notice of the version of the live model
    // (LiveRules.claudeVersionNotice).
    package var versionNotice: String?

    // MARK: Settings > Keys

    // A recording of the key recorder: the slot whose key it records, and why it refused the last
    // key of the recording, or nil.
    package struct Recording: Equatable {
        package var slot: KeySlot
        package var refusal: String?

        package init(slot: KeySlot, refusal: String? = nil) {
            self.slot = slot
            self.refusal = refusal
        }
    }

    // The recording of now, or nil. Only the row of its slot shows the recorder.
    package var recording: Recording?
    // The slot of the last save of Settings > Keys, or nil for Reset all keys. The error of the
    // section shows on the row of this slot, or at the top of the section.
    package var keyErrorSlot: KeySlot?

    @ObservationIgnored private var tracker = SaveTracker<SettingsRowID>()
    // The rows that have a save state, an error or a draft, so that a row that goes away drops
    // them.
    @ObservationIgnored private var rows: Set<SettingsRowID> = []
    @ObservationIgnored private var drafts: [Int: DraftSaver] = [:]
    // The waits of Save for the end of a save.
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    // The drafts that Enter saves now, with the number of each save. Save does not get them.
    @ObservationIgnored private var taken: [Int: Int] = [:]
    // Each close of the panel adds one. A Save of an earlier view of the panel then stops.
    @ObservationIgnored private var closes = 0
    // The task that follows the changes of the settings, also the changes from outside the panel.
    @ObservationIgnored private var settingsFollow: Task<Void, Never>?
    // The last text of the count line, so that each text is told one time.
    @ObservationIgnored private var lastCount = ""
    // The number of the last find of the installed apps. Only the last find sets apps.
    @ObservationIgnored private var appFinds = 0

    package init(
        store: SettingsStore, layout: WindowLayoutModel, live: LiveModel = LiveModel(),
        links: SettingsLinks = SettingsLinks()
    ) {
        self.store = store
        self.layout = layout
        self.live = live
        self.links = links
        for part in LiveModel.Part.allCases { extraWords[part.section] = live.words(part) }
        live.onWords = { [weak self] section, words in self?.extraIndex(section, words: words) }
        // A change of the settings can change the rows that a search shows, for example a new
        // key from outside the panel. A row that goes away then drops its state.
        let changes = Observations { store.settings }
        settingsFollow = Task { [weak self] in
            for await _ in changes { self?.settingsChanged() }
        }
    }

    isolated deinit {
        settingsFollow?.cancel()
    }

    // MARK: - The panel

    // True when Settings is the active panel of the top frame that shows.
    package var settingsOnTop: Bool { layout.layout.topFrame?.active.kind == .settings }

    // Open the Settings panel, or bring it to the front. A section also selects that section.
    // During a Save it does nothing, as a tab does not, so no row goes away during the wait.
    package func open(_ section: SettingsSection? = nil) {
        guard !isSaving else { return }
        if let section { self.section = section }
        layout.apply(.open(.settings))
    }

    package func close() {
        layout.apply(.close(.settings))
    }

    // A click on a tab: the search ends, and the tab shows its section. During a Save the tabs
    // are off.
    package func showTab(_ section: SettingsSection) {
        guard !isSaving else { return }
        query = ""
        self.section = section
    }

    // The Introduction row asks the Setup dialog to show the introduction again. The request
    // changes no setting.
    package func showIntroduction() {
        setup?.showIntroduction()
    }

    // The panel left the last frame. Its rows go away with their save states, errors and drafts,
    // and the search ends. A Save that waits stops and does not close a later view of the panel.
    // A save that runs still saves. The next open reads the status of Live details and of the
    // skills again.
    package func panelClosed() {
        closes += 1
        for row in rows { tracker.remove(row) }
        for id in drafts.keys { tracker.removeDraft(id) }
        rows = []
        drafts = [:]
        taken = [:]
        if !draftTexts.isEmpty { draftTexts = [:] }
        if !errors.isEmpty { errors = [:] }
        recording = nil
        keyErrorSlot = nil
        dailyUpdate.readError = nil
        searchText = ""
        queryChanged()
        wakeWaiters()
        live.panelClosed()
    }

    // MARK: - Settings > General

    // Find the installed apps for the Terminal app setting of now. General finds them when it
    // shows and after each change of the Terminal app. A find that ends after a later find
    // changes nothing.
    package func findApps() async {
        guard let finder = links.appFinder else { return }
        appFinds += 1
        let number = appFinds
        let terminal = store.settings.terminalApp
        let found = await BlockingExecutor.run { finder(terminal) }
        guard number == appFinds, found != apps else { return }
        apps = found
    }

    // MARK: - The search

    // The rows of the sections that show their rows, in the order of the tabs.
    package var index: [SearchSection] {
        let settings = store.settings
        let keys = KeyEditor.groups(KeyChanges(stored: settings.keys), settings.labels)
            .flatMap(\.rows)
            .map { SearchRow(id: $0.slot.text, text: $0.label, key: $0.binding) }
        return SettingsSearch.index(
            general: GeneralSection.rows, slash: settings.slashCommands, keys: keys,
            live: extraWords[.live] ?? [], skills: extraWords[.skills] ?? [],
            updates: UpdatesSection.rows, dailyUpdate: DailyUpdateSection.rows,
            shown: Self.built)
    }

    // The matches of the query, or nil with no search. Each row of the panel asks for the hits
    // in its body (isShown), so the model keeps the last search. It searches again only when the
    // query, the settings or the words of a section changed: these are all the inputs of the
    // search, so a kept result is the same as a new search.
    package var hits: [SearchHit]? {
        let (query, settings, extraWords) = (query, store.settings, extraWords)
        if let last = lastSearch, last.query == query, last.settings == settings,
            last.extraWords == extraWords
        {
            return last.hits
        }
        let hits = SettingsSearch.search(query, index)
        lastSearch = KeptSearch(
            query: query, settings: settings, extraWords: extraWords, hits: hits)
        return hits
    }

    // The inputs and the result of the last search.
    private struct KeptSearch {
        var query: String
        var settings: Settings
        var extraWords: [SettingsSection: [String]]
        var hits: [SearchHit]?
    }

    @ObservationIgnored private var lastSearch: KeptSearch?

    package var content: SettingsContent {
        guard let hits else { return .section(section) }
        return hits.isEmpty ? .noMatch(SettingsSearch.noMatchText(query)) : .hits(hits)
    }

    // The active tab: the section, or nil during a search.
    package var activeTab: SettingsSection? { hits == nil ? section : nil }

    // The line that tells a screen reader the number of matches.
    package var countText: String { SettingsSearch.resultCountText(hits, query) }

    // The words of a section that the search reads: the words of Live details or of Skills.
    package func extraIndex(_ section: SettingsSection, words: [String]) {
        extraWords[section] = words
        dropHiddenRows()
    }

    // True when the key event is Cmd+F for the search field (SettingsSearch.isSearchShortcut). A
    // Bifrost key on the same key acts first, so then the event goes on to the menu and to the
    // key filter of the window.
    package func isSearchShortcut(_ event: KeyEvent, focus: SearchFocus) -> Bool {
        guard SettingsSearch.isSearchShortcut(event, focus: focus, settingsOnTop: settingsOnTop)
        else { return false }
        let keys = KeyMap(stored: store.settings.keys)
        return !KeySlot.all.contains { keys[$0].chord?.match(event) != nil }
    }

    // Esc in the search field: it clears the query, then it closes Settings. During a
    // composition it does nothing. True when Esc acted.
    package func escapeInSearch(composing: Bool) -> Bool {
        switch SettingsSearch.escape(value: query, composing: composing) {
        case .ignore:
            return false
        case .clear:
            query = ""
            return true
        case .close:
            close()
            return true
        }
    }

    // MARK: - The rows

    package func isShown(_ row: SettingsRowID) -> Bool {
        row.isShown(section: section, hits: hits)
    }

    // The reason of the failed save of the row, or nil.
    package func error(of row: SettingsRowID) -> String? {
        errors[row]
    }

    // The user closed the error of the row.
    package func closeError(_ row: SettingsRowID) {
        errors[row] = nil
        tracker.forget(row)
    }

    // Start a save of the row: the store edits the settings with change. The tracker counts the
    // save at once, so a Save that starts later waits for it. The task gives true when the save
    // worked.
    @discardableResult
    package func save(
        _ row: SettingsRowID, _ change: @escaping (inout Settings) -> Void
    ) -> Task<Bool, Never> {
        let number = begin(row)
        return Task { await self.finish(number, row: row, change) }
    }

    // A save of the row that is refused before it starts, for example a text that is not a
    // number. The row shows the reason, and a Save counts the failure.
    package func refuse(_ row: SettingsRowID, reason: String) {
        end(begin(row), row: row, .failed(reason))
    }

    // MARK: - The drafts

    package func draftText(_ id: Int) -> String {
        draftTexts[id] ?? ""
    }

    // The user changed the text of a draft field. save gives what a text saves. A new text
    // clears the error of the row. During a Save, or while its row does not show, the field
    // takes no new text.
    package func editDraft(
        _ id: Int, row: SettingsRowID, text: String, save: @escaping (String) -> TextSave
    ) {
        guard !isSaving, isShown(row) else { return }
        if let old = drafts[id]?.row, old != row { forgetRow(old) }
        drafts[id] = DraftSaver(row: row, save: save)
        rows.insert(row)
        guard draftTexts[id] != text else { return }
        // A new text is a new draft for Save, also while Enter saves the old text.
        taken[id] = nil
        draftTexts[id] = text
        tracker.addDraft(id, row: row, text: text)
        if errors[row] != nil { errors[row] = nil }
    }

    // Save the text of a draft now, for example at Enter. A good save empties the field. While
    // the save runs, the draft is out of the drafts of Save, and a failed save puts it back. nil:
    // nothing to save, the save of the text runs, or the text is refused before a save starts.
    @discardableResult
    package func saveDraft(_ id: Int) -> Task<Bool, Never>? {
        guard !isSaving, taken[id] == nil, let saver = drafts[id], let text = draftTexts[id],
            !text.trimmed().isEmpty
        else { return nil }
        // The draft leaves the tracker before the save starts, so the save gives the state of
        // the row.
        tracker.removeDraft(id)
        return startDraft(id, saver, text: text, taken: true)
    }

    // MARK: - Save

    // The Save button: end the edit of the focused field, save the drafts, wait for each save,
    // then close Settings when no row has a failed save. While a dialog shows, Save does nothing.
    package func saveAndClose() async {
        guard !isSaving, !links.dialogShows() else { return }
        endEditing()
        isSaving = true
        defer { isSaving = false }
        let view = closes
        var settled = false
        defer { if !settled { tracker.cancelSettle() } }
        while true {
            switch tracker.settle() {
            case .save(let list):
                // The tracker must count each save of a draft before the next settle.
                for draft in list {
                    guard let saver = drafts[draft.id] else { continue }
                    startDraft(draft.id, saver, text: draft.text)
                }
            case .wait:
                await nextSaveEnd()
                if Task.isCancelled || view != closes { return }
            case .done(let ok):
                settled = true
                if ok { close() }
                return
            }
        }
    }

    // MARK: - The saves

    private func begin(_ row: SettingsRowID) -> Int {
        rows.insert(row)
        return tracker.started(row: row)
    }

    private func finish(
        _ number: Int, row: SettingsRowID, _ change: @escaping (inout Settings) -> Void
    ) async -> Bool {
        let outcome: SaveOutcome
        defer { end(number, row: row, outcome) }
        do {
            try await store.edit(change)
            outcome = .saved
        } catch {
            outcome = .failed(error.message)
        }
        return outcome == .saved
    }

    // Start the save of the text of a draft. The tracker counts it now, before any await. taken:
    // Enter starts the save, and the draft is out of the drafts of Save until the save ends.
    @discardableResult
    private func startDraft(
        _ id: Int, _ saver: DraftSaver, text: String, taken: Bool = false
    ) -> Task<Bool, Never>? {
        let number = begin(saver.row)
        switch saver.save(text) {
        case .refused(let reason):
            end(number, row: saver.row, .failed(reason))
            if taken { putBack(id, saver.row, text: text) }
            return nil
        case .edit(let change):
            if taken { self.taken[id] = number }
            return Task { await self.finishDraft(number, id: id, text: text, saver.row, change) }
        }
    }

    private func finishDraft(
        _ number: Int, id: Int, text: String, _ row: SettingsRowID,
        _ change: @escaping (inout Settings) -> Void
    ) async -> Bool {
        let outcome: SaveOutcome
        defer { end(number, row: row, outcome) }
        do {
            try await store.edit(change)
            outcome = .saved
            release(id, number)
            // The field is empty again before the save ends, so the next Save does not save
            // the text again. A text that the user typed during the save stays.
            if draftTexts[id] == text, drafts[id] != nil {
                draftTexts[id] = ""
                tracker.addDraft(id, row: row, text: "")
            }
        } catch {
            outcome = .failed(error.message)
            if release(id, number) { putBack(id, row, text: text) }
        }
        return outcome == .saved
    }

    // The save of a draft ended. True when Enter started it and the draft was still taken: a
    // new text gives the draft back to Save at once (editDraft).
    @discardableResult
    private func release(_ id: Int, _ number: Int) -> Bool {
        guard taken[id] == number else { return false }
        taken[id] = nil
        return true
    }

    // The save that Enter started failed: the draft is a draft of Save again, while the field
    // still has its text.
    private func putBack(_ id: Int, _ row: SettingsRowID, text: String) {
        guard draftTexts[id] == text, drafts[id] != nil else { return }
        tracker.addDraft(id, row: row, text: text)
    }

    // The end of a save. The row shows the result only when the tracker says that the save
    // gives the state of the row. A save can change the rows that a search shows, and Save
    // waits for this end.
    private func end(_ number: Int, row: SettingsRowID, _ outcome: SaveOutcome) {
        if tracker.ended(save: number, ok: outcome == .saved) {
            switch outcome {
            case .saved: if errors[row] != nil { errors[row] = nil }
            case .failed(let reason): errors[row] = reason
            }
        }
        dropHiddenRows()
        wakeWaiters()
    }

    private func nextSaveEnd() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append($0) }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wakeWaiters() }
        }
    }

    private func wakeWaiters() {
        let list = waiters
        waiters = []
        for waiter in list { waiter.resume() }
    }

    // MARK: - The rows that go away

    private func queryChanged() {
        dropHiddenRows()
        let text = countText
        guard text != lastCount else { return }
        lastCount = text
        if !text.isEmpty { announce(text) }
    }

    private func settingsChanged() {
        if !rows.isEmpty { dropHiddenRows() }
    }

    private func dropHiddenRows() {
        let hits = hits
        for row in rows where !row.isShown(section: section, hits: hits) {
            forgetRow(row)
        }
    }

    // The row went away: its save state, its error and its drafts go. The results of its saves
    // that still run do not count.
    private func forgetRow(_ row: SettingsRowID) {
        rows.remove(row)
        tracker.remove(row)
        if errors[row] != nil { errors[row] = nil }
        for (id, saver) in drafts where saver.row == row {
            drafts[id] = nil
            draftTexts[id] = nil
            taken[id] = nil
            tracker.removeDraft(id)
        }
    }

    private static func announceToVoiceOver(_ text: String) {
        NSAccessibility.post(
            element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [
                .announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
    }
}
