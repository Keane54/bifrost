import AppKit
import BifrostFoundation
import BifrostKeyboard
import BifrostLayout
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSettings

// The parts of the tests of the Settings panel: a settings store in a temporary folder, the layout
// with Settings open, and the model. The model records each text that it tells a screen reader.
// A test of Live details or Skills gives the live model of its controls (LiveParts).
@MainActor
final class SettingsParts {
    let folder: TemporaryFolder
    let store: SettingsStore
    let layout = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1200, h: 800)))
    let model: SettingsModel
    var said: [String] = []

    // steps: the steps of the safe write, so a test can hold a write (WriteGate).
    init(steps: WriteSteps = .system, live: LiveModel = LiveModel()) async throws {
        folder = try TemporaryFolder()
        store = await SettingsStore.open(
            file: folder.url.appending(path: "settings.json"), log: Recorder<StoreEvent>(),
            steps: steps)
        model = SettingsModel(store: store, layout: layout, live: live)
        model.announce = { [unowned self] in said.append($0) }
        model.open()
    }

    // True while a frame holds the Settings panel.
    var isOpen: Bool { layout.layout.frame(of: .settings) != nil }

    deinit { folder.remove() }
}

// The draft of the field for a new slash command, as Settings > Slash commands saves it.
@MainActor
func slashDraft(_ model: SettingsModel) -> (String) -> TextSave {
    SlashSection.draftSave(model)
}

// The row of the field for a new slash command.
let newSlashRow = SlashSection.newRow

// The Settings panel in its host, in a window that is never ordered front.
@MainActor
final class ShownSettings {
    let parts: SettingsParts
    let panels = SettingsPanels()
    let window: NSWindow
    let body: SettingsBody
    let host: SettingsHost
    // A view outside the panel that can take the focus.
    let other = NSTextField(string: "")

    init(steps: WriteSteps = .system, live: LiveModel = LiveModel()) async throws {
        UITestApp.prepare()
        parts = try await SettingsParts(steps: steps, live: live)
        panels.attach(parts.model)
        window = KeyTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 600))
        window.contentView = content
        guard let body = panels.body(for: .settings) as? SettingsBody, let host = body.host else {
            throw ShownError.noHost
        }
        self.body = body
        self.host = host
        body.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        content.addSubview(body)
        other.frame = NSRect(x: 0, y: 560, width: 200, height: 22)
        content.addSubview(other)
        host.layoutSubtreeIfNeeded()
    }

    enum ShownError: Error {
        case noHost
    }

    var model: SettingsModel { parts.model }

    // The text field of the panel that edits now, or nil.
    var editingField: NSTextField? {
        (window.firstResponder as? NSTextView)?.delegate as? NSTextField
    }

    // A key event of a US keyboard for this window.
    func key(_ id: String, _ mods: Set<USKeyboard.Mod> = [], down: Bool = true) -> NSEvent? {
        USKeyboard.keyEvent(down: down, id: id, mods: mods, isRepeat: false, window: window)
    }

    // The text field of the panel with the accessibility label, after SwiftUI made it.
    func field(_ label: String, sourceLocation: SourceLocation = #_sourceLocation) async
        -> NSTextField?
    {
        var found: NSTextField?
        await render(host, sourceLocation: sourceLocation) {
            found = SettingsPanelTests.textFields(in: host).first {
                $0.accessibilityLabel() == label
            }
            return found != nil
        }
        return found
    }

    // Replace the text of the field with the text, as the user types it. The result is the field
    // editor.
    @discardableResult
    func type(_ text: String, into field: NSTextField) -> NSTextView? {
        #expect(window.makeFirstResponder(field))
        guard let editor = window.firstResponder as? NSTextView else {
            Issue.record("The field does not edit.")
            return nil
        }
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return editor
    }

    // The key recorder of the panel, after SwiftUI made it, or nil.
    var recorder: KeyRecorderView? {
        var next: [NSView] = [host]
        while let view = next.popLast() {
            if let recorder = view as? KeyRecorderView { return recorder }
            next += view.subviews
        }
        return nil
    }

    func close() { window.close() }
}

// A window that acts as the key window, so its text views have an input context. The tests never
// order it front.
final class KeyTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

// Let SwiftUI apply the changes of the model to the views under the view until the condition is
// true: SwiftUI updates its views in turns of the run loop. The wait lays out the views and
// checks the condition, then it suspends for 10 ms (waitUntil). During the suspension the run
// loop turns, and the other jobs of the main actor run. The wait has a limit on the real clock.
// At the limit it records an issue at the line of the caller and gives false.
//
// Do not run the run loop in this wait. A nested run of the run loop in a job of the main queue
// does not run the other jobs of the main queue, so each other test that uses the main actor
// stops until the condition is true.
//
// SwiftUI updates the AppKit view of a view (NSViewRepresentable) only when the values of the
// view change. Until AttributeGraph has the compare layout of a type of view, it counts each
// update as a change, and it makes that layout in the background. So the first update of a type
// in a test run can update an AppKit view whose values did not change, and a later one does not.
// A test that needs such an update passes only when it runs first. With AG_ASYNC_LAYOUTS=0 in the
// environment, AttributeGraph makes each layout at once, so each test sees the later behaviour.
@MainActor
@discardableResult
func render(
    _ view: NSView, within limit: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation, until condition: () -> Bool
) async -> Bool {
    await waitUntil(within: limit, sourceLocation: sourceLocation) {
        view.layoutSubtreeIfNeeded()
        return condition()
    }
}
