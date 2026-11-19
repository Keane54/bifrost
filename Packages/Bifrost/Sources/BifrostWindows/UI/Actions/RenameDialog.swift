// The Rename dialog (docs/behaviour/actions.md, "Rename"): the field "Name in Bifrost", the check
// box "Also rename it in Claude Code", the button "Use the Claude Code name" while the row has a
// local name, the lost note and the reason of a failed save. The dialog reads the row by its ID at
// each step, so the controls follow the row of now. RenameRules gives what each control shows and
// what a save does.
import AppKit
import BifrostFoundation
import BifrostLook
import BifrostSessions
import Observation
import SwiftUI

@MainActor
@Observable
package final class RenameDialogModel {
    package let sessionId: String
    // A new name clears the reason. The field can write the same name again, for example when
    // it gets the focus, and that keeps the reason.
    package var name: String {
        didSet { if name != oldValue { reason = nil } }
    }
    // The check box as the user set it. It counts only while the row can take /rename
    // (RenameRules.effectiveAlsoClaude).
    package var alsoClaude = false {
        didSet { if alsoClaude != oldValue { reason = nil } }
    }
    // The reason why the last save did not work, or nil.
    package private(set) var reason: String?
    // True while a save runs. A save cannot stop, so the dialog stays open until it ends. At the
    // end of a failed save, the name field takes the focus again.
    package private(set) var busy = false
    @ObservationIgnored private weak var runner: ActionRunner?
    // Keeps the focus in the dialog while a save runs and the fields are off.
    @ObservationIgnored private let holdFocus: () -> Void
    @ObservationIgnored private let close: (RenameDialogModel) -> Void

    init(
        sessionId: String, name: String, runner: ActionRunner,
        holdFocus: @escaping () -> Void, close: @escaping (RenameDialogModel) -> Void
    ) {
        self.sessionId = sessionId
        self.name = name
        self.runner = runner
        self.holdFocus = holdFocus
        self.close = close
    }

    // The row of now, or nil when it went.
    package var row: SessionRow? { runner?.row(sessionId) }

    // The title and the save button: "Rename", or "Set callsign" with the space labels.
    package var title: String { ActionID.rename.title(runner?.labels ?? .plain) }

    // The controls for the row of now, or nil when the row went.
    package var controls: RenameControls? { row.map(RenameRules.controls) }

    // The check box shows only for a row that can take /rename now or later.
    package var showsClaudeBox: Bool {
        guard let controls else { return false }
        return controls.claudeBox != .hidden
    }

    // The note when the check box is on but the row cannot take /rename now.
    package var lostNote: String? {
        row.flatMap { RenameRules.lostNote($0, alsoClaude: alsoClaude) }
    }

    // Save. The row can change while the dialog shows, so the save checks the action again.
    // With the check box, the save sends /rename, and the send clears the local name
    // (RenameRules.afterSend). A failed send keeps the local name as it is.
    package func submit() async {
        guard !busy, let runner else { return }
        let state = ActionModel.state(.rename, row, runner.context(sessionId))
        guard state.enabled, let row else {
            reason = state.reason
            return
        }
        let also = RenameRules.effectiveAlsoClaude(row, alsoClaude: alsoClaude)
        let plan: RenamePlan
        switch RenameRules.plan(row, name: name, alsoClaude: also) {
        case .success(let value): plan = value
        case .failure(let refusal):
            reason = refusal.message
            return
        }
        busy = true
        reason = nil
        holdFocus()
        do throws(ActionRefusal) {
            switch plan {
            case .local(let alias):
                try runner.setAlias(sessionId, alias)
            case .claude(let text):
                try await runner.send(sessionId, text)
            }
            close(self)
        } catch {
            reason = error.message
            busy = false
        }
    }

    // Use the Claude Code name: the local name goes.
    package func reset() {
        guard !busy, let runner else { return }
        do throws(ActionRefusal) {
            try runner.setAlias(sessionId, nil)
            close(self)
        } catch {
            reason = error.message
        }
    }

    // Cancel, Esc and a click on the backdrop. A save that runs keeps the dialog open.
    package func cancel() {
        guard !busy else { return }
        close(self)
    }
}

struct RenameDialogView: View {
    @Bindable var model: RenameDialogModel
    let style: PanelStyle
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: style.points(12)) {
            DialogTitle(text: model.title, style: style)
            VStack(alignment: .leading, spacing: style.points(8)) {
                Text(RenameRules.nameFieldLabel)
                    .font(style.font(12))
                    .foregroundStyle(style.dim)
                TextField("", text: $model.name)
                    .focused($focused)
                    .disabled(model.busy)
                    .modifier(DialogFieldStyle(style: style, focused: focused))
                    .accessibilityLabel(RenameRules.nameFieldLabel)
                    .onSubmit { Task { await model.submit() } }
                    .onChange(of: model.name) { _, new in
                        if new.count > InputPlan.maxRename {
                            model.name = String(new.prefix(InputPlan.maxRename))
                        }
                    }
                if let controls = model.controls, model.showsClaudeBox {
                    claudeBox(controls)
                    if let reason = controls.claudeBox.reason {
                        DialogNote(text: reason, style: style)
                    }
                }
                if let note = model.lostNote {
                    DialogNote(text: note, style: style)
                }
                if let reason = model.reason {
                    DialogNote(text: reason, style: style, dim: false)
                }
            }
            HStack(spacing: style.points(8)) {
                Spacer(minLength: 0)
                if model.controls?.showReset == true {
                    Button(RenameRules.resetLabel) { model.reset() }
                        .buttonStyle(DialogButtonStyle(style: style))
                        .disabled(model.busy)
                }
                Button("Cancel") { model.cancel() }
                    .buttonStyle(DialogButtonStyle(style: style))
                    .disabled(model.busy)
                Button(model.title) { Task { await model.submit() } }
                    .buttonStyle(DialogButtonStyle(style: style))
                    .disabled(model.busy)
            }
        }
        .accessibilityLabel(model.title)
        .onAppear { focused = true }
        // While a save runs, the field is off and the layer holds the focus, so the focus state
        // is false then. At the end of a failed save the field takes the focus again.
        .onChange(of: model.busy) { _, busy in focused = !busy }
    }

    // The check box shows the check only while it counts. A disabled box is at 70 % opacity,
    // with its reason as the tooltip.
    private func claudeBox(_ controls: RenameControls) -> some View {
        let enabled = controls.claudeBox == .enabled
        let shown = Binding(
            get: { model.alsoClaude && enabled }, set: { model.alsoClaude = $0 })
        return Toggle(RenameRules.claudeBoxLabel, isOn: shown)
            .toggleStyle(BifrostCheckboxStyle(metrics: style.metrics, keyboardFocus: true))
            .disabled(model.busy || !enabled)
            .opacity(enabled ? 1 : 0.7)
            .background {
                if let reason = controls.claudeBox.reason { TipAnchor(text: reason, side: .top) }
            }
    }
}
