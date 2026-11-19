// The key recorder of Settings > Keys (docs/behaviour/keys.md, "Changing a key"). The view draws
// nothing: the Keys section shows the prompt. It has the key recorder mark, so the focus zone is
// modal: no Bifrost key acts, and the focus on it clears the hold gate.
//
// While it records, the view takes each key and never gives a key on:
// - The window key filter gives it each key event, and each key equivalent before the views and
//   the menu get it. So Cmd+W, Ctrl+Cmd+F, Cmd+Q and the other menu keys are recorded, and the
//   menu does not act. The menu still shows its keys. In a window with no key filter, the view
//   takes the keys in keyDown(with:), keyUp(with:), flagsChanged(with:) and
//   performKeyEquivalent(with:) while it has the focus.
// - The view is not a text input client, so no input method changes a key. The caller makes the
//   chord of the key event as the key rules read it (KeyEditor.checkRecorded).
// - KeyRecording.step(for:) gives the step of each key event. A recorded key goes to onKey. The
//   caller checks it (KeyEditor.checkRecorded) and calls cancel() after a good key. A refused
//   key keeps the recording.
//
// The recording ends at Esc, at Backspace or Delete with no modifier, at cancel(), when the focus
// moves to another view, when the view or a view that holds it becomes hidden, when the window
// stops being the key window or closes, and when the view leaves its window (Settings closes).
// onEnd tells each end one time. At an end the view gives up the focus, so the Bifrost keys act
// again.
//
// The Keys section shows a recorder only while its row records. That recorder starts when it
// joins the window (beginsInWindow). When a recorder leaves the window, it tells the host of the
// panel (SettingsHost.focusLeft(_:)). So a focus that fell to the window goes to the search field
// or to the panel, where Enter, Space, the arrows and the hold keys do not act.
import AppKit
import BifrostKeyboard

@MainActor
package final class KeyRecorderView: NSView {
    // Each recorded key down.
    package var onKey: ((KeyEvent) -> Void)?
    // The recording ended.
    package var onEnd: (() -> Void)?
    // True: the recording starts when the view joins a window, one time.
    package var beginsInWindow = false
    private var recording = KeyRecording()
    // The host of the Settings panel that holds the view, from the time the view joined the
    // window.
    private weak var host: SettingsHost?

    package var isRecording: Bool { recording.on }

    override package init(frame: NSRect) {
        super.init(frame: frame)
        identifier = FocusMark.keyRecorder
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // The view takes the focus only for a recording, so a click does not move the focus to it.
    override package var acceptsFirstResponder: Bool { recording.on }

    // Start a recording: the view takes the focus. A view outside a window does not record. A
    // second begin during a recording changes nothing.
    package func begin() {
        guard let window, recording.set(true) else { return }
        if !window.makeFirstResponder(self) { end(releaseFocus: false) }
    }

    // End the recording, for example after a good key. Without a recording it does nothing.
    package func cancel() {
        end(releaseFocus: true)
    }

    // A key event of the window key filter, or of the view's own key handlers. True when the
    // view took it: while it records, it takes each key event.
    @discardableResult
    package func take(_ event: NSEvent) -> Bool {
        guard recording.on else { return false }
        guard event.type == .keyDown, let key = KeyEvent(event, isComposing: false) else {
            return true
        }
        switch KeyRecording.step(for: key) {
        case .record: onKey?(key)
        case .end: cancel()
        case .ignore: break
        }
        return true
    }

    override package func keyDown(with event: NSEvent) {
        if !take(event) { super.keyDown(with: event) }
    }

    override package func keyUp(with event: NSEvent) {
        if !take(event) { super.keyUp(with: event) }
    }

    override package func flagsChanged(with event: NSEvent) {
        if !take(event) { super.flagsChanged(with: event) }
    }

    // AppKit offers a key equivalent to each view of the window, so the view takes it only while
    // it has the focus.
    override package func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, take(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override package func resignFirstResponder() -> Bool {
        end(releaseFocus: false)
        return super.resignFirstResponder()
    }

    // The view, or a view that holds it, became hidden. AppKit also takes the first responder
    // from a view that becomes hidden, so resignFirstResponder ends the recording first. This
    // method is a second guard.
    override package func viewDidHide() {
        super.viewDidHide()
        end(releaseFocus: true)
    }

    // MARK: - The end of the window

    // The notifications of the window that end a recording.
    private static let endingNotifications = [
        NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
    ]

    // The view leaves its window: the recording ends, the view stops the observation of the
    // window, and it tells the host of the panel. AppKit calls this method before each change of
    // the window, so the old window is still there. The host checks the focus after the change.
    override package func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            end(releaseFocus: false)
            if let window {
                for name in Self.endingNotifications {
                    NotificationCenter.default.removeObserver(self, name: name, object: window)
                }
                host?.focusLeft(self)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override package func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        for name in Self.endingNotifications {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowEnds(_:)), name: name, object: window)
        }
        host = SettingsHost.holding(self)
        if beginsInWindow {
            beginsInWindow = false
            begin()
        }
    }

    // The window stopped being the key window, or it closes.
    @objc private func windowEnds(_ notification: Notification) {
        end(releaseFocus: true)
    }

    // End a recording and tell it. With releaseFocus, the window takes the focus from the view.
    // The focus change calls resignFirstResponder, which finds no recording.
    private func end(releaseFocus: Bool) {
        guard recording.reset() else { return }
        if releaseFocus, let window, window.firstResponder === self {
            window.makeFirstResponder(nil)
        }
        onEnd?()
    }
}
