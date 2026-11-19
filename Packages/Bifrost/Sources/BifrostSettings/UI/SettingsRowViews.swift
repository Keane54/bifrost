// The rows that the sections of the Settings panel share (docs/behaviour/settings.md): a row with
// its label, its control, its hint and its error, and the check, number, select, text and
// Introduction rows. Each row reads store.settings and saves itself through the model. During a
// search, a row that does not match shows nothing. The controls are SwiftUI controls and AppKit
// text fields with the look of the rows of the Electron app (row S3 of docs/ports/settings): the
// UI font at 12, the edge colour of the panels and no system colour. The check box is the check
// box of Bifrost (BifrostCheckboxStyle).
import AppKit
import BifrostFoundation
import BifrostLook
import Observation
import SwiftUI

// The sizes, the font and the colours of the Settings panel at the Interface scale and the Panel
// transparency of the settings.
extension PanelStyle {
    init(_ model: SettingsModel) {
        let settings = model.store.settings
        self.init(
            metrics: CanvasMetrics(interfaceScale: settings.interfaceScale),
            transparency: settings.panelTransparency)
    }
}

// MARK: - The row

// The labels of the rows that show, in the order of the rows. Each row that shows gives its
// label, so a view above the rows, or a test, can read which rows show and in which order.
package struct SettingRowLabels: PreferenceKey {
    package static let defaultValue: [String] = []

    package static func reduce(value: inout [String], nextValue: () -> [String]) {
        value += nextValue()
    }
}

// One row: the label at the left, the control at the right, an optional hint under them, an
// optional detail under the hint, and the error of the row under the detail. A row that the
// search hides shows nothing.
package struct SettingRow<Control: View, Detail: View>: View {
    let model: SettingsModel
    let row: SettingsRowID
    let label: String
    let hint: String?
    let control: Control
    let detail: Detail

    package init(
        model: SettingsModel, row: SettingsRowID, label: String, hint: String? = nil,
        @ViewBuilder control: () -> Control, @ViewBuilder detail: () -> Detail
    ) {
        self.model = model
        self.row = row
        self.label = label
        self.hint = hint
        self.control = control()
        self.detail = detail()
    }

    package var body: some View {
        if model.isShown(row) {
            let style = PanelStyle(model)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: style.points(12)) {
                    Text(label).lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                    HStack(spacing: style.points(8)) { control }
                }
                .padding(.horizontal, style.points(12))
                .frame(minHeight: style.points(28))
                if let hint {
                    Text(hint)
                        .foregroundStyle(style.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, style.points(12))
                        .padding(.bottom, style.points(4))
                }
                detail
                ErrorLine(model: model, row: row)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(style.edge).frame(height: style.points(1))
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .preference(key: SettingRowLabels.self, value: [label])
        }
    }
}

extension SettingRow where Detail == EmptyView {
    package init(
        model: SettingsModel, row: SettingsRowID, label: String, hint: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.init(
            model: model, row: row, label: label, hint: hint, control: control,
            detail: { EmptyView() })
    }
}

// The error of a row, with its close button. The text is not red: red is only for the red box.
// The error of a row stays until the user closes it or a later save of the row works. The
// sections of Live details and Skills give their own error and close.
package struct ErrorLine: View {
    let model: SettingsModel
    let message: String?
    let close: @MainActor () -> Void

    package init(model: SettingsModel, row: SettingsRowID) {
        self.init(model: model, message: model.error(of: row)) { model.closeError(row) }
    }

    package init(
        model: SettingsModel, message: String?, close: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.message = message
        self.close = close
    }

    package var body: some View {
        if let message {
            ErrorLineView(text: message, metrics: PanelStyle(model).metrics, close: close)
        }
    }
}

// MARK: - The rows with a control

