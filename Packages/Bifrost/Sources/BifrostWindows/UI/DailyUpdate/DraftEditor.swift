// The editor of a draft of the Daily update panel (docs/behaviour/daily-update.md, "The panel").
// The draft is Markdown with **bold** parts (DailyMarkup). The editor shows each bold part in the
// bold face with no stars, and the user changes the text in place. Each change gives the draft
// back as Markdown (DraftEditor.markdown(of:)), so the draft of the service is always the text
// that the editor shows.
//
// The editor is an AppKit text view in a scroll view. A bold part has the bold attribute
// (DraftEditor.boldKey) and the bold face: text typed after a bold part stays bold, as in a
// rich text editor. A paste gives plain text only. The editor shows a new draft from the
// service (Redo, Use new draft) only when it differs from the Markdown of its own text
// (DailyUpdatePanelModel.showsDraftAgain), so a change of the user never moves the caret. The
// editor has its own undo manager, and a new draft clears it, so an undo never acts on the text
// of an earlier draft.
import AppKit
import BifrostDailyUpdate
import BifrostLook
import SwiftUI

struct DraftEditor: NSViewRepresentable {
    // The draft as Markdown.
    var draft: String
    var font: NSFont
    var boldFont: NSFont
    // A change of the user, as Markdown.
    var edit: @MainActor (String) -> Void

    // The attribute of a bold part.
    static let boldKey = NSAttributedString.Key("bifrost.draftBold")

    // The draft with each bold part in the bold face and with the bold attribute.
    static func attributed(
        _ markdown: String, font: NSFont, boldFont: NSFont
    ) -> NSAttributedString {
        let parts = DailyMarkup.attributed(markdown)
        let result = NSMutableAttributedString()
        let colour = ThemeTokens.text.nsColor
        for run in parts.runs {
            let text = String(parts[run.range].characters)
            let bold = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            var attributes: [NSAttributedString.Key: Any] = [
                .font: bold ? boldFont : font, .foregroundColor: colour,
            ]
            if bold { attributes[boldKey] = true }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    // The text as Markdown: each run with the bold attribute is a bold part (DailyMarkup.markdown).
    static func markdown(of text: NSAttributedString) -> String {
        var value = AttributedString()
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(boldKey, in: whole) { mark, range, _ in
            var run = AttributedString(text.attributedSubstring(from: range).string)
            if mark as? Bool == true { run.inlinePresentationIntent = .stronglyEmphasized }
            value.append(run)
        }
        return DailyMarkup.markdown(value)
    }

    // A text view with the setup of the editor.
    static func makeTextView() -> DraftTextView {
        let view = DraftTextView(frame: .zero)
        view.isRichText = true
        view.importsGraphics = false
        view.usesFontPanel = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 4, height: 4)
        let most = CGFloat.greatestFiniteMagnitude
        view.maxSize = NSSize(width: most, height: most)
        view.insertionPointColor = ThemeTokens.textStrong.nsColor
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        return view
    }

    // Show the draft in the view when the rule asks for it: a draft that is not the text of the
    // view, or a new font.
    static func update(_ view: DraftTextView, draft: String, font: NSFont, boldFont: NSFont) {
        let again = DailyUpdatePanelModel.showsDraftAgain(
            draft, editorText: markdown(of: view.attributedString()),
            fontChanged: view.shownFont != font)
        guard again else { return }
        view.show(attributed(draft, font: font, boldFont: boldFont), font: font)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = Self.makeTextView()
        view.delegate = context.coordinator
        Self.update(view, draft: draft, font: font, boldFont: boldFont)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? DraftTextView else { return }
        Self.update(view, draft: draft, font: font, boldFont: boldFont)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DraftEditor

        init(_ parent: DraftEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.edit(DraftEditor.markdown(of: view.attributedString()))
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            (view as? DraftTextView)?.undo
        }
    }
}

// The text view of the editor. It reads only plain text from a paste. It keeps the font of the
// last draft that it showed, so a new Interface scale shows the draft again, and it has its own
// undo manager.
final class DraftTextView: NSTextView {
    private(set) var shownFont: NSFont?
    let undo = UndoManager()

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    // Show a draft of the service, with the caret at its end. The change is not a change of the
    // user, so it gives no undo, and the undo of the earlier text goes.
    func show(_ text: NSAttributedString, font: NSFont) {
        breakUndoCoalescing()
        textStorage?.setAttributedString(text)
        typingAttributes = [.font: font, .foregroundColor: ThemeTokens.text.nsColor]
        setSelectedRange(NSRange(location: text.length, length: 0))
        shownFont = font
        undo.removeAllActions()
    }
}
