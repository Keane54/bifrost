// Settings > Keys (docs/behaviour/keys.md, "Changing a key"): the key groups in order, each row
// with the label of its slot, a mark when the user changed the key, the key or "No key", and
// Change, Clear and Reset. Change starts the key recorder on the row. Above the groups are Reset
// all keys, which asks first and is off until the shell links the confirm dialog, and the error
// of the section when it does not show on a row.
//
// Each save of the section goes through the model (SettingsModel.save) as one row of the save
// tracker (row), so the saves of the section share one error. The error shows on the row of the
// slot of the last save (SettingsModel.keyErrorSlot). It shows at the top of the section after
// Reset all keys, and when the search hides the row of that slot. So a failed save never keeps
// Settings open with no error on the screen.
//
// A save of a key edits the newest keys of the store, and only the changed slot gets a new entry
// (KeyChanges.stored(keeping:)). So each other entry stays, also an entry that this version
// cannot read. The row of a slot whose entry this version cannot read shows the default key, so
// its Reset is off, and a Reset of it changes nothing. Reset all keys keeps those entries too
// (KeyEditor.resetAll(keeping:)).
//
// The recorder (KeyRecorderView) shows only under the row that records (SettingsModel
// .recording). The row state is set first, then the recorder joins the window and starts. A
// Change of another row moves the state to that row: the old recorder leaves the window and ends,
// and a new one starts. A recorded key goes through KeyEditor.checkRecorded against the keys of
// store.settings. A refused key shows its reason under the prompt and the recording goes on. A
// good key saves, and the recorder ends.
import AppKit
import BifrostKeyboard
import BifrostLook
import BifrostSessions
import SwiftUI

