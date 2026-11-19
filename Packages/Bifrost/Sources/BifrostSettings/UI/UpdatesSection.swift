// Settings > Updates (docs/behaviour/updates.md, "Settings > Updates"): the setting of the
// automatic checks, the version of the app, the time of the last check, Check now and Release
// notes. The updater of the app, Sparkle, shows an update and its progress with its own window,
// so the section has no state line and no Update button. Check now is off unless the updater
// runs (it is off in Bifrost Dev), and the row then says why. The rows come from UpdatesRow, so
// the search finds each row by its label.
import BifrostLook
import Foundation
import SwiftUI

// The values and the actions of the updater that the section needs. The shell gives them
// (SettingsLinks.updates). The default does nothing, so a test that gives no link starts no
// check.
package struct UpdatesLinks {
    // The version of the app (CFBundleShortVersionString), or nil.
    package var version: String?
    package var state: UpdaterState
    // Start a check for updates. Sparkle shows the result.
    package var check: @MainActor () -> Void
    // Open the release notes dialog.
    package var openReleaseNotes: @MainActor () -> Void
    // The time of now, for the text of the last check.
    package var now: @MainActor () -> Date

    @MainActor
    package init(
        version: String? = nil, state: UpdaterState = UpdaterState(),
        check: @escaping @MainActor () -> Void = {},
        openReleaseNotes: @escaping @MainActor () -> Void = {},
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.version = version
        self.state = state
        self.check = check
        self.openReleaseNotes = openReleaseNotes
        self.now = now
    }
}

package struct UpdatesSection: View {
    let model: SettingsModel

    package init(model: SettingsModel) {
        self.model = model
    }

    // The rows, in their order.
    package static let rows = UpdatesRow.allCases

    private var links: UpdatesLinks { model.links.updates }

    // MARK: - What the section shows

    package var versionText: String { UpdatesRows.versionText(links.version) }

    package var lastCheckText: String {
        UpdatesRows.lastCheckText(links.state.lastCheck, now: links.now())
    }

    // True when the button Check now works: the updater runs and no check runs now.
    package var canCheck: Bool { links.state.phase == .idle }

    // The text under Check for updates: the reason of an updater that does not run, the line of a
    // check that runs, else nil.
    package var checkNowReason: String? {
        switch links.state.phase {
        case .off: UpdatesRows.offReason
        case .checking: UpdatesRows.checkingLine
        case .idle: nil
        }
    }

    // MARK: - The actions

    package func checkNow() {
        guard canCheck else { return }
        links.check()
    }

    package func openReleaseNotes() {
        links.openReleaseNotes()
    }

    // MARK: - The view

    package var body: some View {
        let style = PanelStyle(model)
        VStack(alignment: .leading, spacing: 0) {
            CheckRow(
                model: model, row: id(.auto), label: UpdatesRow.auto.rawValue,
                isOn: model.store.settings.autoUpdate, set: { $0.autoUpdate = $1 })
            SettingRow(model: model, row: id(.version), label: UpdatesRow.version.rawValue) {
                Text(versionText).textSelection(.enabled)
            }
            SettingRow(model: model, row: id(.lastCheck), label: UpdatesRow.lastCheck.rawValue) {
                Text(lastCheckText).textSelection(.enabled)
            }
            SettingRow(
                model: model, row: id(.checkNow), label: UpdatesRow.checkNow.rawValue,
                hint: checkNowReason
            ) {
                Button(UpdatesRows.checkNowButton) { checkNow() }
                    .buttonStyle(DialogButtonStyle(style: style))
                    .disabled(!canCheck)
                    .accessibilityLabel(UpdatesRow.checkNow.rawValue)
            }
            SettingRow(
                model: model, row: id(.releaseNotes), label: UpdatesRow.releaseNotes.rawValue
            ) {
                Button(UpdatesRows.releaseNotesButton) { openReleaseNotes() }
                    .buttonStyle(DialogButtonStyle(style: style))
                    .accessibilityLabel(UpdatesRow.releaseNotes.rawValue)
            }
        }
    }

    // The ID of a row: the search finds it by its label.
    private func id(_ row: UpdatesRow) -> SettingsRowID {
        SettingsRowID(.updates, .found(row.rawValue))
    }
}
