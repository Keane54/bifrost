// The New session dialog (docs/behaviour/actions.md, "New session"): the folder with the recent
// folders and Choose..., the name, the model, the permission mode, the first prompt ("Optional")
// and the worktree check box with its reason. NewSessionForm has the rules of the fields. The
// folder check runs checkDelay after the last change of an absolute folder. While the checks of
// the start run, the fields and the buttons are off, the dialog stays open and shows "Starting
// the session...". A failed check shows its reason in the dialog. When claude --bg starts, the
// dialog closes at once, and the action runner runs the rest of the start
// (ActionRunner.beginSession).
import AppKit
import BifrostFoundation
import BifrostKeyboard
import BifrostLook
import BifrostSessions
import Observation
import SwiftUI

// What Return does in a field of the New session dialog.
package enum ReturnAction: Sendable, Equatable {
    // Start the session.
    case start
    // Add a line break to the prompt.
    case newLine
    // The field gets the key: Return ends a composition of the input method.
    case field
    // Nothing happens.
    case nothing
}

@MainActor
@Observable
package final class NewSessionDialogModel {
    // The folder check starts this long after the last change of the folder.
    package static let checkDelay = Duration.milliseconds(300)
    package static let startingText = "Starting the session..."

    package private(set) var form: NewSessionForm
    // The folder check of the folder of now.
    package private(set) var check = FolderCheck.checking
    // The reason why the values or the checks of the last start did not pass, or nil.
    package private(set) var reason: String?
    // True from the start until a failed check. A start that passed the checks keeps it, so the
    // dialog never starts a second session. After a failed check, the folder field takes the
    // focus again.
    package private(set) var busy = false
    // The recent folders, at the open of the dialog.
    package let folders: [String]
    @ObservationIgnored private weak var runner: ActionRunner?
    @ObservationIgnored private let checkTimer: TimerSlot
    // Each new check adds one, so the result of an old check goes nowhere.
    @ObservationIgnored private var checkNumber = 0
    @ObservationIgnored private let pickFolder: (String?) async -> String?
    // Keeps the focus in the dialog while the start runs and the fields are off.
    @ObservationIgnored private let holdFocus: () -> Void
    // The field editor of the field that has the focus, or nil.
    @ObservationIgnored package var fieldEditor: () -> NSTextView? = { nil }
    @ObservationIgnored private let close: (NewSessionDialogModel) -> Void

    init(
        runner: ActionRunner, clock: any Clock<Duration>,
        pickFolder: @escaping (String?) async -> String?, holdFocus: @escaping () -> Void,
        close: @escaping (NewSessionDialogModel) -> Void
    ) {
        form = NewSessionForm.initial(runner.history, suffix: NewSessionForm.newSuffix())
        folders = runner.recentDirectories
        self.runner = runner
        checkTimer = TimerSlot(clock: clock)
        self.pickFolder = pickFolder
        self.holdFocus = holdFocus
        self.close = close
        startCheck()
    }

    // The title and the start button: "New session", or "Launch" with the space labels.
    package var title: String { ActionID.newSession.label(runner?.labels ?? .plain) }

    // The state of the worktree check box, with its reason when it is off.
    package var worktree: ActionState { NewSessionForm.worktreeState(cwd: form.cwd, check) }

    #if DEBUG
    // The task of the timer of the folder check, or nil. A test waits for it.
    package var checkTask: Task<Void, Never>? { checkTimer.task }
    #endif

    // The keys of a start: Return, and Enter of the numeric keypad.
    package static let startKeys: Set<KeyEquivalent> = [.return, KeyEquivalent("\u{3}")]

    // The rules of a start, unlike KeyEvent.isSendKey of the send box (which also sends with
    // Option, Control or Command): only a plain Return with no marked text of the input method
    // starts the session. Shift+Return adds a line break to the prompt and does nothing in a
    // field of one line. Return with Option, Control or Command never starts a session.
    nonisolated package static func returnAction(
        shift: Bool, option: Bool, control: Bool, command: Bool, composing: Bool,
        multiline: Bool
    ) -> ReturnAction {
        if composing { return .field }
        if option || control || command { return .nothing }
        if shift { return multiline ? .newLine : .nothing }
        return .start
    }

    // A change of a field. A new folder starts a new folder check. A change of the folder, the
    // name or the prompt clears the reason.
    package func apply(_ action: FormAction) {
        guard !busy else { return }
        let folder = form.cwd
        form.apply(action)
        switch action {
        case .cwd, .name, .prompt: reason = nil
        case .model, .mode, .worktree: break
        }
        if form.cwd != folder { startCheck() }
    }

    // The start: the values are checked again first. The first value that fails gives the
    // reason.
    package func submit() async {
        guard !busy, let runner else { return }
        let spec: NewSessionSpec
        switch form.spec() {
        case .success(let value): spec = value
        case .failure(let refusal):
            reason = refusal.message
            return
        }
        busy = true
        reason = nil
        holdFocus()
        do throws(ActionRefusal) {
            try await runner.beginSession(spec)
        } catch {
            reason = error.message
            busy = false
            return
        }
        // The start runs now, and the Overview shows it. The dialog closes and stays busy.
        checkTimer.stop()
        close(self)
    }

    // Choose...: the system panel for folders, at the folder of now with no white space at its
    // ends.
    package func browse() async {
        guard !busy else { return }
        let start = form.cwd.trimmed()
        if let folder = await pickFolder(start.isEmpty ? nil : start) { apply(.cwd(folder)) }
    }

    // Cancel, Esc and a click on the backdrop. The checks of a start keep the dialog open.
    package func cancel() {
        guard !busy else { return }
        checkTimer.stop()
        close(self)
    }

    // The check of the folder of now. A folder that is not absolute gets no check.
    private func startCheck() {
        checkNumber += 1
        let number = checkNumber
        check = .checking
        checkTimer.stop()
        guard NewSessionForm.isAbsoluteDir(form.cwd) else { return }
        let path = form.cwd.trimmed()
        checkTimer.start(after: Self.checkDelay) { [weak self] in
            guard let runner = self?.runner else { return }
            let info = await runner.dirInfo(path)
            guard let self, self.checkNumber == number else { return }
            self.check = .done(info)
        }
    }
}

