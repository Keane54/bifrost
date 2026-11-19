// The key recorder of Settings > Keys (docs/behaviour/keys.md, "Changing a key"), in a plain
// window that is never ordered front. The window key filter of the app is in the tests of
// BifrostWindows.
import AppKit
import BifrostTestSupport
import Testing

@testable import BifrostKeyboard
@testable import BifrostSettings

@MainActor
@Suite("the key recorder", .serialized, .testTimeLimit, .tags(.window))
struct KeyRecorderViewTests {
    // A window with a key recorder and a view behind it that records the keys that get past the
    // recorder.
    @MainActor
    private final class Parts {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled],
            backing: .buffered, defer: false)
        let content = PassedKeysView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let recorder = KeyRecorderView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        let other = PassedKeysView(frame: NSRect(x: 0, y: 100, width: 50, height: 50))
        var keys: [String] = []
        var ends = 0

        init() {
            UITestApp.prepare()
            window.isReleasedWhenClosed = false
            window.contentView = content
            content.addSubview(recorder)
            content.addSubview(other)
            recorder.onKey = { [weak self] in self?.keys.append(Chord(event: $0)?.text ?? "none") }
            recorder.onEnd = { [weak self] in self?.ends += 1 }
        }

        // A key down of a US keyboard, as AppKit gives it to the first responder.
        func event(_ id: String, _ mods: Set<USKeyboard.Mod> = [], isRepeat: Bool = false)
            -> NSEvent?
        {
            USKeyboard.keyEvent(down: true, id: id, mods: mods, isRepeat: isRepeat, window: window)
        }

        func press(_ id: String, _ mods: Set<USKeyboard.Mod> = [], isRepeat: Bool = false) {
            guard let event = event(id, mods, isRepeat: isRepeat) else {
                Issue.record("no key \(id)")
                return
            }
            window.sendEvent(event)
        }

        // A key equivalent, as AppKit offers it to the views of the key window before the menu.
        func keyEquivalent(_ id: String, _ mods: Set<USKeyboard.Mod>) -> Bool {
            guard let event = event(id, mods) else { return false }
            return window.performKeyEquivalent(with: event)
        }

        // A key down as the app gives it: first as a key equivalent, then to the window.
        func appPress(_ id: String, _ mods: Set<USKeyboard.Mod> = []) {
            guard let event = event(id, mods) else {
                Issue.record("no key \(id)")
                return
            }
            if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
        }
    }

    // The recorder has the key recorder mark, so the focus zone is modal and no Bifrost key acts.
    // It takes the focus only while it records.
    @Test func theRecorderHasTheMarkAndTakesTheFocusWhileItRecords() {
        let p = Parts()
        #expect(p.recorder.identifier == FocusMark.keyRecorder)
        #expect(!p.recorder.acceptsFirstResponder)
        p.recorder.begin()
        #expect(p.recorder.acceptsFirstResponder)
        #expect(p.recorder.isRecording)
        #expect(p.window.firstResponder === p.recorder)
        #expect(KeyFocus(p.window.firstResponder, in: p.window).zone == .modal)
    }

    // Each key down goes to onKey with its place and its modifiers, and no key goes on to the
    // views behind the recorder: Tab, Enter and Space are keys like the others.
    @Test func eachKeyDownGoesToTheRecorderAndNoKeyGoesOn() {
        let p = Parts()
        p.recorder.begin()
        p.press("o", [.alt])
        p.press("Tab", [.shift])
        p.press("Enter")
        p.press("Space")
        p.press("1", [.shift])
        #expect(p.keys == ["Alt+O", "Shift+Tab", "Enter", "Space", "Shift+1"])
        #expect(p.content.keys.isEmpty)
        #expect(p.recorder.isRecording)
        #expect(p.ends == 0)
    }

    // The recorder takes each key equivalent while it records, before the menu: Cmd+W,
    // Ctrl+Cmd+F and Cmd+Q are recorded. Without a recording, it takes none.
    @Test func theRecorderTakesTheKeyEquivalentsOnlyWhileItRecords() {
        let p = Parts()
        #expect(!p.keyEquivalent("w", [.meta]))
        p.recorder.begin()
        #expect(p.keyEquivalent("w", [.meta]))
        #expect(p.keyEquivalent("f", [.ctrl, .meta]))
        #expect(p.keyEquivalent("q", [.meta]))
        #expect(p.keys == ["Mod+W", "Mod+Control+F", "Mod+Q"])
        p.recorder.cancel()
        #expect(!p.keyEquivalent("w", [.meta]))
        #expect(p.keys.count == 3)
    }

    // A key repeat is not a new key.
    @Test func aKeyRepeatIsNotRecorded() {
        let p = Parts()
        p.recorder.begin()
        p.press("k", [.meta], isRepeat: true)
        #expect(p.keys.isEmpty)
        #expect(p.content.keys.isEmpty)
    }

    // Esc and a plain Backspace or Delete end the recording with no key. Shift+Backspace is a
    // key.
    @Test func escAndAPlainBackspaceEndTheRecording() {
        for (id, mods) in [("Escape", []), ("Escape", [.meta]), ("Backspace", []), ("Delete", [])]
            as [(String, Set<USKeyboard.Mod>)]
        {
            let p = Parts()
            p.recorder.begin()
            p.appPress(id, mods)
            #expect(p.keys.isEmpty, "\(id)")
            #expect(!p.recorder.isRecording, "\(id)")
            #expect(p.ends == 1, "\(id)")
            // The recorder gives up the focus, so the Bifrost keys act again.
            #expect(p.window.firstResponder === p.window, "\(id)")
            #expect(p.content.keys.isEmpty, "\(id)")
        }
        let p = Parts()
        p.recorder.begin()
        p.press("Backspace", [.shift])
        #expect(p.keys == ["Shift+Backspace"])
        #expect(p.recorder.isRecording)
    }

    // cancel ends the recording one time. A second cancel does nothing.
    @Test func cancelEndsTheRecordingOneTime() {
        let p = Parts()
        p.recorder.cancel()
        #expect(p.ends == 0)
        p.recorder.begin()
        p.recorder.begin()
        #expect(p.ends == 0)
        p.recorder.cancel()
        p.recorder.cancel()
        #expect(p.ends == 1)
        #expect(p.window.firstResponder === p.window)
        // Without a recording, a key goes on to the next responder.
        #expect(p.window.makeFirstResponder(p.other))
        p.press("k")
        #expect(p.keys.isEmpty)
        #expect(p.other.keys == ["k"])
    }

    // Closing Settings takes the recorder out of the window, and closing the window ends it too.
    @Test func aCloseOfSettingsOrOfTheWindowEndsTheRecording() {
        let settings = Parts()
        settings.recorder.begin()
        settings.recorder.removeFromSuperview()
        #expect(!settings.recorder.isRecording)
        #expect(settings.ends == 1)
        let window = Parts()
        window.recorder.begin()
        window.window.close()
        #expect(!window.recorder.isRecording)
        #expect(window.ends == 1)
    }

    // A move of the focus to another view, and a window that stops being the key window, end
    // the recording.
    @Test func aBlurOfTheRecorderOrOfTheWindowEndsTheRecording() {
        let focus = Parts()
        focus.recorder.begin()
        #expect(focus.window.makeFirstResponder(focus.other))
        #expect(!focus.recorder.isRecording)
        #expect(focus.ends == 1)
        #expect(focus.window.firstResponder === focus.other)
        let blur = Parts()
        blur.recorder.begin()
        let resign = NSWindow.didResignKeyNotification
        NotificationCenter.default.post(name: resign, object: blur.window)
        #expect(!blur.recorder.isRecording)
        #expect(blur.ends == 1)
        // The notification of another window does not end a recording.
        let other = Parts()
        other.recorder.begin()
        NotificationCenter.default.post(name: resign, object: blur.window)
        #expect(other.recorder.isRecording)
    }

    // A view that holds the recorder becomes hidden, for example a section of Settings. The
    // recording ends one time, and the recorder gives up the focus. AppKit also takes the first
    // responder from a view that becomes hidden, so resignFirstResponder ends the recording too.
    // viewDidHide is a second guard.
    @Test func aHiddenAncestorEndsTheRecording() {
        let p = Parts()
        let section = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        p.content.addSubview(section)
        section.addSubview(p.recorder)
        p.recorder.begin()
        #expect(p.window.firstResponder === p.recorder)
        section.isHidden = true
        #expect(!p.recorder.isRecording)
        #expect(p.ends == 1)
        #expect(p.window.firstResponder !== p.recorder)
    }

    // A modifier key during the recording does not get to the views behind the recorder.
    @Test func aModifierKeyDuringTheRecordingDoesNotReachTheViews() throws {
        let p = Parts()
        p.recorder.begin()
        let shift = try #require(
            USKeyboard.modifierEvent(id: "Shift", mods: [.shift], window: p.window))
        p.window.sendEvent(shift)
        #expect(p.content.flags == 0)
        #expect(p.keys.isEmpty)
        #expect(p.recorder.isRecording)
        // Without a recording the event goes on.
        p.recorder.cancel()
        #expect(p.window.makeFirstResponder(p.other))
        p.window.sendEvent(shift)
        #expect(p.other.flags == 1)
    }

    // The recorder watches only the window that holds it. In a second window, the end of the
    // first window does not end the recording, and the end of the second one does.
    @Test func theRecorderWatchesOnlyItsOwnWindow() {
        let first = Parts()
        let second = Parts()
        second.content.addSubview(first.recorder)
        first.recorder.begin()
        #expect(second.window.firstResponder === first.recorder)
        let resign = NSWindow.didResignKeyNotification
        NotificationCenter.default.post(name: resign, object: first.window)
        #expect(first.recorder.isRecording)
        NotificationCenter.default.post(name: resign, object: second.window)
        #expect(!first.recorder.isRecording)
        #expect(first.ends == 1)
    }

    // begin needs a window: a recorder outside a window does not record.
    @Test func aRecorderOutsideAWindowDoesNotRecord() {
        UITestApp.prepare()
        let recorder = KeyRecorderView(frame: .zero)
        recorder.begin()
        #expect(!recorder.isRecording)
    }
}

// A view that records the key downs and counts the modifier changes that get to it.
private final class PassedKeysView: NSView {
    private(set) var keys: [String] = []
    private(set) var flags = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keys.append(event.characters ?? "") }
    override func flagsChanged(with event: NSEvent) { flags += 1 }
}
