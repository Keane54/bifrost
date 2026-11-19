// Settings > Slash commands (docs/behaviour/settings.md, "The slash list"): the list of the slash
// commands that the Slash commands menu of a session shows, with Move up, Move down and Remove for
// each command, and the field for a new command. Each change saves through the model
// (SettingsModel.save), so the save tracker counts it and a refusal shows on its row.
//
// The list and the field are two rows of the save tracker. The field holds a draft: Enter and Add
// save it at once, and Save saves it too. A refused command shows its reason on the row of the
// field, so a good save of the list, for example Move up, does not clear that reason.
//
// During a search the section shows only the commands that match. The text above the list, the
// empty line and the field show only with the whole section.
import BifrostLook
import SwiftUI

package struct SlashSection: View {
    let model: SettingsModel
    // The match of the section during a search, or nil.
    let hit: SearchHit?

    package init(model: SettingsModel, hit: SearchHit?) {
        self.model = model
        self.hit = hit
    }

    // The row of the list. It shows with each match of the section.
    nonisolated package static let listRow = SettingsRowID(.slash, .withHit("list"))
    // The row of the field for a new command. It shows only with the whole section.
    nonisolated package static let newRow = SettingsRowID(.slash, .wholeSection("new"))
    // The ID of the draft of the field.
    nonisolated package static let draftID = 1

    nonisolated package static let intro =
        "These commands show in the Slash commands menu of a session. Put the ones you use most "
        + "at the top."
    nonisolated package static let emptyText = "No commands yet."
    nonisolated package static let fieldLabel = "New slash command"
    nonisolated package static let placeholder = "/command"

    // True when the whole section shows: with no search, or when the query matches its title.
    private var whole: Bool { hit?.whole ?? true }

    // The commands that show, in the order of the list. The search finds a command by its text.
    package var shown: [String] {
        let list = model.store.settings.slashCommands
        guard let hit, !hit.whole else { return list }
        return list.filter { hit.rows.contains($0) }
    }

    // True when the line "No commands yet." shows.
    package var showsEmptyText: Bool {
        whole && model.store.settings.slashCommands.isEmpty
    }

    // MARK: - The changes

    // Move the command up (-1) or down (1). The edit finds the command in the newest list, so an
    // earlier save that changed the list does not move another command.
    @discardableResult
    package func move(_ command: String, by step: Int) -> Task<Bool, Never> {
        model.save(Self.listRow) { settings in
            guard let index = settings.slashCommands.firstIndex(of: command) else { return }
            settings.slashCommands = SlashList.move(settings.slashCommands, at: index, by: step)
        }
    }

    @discardableResult
    package func remove(_ command: String) -> Task<Bool, Never> {
        model.save(Self.listRow) { settings in
            guard let index = settings.slashCommands.firstIndex(of: command) else { return }
            settings.slashCommands = SlashList.remove(settings.slashCommands, at: index)
        }
    }

    // The user changed the text of the field.
    package func edit(_ text: String) {
        model.editDraft(Self.draftID, row: Self.newRow, text: text, save: Self.draftSave(model))
    }

    // Enter or Add: save the text of the field now. nil: the field has nothing to save, its save
    // runs, or the command is refused before a save starts (SettingsModel.saveDraft(_:)).
    @discardableResult
    package func add() -> Task<Bool, Never>? {
        model.saveDraft(Self.draftID)
    }

    // What the text of the field saves: the trimmed command at the end of the list, or the
    // reason of SlashList.add for the list of now. The edit adds the command to the newest list.
    // When an earlier save gave that list the command, or filled it, the check of the settings
    // refuses the edit (Settings.validated()), so the command is never in the list two times.
    package static func draftSave(_ model: SettingsModel) -> (String) -> TextSave {
        { [store = model.store] text in
            switch SlashList.add(store.settings.slashCommands, text) {
            case .failure(let refusal):
                return .refused(refusal.message)
            case .success(let list):
                let command = list.last ?? text
                return .edit { $0.slashCommands.append(command) }
            }
        }
    }

    // MARK: - The view

    package var body: some View {
        let style = PanelStyle(model)
        let list = model.store.settings.slashCommands
        VStack(alignment: .leading, spacing: 0) {
            if whole {
                Text(Self.intro)
                    .foregroundStyle(style.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, style.points(12))
                    .padding(.vertical, style.points(8))
            }
            ForEach(shown, id: \.self) { command in
                commandRow(command, list: list, style)
            }
            if showsEmptyText {
                Text(Self.emptyText)
                    .foregroundStyle(style.dim)
                    .padding(.horizontal, style.points(12))
                    .padding(.vertical, style.points(4))
            }
            ErrorLine(model: model, row: Self.listRow)
            if model.isShown(Self.newRow) {
                field(full: list.count >= SettingsText.maxSlashCommands, style)
                ErrorLine(model: model, row: Self.newRow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // One command with its three buttons. The first command cannot move up, and the last one
    // cannot move down.
    private func commandRow(_ command: String, list: [String], _ style: PanelStyle)
        -> some View
    {
        let index = list.firstIndex(of: command)
        return HStack(spacing: style.points(4)) {
            Text(command)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            iconButton("chevron.up", "Move up", disabled: index == list.startIndex, style) {
                move(command, by: -1)
            }
            iconButton("chevron.down", "Move down", disabled: index == list.endIndex - 1, style) {
                move(command, by: 1)
            }
            iconButton("xmark", "Remove", disabled: false, style) { remove(command) }
        }
        .padding(.horizontal, style.points(12))
        .frame(minHeight: style.points(28))
        .overlay(alignment: .bottom) {
            Rectangle().fill(style.edge).frame(height: style.points(1)).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(command)
        .preference(key: SettingRowLabels.self, value: [command])
    }

    private func iconButton(
        _ symbol: String, _ label: String, disabled: Bool, _ style: PanelStyle,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: style.points(10), weight: .semibold))
                .frame(width: style.points(20), height: style.points(20))
        }
        .buttonStyle(IconButtonStyle(style: style))
        .disabled(disabled)
        .accessibilityLabel(label)
        .help(label)
    }

    // The field for a new command, with Add. Enter adds too. While Save runs the field and Add
    // are off. Add is off when the list is full.
    private func field(full: Bool, _ style: PanelStyle) -> some View {
        HStack(spacing: style.points(8)) {
            SettingsTextField(
                text: { model.draftText(Self.draftID) }, label: Self.fieldLabel,
                placeholder: Self.placeholder, enabled: !model.isSaving, font: style.nsFont,
                onChange: { edit($0) }, onEnter: { add() }
            )
            .fieldLook(style, width: nil)
            Button("Add") { add() }
                .buttonStyle(DialogButtonStyle(style: style))
                .disabled(model.isSaving || full)
        }
        .padding(.horizontal, style.points(12))
        .padding(.vertical, style.points(8))
    }
}
