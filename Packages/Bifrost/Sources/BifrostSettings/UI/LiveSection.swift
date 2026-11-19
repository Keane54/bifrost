// Settings > Live details (docs/behaviour/live.md, "Settings > Live details"): the state line,
// the buttons, the steps before Install, the notes, the error of the last action and the version
// of Claude Code. The values come from the live model (SettingsModel.live), and each button acts
// through it. Remove asks first with the confirm dialog of the window (SettingsLinks.confirm),
// and with no confirm dialog Remove is off.
//
// The section reads its status one time for each open of Settings when it shows
// (LiveModel.readOnce(_:)). When it goes away, its error and its steps go.
//
// PluginBlock draws the top part that the Skills section shares: the state line, the text with
// no plugin, the steps of Install with Install and Cancel or the buttons, and the notes.
import BifrostLive
import BifrostLook
import SwiftUI

// What the top part of the Live details or Skills section shows.
package struct PluginContent: Equatable {
    package var stateLine: String
    // The text under the state line while the plugin is not installed, or nil.
    package var without: String?
    // The steps of Install after a click on Install, or nil: then the buttons show.
    package var steps: [String]?
    package var buttons: [LiveActionID]
    package var notes: [String]
    // The text of the last failure, or nil.
    package var error: String?
}

package struct LiveSection: View {
    let model: SettingsModel

    package init(model: SettingsModel) {
        self.model = model
    }

    private var live: LiveModel { model.live }

    // MARK: - What the section shows

    package var content: PluginContent {
        let status = live.status
        let state = live.liveState
        let showsSteps = state.showsSteps && live.notice == .notInstalled
        let steps = showsSteps ? status.map(LiveRules.steps) : nil
        let notes = [
            LiveRules.oldInstallNote(status), LiveRules.liveVersionNote(status),
            state.changed ? LiveTexts.reloadNote : nil,
        ]
        return PluginContent(
            stateLine: live.notice.stateLine,
            without: live.notice == .notInstalled ? LiveTexts.withoutLive : nil, steps: steps,
            buttons: steps == nil ? LiveRules.actions(status) : [], notes: notes.compactMap(\.self),
            error: state.error)
    }

    // The Claude Code line under the state, or nil.
    package var claudeLine: String? { LiveRules.claudeVersionLine(live.version, failed: false) }
    // The notice about the version of Claude Code under that line, or nil.
    package var versionNotice: String? {
        LiveRules.claudeVersionNotice(live.version, failed: false)
    }

    // MARK: - The actions

    @discardableResult
    package func press(_ id: LiveActionID) -> Task<Void, Never> {
        PluginBlock.press(model, .live, id)
    }

    @discardableResult
    package func install() -> Task<Void, Never> {
        PluginBlock.install(model, .live)
    }

    package func cancelInstall() {
        PluginBlock.cancelInstall(model, .live)
    }

    // MARK: - The view

    package var body: some View {
        let style = PanelStyle(model)
        VStack(alignment: .leading, spacing: 0) {
            PluginBlock(model: model, part: .live, content: content)
            ErrorLine(model: model, message: content.error) { live.closeError(.live) }
            VStack(alignment: .leading, spacing: style.points(8)) {
                if let claudeLine {
                    Text(claudeLine).textSelection(.enabled)
                }
                if let versionNotice {
                    Text(versionNotice).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, style.points(12))
            .padding(.vertical, style.points(8))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { live.readOnce(.live) }
        .onDisappear { live.sectionHidden(.live) }
    }
}

// The top part of the Live details and Skills sections, with the edge line under it.
struct PluginBlock: View {
    let model: SettingsModel
    let part: LiveModel.Part
    let content: PluginContent

    // A click on a button of the section. Remove asks first with the confirm dialog.
    @discardableResult
    static func press(_ model: SettingsModel, _ part: LiveModel.Part, _ id: LiveActionID)
        -> Task<Void, Never>
    {
        let confirm = model.links.confirm
        return Task { await model.live.press(id, part, confirm: confirm) }
    }

    // The Install button under the steps of Install. A good install hides the steps.
    @discardableResult
    static func install(_ model: SettingsModel, _ part: LiveModel.Part) -> Task<Void, Never> {
        Task { await model.live.install(part) }
    }

    // The Cancel button under the steps of Install: the buttons show again.
    static func cancelInstall(_ model: SettingsModel, _ part: LiveModel.Part) {
        model.live.cancelInstall(part)
    }

    // True when the button is off: while the section is busy, and Remove with no confirm dialog.
    static func isOff(_ model: SettingsModel, _ part: LiveModel.Part, _ id: LiveActionID) -> Bool {
        model.live.isBusy(part) || (id == .remove && model.links.confirm == nil)
    }

    var body: some View {
        let style = PanelStyle(model)
        let busy = model.live.isBusy(part)
        VStack(alignment: .leading, spacing: 0) {
            Text(content.stateLine)
                .foregroundStyle(ThemeTokens.textStrong.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let without = content.without {
                Text(without)
                    .foregroundStyle(style.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, style.points(4))
            }
            if let steps = content.steps {
                VStack(alignment: .leading, spacing: style.points(4)) {
                    Text(LiveTexts.installLead)
                    StepList(steps: steps, style: style)
                    HStack(spacing: style.points(8)) {
                        Button("Install") { Self.install(model, part) }
                        Button("Cancel") { Self.cancelInstall(model, part) }
                    }
                    .buttonStyle(DialogButtonStyle(style: style))
                    .disabled(busy)
                    .padding(.top, style.points(4))
                }
                .padding(.top, style.points(8))
            } else if !content.buttons.isEmpty {
                HStack(spacing: style.points(8)) {
                    ForEach(content.buttons, id: \.self) { id in
                        Button(id.label) { Self.press(model, part, id) }
                            .disabled(Self.isOff(model, part, id))
                    }
                }
                .buttonStyle(DialogButtonStyle(style: style))
                .padding(.top, style.points(8))
            }
            ForEach(content.notes, id: \.self) { note in
                Text(note)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, style.points(8))
            }
        }
        .padding(.horizontal, style.points(12))
        .padding(.vertical, style.points(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(style.edge).frame(height: style.points(1)).accessibilityHidden(true)
        }
    }
}

// The changes of Install, as a numbered list.
struct StepList: View {
    let steps: [String]
    let style: PanelStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style.points(4)) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: style.points(6)) {
                    Text("\(index + 1).").monospacedDigit()
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
        .padding(.leading, style.points(8))
    }
}
