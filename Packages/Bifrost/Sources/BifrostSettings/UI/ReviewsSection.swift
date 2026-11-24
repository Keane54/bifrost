// Settings > Reviews (docs/behaviour/reviews.md, "Settings > Reviews"): the watch of GitHub, its
// limits and the list of repositories to ignore, one row for each label of ReviewsSettingsRow, in
// that order. Each change saves through the model (SettingsModel.save), so a refusal shows on its
// row.
//
// Each turn-on of Watch GitHub and of the three settings of the automatic work on the PRs of the
// user ("Handle comments on my PRs automatically", "Resolve merge conflicts automatically" and
// "Fix failing CI automatically") asks first with the confirm dialog of the window
// (SettingsLinks.confirm). A Cancel saves nothing, and with no confirm dialog the box cannot turn
// on. A turn-off saves at once. After a confirmed turn-on of one of the three settings saves, the
// section tells the Reviews services through the link of that setting (ReviewsLinks), and they
// record the consent of the user for that work. Only this call records a consent: another write
// of the setting (a settings file, an import) gives none.
//
// The ignore list works like the list of slash commands: a field with Add, and the entries under
// it, each with a Remove button. The field holds a draft: Enter and Add save it at once, and Save
// saves it too. A refused entry shows its reason (IgnoreRule.refusal) on the row.
//
// Remove all clones asks first, then deletes Bifrost's own copies of the repositories through
// the Reviews services (ReviewsLinks.removeClones). A failure shows on its row.
import BifrostFoundation
import BifrostLook
import BifrostReviews
import BifrostSessions
import SwiftUI

// The actions of Settings > Reviews that reach the Reviews services. The shell gives them in the
// links of the model (SettingsLinks.reviews). Each link has a default that does nothing.
@MainActor
package struct ReviewsLinks {
    // The user turned on "Handle comments on my PRs automatically" with its confirm, and the
    // setting saved. The Reviews services record the consent of the automatic request rounds.
    package var confirmAutoFix: @MainActor () -> Void
    // The user turned on "Resolve merge conflicts automatically" with its confirm, and the
    // setting saved. The Reviews services record the consent of the conflict rounds.
    package var confirmResolveConflicts: @MainActor () -> Void
    // The user turned on "Fix failing CI automatically" with its confirm, and the setting saved.
    // The Reviews services record the consent of the CI rounds.
    package var confirmFixCI: @MainActor () -> Void
    // The user confirmed Remove all clones. The Reviews services delete the clones. The result
    // is the friendly text of a failure, or nil when the clones went.
    package var removeClones: @MainActor () async -> String?

    package init(
        confirmAutoFix: @escaping @MainActor () -> Void = {},
        confirmResolveConflicts: @escaping @MainActor () -> Void = {},
        confirmFixCI: @escaping @MainActor () -> Void = {},
        removeClones: @escaping @MainActor () async -> String? = { nil }
    ) {
        self.confirmAutoFix = confirmAutoFix
        self.confirmResolveConflicts = confirmResolveConflicts
        self.confirmFixCI = confirmFixCI
        self.removeClones = removeClones
    }
}

