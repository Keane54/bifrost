// A text field of many lines for the Settings panel (DraftArea), for the format, the examples and
// the description of a work area of Settings > Daily update. It works as DraftField with
// keepOnRefusal does: the text saves when its edit ends (the blur, and Save, which ends the edit),
// the saved text is the trimmed text (DraftRule), a refused text stays in the field until a good
// save or Esc, and Esc puts the saved value back. Return makes a new line.
//
// The field is an AppKit text view in a scroll view (SettingsTextArea), with plain text only, the
// UI font and the look of the text fields of the rows. The end of an edit tells the host of the
// panel (SettingsHost.focusLeft(_:)), as a text field of the panel does. The field has its own
// undo manager, and a text that the field puts in (a new saved value, the revert of Esc) clears
// it, so an undo never acts on an earlier text.
import AppKit
import BifrostLook
import SwiftUI

package struct DraftArea: View {
    let model: SettingsModel
    let row: SettingsRowID
    let saved: String
    // The height of the field in lines.
    let lines: Int
    let save: (String) -> TextSave
    // The text of the user that a save refused, or that saves now. nil: the field shows the saved
    // value.
    @State private var kept = DraftText()

    // What the end of an edit does.
    package enum End {
        // The trimmed text is the saved value.
        case nothing
        // The text is refused for this reason. It stays in the field.
        case refused(String)
        // The edit saves the text.
        case save((inout Settings) -> Void)
    }

    // What the end of an edit with the text does, for the saved value and the save of the row.
    package static func end(
        _ text: String, saved: String, save: (String) -> TextSave
    ) -> End {
        guard let toSave = DraftRule.toSave(text, saved: saved) else { return .nothing }
        switch save(toSave) {
        case .refused(let reason): return .refused(reason)
        case .edit(let change): return .save(change)
        }
    }

    package init(
        model: SettingsModel, row: SettingsRowID, saved: String, lines: Int,
        save: @escaping (String) -> TextSave
    ) {
        self.model = model
        self.row = row
        self.saved = saved
        self.lines = lines
        self.save = save
    }

    package var body: some View {
        let style = PanelStyle(model)
        let kept = kept
        SettingsTextArea(
            shown: kept.text ?? saved, saved: saved, enabled: !model.isSaving,
            font: style.nsFont, onEnd: commit, onRevert: { kept.text = nil })
        .padding(.horizontal, style.points(2))
        .padding(.vertical, style.points(2))
        .frame(height: style.points(Double(lines) * 17 + 8))
        .frame(maxWidth: .infinity)
        .background(ThemeTokens.bg.color)
        .overlay {
            Rectangle().strokeBorder(style.edge, lineWidth: style.points(1))
                .accessibilityHidden(true)
        }
    }

    // The edit ended with the text of the field. A refused text stays in the field, so the user
    // can correct it. A text that saves stays until its save works.
    private func commit(_ text: String) {
        switch Self.end(text, saved: saved, save: save) {
        case .nothing:
            kept.text = nil
        case .refused(let reason):
            kept.text = text
            model.refuse(row, reason: reason)
        case .save(let change):
            kept.text = text
            let saving = model.save(row, change)
            let kept = kept
            Task {
                if await saving.value, kept.text == text { kept.text = nil }
            }
        }
    }
}

// The text view of DraftArea. It shows the text of shown while it does not edit, and it gives the
// text to onEnd when its edit ends. Esc shows saved and calls onRevert.
struct SettingsTextArea: NSViewRepresentable {
    // The text to show: a kept text of the user, else the saved value.
    var shown: String
    var saved: String
    var enabled: Bool
    var font: NSFont
    var onEnd: (String) -> Void
    var onRevert: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = Self.makeTextView()
        view.delegate = context.coordinator
        view.show(shown)
        scroll.documentView = view
        apply(to: view)
        return scroll
    }

    // A text view with the setup of the field.
    static func makeTextView() -> AreaTextView {
        let view = AreaTextView(frame: .zero)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 2, height: 2)
        let most = CGFloat.greatestFiniteMagnitude
        view.maxSize = NSSize(width: most, height: most)
        view.textColor = ThemeTokens.text.nsColor
        view.insertionPointColor = ThemeTokens.textStrong.nsColor
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        return view
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? AreaTextView else { return }
        apply(to: view)
        // While the view edits, its text is the text of the user.
        if view.window?.firstResponder !== view, view.string != shown { view.show(shown) }
    }

    private func apply(to view: NSTextView) {
        view.font = font
        view.isEditable = enabled
        view.isSelectable = enabled
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SettingsTextArea
        // True while Esc ends the edit: that end saves nothing.
        private var reverting = false

        init(_ parent: SettingsTextArea) {
            self.parent = parent
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if !reverting { parent.onEnd(view.string) }
            if let host = SettingsHost.holding(view) { host.focusLeft(view) }
        }

        // Esc puts the saved text back and ends the edit, so nothing saves.
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), !view.hasMarkedText()
            else { return false }
            (view as? AreaTextView)?.show(parent.saved)
            parent.onRevert()
            reverting = true
            view.window?.makeFirstResponder(nil)
            reverting = false
            return true
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            (view as? AreaTextView)?.undo
        }
    }
}

// The text view of the area. It reads only plain text from a paste, and it has its own undo
// manager.
final class AreaTextView: NSTextView {
    let undo = UndoManager()

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    // Show a text that is not a change of the user. It gives no undo, and the undo of the earlier
    // text goes.
    func show(_ text: String) {
        breakUndoCoalescing()
        string = text
        undo.removeAllActions()
    }
}