struct NewSessionDialogView: View {
    let model: NewSessionDialogModel
    let style: PanelStyle

    private enum Field: Hashable {
        case folder, name, prompt
    }

    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: style.points(12)) {
            DialogTitle(text: model.title, style: style)
            folderRow
            labelled("Name") {
                field(.name, text: binding(\.name, FormAction.name)) { text in
                    String(text.prefix(NewSessionSpec.maxName))
                }
            }
            HStack(alignment: .top, spacing: style.points(8)) {
                labelled("Model") { modelPicker }
                labelled("Permission mode") { modePicker }
            }
            labelled("First prompt") { promptField }
            worktreeBox
            if model.busy {
                DialogNote(text: NewSessionDialogModel.startingText, style: style)
            }
            if let reason = model.reason {
                DialogNote(text: reason, style: style, dim: false)
            }
            HStack(spacing: style.points(8)) {
                Spacer(minLength: 0)
                Button("Cancel") { model.cancel() }
                    .buttonStyle(DialogButtonStyle(style: style))
                Button(model.title) { submit() }
                    .buttonStyle(DialogButtonStyle(style: style))
            }
            .disabled(model.busy)
        }
        .accessibilityLabel(model.title)
        .onAppear { focus = .folder }
        // While a start runs, the fields are off and the layer holds the focus, so the focus
        // state is none then. At the end of a failed start the folder field takes the focus
        // again.
        .onChange(of: model.busy) { _, busy in focus = busy ? nil : .folder }
    }

    private var folderRow: some View {
        labelled("Folder") {
            HStack(spacing: style.points(8)) {
                field(.folder, text: binding(\.cwd, FormAction.cwd)) { $0 }
                if !model.folders.isEmpty {
                    Menu {
                        ForEach(model.folders, id: \.self) { folder in
                            Button(folder) { model.apply(.cwd(folder)) }
                        }
                    } label: {
                        Text("Recent")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .disabled(model.busy)
                    .accessibilityLabel("Recent folders")
                }
                Button("Choose...") { Task { await model.browse() } }
                    .buttonStyle(DialogButtonStyle(style: style))
                    .disabled(model.busy)
            }
        }
    }

    private var modelPicker: some View {
        Picker(
            "Model",
            selection: Binding(get: { model.form.model }, set: { model.apply(.model($0)) })
        ) {
            ForEach(NewSessionRules.modelChoices, id: \.value) { choice in
                Text(choice.label).tag(choice.value)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .disabled(model.busy)
        .frame(maxWidth: .infinity)
    }

    private var modePicker: some View {
        Picker(
            "Permission mode",
            selection: Binding(
                get: { model.form.permissionMode }, set: { model.apply(.mode($0)) })
        ) {
            Text("Default").tag(PermissionMode?.none)
            ForEach(PermissionMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(PermissionMode?.some(mode))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .disabled(model.busy)
        .frame(maxWidth: .infinity)
    }

    // The first prompt: three lines. Return starts the session, and Shift+Return adds a line.
    private var promptField: some View {
        TextField("Optional", text: binding(\.prompt, FormAction.prompt), axis: .vertical)
            .lineLimit(3, reservesSpace: true)
            .focused($focus, equals: .prompt)
            .disabled(model.busy)
            .modifier(DialogFieldStyle(style: style, focused: focus == .prompt))
            .onKeyPress(keys: NewSessionDialogModel.startKeys, phases: .down) {
                returnKey($0, multiline: true)
            }
    }

    // The worktree check box. While it is off, its reason is its tooltip.
    private var worktreeBox: some View {
        let state = model.worktree
        return Toggle(
            "Use a worktree",
            isOn: Binding(get: { model.form.worktree }, set: { model.apply(.worktree($0)) })
        )
        .toggleStyle(BifrostCheckboxStyle(metrics: style.metrics, keyboardFocus: true))
        .font(style.font(12))
        .disabled(!state.enabled || model.busy)
        .background {
            if let reason = state.reason { TipAnchor(text: reason, side: .top) }
        }
    }

    // A label above its control, in the dim colour.
    private func labelled(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: style.points(4)) {
            Text(label)
                .font(style.font(12))
                .foregroundStyle(style.dim)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // A one-line text field. limit cuts a new text, for example to the longest name. Return
    // starts the session.
    private func field(
        _ id: Field, text: Binding<String>, limit: @escaping (String) -> String
    ) -> some View {
        let limited = Binding(get: { text.wrappedValue }, set: { text.wrappedValue = limit($0) })
        return TextField("", text: limited)
            .focused($focus, equals: id)
            .disabled(model.busy)
            .modifier(DialogFieldStyle(style: style, focused: focus == id))
            .onKeyPress(keys: NewSessionDialogModel.startKeys, phases: .down) {
                returnKey($0, multiline: false)
            }
    }

    // Return in a field: the rules of NewSessionDialogModel.returnAction.
    private func returnKey(_ press: KeyPress, multiline: Bool) -> KeyPress.Result {
        let editor = model.fieldEditor()
        let action = NewSessionDialogModel.returnAction(
            shift: press.modifiers.contains(.shift), option: press.modifiers.contains(.option),
            control: press.modifiers.contains(.control),
            command: press.modifiers.contains(.command),
            composing: editor?.hasMarkedText() ?? false, multiline: multiline)
        switch action {
        case .start: submit()
        case .newLine: editor?.insertNewlineIgnoringFieldEditor(nil)
        case .field: return .ignored
        case .nothing: break
        }
        return .handled
    }

    // A binding of a field of the form: each change goes through the action of the field.
    private func binding(
        _ path: KeyPath<NewSessionForm, String>, _ action: @escaping (String) -> FormAction
    ) -> Binding<String> {
        Binding(get: { model.form[keyPath: path] }, set: { model.apply(action($0)) })
    }

    private func submit() {
        Task { await model.submit() }
    }
}
