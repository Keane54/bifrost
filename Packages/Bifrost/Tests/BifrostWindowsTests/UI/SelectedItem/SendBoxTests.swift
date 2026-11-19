// The send box of the Selected Item panel (docs/behaviour/actions.md, "The send box"): the drafts,
// the sends and the line of SendBoxModel, and the AppKit box: the keys, the focus and the session
// that it shows. The box is in a window that is never ordered front. The sends type into the fake
// attach of the harness.
import AppKit
import BifrostKeyboard
import BifrostSessions
import BifrostTestSupport
import Testing

@testable import BifrostWindows

// The box on the harness, in a window. The runner focuses this box.
@MainActor
private final class BoxParts {
    let h: ActionsHarness
    let model: SendBoxModel
    let box: SendBoxView
    let window: NSWindow

    init(active: [AgentEntry] = [Entry.running(s1), Entry.running(s2)], all: [AgentEntry] = [])
        async throws
    {
        h = try await ActionsHarness(active: active, all: all)
        model = SendBoxModel(runner: h.runner)
        let selection = h.selection
        box = SendBoxView(model: model) { selection.selectedRow?.sessionId }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let box = box
        h.runner.focusSendBox = { box.takeFocus(for: $0, slash: $1) }
        box.frame = NSRect(x: 0, y: 0, width: 320, height: 60)
        window.contentView?.addSubview(box)
    }

    var field: SendTextView { box.field }

    // Select the session, and wait until the box shows it.
    func select(_ id: String?) async {
        h.selection.selectedId = id
        await waitUntil { box.sessionId == id }
    }

    func focus() {
        _ = window.makeFirstResponder(field)
    }

    func key(_ id: String, _ mods: Set<USKeyboard.Mod> = []) {
        guard
            let event = USKeyboard.keyEvent(
                down: true, id: id, mods: mods, isRepeat: false, window: window)
        else { return }
        field.keyDown(with: event)
    }

    // Type the text as the input method of a key gives it.
    func type(_ text: String) {
        field.insertText(text, replacementRange: field.selectedRange())
    }

    func close() {
        box.removeFromSuperview()
        window.close()
    }
}

@Suite("the send box", .serialized, .testTimeLimit, .tags(.window))
@MainActor
struct SendBoxTests {
    // Each session has its own draft. The draft stays when the selection changes, and the box
    // shows the draft of the selected session.
    @Test func theDraftOfEachSessionStays() async throws {
        let p = try await BoxParts()
        defer { p.close() }
        await p.select(s1)
        p.focus()
        p.type("one")
        #expect(p.model.draft(s1) == "one")
        await p.select(s2)
        #expect(p.field.string == "")
        p.focus()
        p.type("two")
        await p.select(s1)
        #expect(p.field.string == "one")
        #expect(p.model.draft(s2) == "two")
        // An empty draft is no draft.
        p.model.setDraft(s2, "")
        #expect(p.model.draft(s2) == "")
    }

    // A failed send keeps the draft, and its text is the failed line of that session until the
    // next change of the draft.
    @Test func aFailedSendKeepsTheDraft() async throws {
        let p = try await BoxParts()
        defer { p.close() }
        p.model.setDraft(s1, "/a\nb")
        await p.model.submit(s1)
        #expect(p.model.draft(s1) == "/a\nb")
        let failed = try #require(p.model.line(s1))
        #expect(failed.text == "A slash command has one line.")
        #expect(failed.failed)
        // Only that session has the failure.
        #expect(p.model.line(s2) == nil)
        p.model.setDraft(s1, "/a")
        let hint = try #require(p.model.line(s1))
        #expect(hint.text == SendBoxModel.slashHint)
        #expect(!hint.failed)
        p.model.setDraft(s1, "/a\nb")
        await p.model.submit(s1)
        #expect(p.model.line(s1)?.failed == true)
        p.model.clearFailure()
        #expect(p.model.line(s1)?.failed == false)
    }

    // A good send clears the draft. While it runs, the line is "Sending..." and the field is
    // read-only. A draft of only white space sends nothing.
    @Test func aGoodSendClearsTheDraft() async throws {
        let p = try await BoxParts()
        defer { p.close() }
        await p.select(s1)
        try await p.h.quietChat(s1, shortId: short1)
        p.model.setDraft(s1, "  \n ")
        await p.model.submit(s1)
        #expect(p.h.typed.isEmpty)
        p.model.setDraft(s1, "hello")
        p.model.startSubmit(s1)
        let task = try #require(p.model.lastSubmit)
        await waitUntil { p.model.isSending(s1) }
        #expect(p.model.line(s1)?.text == SendBoxModel.sendingLine)
        await waitUntil { !p.field.isEditable }
        #expect(p.field.isSelectable)
        await p.h.drive(task)
        #expect(p.h.typed.contains("hello"))
        #expect(p.model.draft(s1) == "")
        #expect(p.model.line(s1) == nil)
        await waitUntil { p.field.isEditable && p.field.string == "" }
    }

