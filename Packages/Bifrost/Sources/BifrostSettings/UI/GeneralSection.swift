// Settings > General (docs/behaviour/settings.md, "The sections"): one row for each row of
// GeneralRow, in that order, each with its label, its control and its hint. A check box, a
// choice and a menu save at once. A text field saves when its edit ends (DraftField). Each save
// goes through the model (SettingsModel.save), so a refusal shows on its row.
//
// Two rows show values that the settings file does not keep. Display mode asks the window for its
// mode. Start at login shows why the last change of the login item failed, with a button to the
// Login Items of System Settings when macOS waits for the approval of the user.
//
// The section finds the installed apps of its two app selects when it shows, and again after each
// change of the Terminal app (SettingsModel.findApps()).
//
// With no search, the notice about the version of Claude Code shows above the rows when the model
// has one (SettingsModel.versionNotice, from the live model), and the last line is the version of
// the app, "Bifrost 0.0.1" (SettingsLinks.appVersion).
import BifrostFoundation
import BifrostLayout
import BifrostLook
import BifrostSessions
import Foundation
import SwiftUI

// The installed apps of the two app selects of General.
package struct GeneralApps: Sendable, Equatable {
    // Each installed terminal app, in the terminal order (TerminalAppID).
    package var terminals: [ProjectApp]
    // The installed apps of Open project: Finder, VS Code, Zed and one terminal app. The select
    // does not offer Finder (Settings.projectAppChoices).
    package var projectApps: [ProjectApp]

    package init(terminals: [ProjectApp] = [], projectApps: [ProjectApp] = []) {
        self.terminals = terminals
        self.projectApps = projectApps
    }

    // The installed apps in the home for a Terminal app setting. exists checks a path, so the
    // find reads the file system.
    package static func find(
        home: URL, terminal: TerminalAppID?, exists: (String) -> Bool
    ) -> GeneralApps {
        GeneralApps(
            terminals: ProjectApps.terminals(home: home, exists: exists).map(\.app),
            projectApps: ProjectApps.projectApps(home: home, exists: exists, terminal: terminal)
                .map(\.app))
    }
}

// The text under the Start at login row when the last change of the login item failed.
package struct LoginItemNote: Equatable {
    package var text: String
    // True when the row has the button that opens the Login Items of System Settings.
    package var opensSettings: Bool
}

