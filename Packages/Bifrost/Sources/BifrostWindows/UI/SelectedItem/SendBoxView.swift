// The send box of the Selected Item panel (docs/behaviour/actions.md, "The send box"): an AppKit
// text view of three lines in a scroll view, with the send box mark, so the keys of the window
// know the zone. SendBoxModel has the drafts, the sends and the line. The box shows no line of its
// own: the panel shows the line in its status icon.
//
// - The box shows the draft of the selected session of now. It follows the selection and the
//   model with Observations while it is in a window.
// - Enter sends, also with Option or Ctrl (KeyEvent.isSendKey: not during a composition), and
//   Shift+Enter adds a line. The rule also sends Cmd+Enter, but with the default keys the key
//   filter of the window takes Cmd+Enter first (Open). Tab and Shift+Tab move the focus, as in a
//   text area.
// - The box is off while Send message is off, and read-only while a send of its session runs.
// - A change of the session gives up the focus at once. Before each change of the text and each
//   key, the box reads the selection of now, so a key never types into the draft of another
//   session (for example after Take control selected it), also before the next turn of
//   Observations.
// - Send message and Run slash command focus the box at once (takeFocus(for:slash:)), when the
//   box shows the session. Run slash command first puts "/" in an empty draft.
import AppKit
import BifrostKeyboard
import BifrostLook
import BifrostSessions

@MainActor
package final class SendBoxView: NSView {
    // The lines of the field, its text size and its inner space, in layout units.
    package static let lines = 3
    package static let textSize = 12.0
    package static let insetX = 8.0
    package static let insetY = 4.0

    // What the box shows.
    private struct Shown: Equatable {
        var sessionId: String?
        var draft: String
        var enabled: Bool
        var sending: Bool
        var label: String
    }

    package let model: SendBoxModel
    package let scroll = NSScrollView()
    package let field = SendTextView()
    // The session that the box shows, or nil.
    package private(set) var sessionId: String?
    // The session of the selection now.
    private let selected: () -> String?
    private var shown: Shown?
    private var following: Task<Void, Never>?
    package private(set) var metrics = CanvasMetrics(interfaceScale: 100)

    // selected gives the session ID of the selected row of now, or nil.
    package init(model: SendBoxModel, selected: @escaping () -> String?) {
        self.model = model
        self.selected = selected
        super.init(frame: .zero)
        identifier = FocusMark.sendBox
        wantsLayer = true
        field.owner = self
        field.isRichText = false
        field.importsGraphics = false
        field.allowsUndo = true
        field.isContinuousSpellCheckingEnabled = false
        field.isGrammarCheckingEnabled = false
        field.isAutomaticSpellingCorrectionEnabled = false
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.isAutomaticTextReplacementEnabled = false
        field.isAutomaticLinkDetectionEnabled = false
        field.isAutomaticDataDetectionEnabled = false
        field.smartInsertDeleteEnabled = false
        field.usesFindBar = false
        field.textColor = ThemeTokens.text.nsColor
        field.insertionPointColor = ThemeTokens.text.nsColor
        field.drawsBackground = false
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = false
        field.autoresizingMask = [.width]
        field.textContainer?.widthTracksTextView = true
        field.textContainer?.lineFragmentPadding = 0
        field.delegate = field
        scroll.documentView = field
        scroll.backgroundColor = ThemeTokens.bg.nsColor
        scroll.drawsBackground = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        addSubview(scroll)
        setMetrics(metrics)
        apply(current())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        following?.cancel()
    }

    override package var isFlipped: Bool { true }

    // The height of the box: three lines, the inner space and the border. The view of the panel
    // reads it at each update, so each Interface scale gets its height one time.
    package static func height(metrics: CanvasMetrics) -> CGFloat {
        if let height = heights[metrics.interfaceScale] { return height }
        let font = Fonts.ui(metrics.points(textSize), weight: .regular)
        let line = NSLayoutManager().defaultLineHeight(for: font)
        let height = (CGFloat(lines) * line + 2 * metrics.points(insetY) + 2 * metrics.points(1))
            .rounded(.up)
        heights[metrics.interfaceScale] = height
        return height
    }

    private static var heights: [Int: CGFloat] = [:]

    package func setMetrics(_ metrics: CanvasMetrics) {
        self.metrics = metrics
        field.font = Fonts.ui(metrics.points(Self.textSize), weight: .regular)
        field.textContainerInset = NSSize(
            width: metrics.points(Self.insetX), height: metrics.points(Self.insetY))
        layer?.borderWidth = metrics.points(1)
        updateBorder()
        needsLayout = true
    }

    // True while the field has the key focus.
    package var hasFocus: Bool { window?.firstResponder === field }

    // MARK: - The follow

    override package func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        following?.cancel()
        following = nil
        guard window != nil else { return }
        let changes = Observations { [weak self] in self?.current() }
        following = Task { [weak self] in
            for await state in changes {
                guard let self, let state else { return }
                apply(state)
            }
        }
    }

    // The state of now: the selection and the model.
    private func current() -> Shown {
        let id = selected()
        let label = ActionID.sendMessage.label(model.runner.labels)
        guard let id else {
            return Shown(sessionId: nil, draft: "", enabled: false, sending: false, label: label)
        }
        return Shown(
            sessionId: id, draft: model.draft(id), enabled: model.state(id).enabled,
            sending: model.isSending(id), label: label)
    }

    private func apply(_ state: Shown) {
        if state.sessionId != sessionId {
            // The focus goes at once, so the next key does not type into the new draft. The
            // field shows the new draft, and an undo cannot bring back the old one.
            if hasFocus { window?.makeFirstResponder(nil) }
            sessionId = state.sessionId
            field.show(state.draft)
        } else if field.string != state.draft {
            field.show(state.draft)
        }
        // A box that is off gives up the focus, as a field that turns off does.
        if !state.enabled && hasFocus { window?.makeFirstResponder(nil) }
        field.isEnabled = state.enabled
        field.isEditable = state.enabled && !state.sending
        field.isSelectable = state.enabled
        alphaValue = state.enabled ? 1 : 0.4
        field.placeholder = state.label
        field.setAccessibilityLabel(state.label)
        field.setAccessibilityPlaceholderValue(state.label)
        field.needsDisplay = true
        shown = state
    }

    // MARK: - The focus

    // Send message or Run slash command of the session: the box takes the focus, with the caret
    // at the end of the draft. The box first shows the selection of now, so it takes the focus
    // only when it shows the session. A box in no window, and a box that is off, take no focus.
    // A Bifrost menu that started the action closed before the action, so the focus stays.
    package func takeFocus(for id: String, slash: Bool) {
        apply(current())
        guard sessionId == id, let window, model.prepareFocus(for: id, slash: slash) else {
            return
        }
        // The "/" of Run slash command shows at once.
        let draft = model.draft(id)
        if field.string != draft { field.show(draft) }
        window.makeFirstResponder(field)
        field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
        // In a low panel the box can be below the visible part: the panel scrolls to it.
        scrollToVisible(bounds)
    }

    // MARK: - The inputs of the field

    // The field asks before each change of its text and each key. When the selection of now is
    // another session, the box shows that session at once, and the change or the key does not
    // go through.
    func sessionStays() -> Bool {
        let state = current()
        guard state.sessionId == sessionId else {
            apply(state)
            return false
        }
        return true
    }

    // True while a send of the shown session runs: the text cannot change, also before the
    // follow made the field read-only.
    var isSending: Bool {
        sessionId.map(model.isSending) ?? false
    }

    // The text of the field changed.
    func textChanged() {
        guard let sessionId else { return }
        model.setDraft(sessionId, field.string)
    }

    // The send key.
    func send() {
        guard let sessionId, sessionStays() else { return }
        model.startSubmit(sessionId)
    }

    func focusChanged() {
        updateBorder()
    }

    private func updateBorder() {
        let edge = hasFocus ? ThemeTokens.textStrong.opacity(0.3) : ThemeTokens.panelEdge
        layer?.borderColor = edge.nsColor.cgColor
    }

    // The field fills the box at least, so a click anywhere in the box puts the caret in it.
    override package func layout() {
        super.layout()
        // A box with no size has an inner rect of no size: insetBy would give the null rect,
        // whose infinite origin AppKit refuses as a layout constant.
        let border = metrics.points(1)
        scroll.frame = NSRect(
            x: border, y: border, width: max(0, bounds.width - 2 * border),
            height: max(0, bounds.height - 2 * border))
        let size = scroll.contentSize
        field.minSize = NSSize(width: 0, height: size.height)
        field.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if field.frame.width != size.width || field.frame.height < size.height {
            let height = max(field.frame.height, size.height)
            field.setFrameSize(NSSize(width: size.width, height: height))
        }
    }
}