package struct KeysSection: View {
    let model: SettingsModel
    // The match of the section during a search, or nil.
    let hit: SearchHit?

    package init(model: SettingsModel, hit: SearchHit?) {
        self.model = model
        self.hit = hit
    }

    // The one row of the save tracker for the saves of the section. It shows with each match of
    // the section.
    nonisolated package static let row = SettingsRowID(.keys, .withHit("keys"))

    nonisolated package static let intro =
        "You can't record Esc or a plain Backspace, because the recorder uses them. Reset brings "
        + "back the default key."
    nonisolated package static let prompt = "Press the new shortcut. Esc cancels."
    nonisolated package static let noKey = "No key"
    nonisolated package static let resetAllConfirm = ConfirmText(
        title: "Reset all keys", body: "This puts every key back to its Bifrost default.",
        confirm: "Reset all keys")

    // True when the whole section shows: with no search, or when the query matches its title.
    private var whole: Bool { hit?.whole ?? true }

    // True when the row of the slot shows. The search finds a row by the stored ID of its slot.
    package func shows(_ slot: KeySlot) -> Bool {
        whole || hit?.rows.contains(slot.text) == true
    }

    // The groups that show, in the order of SlotGroup, each with its rows that show. During a
    // search a group with no row that shows does not show.
    package var groups: [KeyRowGroup] {
        let settings = model.store.settings
        let all = KeyEditor.groups(KeyChanges(stored: settings.keys), settings.labels)
        guard !whole else { return all }
        return all.compactMap { group in
            var shown = group
            shown.rows = group.rows.filter { shows($0.slot) }
            return shown.rows.isEmpty ? nil : shown
        }
    }

    // True when the error of the section shows at the top: after Reset all keys, or when the
    // search hides the row of the slot of the last save.
    package var errorAtTop: Bool {
        guard let slot = model.keyErrorSlot else { return true }
        return !shows(slot)
    }

    // The text of the key of a row: the modifier symbols in the order of the macOS menus, then
    // the key, with a space between the parts (Chord.shown), or "No key" for Off.
    package static func keyText(_ binding: KeyBinding) -> String {
        binding.chord?.shown ?? noKey
    }

    // Change and Reset all keys are off while Save runs: a recording or the confirm dialog
    // during the wait could save after Settings closed.
    package var canChange: Bool { !model.isSaving }

    // Reset all keys asks first, so it is off while the model has no confirm dialog
    // (SettingsLinks.confirm), and while Save runs.
    package var canResetAll: Bool { canChange && model.links.confirm != nil }

    // Clear is off for a row that has no key. It stays on while Save runs: the tracker counts its
    // save, and Save waits for it.
    package func canClear(_ row: KeyRow) -> Bool { row.binding != .off }

    // Reset is off for a row with its default key, also a row whose entry this version cannot
    // read. It stays on while Save runs, as Clear does.
    package func canReset(_ row: KeyRow) -> Bool { row.changed }

    // MARK: - The changes

    // Change: the recorder starts on the row of the slot. The refusal of an earlier key goes.
    package func startRecording(_ slot: KeySlot) {
        model.recording = SettingsModel.Recording(slot: slot)
    }

    // A key that the recorder of the slot recorded. It is checked against the keys of
    // store.settings. A refused key gives its reason and no save. nil: the key is refused.
    @discardableResult
    package func record(_ event: KeyEvent, for slot: KeySlot) -> Task<Bool, Never>? {
        let settings = model.store.settings
        switch KeyEditor.checkRecorded(event, slot: slot, old: KeyMap(stored: settings.keys)) {
        case .failure(let refusal):
            setRefusal(refusal.message(labels: settings.labels), of: slot)
            return nil
        case .success(let chord):
            setRefusal(nil, of: slot)
            return save(slot) { $0.set(.chord(chord), for: slot) }
        }
    }

    // The recording of the slot ended. A recording of another slot that started since then
    // stays.
    package func recordingEnded(_ slot: KeySlot) {
        guard model.recording?.slot == slot else { return }
        model.recording = nil
    }

    // The refusal of the last key of the recording of the slot. A recording of another slot keeps
    // its own refusal.
    private func setRefusal(_ refusal: String?, of slot: KeySlot) {
        guard model.recording?.slot == slot else { return }
        model.recording?.refusal = refusal
    }

    // Clear: the slot has no key.
    @discardableResult
    package func clear(_ slot: KeySlot) -> Task<Bool, Never> {
        save(slot) { $0.set(.off, for: slot) }
    }

    // Reset: the slot gets its default key again.
    @discardableResult
    package func reset(_ slot: KeySlot) -> Task<Bool, Never> {
        save(slot) { $0.reset(slot) }
    }

    // Reset all keys: after the user confirms, each slot gets its default key. True when the
    // reset saved. False with no confirm dialog, when the user did not confirm, or when the save
    // failed.
    package func resetAll() async -> Bool {
        guard let confirm = model.links.confirm, await confirm(Self.resetAllConfirm) else {
            return false
        }
        model.keyErrorSlot = nil
        return await model.save(Self.row) { $0.keys = KeyEditor.resetAll(keeping: $0.keys) }.value
    }

    // Save a change of the keys of the slot. The change edits the newest keys. A change that
    // gives the keys that the settings have already changes nothing, so the store writes
    // nothing.
    private func save(
        _ slot: KeySlot, _ change: @escaping (inout KeyChanges) -> Void
    ) -> Task<Bool, Never> {
        model.keyErrorSlot = slot
        return model.save(Self.row) { settings in
            let before = KeyChanges(stored: settings.keys)
            var after = before
            change(&after)
            guard after != before else { return }
            settings.keys = after.stored(keeping: settings.keys)
        }
    }

    // MARK: - The view

    package var body: some View {
        let style = PanelStyle(model)
        VStack(alignment: .leading, spacing: 0) {
            if whole { header(style) }
            if errorAtTop { ErrorLine(model: model, row: Self.row) }
            ForEach(groups, id: \.group) { group in
                Text(group.title)
                    .foregroundStyle(style.dim)
                    .lineLimit(1)
                    .padding(.horizontal, style.points(12))
                    .padding(.vertical, style.points(4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ThemeTokens.title.color)
                    .overlay(alignment: .top) { edge(style) }
                    .overlay(alignment: .bottom) { edge(style) }
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.rows, id: \.slot) { row in
                    keyRow(row, style)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The text about the keys of the recorder, with Reset all keys.
    private func header(_ style: PanelStyle) -> some View {
        HStack(alignment: .top, spacing: style.points(12)) {
            Text(Self.intro)
                .foregroundStyle(style.dim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(Self.resetAllConfirm.confirm) { Task { await resetAll() } }
                .buttonStyle(DialogButtonStyle(style: style))
                .disabled(!canResetAll)
        }
        .padding(.horizontal, style.points(12))
        .padding(.vertical, style.points(8))
    }

    // One row: the label, the mark of a changed key, the key, and Change, Clear and Reset. Under
    // them the prompt with the recorder and the refusal while the row records, and the error of
    // the section when it belongs to this row. A narrow frame cuts the label, and its tooltip
    // shows the full label.
    private func keyRow(_ row: KeyRow, _ style: PanelStyle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: style.points(8)) {
                Text(row.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(row.label)
                if row.changed {
                    Rectangle()
                        .fill(ThemeTokens.textStrong.color)
                        .frame(width: style.points(6), height: style.points(6))
                        .accessibilityHidden(true)
                }
                Text(Self.keyText(row.binding))
                    .foregroundStyle(row.binding == .off ? style.dim : ThemeTokens.text.color)
                    .lineLimit(1)
                    .fixedSize()
                Button("Change") { startRecording(row.slot) }
                    .disabled(!canChange)
                Button("Clear") { clear(row.slot) }
                    .disabled(!canClear(row))
                Button("Reset") { reset(row.slot) }
                    .disabled(!canReset(row))
            }
            .buttonStyle(DialogButtonStyle(style: style))
            .padding(.horizontal, style.points(12))
            .frame(minHeight: style.points(28))
            if model.recording?.slot == row.slot {
                prompt(row.slot, style)
            }
            if model.keyErrorSlot == row.slot && !errorAtTop {
                ErrorLine(model: model, row: Self.row)
            }
        }
        .overlay(alignment: .bottom) { edge(style) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.label)
        .preference(key: SettingRowLabels.self, value: [row.label])
    }

    // The prompt of the row that records, with the recorder behind it, and the reason of the last
    // refused key.
    private func prompt(_ slot: KeySlot, _ style: PanelStyle) -> some View {
        VStack(alignment: .leading, spacing: style.points(4)) {
            Text(Self.prompt)
                .foregroundStyle(ThemeTokens.textStrong.color)
                .padding(.horizontal, style.points(6))
                .padding(.vertical, style.points(2))
                .overlay {
                    Rectangle()
                        .strokeBorder(
                            ThemeTokens.textStrong.color.opacity(0.3), lineWidth: style.points(1))
                        .accessibilityHidden(true)
                }
                .background(
                    RecorderBox(
                        onKey: { event, recorder in
                            if record(event, for: slot) != nil { recorder.cancel() }
                        },
                        onEnd: { recordingEnded(slot) }))
            if let refusal = model.recording?.refusal {
                Text(refusal)
                    .foregroundStyle(style.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, style.points(12))
        .padding(.bottom, style.points(4))
    }

    private func edge(_ style: PanelStyle) -> some View {
        Rectangle().fill(style.edge).frame(height: style.points(1)).accessibilityHidden(true)
    }
}

// The key recorder of the row that records. It starts when it joins the window. onKey gets each
// recorded key with the recorder, so the section can end the recording after a good key.
private struct RecorderBox: NSViewRepresentable {
    let onKey: (KeyEvent, KeyRecorderView) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> KeyRecorderView {
        let recorder = KeyRecorderView(frame: .zero)
        recorder.beginsInWindow = true
        apply(to: recorder)
        return recorder
    }

    func updateNSView(_ recorder: KeyRecorderView, context: Context) {
        apply(to: recorder)
    }

    private func apply(to recorder: KeyRecorderView) {
        recorder.onKey = { [weak recorder, onKey] event in
            guard let recorder else { return }
            onKey(event, recorder)
        }
        recorder.onEnd = onEnd
    }
}