package struct GeneralSection: View {
    let model: SettingsModel

    package init(model: SettingsModel) {
        self.model = model
    }

    // The rows, in their order. The last row, Introduction, opens the Setup dialog again.
    package static let rows = GeneralRow.allCases

    // MARK: - The texts

    package static let autoTerminal = "Automatic (first installed: Warp, Ghostty, iTerm2, Terminal)"
    package static let autoProject = "Automatic (VS Code, else Zed, else your terminal app)"
    package static let openLoginItemsText = "Open System Settings"
    // The font families that the menu next to the family field offers.
    package static let fontFamilies = ["SF Mono", "Menlo", "Monaco", "Courier New"]
    package static let labelChoices = [
        RowChoice(LabelSet.plain, "Plain"), RowChoice(.space, "Space"),
    ]
    package static let displayChoices = [
        RowChoice(DisplayMode.window, "Window"), RowChoice(.borderless, "Borderless"),
        RowChoice(.fullscreen, "Fullscreen"),
    ]

    // The hint under a row, or nil.
    package static func hint(_ row: GeneralRow) -> String? {
        switch row {
        case .accountUsage:
            "Shows usage from all your devices. Bifrost reads your Claude Code login from the "
                + "Keychain. macOS may ask you to allow this."
        case .animatedBackground:
            "Slowly shifting colours behind the panels. Turn it off to save battery."
        default: nil
        }
    }

    // The setting of a row with a check box, or nil for a row with another control.
    package static func checkSetting(_ row: GeneralRow) -> WritableKeyPath<Settings, Bool>? {
        switch row {
        case .rowFlash: \.rowFlash
        case .notifications: \.notifications
        case .redBoxSound: \.redBoxSound
        case .startAtLogin: \.startAtLogin
        case .accountUsage: \.accountUsage
        case .animatedBackground: \.animatedBackground
        default: nil
        }
    }

    package static func pollText(_ seconds: Int) -> String {
        seconds == 1 ? "1 second" : "\(seconds) seconds"
    }

    package static func transparencyText(_ percent: Int) -> String {
        percent == 0 ? "0% (solid)" : "\(percent)%"
    }

    package static func scaleText(_ percent: Int) -> String { "\(percent)%" }

    // The text of a saved app that is not installed.
    package static func notInstalled(_ app: ProjectAppID) -> String {
        "\(app.name) (not installed)"
    }

    // MARK: - The choices

    private var settings: Settings { model.store.settings }

    // The choices of the Terminal app select: Automatic, then each installed terminal app, then
    // the saved app when it is not in the list (savedText).
    package var terminalChoices: [RowChoice<TerminalAppID?>] {
        var list = [RowChoice<TerminalAppID?>(nil, Self.autoTerminal)]
        for app in model.apps?.terminals ?? [] {
            if let terminal = app.id.terminal { list.append(RowChoice(terminal, app.label)) }
        }
        if let saved = settings.terminalApp, !list.contains(where: { $0.value == saved }) {
            list.append(RowChoice(saved, savedText(ProjectAppID(terminal: saved))))
        }
        return list
    }

    // The choices of the select of the default app of Open project: Automatic, then each app of
    // Open project but Finder, then the saved app when it is not in the list (savedText). The
    // list has only the chosen terminal app, so a saved terminal app can be installed and not in
    // the list. A saved Finder shows as Automatic (shownProjectApp).
    package var projectChoices: [RowChoice<ProjectAppID?>] {
        var list = [RowChoice<ProjectAppID?>(nil, Self.autoProject)]
        let apps = Settings.projectAppChoices(model.apps?.projectApps ?? [])
        list += apps.map { RowChoice($0.id, $0.label) }
        if let saved = shownProjectApp, !list.contains(where: { $0.value == saved }) {
            list.append(RowChoice(saved, savedText(saved)))
        }
        return list
    }

    // The value that the select of the default app of Open project shows.
    package var shownProjectApp: ProjectAppID? { settings.shownProjectApp }

    // The text of a saved app that is not in its list: its name when it is installed, or before
    // the first find, else its name with "(not installed)".
    private func savedText(_ app: ProjectAppID) -> String {
        guard let apps = model.apps else { return app.name }
        let installed = (apps.terminals + apps.projectApps).contains { $0.id == app }
        return installed ? app.name : Self.notInstalled(app)
    }

    // The last line of the section: the version of the app, or "Bifrost" with no version. nil
    // during a search.
    package var versionLine: String? {
        guard model.hits == nil else { return nil }
        return model.links.appVersion.map { "Bifrost \($0)" } ?? "Bifrost"
    }

    // The notice about the version of Claude Code above the rows, or nil. nil during a search.
    package var notice: String? {
        model.hits == nil ? model.versionNotice : nil
    }

    // The text under the Start at login row, or nil.
    package var loginItemNote: LoginItemNote? {
        model.links.loginItemProblem().map {
            LoginItemNote(text: $0.message, opensSettings: $0 == .needsApproval)
        }
    }

    // MARK: - The changes

    // Each change of a setting saves through the model. The task gives true when the save worked.
    @discardableResult
    package func setCheck(_ row: GeneralRow, _ on: Bool) -> Task<Bool, Never>? {
        guard let setting = Self.checkSetting(row) else { return nil }
        return model.save(.general(row)) { $0[keyPath: setting] = on }
    }

    @discardableResult
    package func choose(labels: LabelSet) -> Task<Bool, Never> {
        model.save(.general(.labels)) { $0.labels = labels }
    }

    @discardableResult
    package func choose(terminalApp: TerminalAppID?) -> Task<Bool, Never> {
        model.save(.general(.terminalApp)) { $0.terminalApp = terminalApp }
    }

    @discardableResult
    package func choose(projectApp: ProjectAppID?) -> Task<Bool, Never> {
        model.save(.general(.projectApp)) { $0.projectApp = projectApp }
    }

    @discardableResult
    package func choose(poll seconds: Int) -> Task<Bool, Never> {
        model.save(.general(.poll)) { $0.pollSeconds = seconds }
    }

    @discardableResult
    package func choose(transparency percent: Int) -> Task<Bool, Never> {
        model.save(.general(.transparency)) { $0.panelTransparency = percent }
    }

    @discardableResult
    package func choose(scale percent: Int) -> Task<Bool, Never> {
        model.save(.general(.scale)) { $0.interfaceScale = percent }
    }

    // A family of the menu. The edit of the focused field ends first, so a draft of the family
    // field saves before the pick and cannot replace it at a later blur.
    @discardableResult
    package func choose(fontFamily family: String) -> Task<Bool, Never> {
        model.endEditing()
        return model.save(.general(.font)) { $0.terminalFont.family = family }
    }

    // The display mode is not a setting: the window changes its mode, and the row follows it.
    package func choose(displayMode mode: DisplayMode) {
        model.links.requestDisplayMode(mode)
    }

    package func openLoginItems() {
        model.links.openLoginItems()
    }

    // What the text of the font family field saves: the trimmed family, or the reason.
    package static func saveFamily(_ text: String) -> TextSave {
        do throws(SettingsRefusal) {
            let family = try SettingsText.checkFontFamily(text)
            return .edit { $0.terminalFont.family = family }
        } catch {
            return .refused(error.message)
        }
    }

    // What the text of the font size field saves: a whole number of points in the range.
    package static func saveSize(_ text: String) -> TextSave {
        NumberRow.save(text, range: Settings.fontSizeRange) { $0.terminalFont.size = $1 }
    }

    // MARK: - The view

    package var body: some View {
        let style = PanelStyle(model)
        VStack(alignment: .leading, spacing: 0) {
            if let notice {
                Text(notice)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, style.points(12))
                    .padding(.vertical, style.points(8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(style.edge).frame(height: style.points(1))
                    }
            }
            ForEach(Self.rows, id: \.self) { row in
                rowView(row)
            }
            if let versionLine {
                Text(versionLine)
                    .foregroundStyle(style.dim)
                    .padding(.horizontal, style.points(12))
                    .padding(.vertical, style.points(8))
            }
        }
        .task(id: settings.terminalApp) { await model.findApps() }
    }

    // The view of a row. Each row has the raw value of its GeneralRow as its label.
    @ViewBuilder
    private func rowView(_ row: GeneralRow) -> some View {
        let id = SettingsRowID.general(row)
        let label = row.rawValue
        switch row {
        case .labels:
            SettingRow(model: model, row: id, label: label) {
                ChoiceButtons(
                    model: model, label: label, value: settings.labels,
                    choices: Self.labelChoices, choose: { choose(labels: $0) })
            }
        case .terminalApp:
            SelectRow(
                model: model, row: id, label: label, value: settings.terminalApp,
                choices: terminalChoices, choose: { choose(terminalApp: $0) })
        case .projectApp:
            SelectRow(
                model: model, row: id, label: label, value: shownProjectApp,
                choices: projectChoices, choose: { choose(projectApp: $0) })
        case .escalation:
            NumberRow(
                model: model, row: id, label: label, value: settings.escalationMinutes,
                range: Settings.escalationRange, unit: "minutes (0 turns escalation off)"
            ) { $0.escalationMinutes = $1 }
        case .startAtLogin:
            CheckRow(model: model, row, \.startAtLogin) {
                LoginItemNoteView(model: model, note: loginItemNote, open: openLoginItems)
            }
        case .rowFlash, .notifications, .redBoxSound, .accountUsage, .animatedBackground:
            if let setting = Self.checkSetting(row) {
                CheckRow(model: model, row, hint: Self.hint(row), setting)
            }
        case .poll:
            SelectRow(
                model: model, row: id, label: label, value: settings.pollSeconds,
                choices: Settings.pollChoices.map { RowChoice($0, Self.pollText($0)) },
                choose: { choose(poll: $0) })
        case .snap:
            NumberRow(
                model: model, row: id, label: label, value: settings.snapDistance,
                range: Settings.snapRange, unit: "pixels"
            ) { $0.snapDistance = $1 }
        case .transparency:
            SelectRow(
                model: model, row: id, label: label, value: settings.panelTransparency,
                choices: ThemeTokens.transparencyChoices.map {
                    RowChoice($0, Self.transparencyText($0))
                },
                choose: { choose(transparency: $0) })
        case .scale:
            SelectRow(
                model: model, row: id, label: label, value: settings.interfaceScale,
                choices: CanvasMetrics.scaleChoices.map { RowChoice($0, Self.scaleText($0)) },
                choose: { choose(scale: $0) })
        case .font:
            SettingRow(model: model, row: id, label: label) { fontControls(id) }
        case .displayMode:
            SettingRow(model: model, row: id, label: label) {
                ChoiceButtons(
                    model: model, label: label, value: model.links.displayMode(),
                    choices: Self.displayChoices, choose: { choose(displayMode: $0) })
            }
        case .introduction:
            IntroRow(model: model)
        }
    }

    // The family field with the menu of common families, and the size field with its unit.
    @ViewBuilder
    private func fontControls(_ id: SettingsRowID) -> some View {
        let style = PanelStyle(model)
        let font = settings.terminalFont
        DraftField(
            model: model, row: id, label: "Terminal font family", saved: font.family, width: 144,
            save: Self.saveFamily)
        Menu {
            ForEach(Self.fontFamilies, id: \.self) { family in
                Button(family) { choose(fontFamily: family) }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: style.points(9), weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // The menu is a part of the family field, so it is off while Save runs, as the text
        // fields are. The check boxes and the menus of the other rows stay on: the tracker counts
        // each of their saves, and Save waits for it.
        .disabled(model.isSaving)
        .accessibilityLabel("Font families")
        DraftField(
            model: model, row: id, label: "Terminal font size", saved: String(font.size),
            width: 56, save: Self.saveSize)
        Text("pt").foregroundStyle(style.dim)
    }
}

// The text under the Start at login row when the last change of the login item failed. A login
// item that waits for the approval of the user gets the button that opens the Login Items of
// System Settings.
private struct LoginItemNoteView: View {
    let model: SettingsModel
    let note: LoginItemNote?
    let open: () -> Void

    var body: some View {
        if let note {
            let style = PanelStyle(model)
            HStack(alignment: .firstTextBaseline, spacing: style.points(8)) {
                Text(note.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if note.opensSettings {
                    Button(GeneralSection.openLoginItemsText, action: open)
                        .buttonStyle(DialogButtonStyle(style: style))
                }
            }
            .padding(.horizontal, style.points(12))
            .padding(.bottom, style.points(4))
        }
    }
}