// A row with a check box. The box shows On or Off, and a change saves at once. An optional
// detail shows under the hint.
package struct CheckRow<Detail: View>: View {
    let model: SettingsModel
    let row: SettingsRowID
    let label: String
    let hint: String?
    let isOn: Bool
    let disabled: Bool
    let set: (inout Settings, Bool) -> Void
    let detail: Detail

    package init(
        model: SettingsModel, row: SettingsRowID, label: String, hint: String? = nil,
        isOn: Bool, disabled: Bool = false, set: @escaping (inout Settings, Bool) -> Void,
        @ViewBuilder detail: () -> Detail
    ) {
        self.model = model
        self.row = row
        self.label = label
        self.hint = hint
        self.isOn = isOn
        self.disabled = disabled
        self.set = set
        self.detail = detail()
    }

    // A row of Settings > General for a setting of the settings file.
    package init(
        model: SettingsModel, _ general: GeneralRow, hint: String? = nil, disabled: Bool = false,
        _ setting: WritableKeyPath<Settings, Bool>, @ViewBuilder detail: () -> Detail
    ) {
        self.init(
            model: model, row: .general(general), label: general.rawValue, hint: hint,
            isOn: model.store.settings[keyPath: setting], disabled: disabled,
            set: { $0[keyPath: setting] = $1 }, detail: detail)
    }

    package var body: some View {
        SettingRow(model: model, row: row, label: label, hint: hint) {
            Toggle(isOn: Binding(get: { isOn }, set: { value in save(value) })) {
                Text(isOn ? "On" : "Off")
            }
            .toggleStyle(BifrostCheckboxStyle(metrics: PanelStyle(model).metrics))
            .fixedSize()
            .disabled(disabled)
            .accessibilityLabel(label)
        } detail: {
            detail
        }
    }

    private func save(_ value: Bool) {
        model.save(row) { set(&$0, value) }
    }
}

extension CheckRow where Detail == EmptyView {
    package init(
        model: SettingsModel, row: SettingsRowID, label: String, hint: String? = nil,
        isOn: Bool, disabled: Bool = false, set: @escaping (inout Settings, Bool) -> Void
    ) {
        self.init(
            model: model, row: row, label: label, hint: hint, isOn: isOn, disabled: disabled,
            set: set, detail: { EmptyView() })
    }

    package init(
        model: SettingsModel, _ general: GeneralRow, hint: String? = nil, disabled: Bool = false,
        _ setting: WritableKeyPath<Settings, Bool>
    ) {
        self.init(
            model: model, general, hint: hint, disabled: disabled, setting,
            detail: { EmptyView() })
    }
}

// A row with a number field and its unit. The field saves a whole number in the range of the row
// when its edit ends. A text that is not a whole number, or a number outside the range, gives
// the reason with the range before a save starts.
package struct NumberRow: View {
    let model: SettingsModel
    let row: SettingsRowID
    let label: String
    let hint: String?
    let value: Int
    let range: ClosedRange<Int>
    let unit: String
    let set: (inout Settings, Int) -> Void

    package init(
        model: SettingsModel, row: SettingsRowID, label: String, hint: String? = nil, value: Int,
        range: ClosedRange<Int>, unit: String, set: @escaping (inout Settings, Int) -> Void
    ) {
        self.model = model
        self.row = row
        self.label = label
        self.hint = hint
        self.value = value
        self.range = range
        self.unit = unit
        self.set = set
    }

    // The reason for a text that is not a whole number.
    package static func notANumber(_ range: ClosedRange<Int>) -> String {
        "Enter a whole number from \(range.lowerBound) to \(range.upperBound)."
    }

    // The whole number of a text, or nil. A text such as "5.0" or "1e3" is a whole number too.
    package static func wholeNumber(_ text: String) -> Int? {
        if let number = Int(text) { return number }
        guard let value = Double(text), value.isFinite, value.rounded() == value else { return nil }
        return Int(exactly: value)
    }

    // What the text of a number field saves: the edit with the number, or the reason when the
    // text is not a whole number in the range.
    package static func save(
        _ text: String, range: ClosedRange<Int>, _ set: @escaping (inout Settings, Int) -> Void
    ) -> TextSave {
        guard let number = wholeNumber(text), range.contains(number) else {
            return .refused(notANumber(range))
        }
        return .edit { set(&$0, number) }
    }

    package var body: some View {
        SettingRow(model: model, row: row, label: label, hint: hint) {
            DraftField(model: model, row: row, label: label, saved: String(value), width: 64) {
                [range, set] text in Self.save(text, range: range, set)
            }
            Text(unit).foregroundStyle(PanelStyle(model).dim)
        }
    }
}

// A choice of a menu or of a row of choice buttons: the value and the text that shows.
package struct RowChoice<Value: Hashable>: Hashable {
    package var value: Value
    package var text: String

    package init(_ value: Value, _ text: String) {
        self.value = value
        self.text = text
    }
}

