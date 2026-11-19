import AppKit
import BifrostTestSupport
import Testing

@testable import BifrostDictation
@testable import BifrostLook

// A flipped parent view, as the chat body.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// The notice line of a chat: the text, the button of System Settings and the announcement.
@Suite("the notice line shows its text and its button, and announces each new text", .tags(.window))
@MainActor
struct DictationNoticeViewTests {
    @Test
    func textWithNoButton() {
        // The parent stands in for the chat body. A hit test takes a point of the parent.
        let parent = FlippedView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        let notice = DictationNoticeView(frame: parent.bounds)
        parent.addSubview(notice)
        #expect(notice.isHidden)
        notice.show(NoticeLine(text: DictationNoticeText.modelReady, opensSettings: false))
        // The notice lays out in the layout pass of AppKit. The test runs the pass.
        parent.layoutSubtreeIfNeeded()
        #expect(!notice.isHidden)
        #expect(notice.label.stringValue == DictationNoticeText.modelReady)
        #expect(notice.button.isHidden)
        #expect(notice.accessibilityChildren()?.count == 1)
        // The line is at the top of the chat, in the middle, and it takes no pointer input.
        #expect(notice.box.frame.minY == 8)
        #expect(abs(notice.box.frame.midX - 300) <= 1)
        let middle = parent.convert(
            NSPoint(x: notice.box.bounds.midX, y: notice.box.bounds.midY), from: notice.box)
        #expect(notice.hitTest(middle) == nil)
        notice.show(NoticeLine(text: DictationNoticeText.error(.micDenied), opensSettings: true))
        parent.layoutSubtreeIfNeeded()
        #expect(!notice.button.isHidden)
        #expect(notice.button.title == DictationNoticeText.openSettings)
        let button = parent.convert(
            NSPoint(x: notice.button.bounds.midX, y: notice.button.bounds.midY),
            from: notice.button)
        #expect(notice.hitTest(button) === notice.button)
        notice.show(nil)
        #expect(notice.isHidden)
    }

    // The line is a status for VoiceOver (role="status"): each new text is announced one time.
    @Test func eachNewTextIsAnnouncedOneTime() {
        let notice = DictationNoticeView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        var said: [String] = []
        notice.announce = { said.append($0) }
        let ready = NoticeLine(text: DictationNoticeText.modelReady, opensSettings: false)
        notice.show(ready)
        notice.show(ready)
        #expect(said == [DictationNoticeText.modelReady])
        notice.show(nil)
        notice.show(ready)
        let denied = NoticeLine(
            text: DictationNoticeText.error(.micDenied), opensSettings: true)
        notice.show(denied)
        #expect(
            said == [
                DictationNoticeText.modelReady, DictationNoticeText.modelReady,
                DictationNoticeText.error(.micDenied),
            ])
    }
}