    // Enter sends the draft, Shift+Enter adds a line, and Enter during a composition does not
    // send.
    @Test func enterSendsAndShiftEnterAddsALine() async throws {
        let p = try await BoxParts()
        defer { p.close() }
        await p.select(s1)
        try await p.h.quietChat(s1, shortId: short1)
        p.focus()
        p.type("hi")
        p.key("Enter", [.shift])
        p.type("there")
        #expect(p.model.draft(s1) == "hi\nthere")
        #expect(p.model.lastSubmit == nil)
        p.field.setMarkedText(
            "k", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: p.field.selectedRange())
        #expect(p.field.hasMarkedText())
        p.key("Enter")
        #expect(p.model.lastSubmit == nil)
        p.field.unmarkText()
        p.model.setDraft(s1, "hi\nthere")
        p.field.show("hi\nthere")
        p.key("Enter")
        let task = try #require(p.model.lastSubmit)
        await p.h.drive(task)
        #expect(p.h.typed.contains("hi"))
        #expect(p.h.typed.contains("there"))
        #expect(p.model.draft(s1) == "")
    }

    // The rule of the field sends Enter with Cmd, Option or Ctrl too, as in the Electron send box.
    // In the window, the key filter takes Cmd+Enter first with the default keys (Open), so only
    // Option+Enter and Ctrl+Enter reach the box there. The test gives the keys to the field. A
    // second Enter in the same turn starts no second send.
    @Test func cmdOptionAndCtrlEnterSendToo() async throws {
        let p = try await BoxParts()
        defer { p.close() }
        await p.select(s1)
        try await p.h.quietChat(s1, shortId: short1)
        p.focus()
        for (text, mods) in [("one", USKeyboard.Mod.alt), ("two", .meta), ("three", .ctrl)] {
            p.type(text)
            p.key("Enter", [mods])
            let task = try #require(p.model.lastSubmit)
            p.key("Enter", [mods])
            #expect(p.model.lastSubmit == task)
            await p.h.drive(task)
            #expect(p.model.draft(s1) == "")
            #expect(p.h.typed.contains(text))
        }
    }

    // An Enter in the same turn as a change of the selection sends nothing: the box shows the new
    // session first, and the key goes nowhere.
    @Test func enterInTheTurnOfASelectionChangeSendsNothing() async throws {
        let p = try await BoxParts()
        defer { p.close() }
        await p.select(s1)
        p.focus()
        p.type("one")
        p.model.setDraft(s2, "two")
        p.h.selection.selectedId = s2
        p.key("Enter")
        #expect(p.model.lastSubmit == nil)
        #expect(!p.box.hasFocus)
        #expect(p.box.sessionId == s2)
        #expect(p.field.string == "two")
        #expect(p.model.draft(s1) == "one")
        #expect(p.model.draft(s2) == "two")
    }

    // A send runs on: the box can show and edit another session meanwhile. The send counts as
    // running from the key, so the text of its session cannot change in that turn. Its end
    // clears only its own draft.
    @Test func aSelectionChangeWhileASendRuns() async throws {
        let p = try await BoxParts()
        defer { p.close() }
        await p.select(s1)
        try await p.h.quietChat(s1, shortId: short1)
        p.focus()
        p.type("hello")
        p.key("Enter")
        let task = try #require(p.model.lastSubmit)
        #expect(p.model.isSending(s1))
        p.type("x")
        #expect(p.model.draft(s1) == "hello")
        await p.select(s2)
        await waitUntil { p.field.isEditable }
        #expect(p.field.string == "")
        p.focus()
        p.type("two")
        await p.h.drive(task)
        #expect(p.model.draft(s1) == "")
        #expect(p.model.draft(s2) == "two")
        #expect(p.field.string == "two")
        #expect(p.h.typed.contains("hello"))
        #expect(!p.h.typed.contains("two"))
    }

    // The undo of the field forgets the typing of the old session at a change of the session,
    // so an undo never brings back the text of another session. The typing of the new session
    // gets its own undo: an undo removes only that typing.
    @Test func anUndoAfterASessionChangeBringsBackNothing() async throws {
        let p = try await BoxParts()
        defer { p.close() }
        await p.select(s1)
        p.focus()
        p.type("abc")
        #expect(p.field.undoManager?.canUndo == true)
        await p.select(s2)
        #expect(p.field.undoManager?.canUndo == false)
        p.focus()
        p.type("de")
        #expect(p.model.draft(s2) == "de")
        p.field.undoManager?.undo()
        #expect(p.field.string == "")
        #expect(p.model.draft(s2) == "")
        #expect(p.model.draft(s1) == "abc")
    }