// A row with a pop-up menu of choices. choose runs at once with the value of a new choice, for
// example a save of the row.
package struct SelectRow<Value: Hashable>: View {
    let model: SettingsModel
    let row: SettingsRowID
    let label: String
    let hint: String?
    let value: Value
    let choices: [RowChoice<Value>]
    let choose: (Value) -> Void

    package init(
        model: SettingsModel, row: SettingsRowID, label: String, hint: String? = nil,
        value: Value, choices: [RowChoice<Value>], choose: @escaping (Value) -> Void
    ) {
        self.model = model
        self.row = row
        self.label = label
        self.hint = hint
        self.value = value
        self.choices = choices
        self.choose = choose
    }

    package var body: some View {
        SettingRow(model: model, row: row, label: label, hint: hint) {
            Picker(label, selection: Binding(get: { value }, set: { choice in choose(choice) })) {
                ForEach(choices, id: \.self) { choice in
                    Text(choice.text).tag(choice.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }
}

// Choice buttons in a row, as radio buttons: each is a small dark square with its text, and the
// chosen one has a filled square in its box. A click on the text also chooses. choose runs with
// the value of a new choice. A choice that is already chosen does nothing. The buttons never take
// the focus. For accessibility the buttons are a radio group.
package struct ChoiceButtons<Value: Hashable>: View {
    let model: SettingsModel
    let label: String
    let value: Value
    let choices: [RowChoice<Value>]
    let choose: (Value) -> Void

    package init(
        model: SettingsModel, label: String, value: Value, choices: [RowChoice<Value>],
        choose: @escaping (Value) -> Void
    ) {
        self.model = model
        self.label = label
        self.value = value
        self.choices = choices
        self.choose = choose
    }

    package var body: some View {
        let style = PanelStyle(model)
        HStack(spacing: style.points(12)) {
            ForEach(choices, id: \.self) { choice in
                Button {
                    if choice.value != value { choose(choice.value) }
                } label: {
                    HStack(spacing: style.points(6)) {
                        box(chosen: choice.value == value, style)
                        Text(choice.text).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressTintStyle())
                .focusable(false)
            }
        }
        .fixedSize()
        .accessibilityRepresentation {
            Picker(label, selection: Binding(get: { value }, set: { choice in choose(choice) })) {
                ForEach(choices, id: \.self) { choice in
                    Text(choice.text).tag(choice.value)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }

    // The box of a choice: 14 units, the dim text colour as its border (the text colour when it
    // is chosen), and a filled square of 6 units when it is chosen.
    private func box(chosen: Bool, _ style: PanelStyle) -> some View {
        ZStack {
            Rectangle().fill(ThemeTokens.bg.color)
            Rectangle().strokeBorder(
                (chosen ? ThemeTokens.text : ThemeTokens.textDim).color,
                lineWidth: style.points(1))
            if chosen {
                Rectangle().fill(ThemeTokens.textStrong.color)
                    .frame(width: style.points(6), height: style.points(6))
            }
        }
        .frame(width: style.points(14), height: style.points(14))
    }
}

// A text field whose text saves when its edit ends: at the blur, at Enter, and when Save ends
// the edit. The text to save is the trimmed text (DraftRule). Esc puts the saved value back. A
// refused text goes back to the saved value, unless keepOnRefusal is true.
package struct DraftField: View {
    let model: SettingsModel
    let row: SettingsRowID
    let label: String
    let saved: String
    // The width of the field in layout units.
    let width: Double
    let keepOnRefusal: Bool
    let save: (String) -> TextSave
    // The text that the user typed, or nil: the field shows the saved value.
    @State private var draft = DraftText()

    package init(
        model: SettingsModel, row: SettingsRowID, label: String, saved: String, width: Double,
        keepOnRefusal: Bool = false, save: @escaping (String) -> TextSave
    ) {
        self.model = model
        self.row = row
        self.label = label
        self.saved = saved
        self.width = width
        self.keepOnRefusal = keepOnRefusal
        self.save = save
    }

    package var body: some View {
        let style = PanelStyle(model)
        let (draft, saved) = (draft, saved)
        SettingsTextField(
            text: { draft.text ?? saved }, label: label, enabled: !model.isSaving,
            font: style.nsFont, onChange: { draft.text = $0 }, onEnd: commit,
            onEscape: { composing in
                if composing { return false }
                showSaved()
                return true
            }
        )
        .fieldLook(style, width: width)
    }

    // The edit ended with the text of the field.
    private func commit(_ text: String) {
        guard let toSave = DraftRule.toSave(text, saved: saved) else {
            showSaved()
            return
        }
        switch save(toSave) {
        case .refused(let reason):
            model.refuse(row, reason: reason)
            if !keepOnRefusal { showSaved() }
        case .edit(let change):
            let saving = model.save(row, change)
            Task {
                let ok = await saving.value
                // A text that the user typed during the save stays.
                if (ok || !keepOnRefusal) && draft.text == text { showSaved() }
            }
        }
    }

    // The field shows the saved value again.
    private func showSaved() {
        draft.text = nil
    }
}

// The text that the user typed in a DraftField, or nil while the field shows the saved value. It
// is observable, so the field follows each change, also a change back to the saved value.
@MainActor
@Observable
final class DraftText {
    var text: String?
}

// The Introduction row of Settings > General: its button asks the Setup dialog to show the
// introduction again. It changes no setting.
package struct IntroRow: View {
    let model: SettingsModel

    package init(model: SettingsModel) {
        self.model = model
    }

    package var body: some View {
        let label = GeneralRow.introduction.rawValue
        SettingRow(model: model, row: .general(.introduction), label: label) {
            Button("Show introduction") { model.showIntroduction() }
                .buttonStyle(DialogButtonStyle(style: PanelStyle(model)))
        }
    }
}

// MARK: - The text field

// A text field of the Settings panel. It is an AppKit text field, so the panel can end its edit
// at once (Save) and can read the composition of an input method at Esc.
// - text gives the text to show. It reads observed values, and the field follows each change of
//   them with Observations, so the field shows the text of now also when SwiftUI does not
//   update the view (for example a change back to the text of its last update). The field
//   never changes the text of an edit with a composition of an input method.
// - onChange gets each change of the text, and onEnd gets the text when the edit ends.
// - Enter calls onEnter. With no onEnter, Enter ends the edit.
// - Esc calls onEscape with true during a composition. True from onEscape: Esc acted, so it goes
//   no further.
struct SettingsTextField: NSViewRepresentable {
    var text: @MainActor () -> String
    var label: String
    var placeholder = ""
    var identifier: NSUserInterfaceItemIdentifier?
    var enabled = true
    var font: NSFont
    var onChange: (String) -> Void = { _ in }
    var onEnd: (String) -> Void = { _ in }
    var onEnter: (() -> Void)?
    var onEscape: (Bool) -> Bool = { _ in false }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = SettingsField(string: text())
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.textColor = ThemeTokens.text.nsColor
        field.identifier = identifier
        field.delegate = context.coordinator
        apply(to: field)
        context.coordinator.follow(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        apply(to: field)
        Coordinator.show(text(), in: field)
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.stop()
    }

    private func apply(to field: NSTextField) {
        field.font = font
        field.isEnabled = enabled
        field.setAccessibilityLabel(label)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: ThemeTokens.textDim.nsColor, .font: font])
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SettingsTextField
        private var following: Task<Void, Never>?

        init(_ parent: SettingsTextField) {
            self.parent = parent
        }

        isolated deinit {
            following?.cancel()
        }

        // Follow the text of the field: each change of an observed value that the text reads
        // shows in the field.
        func follow(_ field: NSTextField) {
            guard following == nil else { return }
            let changes = Observations { [weak self] in self?.parent.text() }
            following = Task { [weak self, weak field] in
                for await text in changes {
                    guard self != nil, let field, let text else { return }
                    Self.show(text, in: field)
                }
            }
        }

        func stop() {
            following?.cancel()
            following = nil
        }

        // Show the text in the field. While the field edits, the field editor holds the text. A
        // composition keeps its text.
        static func show(_ text: String, in field: NSTextField) {
            if let editor = field.currentEditor() as? NSTextView {
                if editor.string != text && !editor.hasMarkedText() { editor.string = text }
            } else if field.stringValue != text {
                field.stringValue = text
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onChange(field.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onEnd(field.stringValue)
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
        ) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if let onEnter = parent.onEnter {
                    onEnter()
                } else {
                    control.window?.makeFirstResponder(nil)
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onEscape(textView.hasMarkedText())
            default:
                return false
            }
        }
    }
}

// The text field of SettingsTextField. It tells the host of the panel when its edit ends
// (SettingsHost.focusLeft(_:)), so the focus does not fall to the window when a change removes
// the field while it has the focus. AppKit ends the edit before it takes the field out of the
// window, so the field keeps its host from the time it joined the window. The search field also
// tells the host that it joined, so Cmd+F finds it.
final class SettingsField: NSTextField {
    private weak var host: SettingsHost?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let found = SettingsHost.holding(self) else { return }
        host = found
        if identifier == SettingsHost.searchField { found.searchFieldJoined(self) }
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        host?.focusLeft(self)
    }
}

extension View {
    // The look of a text field of a row: the background colour, the edge colour and a padding.
    // width is in layout units. nil: the field takes the free width.
    func fieldLook(_ style: PanelStyle, width: Double?) -> some View {
        padding(.horizontal, style.points(6))
            .frame(width: width.map { style.points($0) }, height: style.points(20))
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(ThemeTokens.bg.color)
            .overlay {
                Rectangle().strokeBorder(style.edge, lineWidth: style.points(1))
                    .accessibilityHidden(true)
            }
    }
}