// The field of the send box. It draws the placeholder while it is empty. It has its own undo
// manager, and a text that the box puts in clears it, so an undo never brings back the text of
// another session.
@MainActor
package final class SendTextView: NSTextView, NSTextViewDelegate {
    weak var owner: SendBoxView?
    // The label of Send message: the placeholder of an empty field.
    var placeholder = ""
    // False while Send message is off: the field then takes no focus.
    var isEnabled = true
    private let undo = UndoManager()

    // Show a text of the box (a draft of another session, a cleared draft or the "/" of Run
    // slash command), with the caret at its end. The change is not a change of the user. The
    // typing that the undo manager groups ends first, so no group stays open after the clear. A
    // new text also ends that group, so the break is a guard: no test can see it.
    func show(_ text: String) {
        breakUndoCoalescing()
        string = text
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        undo.removeAllActions()
        needsDisplay = true
    }

    package func undoManager(for view: NSTextView) -> UndoManager? { undo }

    override package var acceptsFirstResponder: Bool { isEnabled && super.acceptsFirstResponder }

    override package func becomeFirstResponder() -> Bool {
        guard isEnabled, super.becomeFirstResponder() else { return false }
        owner?.focusChanged()
        return true
    }

    override package func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        owner?.focusChanged()
        return true
    }

    override package func keyDown(with event: NSEvent) {
        guard owner?.sessionStays() ?? true else { return }
        let key = KeyEvent(event, isComposing: hasMarkedText())
        if let key, key.isSendKey {
            owner?.send()
            return
        }
        if let key, key.key == .named(.enter), key.modifiers == .shift, !key.isComposing {
            insertNewlineIgnoringFieldEditor(nil)
            return
        }
        super.keyDown(with: event)
    }

    // Tab and Shift+Tab move the focus, as in a text area.
    override package func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(self)
    }

    override package func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(self)
    }

    // Esc does not open the completions of the text view.
    override package func complete(_ sender: Any?) {}

    override package func shouldChangeText(
        in affectedCharRange: NSRange, replacementString: String?
    ) -> Bool {
        guard owner?.sessionStays() ?? true, !(owner?.isSending ?? false) else { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    package func textDidChange(_ notification: Notification) {
        owner?.textChanged()
        needsDisplay = true
    }

    override package func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), let font else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: ThemeTokens.textDim.nsColor,
        ]
        let origin = NSPoint(
            x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}
