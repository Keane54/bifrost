// The SwiftTerm view of a chat window and its settings (docs/behaviour/chat.md).
import AppKit
import BifrostKeyboard
import BifrostLook
import BifrostSessions
import BifrostSettings
import SwiftTerm

// The renderer of the chat terminals: Metal (user decision, 2026-11-14), or Core Graphics. Core
// Graphics is a hidden fallback setting, because SwiftTerm still calls its Metal renderer
// experimental. The user sets it with "defaults write <bundle ID> TerminalRenderer cg". The app
// only reads the key.
nonisolated public enum TerminalRenderer: String, Sendable {
    case metal, cg

    // The defaults key of the app.
    package static let defaultsKey = "TerminalRenderer"

    // The value "cg" of the key gives Core Graphics. Each other value, and no value, gives Metal.
    public static func read(_ defaults: UserDefaults) -> TerminalRenderer {
        defaults.string(forKey: defaultsKey) == TerminalRenderer.cg.rawValue ? .cg : .metal
    }
}

// The terminal view of a chat window. It is the first responder of the chat, so it is the chat
// target of the key filter. It gives each key, each focus change and each event of SwiftTerm to its
// chat terminal, which owns the chat input and the attach.
package final class ChatTerminalView: TerminalView, ChatKeyTarget, TerminalViewDelegate {
    // The scrollback is small: "claude attach" always uses the alternate screen, which has no
    // scrollback. A measure of 8 streaming chats on the normal screen showed that 500 lines cost
    // about 3.5 MB more than 200 lines (the rule allows 5 MB), so the value stays 500
    // (docs/archive/phase-records/phase-3-performance.md).
    static let scrollback = 500

    // The options of a new terminal: the start size 120 x 32 (SizeRule.defaultTerm) and the
    // xterm 256-colour palette.
    static var options: TerminalOptions {
        TerminalOptions(
            cols: SizeRule.defaultTerm.cols, rows: SizeRule.defaultTerm.rows,
            scrollback: scrollback, ansi256PaletteStrategy: .xterm)
    }

    package let sessionId: String
    // The chat terminal of the view. The view gives it each event.
    weak var chat: ChatTerminal?
    // The buttons of the mouse that are down now (NSEvent.pressedMouseButtons). A test gives
    // its own buttons, because a synthetic drag has no real button down.
    package var pressedButtons: () -> Int = { NSEvent.pressedMouseButtons }
    // The slider of the scroll bar, with the colours of the tokens.
    let slider = ScrollSlider()

    init(sessionId: String, font: NSFont) {
        self.sessionId = sessionId
        super.init(frame: .zero, font: font, options: Self.options)
        terminalDelegate = self
        // The background is clear, so the frame fill and its blur show through (user decision,
        // 2026-11-06).
        nativeBackgroundColor = ThemeTokens.terminalBackground.nsColor
        nativeForegroundColor = ThemeTokens.text.nsColor
        // Option types the character of the keyboard layout, so a dead key (Option+E, then E) and
        // the Option characters of other layouts work. Option stays Meta for the keys that have no
        // text: the arrows, Backspace, Enter, Tab and Esc.
        optionAsMetaKey = false
        optionAsMetaKeyForFunctionalKeys = true
        // OSC 8 links first, then links in the text. A Cmd+click opens a link. A plain click
        // goes to Claude Code, because Claude Code uses the mouse (user decision, 2026-11-14).
        linkReporting = .implicit
        linkHighlightMode = .hoverWithModifier
        allowMouseReporting = true
        // A bell makes no sound.
        bellStyle = .none
        // A Cmd key never goes to the program before the key filter of the window: the Bifrost
        // keys act first, also when Claude Code turns on the kitty keyboard protocol.
        shouldSendCommandKeyToTerminal = { _ in false }
        // A key does not restart the blink of the cursor. That restart takes the render lock of
        // SwiftTerm on the main thread. The render thread holds the same lock while it waits for
        // a drawable, and that wait can be 1 s when the window server is slow. Then each key
        // stopped the main thread for up to 1 s. The only visible change: while the user types,
        // a cursor that shows keeps its blink.
        cursorBlinkResetsOnInput = false
        addSlider()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // The font of the terminal font setting at the Interface scale: the family, then SF Mono, then
    // Menlo. SF Mono is the monospaced system font. Another family that is not installed gives SF
    // Mono. A character that the family does not have comes from SF Mono, then from Menlo.
    static func font(_ setting: TerminalFont, metrics: CanvasMetrics) -> NSFont {
        let size = metrics.points(Double(setting.size))
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        guard setting.family.caseInsensitiveCompare("SF Mono") != .orderedSame,
            let font = NSFontManager.shared.font(
                withFamily: setting.family, traits: [], weight: 5, size: size)
        else { return system }
        let cascade = [system.fontDescriptor, NSFontDescriptor(name: "Menlo-Regular", size: size)]
        let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: cascade])
        return NSFont(descriptor: descriptor, size: size) ?? font
    }

    // MARK: - ChatKeyTarget

    package var isComposing: Bool { hasMarkedText() }

    package func chatKey(_ event: KeyEvent, dictationKey: KeyCode?) -> Bool {
        chat?.chatKey(event, dictationKey: dictationKey) ?? false
    }

    package func chatFocus(_ focused: Bool, dictationKey: KeyCode?) {
        chat?.chatFocus(focused, dictationKey: dictationKey)
    }

    // MARK: - Input with no key down

    // True from a mouse down with Option until its mouse up, or until a drag comes with no left
    // button down (a lost mouse up).
    private(set) var optionPress = false

    // A click report, a paste or a drop goes to the PTY with no key down. SwiftTerm has no drop of
    // files.
    //
    // Option+click and Option+drag make a normal selection of the text, also while Claude Code
    // reads the mouse. SwiftTerm makes a block selection on Option+drag, and Shift makes SwiftTerm
    // skip the mouse reports. So the view gives SwiftTerm each left button event of an Option press
    // with Shift in place of Option. A new press starts a new selection, not an extension of the
    // old one.
    package override func mouseDown(with event: NSEvent) {
        chat?.otherInput()
        optionPress = event.modifierFlags.contains(.option)
        if optionPress { selectNone() }
        super.mouseDown(with: optionPress ? Self.shifted(event) : event)
    }

    package override func mouseDragged(with event: NSEvent) {
        // The mouse up of the press did not come: a later drag must not get Shift.
        if pressedButtons() & 1 == 0 { optionPress = false }
        super.mouseDragged(with: optionPress ? Self.shifted(event) : event)
    }

    package override func mouseUp(with event: NSEvent) {
        let press = optionPress
        optionPress = false
        super.mouseUp(with: press ? Self.shifted(event) : event)
    }

    // The event with Shift in place of Option.
    static func shifted(_ event: NSEvent) -> NSEvent {
        var flags = event.modifierFlags
        flags.remove(.option)
        flags.insert(.shift)
        return NSEvent.mouseEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: flags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            eventNumber: event.eventNumber, clickCount: event.clickCount,
            pressure: event.pressure) ?? event
    }

    package override func rightMouseDown(with event: NSEvent) {
        chat?.otherInput()
        super.rightMouseDown(with: event)
    }

    package override func otherMouseDown(with event: NSEvent) {
        chat?.otherInput()
        super.otherMouseDown(with: event)
    }

    package override func paste(_ sender: Any) {
        chat?.otherInput()
        super.paste(sender)
    }

    // The view went into a window or left it. Metal starts only in a window.
    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        chat?.windowChanged()
    }

    // MARK: - The scroll bar

    // The scroller of SwiftTerm: a subview of the terminal view.
    private var scroller: NSScroller? {
        subviews.lazy.compactMap { $0 as? NSScroller }.first
    }

    // Show the scroll bar while the normal screen has lines above it (C13): the
    // legacy style of SwiftTerm shows at all times and takes its width from the grid. The
    // scroller of SwiftTerm keeps the clicks and the drags of the knob, but it draws nothing
    // (alpha 0). The slider draws its knob with the colours of the tokens (C21).
    func showScrollBar(_ on: Bool) {
        scrollerStyle = on ? .legacy : .overlay
        if on { scroller?.alphaValue = 0 }
        slider.isHidden = !on
        placeSlider()
    }

    // The slider stays above the scroller, also after a new Metal view moved the scroller.
    func placeSlider() {
        guard let scroller else { return }
        addSubview(slider, positioned: .above, relativeTo: scroller)
        slider.needsDisplay = true
    }

    private func addSlider() {
        guard let scroller else { return }
        slider.scroller = scroller
        slider.isHidden = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider, positioned: .above, relativeTo: scroller)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: scroller.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: scroller.trailingAnchor),
            slider.topAnchor.constraint(equalTo: scroller.topAnchor),
            slider.bottomAnchor.constraint(equalTo: scroller.bottomAnchor),
        ])
    }

    // MARK: - TerminalViewDelegate

    // The decided size of the chat terminal sets the size of the terminal. This call never
    // resizes the PTY: only the SizeSender does.
    package func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        chat?.gridChanged()
    }

    package func setTerminalTitle(source: TerminalView, title: String) {}

    package func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    // The keys, a paste and the replies of the terminal.
    package func send(source: TerminalView, data: ArraySlice<UInt8>) {
        chat?.terminalData(Array(data))
    }

    // The scroll position changed: the slider moves.
    package func scrolled(source: TerminalView, position: Double) {
        slider.needsDisplay = true
    }

    package func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // A Cmd+click on a link (OSC 8 or a link in the text).
    package func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        chat?.openLink(request.link)
    }

    package func bell(source: TerminalView) {}

    // OSC 52: Claude Code copies a selection with this sequence.
    package func clipboardCopy(source: TerminalView, content: Data) {
        chat?.copy(content)
    }

    // A program cannot read the clipboard.
    package func clipboardRead(source: TerminalView) -> Data? { nil }
}

// The slider of the scroll bar of a chat (docs/behaviour/chat.md, "The scroll bar and the screen"):
// the knob of the scroller of SwiftTerm in terminalSlider at rest and in terminalSliderHover under
// the pointer, with no track. The pointer goes through the slider to the scroller, which takes the
// clicks and the drags.
final class ScrollSlider: NSView {
    weak var scroller: NSScroller?
    // True while the pointer is on the scroll bar.
    private(set) var hovered = false

    // The colour of the knob now.
    var colour: TokenColour {
        hovered ? ThemeTokens.terminalSliderHover : ThemeTokens.terminalSlider
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addHoverArea(.activeAlways)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let scroller else { return }
        let knob = scroller.rect(for: .knob)
        guard !knob.isEmpty else { return }
        colour.nsColor.setFill()
        NSBezierPath(rect: knob).fill()
    }
}
