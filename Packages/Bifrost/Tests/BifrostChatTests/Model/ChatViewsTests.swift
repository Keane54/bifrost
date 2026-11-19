import BifrostChat
import BifrostFoundation
import BifrostLayout
import BifrostTestSupport
import Testing

// The chat views of the sessions (docs/behaviour/chat.md). The attach targets have their tests
// in AttachRulesTests.swift. A panel ID of a chat must hold a session ID of 8-4-4-4-12 hex
// digits, so the tests use such IDs in place of "a", "b" and "c".

private let a = "aaaaaaaa-0000-4000-8000-000000000000"
private let b = "bbbbbbbb-0000-4000-8000-000000000000"
private let c = "cccccccc-0000-4000-8000-000000000000"

private func chat(_ session: String) -> String { "chat:\(session)" }

private func frame(_ number: Int, _ panels: [String], _ active: String, minimised: Bool = false)
    -> LayoutFrame
{
    LayoutFrame(
        id: frameID(number), panels: panels.map(panel), active: panel(active),
        rect: rect(h: 100, w: 100, x: 0, y: 0), minimised: minimised, locked: false)
}

// A layout with these frames, in z-order.
private func layout(_ frames: [LayoutFrame]) -> WindowLayout {
    var layout = WindowLayout(bounds: size(h: 800, w: 1200))
    let saved = frames.map {
        SavedFrame(
            panels: $0.panels, active: $0.active, rect: $0.rect, minimised: $0.minimised,
            locked: $0.locked)
    }
    layout.apply(.load(LayoutSnapshot(frames: saved, memory: [:])))
    return layout
}

@Suite("chat ids")
struct ChatIdTests {
    @Test("a chat panel ID and its session ID convert both ways")
    func bothWays() {
        #expect(PanelID.chat(SessionID(a)!).text == "chat:\(a)")
        #expect(panel(chat(a)) == .chat(SessionID(a)!))
        #expect(PanelID("chat:") == nil)
    }

    @Test
    func backTabsAndMinimisedFrames() {
        let frames = [
            frame(1, ["overview:1", chat(a), chat(b)], chat(a)),
            frame(2, [chat(c)], chat(c), minimised: true),
        ]
        #expect(ChatViews.openChatIds(frames).map(\.text) == [a, b, c])
    }
}

@Suite("chat view IDs")
struct ChatViewsTests {
    @Test("the active chat of the top frame is focused and visible")
    func theTopFrame() {
        let views = ChatViews.views(
            layout([frame(1, [chat(a)], chat(a)), frame(2, [chat(b)], chat(b))]))
        #expect(views[b] == ChatView(visible: true, focused: true))
        #expect(views[a] == ChatView(visible: true, focused: false))
    }

    @Test
    func aBackTabAndAMinimisedChat() {
        let views = ChatViews.views(
            layout([
                frame(1, [chat(a), chat(b)], chat(a)),
                frame(2, [chat(c)], chat(c), minimised: true),
            ]))
        #expect(views[b] == ChatView(visible: false, focused: false))
        #expect(views[c] == ChatView(visible: false, focused: false))
        // The minimised frame is on top but is not the top frame.
        #expect(views[a] == ChatView(visible: true, focused: true))
    }
}

@Suite("gaining focus")
struct GainedFocusTests {
    @Test
    func theChatsThatBecameFocused() {
        let view = { (focused: Bool) in ChatView(visible: true, focused: focused) }
        let before = ["a": view(true), "b": view(false)]
        let after = ["a": view(false), "b": view(true)]
        #expect(ChatViews.gainedFocus(before, after) == ["b"])
        #expect(ChatViews.gainedFocus(after, after).isEmpty)
    }

    @Test("a new chat is focused")
    func aNewChat() {
        let after = ["c": ChatView(visible: true, focused: true)]
        #expect(ChatViews.gainedFocus([:], after) == ["c"])
    }
}