package struct ReviewsSection: View {
    let model: SettingsModel

    package init(model: SettingsModel) {
        self.model = model
    }

    // A setting whose each turn-on asks first.
    package enum Confirmed: Sendable, CaseIterable {
        case watch, autoFix, resolveConflicts, fixCI

        package var row: ReviewsSettingsRow {
            switch self {
            case .watch: .watch
            case .autoFix: .autoFix
            case .resolveConflicts: .resolveConflicts
            case .fixCI: .fixCI
            }
        }

        package var setting: WritableKeyPath<Settings, Bool> {
            switch self {
            case .watch: \.reviewsWatch
            case .autoFix: \.reviewsAutoFix
            case .resolveConflicts: \.reviewsResolveConflicts
            case .fixCI: \.reviewsFixCI
            }
        }

        package var confirm: ConfirmText {
            switch self {
            case .watch: ReviewsSection.watchConfirm
            case .autoFix: ReviewsSection.autoFixConfirm
            case .resolveConflicts: ReviewsSection.resolveConflictsConfirm
            case .fixCI: ReviewsSection.fixCIConfirm
            }
        }

        // The link that records the consent after a confirmed turn-on, or nil for a setting
        // whose turn-on gives no consent.
        @MainActor
        func consent(_ links: ReviewsLinks) -> (@MainActor () -> Void)? {
            switch self {
            case .watch: nil
            case .autoFix: links.confirmAutoFix
            case .resolveConflicts: links.confirmResolveConflicts
            case .fixCI: links.confirmFixCI
            }
        }
    }

    // MARK: - The texts

    nonisolated package static let watchConfirm = ConfirmText(
        title: "Watch GitHub?",
        body: "Bifrost will use your gh login to check your review requests and your pull "
            + "requests every few minutes. It makes its own copy of each of their repositories, "
            + "and asks you to trust each copy once. When you click Review, Claude reviews the "
            + "pull request and Bifrost saves a draft review that only you can see. On your own "
            + "pull requests, Claude fixes or answers new review comments, and Bifrost pushes "
            + "the fixes and posts the replies. Bifrost changes, sends or approves a review only "
            + "when you click a button in the Review panel or Approve, and it never merges.",
        confirm: "Turn on")

    nonisolated package static let autoFixConfirm = ConfirmText(
        title: "Handle comments automatically?",
        body: "When someone reviews one of your pull requests, Claude fixes or answers each new "
            + "comment. Bifrost then pushes the fixes to your branch, replies to each comment "
            + "and resolves its thread. It never force-pushes, merges or approves. Comments from "
            + "before now wait until you choose Handle now.",
        confirm: "Turn on")

    nonisolated package static let resolveConflictsConfirm = ConfirmText(
        title: "Resolve merge conflicts automatically?",
        body: "When GitHub says one of your pull requests has conflicts, Bifrost merges the base "
            + "branch into your branch in its own copy of the repository, and Claude resolves "
            + "the conflicts. Bifrost checks Claude's work, then commits the merge and pushes it "
            + "to your branch. It never rebases or force-pushes, and it tries once for each new "
            + "conflict. This includes pull requests that have conflicts now.",
        confirm: "Turn on")

    nonisolated package static let fixCIConfirm = ConfirmText(
        title: "Fix failing CI automatically?",
        body: "When GitHub Actions fails on one of your pull requests, Claude reads the failed "
            + "logs and your code. Bifrost then pushes Claude's fix to your branch, or re-runs "
            + "the failed jobs if Claude thinks they were flaky, and asks you when Claude isn't "
            + "sure. Each commit you push gets at most two fixes and one re-run. This includes "
            + "pull requests that are failing now.",
        confirm: "Turn on")

    nonisolated package static let removeClonesConfirm = ConfirmText(
        title: "Remove all clones?",
        body: "Bifrost will delete its copies of your repositories, the review and request "
            + "sessions that use them and any queued reviews. Changes in a copy that aren't on "
            + "GitHub yet go too. Your own checkouts and your draft reviews on GitHub stay as "
            + "they are. While Watch GitHub is on, Bifrost copies the repositories of your open "
            + "pull requests again.",
        confirm: "Remove")

    nonisolated package static let removeClonesHint =
        "Deletes Bifrost's own copies of your repositories. Your own checkouts aren't touched."

    nonisolated package static let removeClonesButton = "Remove"

    nonisolated package static let autoFixHint =
        "Claude fixes or answers new review comments on your pull requests. Bifrost then pushes "
        + "the fixes and posts the replies."

    nonisolated package static let resolveConflictsHint =
        "When one of your pull requests has conflicts, Claude resolves them and Bifrost pushes a "
        + "merge of the base branch."

    nonisolated package static let fixCIHint =
        "When GitHub Actions fails on one of your pull requests, Claude fixes the code or Bifrost "
        + "re-runs the failed jobs."

    nonisolated package static let signedCommitsHint =
        "Bifrost sends each fix to GitHub with your gh login, and GitHub signs the commit, so it "
        + "shows as Verified. You don't need a signing key."

    nonisolated package static let ignoreFieldLabel = "New repository to ignore"
    nonisolated package static let ignorePlaceholder = "owner/repo or owner/*"
    // The ID of the draft of the field of the ignore list.
    nonisolated package static let ignoreDraftID = 2

    nonisolated package static func minutesText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    nonisolated package static func pollText(_ minutes: Int) -> String {
        minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    static let pauseChoices = Settings.reviewsPauseChoices.map { RowChoice($0, minutesText($0)) }
    static let pollChoices = Settings.reviewsPollChoices.map { RowChoice($0, pollText($0)) }
    static let modelChoices = NewSessionRules.modelOptions().map { RowChoice($0.value, $0.label) }

    // MARK: - The changes

    // Change a setting whose turn-on asks first. A turn-on saves only after the user confirms. A
    // Cancel, or no confirm dialog, saves nothing. A turn-off, and a value that does not change,
    // save at once. After a confirmed turn-on of a setting with a consent saves, the Reviews
    // services get the consent through the link of that setting (Confirmed.consent). The result
    // is true when the change saved.
    @discardableResult
    package func change(_ setting: Confirmed, to on: Bool) async -> Bool {
        let turnOn = on && !model.store.settings[keyPath: setting.setting]
        if turnOn {
            guard let confirm = model.links.confirm, await confirm(setting.confirm) else {
                return false
            }
        }
        let path = setting.setting
        let saved = await model.save(setting.row.row) { $0[keyPath: path] = on }.value
        if saved && turnOn, let consent = setting.consent(model.links.reviews) { consent() }
        return saved
    }

    // Remove all clones: ask first, then delete the clones. A Cancel, or no confirm dialog,
    // deletes nothing. A failure shows on the row. The result is true when the clones went.
    @discardableResult
    package func removeClones() async -> Bool {
        guard let confirm = model.links.confirm, await confirm(Self.removeClonesConfirm) else {
            return false
        }
        if let failure = await model.links.reviews.removeClones() {
            model.refuse(ReviewsSettingsRow.removeClones.row, reason: failure)
            return false
        }
        model.closeError(ReviewsSettingsRow.removeClones.row)
        return true
    }

    // The user changed the text of the field of the ignore list.
    package func editIgnore(_ text: String) {
        model.editDraft(
            Self.ignoreDraftID, row: ReviewsSettingsRow.ignore.row, text: text,
            save: Self.ignoreSave(model))
    }

    // Enter or Add: save the text of the field now. nil: the field has nothing to save, its save
    // runs, or the entry is refused before a save starts (SettingsModel.saveDraft(_:)).
    @discardableResult
    package func addIgnore() -> Task<Bool, Never>? {
        model.saveDraft(Self.ignoreDraftID)
    }

    @discardableResult
    package func removeIgnore(_ entry: String) -> Task<Bool, Never> {
        model.save(ReviewsSettingsRow.ignore.row) { $0.reviewsIgnore.removeAll { $0 == entry } }
    }

    // What the text of the field saves: the entry in its clean form at the end of the list, or
    // the reason of IgnoreRule.refusal for the list of now. When an earlier save gave the newest
    // list the entry, or filled it, the check of the settings refuses the edit.
    package static func ignoreSave(_ model: SettingsModel) -> (String) -> TextSave {
        { [store = model.store] text in
            let list = store.settings.reviewsIgnore.compactMap(IgnoreEntry.init)
            if let reason = IgnoreRule.refusal(text, list: list) { return .refused(reason) }
            guard let entry = IgnoreEntry(text) else { return .refused(IgnoreRule.badEntry) }
            return .edit { $0.reviewsIgnore.append(entry.text) }
        }
    }

    // MARK: - The view

    package var body: some View {
        let settings = model.store.settings
        let style = PanelStyle(model)
        VStack(alignment: .leading, spacing: 0) {
            confirmedRow(.watch, hint: nil, style)
            confirmedRow(.autoFix, hint: Self.autoFixHint, style)
            confirmedRow(.resolveConflicts, hint: Self.resolveConflictsHint, style)
            // The Fix CI row stays hidden until the CI watcher exists. Its setting, key and
            // consent stay.
            checkRow(.signedCommits, hint: Self.signedCommitsHint, \.reviewsSignedCommits)
            checkRow(.teamRequests, hint: nil, \.reviewsTeamRequests)
            NumberRow(
                model: model, row: ReviewsSettingsRow.maxSessions.row,
                label: ReviewsSettingsRow.maxSessions.rawValue, value: settings.reviewsMaxSessions,
                range: Settings.reviewsMaxSessionsRange, unit: "sessions"
            ) { $0.reviewsMaxSessions = $1 }
            selectRow(.pauseTime, settings.reviewsPauseMinutes, Self.pauseChoices) {
                $0.reviewsPauseMinutes = $1
            }
            selectRow(.pollInterval, settings.reviewsPollMinutes, Self.pollChoices) {
                $0.reviewsPollMinutes = $1
            }
            selectRow(.requestModel, settings.reviewsRequestModel, Self.modelChoices) {
                $0.reviewsRequestModel = $1
            }
            selectRow(.reviewModel, settings.reviewsReviewModel, Self.modelChoices) {
                $0.reviewsReviewModel = $1
            }
            ignoreRow(settings.reviewsIgnore, style)
            RemoveClonesRow(section: self, style: style)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // A check box whose turn-on asks first. The box shows the saved value until the change saves.
    // With no confirm dialog, an Off box cannot turn on.
    private func confirmedRow(_ setting: Confirmed, hint: String?, _ style: PanelStyle)
        -> some View
    {
        let isOn = model.store.settings[keyPath: setting.setting]
        let label = setting.row.rawValue
        return SettingRow(model: model, row: setting.row.row, label: label, hint: hint) {
            Toggle(
                isOn: Binding(
                    get: { isOn }, set: { value in Task { await change(setting, to: value) } })
            ) {
                Text(isOn ? "On" : "Off")
            }
            .toggleStyle(BifrostCheckboxStyle(metrics: style.metrics))
            .fixedSize()
            .disabled(!isOn && model.links.confirm == nil)
            .accessibilityLabel(label)
        }
    }

    private func checkRow(
        _ row: ReviewsSettingsRow, hint: String?, _ setting: WritableKeyPath<Settings, Bool>
    ) -> some View {
        CheckRow(
            model: model, row: row.row, label: row.rawValue, hint: hint,
            isOn: model.store.settings[keyPath: setting], set: { $0[keyPath: setting] = $1 })
    }

    private func selectRow<Value: Hashable>(
        _ row: ReviewsSettingsRow, _ value: Value, _ choices: [RowChoice<Value>],
        set: @escaping (inout Settings, Value) -> Void
    ) -> some View {
        SelectRow(
            model: model, row: row.row, label: row.rawValue, value: value, choices: choices
        ) { [model] choice in
            model.save(row.row) { set(&$0, choice) }
        }
    }

    // The row of the ignore list: the field with Add at the right of the label, then the entries
    // under it, each with its Remove button. While Save runs the field and Add are off. Add is
    // off when the list is full.
    private func ignoreRow(_ list: [String], _ style: PanelStyle) -> some View {
        let row = ReviewsSettingsRow.ignore
        let full = list.count >= SettingsText.maxReviewsIgnore
        return SettingRow(model: model, row: row.row, label: row.rawValue) {
            SettingsTextField(
                text: { model.draftText(Self.ignoreDraftID) }, label: Self.ignoreFieldLabel,
                placeholder: Self.ignorePlaceholder, enabled: !model.isSaving,
                font: style.nsFont, onChange: { editIgnore($0) }, onEnter: { addIgnore() }
            )
            .fieldLook(style, width: 176)
            Button("Add") { addIgnore() }
                .buttonStyle(DialogButtonStyle(style: style))
                .disabled(model.isSaving || full)
        } detail: {
            ForEach(list, id: \.self) { entry in
                ignoreEntry(entry, style)
            }
        }
    }

    // One entry of the ignore list with its Remove button.
    private func ignoreEntry(_ entry: String, _ style: PanelStyle) -> some View {
        HStack(spacing: style.points(4)) {
            Text(entry)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                removeIgnore(entry)
            } label: {
                ButtonIcon(icon: .x, size: style.points(14))
                    .frame(width: style.points(20), height: style.points(20))
            }
            .buttonStyle(IconButtonStyle(style: style))
            .accessibilityLabel("Remove \(entry)")
            .background(TipAnchor(text: "Remove", side: .top))
        }
        .padding(.horizontal, style.points(12))
        .frame(minHeight: style.points(28))
        .overlay(alignment: .top) {
            Rectangle().fill(style.edge).frame(height: style.points(1)).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry)
    }
}

// The row of Remove all clones: its button asks first. The button is off while the confirm or
// the removal runs.
private struct RemoveClonesRow: View {
    let section: ReviewsSection
    let style: PanelStyle
    @State private var busy = false

    var body: some View {
        let row = ReviewsSettingsRow.removeClones
        SettingRow(
            model: section.model, row: row.row, label: row.rawValue,
            hint: ReviewsSection.removeClonesHint
        ) {
            Button(ReviewsSection.removeClonesButton) {
                busy = true
                Task {
                    await section.removeClones()
                    busy = false
                }
            }
            .buttonStyle(DialogButtonStyle(style: style))
            .disabled(busy || section.model.links.confirm == nil)
        }
    }
}