    // A change of the session gives up the focus at once. A key that comes before the box saw
    // the change does not type into the draft of either session.
    @Test func aSessionChangeTakesTheFocusFromTheSendBox() async throws {
        let p = try await BoxParts()
        defer { p.close() }
        await p.select(s1)
        p.focus()
        #expect(p.box.hasFocus)
        // Take control (or a focus in a chat window) selects another session. The key comes in
        // the same turn.
        p.h.selection.selectedId = s2
        p.type("x")
        #expect(!p.box.hasFocus)
        #expect(p.model.draft(s1) == "")
        #expect(p.model.draft(s2) == "")
        #expect(p.box.sessionId == s2)
        // The follow of the selection also gives up the focus.
        await p.select(s1)
        p.focus()
        await p.select(s2)
        #expect(!p.box.hasFocus)
    }

    // A focus is only for the session that the box shows. Run slash command puts "/" in an empty
    // draft, and a draft stays. A box that is off takes no focus and no text.
    @Test func aFocusPreparesTheDraftOfItsSession() async throws {
        let p = try await BoxParts()
        defer { p.close() }
        #expect(p.model.prepareFocus(for: s1, slash: false))
        #expect(p.model.draft(s1) == "")
        #expect(p.model.prepareFocus(for: s1, slash: true))
        #expect(p.model.draft(s1) == "/")
        p.model.setDraft(s1, "/re")
        #expect(p.model.prepareFocus(for: s1, slash: true))
        #expect(p.model.draft(s1) == "/re")
        #expect(!p.model.prepareFocus(for: "gone", slash: true))
        #expect(p.model.draft("gone") == "")
    }

    // Run slash command focuses the box at once, with the "/" and the caret at the end of the
    // draft. The box shows the selection of now first, so a focus for a session that the box
    // does not show any more does nothing.
    @Test func runSlashFocusesTheBoxAtOnce() async throws {
        let p = try await BoxParts()
        defer { p.close() }
        p.h.runner.run(.runSlash, s1)
        #expect(p.box.sessionId == s1)
        #expect(p.field.string == "/")
        #expect(p.box.hasFocus)
        #expect(p.field.selectedRange() == NSRange(location: 1, length: 0))
        _ = p.window.makeFirstResponder(nil)
        p.box.takeFocus(for: s2, slash: false)
        #expect(!p.box.hasFocus)
    }

    // The box shows no line of its own: no text field, only the text view. The panel shows the
    // line in its status icon.
    @Test func theSendBoxShowsNoLineOfItsOwn() async throws {
        let p = try await BoxParts()
        defer { p.close() }
        await p.select(s1)
        p.model.setDraft(s1, "/compact")
        var views: [NSView] = [p.box]
        var all: [NSView] = []
        while let view = views.popLast() {
            all.append(view)
            views += view.subviews
        }
        #expect(!all.contains { $0 is NSTextField })
        #expect(all.filter { $0 is NSText }.count == 1)
        #expect(p.box.identifier == FocusMark.sendBox)
        #expect(p.model.line(s1)?.text == SendBoxModel.slashHint)
    }

    // The box is off while Send message is off: no focus, no edit, at 40 % opacity, and its
    // line is the reason. The placeholder and the label are the label of Send message.
    @Test func theBoxIsOffWhileSendMessageIsOff() async throws {
        let p = try await BoxParts(active: [Entry.running(s1)], all: [Entry.stopped(s2)])
        defer { p.close() }
        await p.select(s1)
        #expect(p.field.isEditable)
        #expect(p.field.placeholder == "Send message...")
        #expect(p.field.accessibilityLabel() == "Send message...")
        p.focus()
        await p.select(s2)
        #expect(!p.box.hasFocus)
        await waitUntil { !p.field.isEditable }
        #expect(!p.field.isSelectable)
        #expect(p.box.alphaValue == 0.4)
        _ = p.window.makeFirstResponder(p.field)
        #expect(p.window.firstResponder !== p.field)
        #expect(p.model.line(s2)?.text == "This session is parked. Resume it first.")
        // A submit while the box is off sends nothing and keeps the draft.
        p.model.setDraft(s2, "hello")
        await p.model.submit(s2)
        #expect(p.model.draft(s2) == "hello")
        #expect(!p.model.isSending(s2))
    }
}
