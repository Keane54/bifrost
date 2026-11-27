import AppKit
import BifrostFoundation
import BifrostSessions
import BifrostTestSupport
import Foundation
import Observation
import Synchronization
import Testing

@testable import BifrostChat
@testable import BifrostDictation
@testable import BifrostLayout
@testable import BifrostLook
@testable import BifrostWindows

// The canvas, the frames and the drag (docs/behaviour/windows.md). Each test has its own
// window, which is never ordered front. MouseDriver gives the mouse events (MouseEvents.swift).
@MainActor
@Suite("canvas", .serialized, .testTimeLimit, .tags(.window))
struct CanvasTests {
    // A drag of the title bar moves only the frame view, with no snap. The layout gets the
    // snapped rect at the release.
    @Test func aTitleBarDragMovesTheFrameAndSnapsOnRelease() {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let b = f.open("watchlist", at: rect(600, 100, 300, 300))
        f.mouse.down(at: CGPoint(x: 200, y: 110), in: f.canvas)
        #expect(f.model.layout.topFrame?.id == a)
        f.mouse.drag(to: CGPoint(x: 295, y: 112), in: f.canvas)
        // The raw rect: 95 to the right and 2 down. The right edge is 5 from the left edge of b.
        #expect(f.view(a).frame == CGRect(x: 195, y: 102, width: 400, height: 300))
        #expect(f.frame(a)?.rect == rect(100, 100, 400, 300))
        f.mouse.up(at: CGPoint(x: 295, y: 112), in: f.canvas)
        // The release snaps the right edge to b and the top edge to the top of b.
        #expect(f.frame(a)?.rect == rect(200, 100, 400, 300))
        #expect(f.view(a).frame == CGRect(x: 200, y: 100, width: 400, height: 300))
        #expect(f.frame(b)?.rect == rect(600, 100, 300, 300))
        #expect(f.model.drag == nil)
    }

    @Test func onlyTheDraggedFrameViewChangesDuringADrag() {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let b = f.open("watchlist", at: rect(600, 100, 300, 300))
        let c = f.open("event-log", at: rect(100, 450, 400, 300))
        f.mouse.down(at: CGPoint(x: 200, y: 110), in: f.canvas)
        let layout = f.model.layout
        let syncs = f.canvas.syncCount
        let others = [f.view(b).frame, f.view(c).frame]
        for step in 1...20 {
            let point = CGPoint(x: 200 + Double(step) * 7, y: 110 + Double(step))
            f.mouse.drag(to: point, in: f.canvas)
        }
        #expect(f.view(a).frame.origin == CGPoint(x: 240, y: 120))
        #expect([f.view(b).frame, f.view(c).frame] == others)
        // The layout and the other frames get no step. The steps make no implicit animation.
        #expect(f.model.layout == layout)
        #expect(f.canvas.syncCount == syncs)
        #expect(f.view(a).layer?.animationKeys() == nil)
        f.mouse.up(at: CGPoint(x: 340, y: 130), in: f.canvas)
        #expect(f.frame(a)?.rect == rect(240, 120, 400, 300))
    }

    @Test func theSnapMarksShowDuringADragAndGoAtTheRelease() {
        let f = CanvasFixture()
        defer { f.close() }
        f.open("settings", at: rect(100, 100, 400, 300))
        f.open("watchlist", at: rect(600, 100, 300, 300))
        f.mouse.down(at: CGPoint(x: 200, y: 110), in: f.canvas)
        f.mouse.drag(to: CGPoint(x: 250, y: 160), in: f.canvas)
        // Far from each line: no mark.
        #expect(f.canvas.marks.shown == [])
        f.mouse.drag(to: CGPoint(x: 295, y: 112), in: f.canvas)
        let marks = [
            SnapMark(x: 600, y: 250, direction: .right), SnapMark(x: 600, y: 100, direction: .up),
        ]
        #expect(f.canvas.marks.shown == marks)
        #expect(f.model.drag?.marks == marks)
        // Each arrow is 10 by 10, centred on its point and inside the area.
        #expect(f.canvas.marks.arrowFrames == [
            CGRect(x: 595, y: 245, width: 10, height: 10),
            CGRect(x: 595, y: 95, width: 10, height: 10),
        ])
        #expect(!f.canvas.marks.isAccessibilityElement())
        #expect(f.canvas.marks.hitTest(CGPoint(x: 600, y: 250)) == nil)
        f.mouse.up(at: CGPoint(x: 295, y: 112), in: f.canvas)
        #expect(f.canvas.marks.shown == [])
    }

    @Test func aDropOnATitleBarStacksTheFramesAsTabs() throws {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 300, 400, 300))
        let b = f.open("watchlist", at: rect(600, 100, 300, 300))
        f.mouse.down(at: CGPoint(x: 150, y: 310), in: f.canvas)
        f.mouse.drag(to: CGPoint(x: 650, y: 110), in: f.canvas)
        // The outline is over the title bar of b, and no snap mark shows.
        #expect(f.model.drag?.dropTarget == b)
        #expect(!f.canvas.outline.isHidden)
        #expect(f.canvas.outline.frame == CGRect(x: 600, y: 100, width: 300, height: 28))
        #expect(f.canvas.marks.shown == [])
        #expect(f.canvas.subviews.last === f.canvas.outline)
        f.mouse.up(at: CGPoint(x: 650, y: 110), in: f.canvas)
        #expect(f.canvas.outline.isHidden)
        #expect(f.frame(a) == nil)
        let stack = try #require(f.frame(b))
        #expect(stack.panels == [panel("watchlist"), panel("settings")])
        #expect(stack.active == panel("settings"))
        let tabs = f.view(b).titleBar.tabViews
        #expect(tabs.map(\.title) == ["Watchlist", "Settings"])
        #expect(tabs.map(\.isActive) == [false, true])
        #expect(f.canvas.frameView(a) == nil)
    }

    @Test func aTabDragPast12PointsTearsOutANewFrame() throws {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("watchlist", at: rect(600, 100, 300, 300))
        let b = f.open("settings", at: rect(100, 450, 400, 250))
        f.model.apply(.stack(b, onto: a))
        let tab = try #require(f.view(a).titleBar.tabViews.first)
        let start = f.centre(of: tab)
        f.mouse.down(at: start, in: f.canvas)
        // 12 below the title bar (y 100 to 128) is not a tear-out.
        f.mouse.drag(to: CGPoint(x: start.x, y: 140), in: f.canvas)
        #expect(f.model.layout.frames.count == 1)
        f.mouse.drag(to: CGPoint(x: start.x, y: 141), in: f.canvas)
        let torn = try #require(f.model.layout.frame(of: panel("watchlist")))
        #expect(torn.id == FrameID(number: 3))
        // The new frame is 60 left of the pointer and 14 above it, with the size of the stack.
        #expect(torn.rect == rect((start.x - 60).rounded(), 127, 300, 300))
        #expect(f.frame(a)?.panels == [panel("settings")])
        #expect(f.view(a).titleBar.tabViews.isEmpty)
        // The same drag moves the new frame.
        f.mouse.drag(to: CGPoint(x: start.x - 100, y: 241), in: f.canvas)
        let x = (start.x - 160).rounded()
        #expect(f.view(torn.id).frame.origin == CGPoint(x: x, y: 227))
        f.mouse.up(at: CGPoint(x: start.x - 100, y: 241), in: f.canvas)
        #expect(f.frame(torn.id)?.rect == rect(x, 227, 300, 300))
        #expect(f.model.layout.topFrame?.id == torn.id)
    }

    // The body view of a panel is made one time. It stays the same view through a stack, a tab
    // change, a minimise and a tear-out.
    @Test func theBodyOfAPanelSurvivesAStackAndATearOut() throws {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("watchlist", at: rect(600, 100, 300, 300))
        let b = f.open("settings", at: rect(100, 450, 400, 250))
        let watchlist = try #require(f.view(a).shownBody)
        let settings = try #require(f.view(b).shownBody)
        f.mouse.drag(
            from: CGPoint(x: 150, y: 460), through: [CGPoint(x: 650, y: 110)], in: f.canvas)
        #expect(f.view(a).shownBody === settings)
        #expect(settings.isDescendant(of: f.view(a)))
        // A click on the other tab shows its body.
        let first = try #require(f.view(a).titleBar.tabViews.first)
        f.mouse.drag(from: f.centre(of: first), through: [f.centre(of: first)], in: f.canvas)
        #expect(f.frame(a)?.active == panel("watchlist"))
        #expect(f.view(a).shownBody === watchlist)
        #expect(settings.superview == nil)
        f.model.apply(.minimise(a))
        f.model.apply(.restore(a))
        #expect(f.view(a).shownBody === watchlist)
        // Tear out the Settings tab: its body goes to the new frame.
        let second = try #require(f.view(a).titleBar.tabViews.last)
        let start = f.centre(of: second)
        f.mouse.drag(
            from: start, through: [CGPoint(x: start.x, y: 200), CGPoint(x: 300, y: 300)],
            in: f.canvas)
        let torn = try #require(f.model.layout.frame(of: panel("settings")))
        #expect(torn.id != a)
        #expect(f.view(torn.id).shownBody === settings)
        #expect(f.view(a).shownBody === watchlist)
        #expect(f.bodies.made == [panel("watchlist"): 1, panel("settings"): 1])
        #expect(f.bodies.released == [])
    }

    // A press on any part of a frame brings it to the front, also a press in the body and a
    // press of another button. The body takes each press, as
    // a terminal does, so only the gesture recognizer of the frame sees the press.
    @Test func aPressInTheBodyBringsTheFrameToTheFront() throws {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let b = f.open("watchlist", at: rect(600, 100, 300, 300))
        let body = try #require(f.view(a).shownBody)
        let hit = f.mouse.down(at: CGPoint(x: 300, y: 250), in: f.canvas)
        #expect(hit === body)
        #expect(f.model.layout.topFrame?.id == a)
        #expect(f.model.drag == nil)
        f.mouse.up(at: CGPoint(x: 300, y: 250), in: f.canvas)
        f.mouse.down(at: CGPoint(x: 700, y: 250), in: f.canvas, type: .rightMouseDown)
        #expect(f.model.layout.topFrame?.id == b)
    }

    // A right or other-button press that the top frame passes on never reaches the frame under
    // it. AppKit hands a press that a view passes on to the view beneath it at the same point, so
    // a right press on overlapping title bars went into the lower frame, which came to the front
    // and passed it back up, and the two frames swapped until the main thread ran out of stack
    // (the right-click crash of 1.3.0). The test lets the canvas see only the first few layout
    // changes, so the old swap ends with a failure here, not a crash.
    @Test func aPressOnTheTopFrameNeverReachesTheFrameUnderIt() throws {
        let f = CanvasFixture()
        defer { f.close() }
        // The title bar of the lower frame is at y 80 to 108 and its body starts at 108. The top
        // frame's title bar is at y 90 to 118, over both.
        _ = f.open("watchlist", at: rect(150, 80, 400, 300))
        let top = f.open("settings", at: rect(100, 90, 400, 300))
        let lowerBody = try #require(f.bodies.views[panel("watchlist")])
        var changes = 0
        let forward = f.model.onChange
        f.model.onChange = { change in
            changes += 1
            if changes <= 8 { forward?(change) }
        }
        let overTitleBars = CGPoint(x: 300, y: 100)
        let overLowerBody = CGPoint(x: 300, y: 114)
        for point in [overTitleBars, overLowerBody] {
            for type in [NSEvent.EventType.rightMouseDown, .otherMouseDown] {
                let hit = f.mouse.down(at: point, in: f.canvas, type: type)
                #expect(hit === f.view(top).titleBar)
            }
        }
        #expect(changes == 0)
        #expect(f.model.layout.focusedFrame?.id == top)
        #expect(f.view(top).isTop)
        #expect(lowerBody.rightPresses == 0)
        #expect(lowerBody.otherPresses == 0)
    }

    // A drag or a release of the right or other button, or a scroll, that the top frame passes
    // on never reaches the frame under it either. Through super AppKit gave it to the view
    // beneath, so a chat terminal there got a release it never saw pressed, and a scroll over
    // the title bar scrolled the panel under it. A plain view over the part of the lower body
    // that the top frame leaves free shows first that the events of the test do reach the view
    // beneath when nothing hands them on.
    @Test func aDragAReleaseOrAScrollOnTheTopFrameNeverReachesTheFrameUnderIt() throws {
        let f = CanvasFixture()
        defer { f.close() }
        _ = f.open("watchlist", at: rect(150, 80, 400, 300))
        let top = f.open("settings", at: rect(100, 90, 400, 300))
        let lowerBody = try #require(f.bodies.views[panel("watchlist")])
        let topBody = try #require(f.bodies.views[panel("settings")])
        let types: [NSEvent.EventType] = [
            .rightMouseDragged, .rightMouseUp, .otherMouseDragged, .otherMouseUp, .scrollWheel,
        ]
        let cover = NSView()
        f.canvas.dialogLayer = cover
        let besideTheTopFrame = CGPoint(x: 520, y: 200)
        for type in types {
            #expect(f.mouse.send(type, at: besideTheTopFrame, in: f.canvas) === cover)
        }
        #expect(lowerBody.passedOn == types)
        f.canvas.dialogLayer = nil
        let overLowerBody = CGPoint(x: 300, y: 114)
        for type in types {
            #expect(f.mouse.send(type, at: overLowerBody, in: f.canvas) === f.view(top).titleBar)
        }
        #expect(lowerBody.passedOn == types)
        #expect(topBody.passedOn.isEmpty)
        #expect(f.model.layout.focusedFrame?.id == top)
    }

    // A right or other-button press, drag or release on the backdrop of a dialog stops at the
    // overlay and the canvas, as on a frame. Through super AppKit gave it to the view behind the
    // backdrop, so a right-click there focused the frame behind the dialog, and a body there got
    // the rest.
    @Test func aRightPressOnADialogNeverReachesTheFramesBehindIt() async throws {
        let f = CanvasFixture(bifrostWindow: true)
        defer { f.close() }
        let host = DialogHost(look: PanelLook(), clock: ManualClock())
        f.canvas.dialogLayer = host.view
        // The lower frame is to the right of the box of the dialog, which is 420 wide in the
        // middle of the canvas.
        _ = f.open("watchlist", at: rect(850, 100, 300, 300))
        let top = f.open("settings", at: rect(100, 100, 400, 300))
        let lowerBody = try #require(f.bodies.views[panel("watchlist")])
        let ask = Task {
            await host.confirm(
                ConfirmText(title: "Stop session", body: "b", confirm: "Stop"), openFolder: nil,
                onBusy: {})
        }
        await waitUntil { host.isOpen }
        let types: [NSEvent.EventType] = [
            .rightMouseDown, .rightMouseDragged, .rightMouseUp, .otherMouseDown,
            .otherMouseDragged, .otherMouseUp,
        ]
        for point in [CGPoint(x: 1000, y: 110), CGPoint(x: 1000, y: 250)] {
            for type in types {
                let hit = f.mouse.send(type, at: point, in: f.canvas)
                #expect(hit === host.view || hit?.isDescendant(of: host.view) == true)
            }
        }
        #expect(f.model.layout.focusedFrame?.id == top)
        #expect(lowerBody.rightPresses == 0 && lowerBody.otherPresses == 0)
        #expect(lowerBody.passedOn.isEmpty)
        #expect(host.isOpen)
        host.escape()
        #expect(await ask.value == false)
    }

    // A right or other-button press, drag or release on the button of a chat's dictation notice
    // never reaches the chat terminal under the notice. Through super AppKit gave what the button
    // passed on to the terminal beneath it. The press still goes to the frame, which takes the
    // focus.
    @Test func aRightPressOnTheDictationNoticeNeverReachesTheTerminal() throws {
        let f = CanvasFixture()
        defer { f.close() }
        let chat = ChatPanelBody(metrics: CanvasMetrics(interfaceScale: 100))
        let terminal = FakeBody()
        chat.host.addSubview(terminal)
        f.bodies.given[panel("settings")] = chat
        let lower = f.open("settings", at: rect(100, 100, 400, 300))
        let top = f.open("watchlist", at: rect(600, 100, 300, 300))
        #expect(f.model.layout.focusedFrame?.id == top)
        chat.showDictationNotice(
            NoticeLine(text: DictationNoticeText.error(.micDenied), opensSettings: true))
        chat.layoutSubtreeIfNeeded()
        terminal.frame = chat.host.bounds
        let button = chat.dictationNotice.button
        let point = f.canvas.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
        let types: [NSEvent.EventType] = [
            .rightMouseDown, .rightMouseDragged, .rightMouseUp, .otherMouseDown,
            .otherMouseDragged, .otherMouseUp,
        ]
        for type in types { #expect(f.mouse.send(type, at: point, in: f.canvas) === button) }
        #expect(terminal.rightPresses == 0 && terminal.otherPresses == 0)
        #expect(terminal.passedOn.isEmpty)
        #expect(f.model.layout.focusedFrame?.id == lower)
    }

    // A press on a title bar button of a lower frame brings the frame to the front before the
    // click.
    @Test func aPressOnATitleButtonOfALowerFrameBringsItToTheFront() {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let b = f.open("watchlist", at: rect(600, 100, 300, 300))
        let button = f.view(a).titleBar.minimiseButton
        let hit = f.mouse.down(at: f.centre(of: button), in: f.canvas)
        #expect(hit === button)
        #expect(f.model.layout.topFrame?.id == a)
        button.performClick(nil)
        #expect(f.frame(a)?.minimised == true)
        #expect(f.model.layout.topFrame?.id == b)
    }

    // A body that moves to another frame (a stack, a tear-out) stays in the window, and it keeps
    // the keyboard focus. A terminal needs this.
    @Test func aMovedBodyStaysInTheWindowAndKeepsTheFocus() throws {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("watchlist", at: rect(600, 100, 300, 300))
        let b = f.open("settings", at: rect(100, 450, 400, 250))
        let settings = try #require(f.bodies.views[panel("settings")])
        let watchlist = try #require(f.bodies.views[panel("watchlist")])
        #expect(f.window.makeFirstResponder(settings))
        // A drop of b on the title bar of a.
        f.mouse.drag(
            from: CGPoint(x: 150, y: 460), through: [CGPoint(x: 650, y: 110)], in: f.canvas)
        #expect(f.frame(b) == nil)
        #expect(settings.isDescendant(of: f.view(a)))
        #expect(settings.leftWindow == 0)
        #expect(f.window.firstResponder === settings)
        // A tear-out of the Settings tab.
        let tab = try #require(f.view(a).titleBar.tabViews.last)
        let start = f.centre(of: tab)
        f.mouse.drag(
            from: start, through: [CGPoint(x: start.x, y: 200), CGPoint(x: 300, y: 300)],
            in: f.canvas)
        let torn = try #require(f.model.layout.frame(of: panel("settings")))
        #expect(settings.isDescendant(of: f.view(torn.id)))
        #expect(settings.leftWindow == 0)
        #expect(f.window.firstResponder === settings)
        // A stack by the layout (no drag) makes Settings the active tab of a. The Watchlist body
        // is the body of a tab that is not active now, so it leaves the window.
        f.model.apply(.stack(torn.id, onto: a))
        #expect(settings.isDescendant(of: f.view(a)))
        #expect(watchlist.window == nil)
        // Focus changes reorder the frames, and the body stays.
        let c = f.open("event-log", at: rect(100, 100, 300, 300))
        f.model.apply(.focus(a))
        f.model.apply(.focus(c))
        #expect(settings.leftWindow == 0)
        #expect(f.window.firstResponder === settings)
        // A minimised frame hides its body: the body stays in the window, but it does not keep
        // the keyboard focus, as an element with display: none.
        f.model.apply(.minimise(a))
        #expect(settings.leftWindow == 0)
        #expect(f.window.firstResponder !== settings)
    }

    // The menu button opens the Panel menu (FrameMenuTests has its place and its rows), and its
    // Lock row locks the frame.
    @Test func theMenuButtonOpensThePanelMenu() throws {
        let f = CanvasFixture(settings: CanvasSettings(interfaceScale: 150))
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let button = f.view(a).titleBar.menuButton
        button.performClick(nil)
        let menu = f.canvas.bifrostMenu
        let panel = try #require(menu.panels.first)
        #expect(panel.list.state.rows == FrameMenu.rows(locked: false, setName: nil))
        menu.clicked([0])
        #expect(f.frame(a)?.locked == true)
        menu.close()
        // The title bar buttons are 24 units at the scale 150, with 12 units at the right.
        #expect(button.frame.width == 36)
        let close = f.view(a).titleBar.closeButton
        #expect(close.frame.maxX == f.view(a).titleBar.bounds.width - 18)
    }

    @Test func anEdgeDragResizes() {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        // The right edge handle is 6 wide. A press on it gets the frame view.
        let hit = f.mouse.down(at: CGPoint(x: 497, y: 250), in: f.canvas)
        #expect(hit === f.view(a))
        f.mouse.drag(to: CGPoint(x: 547, y: 250), in: f.canvas)
        #expect(f.view(a).frame == CGRect(x: 100, y: 100, width: 450, height: 300))
        f.mouse.up(at: CGPoint(x: 547, y: 250), in: f.canvas)
        #expect(f.frame(a)?.rect == rect(100, 100, 450, 300))
        // The bottom right corner is 12 by 12.
        f.mouse.drag(
            from: CGPoint(x: 540, y: 390), through: [CGPoint(x: 580, y: 440)], in: f.canvas)
        #expect(f.frame(a)?.rect == rect(100, 100, 490, 350))
        // The top edge is above the title bar, but the buttons are above the edge.
        let close = f.view(a).titleBar.closeButton
        let button = f.mouse.hitView(at: CGPoint(x: f.centre(of: close).x, y: 104), in: f.canvas)
        #expect(button === close)
        #expect(f.view(a).edge(at: CGPoint(x: 200, y: 3)) == .n)
        #expect(f.view(a).edge(at: CGPoint(x: 200, y: 7)) == nil)
    }

    // Each of the 8 handles moves its own edges: a drag of -37 by -23 from each handle of a
    // frame at 300, 200, 400 by 300, far from each snap line.
    @Test(arguments: [
        (FrameEdge.n, CGPoint(x: 200, y: 3), LayoutRect(x: 300, y: 177, w: 400, h: 323)),
        (.s, CGPoint(x: 200, y: 297), LayoutRect(x: 300, y: 200, w: 400, h: 277)),
        (.w, CGPoint(x: 3, y: 150), LayoutRect(x: 263, y: 200, w: 437, h: 300)),
        (.e, CGPoint(x: 397, y: 150), LayoutRect(x: 300, y: 200, w: 363, h: 300)),
        (.nw, CGPoint(x: 5, y: 5), LayoutRect(x: 263, y: 177, w: 437, h: 323)),
        (.ne, CGPoint(x: 395, y: 5), LayoutRect(x: 300, y: 177, w: 363, h: 323)),
        (.sw, CGPoint(x: 5, y: 295), LayoutRect(x: 263, y: 200, w: 437, h: 277)),
        (.se, CGPoint(x: 395, y: 295), LayoutRect(x: 300, y: 200, w: 363, h: 277)),
    ])
    func eachResizeHandleMovesItsEdges(edge: FrameEdge, at local: CGPoint, result: LayoutRect) {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(300, 200, 400, 300))
        #expect(f.view(a).edge(at: local) == edge)
        let start = CGPoint(x: 300 + local.x, y: 200 + local.y)
        let hit = f.mouse.down(at: start, in: f.canvas)
        #expect(hit === f.view(a))
        let end = CGPoint(x: start.x - 37, y: start.y - 23)
        f.mouse.drag(to: end, in: f.canvas)
        f.mouse.up(at: end, in: f.canvas)
        #expect(f.frame(a)?.rect == result)
    }

    // A drag step does not write the layout: the observers of the layout (the side bar) get no
    // change until the release.
    @Test func aDragStepDoesNotWriteTheLayout() {
        let f = CanvasFixture()
        defer { f.close() }
        f.open("settings", at: rect(100, 100, 400, 300))
        f.open("watchlist", at: rect(600, 100, 300, 300))
        f.mouse.down(at: CGPoint(x: 200, y: 110), in: f.canvas)
        let written = Mutex(0)
        withObservationTracking {
            _ = f.model.layout
        } onChange: {
            written.withLock { $0 += 1 }
        }
        for step in 1...10 {
            f.mouse.drag(to: CGPoint(x: 200 + Double(step) * 9, y: 160), in: f.canvas)
        }
        #expect(written.withLock { $0 } == 0)
        f.mouse.up(at: CGPoint(x: 290, y: 160), in: f.canvas)
        #expect(written.withLock { $0 } == 1)
    }

    // At 90 %, one unit is 0.9 points. The frames and the outline snap to the device pixels, so
    // their edges are sharp.
    @Test func theFramesAndTheOutlineSnapToDevicePixels() {
        let f = CanvasFixture(settings: CanvasSettings(interfaceScale: 90))
        defer { f.close() }
        let a = f.open("settings", at: rect(101, 101, 401, 301))
        f.open("watchlist", at: rect(601, 101, 301, 301))
        // 90.9, 90.9, 360.9 by 270.9 points snap to whole points at 1x and at 2x.
        #expect(f.view(a).frame == CGRect(x: 91, y: 91, width: 361, height: 271))
        let scale = f.window.backingScaleFactor
        func aligned(_ r: CGRect) -> Bool {
            [r.minX, r.minY, r.maxX, r.maxY].allSatisfy { ($0 * scale).rounded() == $0 * scale }
        }
        // A drag to the title bar of the other frame.
        f.mouse.down(at: CGPoint(x: 135.9, y: 99.9), in: f.canvas)
        f.mouse.drag(to: CGPoint(x: 590.4, y: 100.8), in: f.canvas)
        #expect(f.model.drag?.live != nil)
        #expect(aligned(f.view(a).frame))
        #expect(!f.canvas.outline.isHidden)
        // The title bar of 601, 101, 301 by 28 units is 540.9, 90.9, 270.9 by 25.2 points.
        #expect(f.canvas.outline.frame == CGRect(x: 541, y: 91, width: 271, height: 25))
        f.mouse.up(at: CGPoint(x: 590.4, y: 100.8), in: f.canvas)
    }

    @Test func aLockedFrameHasNoHandlesAndDoesNotMove() {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        f.model.apply(.lock(a, true))
        #expect(!f.view(a).titleBar.lockView.isHidden)
        #expect(f.view(a).edge(at: CGPoint(x: 397, y: 150)) == nil)
        f.mouse.drag(
            from: CGPoint(x: 497, y: 250), through: [CGPoint(x: 547, y: 250)], in: f.canvas)
        f.mouse.down(at: CGPoint(x: 200, y: 110), in: f.canvas)
        f.mouse.drag(to: CGPoint(x: 300, y: 210), in: f.canvas)
        #expect(f.model.drag == nil)
        #expect(f.view(a).frame == CGRect(x: 100, y: 100, width: 400, height: 300))
        f.mouse.up(at: CGPoint(x: 300, y: 210), in: f.canvas)
        #expect(f.frame(a)?.rect == rect(100, 100, 400, 300))
        // The Lock row of the Panel menu unlocks the frame.
        f.canvas.showMenu(for: a, from: f.view(a).titleBar.menuButton)
        let menu = f.canvas.bifrostMenu
        #expect(
            menu.panels.first?.list.state.rows == FrameMenu.rows(locked: true, setName: nil))
        menu.clicked([0])
        menu.close()
        #expect(f.frame(a)?.locked == false)
        #expect(f.view(a).titleBar.lockView.isHidden)
        #expect(f.view(a).edge(at: CGPoint(x: 397, y: 150)) == .e)
    }

    @Test func minimiseHidesTheFrameAndTheSideBarRestoresIt() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let b = f.open("watchlist", at: rect(600, 100, 300, 300))
        let store = await UIStateStore.open(
            file: dir.appending(path: "ui-state.json"), clock: ManualClock(),
            log: Recorder<StoreEvent>())
        let sideBar = SideBarModel(layout: f.model, store: store)
        f.view(a).titleBar.minimiseButton.performClick(nil)
        #expect(f.frame(a)?.minimised == true)
        #expect(f.view(a).isHidden)
        #expect(sideBar.minimised.map(\.id) == [a])
        #expect(f.model.layout.topFrame?.id == b)
        sideBar.restore(a)
        #expect(!f.view(a).isHidden)
        #expect(sideBar.minimised.isEmpty)
        #expect(f.model.layout.topFrame?.id == a)
        #expect(f.canvas.subviews.firstIndex(of: f.view(a)) == 1)
    }

    // A new body of a panel (a part that came after the start) shows in the frame of the panel
    // in place of the old view. The old view leaves the window, and the bodies get no release.
    // A panel with no view in the canvas changes nothing.
    @Test func aReloadShowsTheNewBodyOfAPanel() throws {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let old = try #require(f.view(a).shownBody)
        f.bodies.replaceBody(of: panel("settings"))
        f.canvas.reloadBodies([panel("settings"), panel("watchlist")])
        let new = try #require(f.bodies.views[panel("settings")])
        #expect(new !== old)
        #expect(f.view(a).shownBody === new)
        #expect(old.superview == nil)
        #expect(f.bodies.released.isEmpty)
        #expect(f.bodies.made[panel("watchlist")] == nil)
    }

    @Test func closeRemovesThePanelAndRemembersItsRect() throws {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let body = try #require(f.view(a).shownBody)
        f.view(a).titleBar.closeButton.performClick(nil)
        #expect(f.frame(a) == nil)
        #expect(f.canvas.frameView(a) == nil)
        #expect(f.model.layout.memory[panel("settings")] == rect(100, 100, 400, 300))
        #expect(f.bodies.released == [panel("settings")])
        #expect(body.superview == nil)
        f.model.apply(.open(panel("settings")))
        let again = try #require(f.model.layout.frame(of: panel("settings")))
        #expect(again.rect == rect(100, 100, 400, 300))
        #expect(f.bodies.made[panel("settings")] == 2)
    }

    @Test func theBlurShowsOnlyWhereAFrameCoversALowerFrame() {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let b = f.open("watchlist", at: rect(700, 100, 300, 300))
        #expect(!f.view(a).blurShows)
        #expect(!f.view(b).blurShows)
        // b covers a: only b, the higher frame, gets the blur.
        f.model.apply(.setRect(b, rect(400, 200, 300, 300)))
        #expect(!f.view(a).blurShows)
        #expect(f.view(b).blurShows)
        #expect(f.view(b).blurView?.isHidden == false)
        #expect(f.view(a).blurView?.isHidden == true)
        // During a drag the live rect counts.
        f.mouse.down(at: CGPoint(x: 450, y: 210), in: f.canvas)
        f.mouse.drag(to: CGPoint(x: 850, y: 210), in: f.canvas)
        #expect(!f.view(b).blurShows)
        f.mouse.up(at: CGPoint(x: 450, y: 210), in: f.canvas)
        #expect(f.view(b).blurShows)
        // A minimised frame is not a lower frame.
        f.model.apply(.minimise(a))
        #expect(!f.view(b).blurShows)
        // A blur of another kind replaces the blur of each frame.
        f.model.apply(.restore(a))
        f.canvas.apply(CanvasSettings(blur: .material))
        #expect(f.view(a).blurView is NSVisualEffectView)
        #expect(f.view(a).blurShows)
        #expect(f.view(a).blurView?.isHidden == false)
        f.canvas.apply(CanvasSettings(blur: .none))
        #expect(f.view(a).blurView == nil)
    }

    @Test
    func theTopFrameHasTheFocusLook() throws {
        let f = CanvasFixture(settings: CanvasSettings(panelTransparency: 20))
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let b = f.open("watchlist", at: rect(600, 100, 300, 300))
        func check(_ id: FrameID, top: Bool) {
            let look = f.view(id).look
            let fill =
                top
                ? ThemeTokens.panelFocus(transparency: 20) : ThemeTokens.panel(transparency: 20)
            #expect(look.fill == fill.cgColor)
            #expect(look.border == (top ? textStrong30 : ThemeTokens.panelEdge.cgColor))
            #expect(look.topLine == (top ? ThemeTokens.accent.cgColor : accent35))
            #expect(look.glow == (top ? 1 : 0))
            #expect(f.view(id).isTop == top)
        }
        check(b, top: true)
        check(a, top: false)
        // The glow is above the top edge only. Its strip starts 6 in from each end, and the light
        // goes 18 (3 softness lengths) past the strip. The canvas clips it at its own edge.
        #expect(f.view(b).glowFrame == CGRect(x: -12, y: -18, width: 324, height: 18))
        #expect(f.view(b).focusGlowStrip == CGRect(x: 18, y: 18, width: 288, height: 18))
        #expect(f.canvas.clipsToBounds)
        f.mouse.down(at: CGPoint(x: 200, y: 110), in: f.canvas)
        f.mouse.up(at: CGPoint(x: 200, y: 110), in: f.canvas)
        check(a, top: true)
        check(b, top: false)
        // The change takes 250 ms, ease-out.
        let fill = try #require(f.view(a).fillLayer.animation(forKey: "backgroundColor"))
        #expect(fill.duration == 0.25)
        #expect(controlPoints(fill.timingFunction) == controlPoints(.init(name: .easeOut)))
        #expect(f.view(a).glowLayer.animation(forKey: "opacity") != nil)
    }

    // The layout keeps the rects that the user set. A scale change changes only the bounds and
    // the shown rects.
    @Test func aScaleChangeKeepsTheSavedRects() {
        let f = CanvasFixture(size: CGSize(width: 1200, height: 801))
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let b = f.open("watchlist", at: rect(700, 400, 480, 380))
        let rects = f.model.layout.frames.map(\.rect)
        f.canvas.apply(CanvasSettings(interfaceScale: 150))
        #expect(f.model.layout.bounds == LayoutSize(w: 800, h: 534))
        #expect(f.model.layout.frames.map(\.rect) == rects)
        #expect(f.view(a).frame == CGRect(x: 150, y: 150, width: 600, height: 450))
        // b shows inside the smaller area: x 800 - 480 = 320, y 534 - 380 = 154.
        #expect(f.view(b).frame == CGRect(x: 480, y: 231, width: 720, height: 570))
        #expect(f.view(a).titleBar.frame.height == 42)
        f.canvas.apply(CanvasSettings(interfaceScale: 100))
        #expect(f.model.layout.bounds == LayoutSize(w: 1200, h: 801))
        #expect(f.model.layout.frames.map(\.rect) == rects)
        #expect(f.view(b).frame == CGRect(x: 700, y: 400, width: 480, height: 380))
    }

    // The store gets each change of the layout, but a drag holds the saves. One save follows the
    // end of the drag.
    @Test func noSaveDuringADrag() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "ui-state.json")
        let clock = ManualClock()
        let store = await UIStateStore.open(file: file, clock: clock, log: Recorder<StoreEvent>())
        let f = CanvasFixture()
        defer { f.close() }
        f.store = store
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        let b = f.open("watchlist", at: rect(600, 100, 300, 300))
        await store.saveNow()
        let before = try readSaved(file)
        // A change starts the save timer.
        f.model.apply(.lock(b, true))
        await clock.waitForSleepers(1)
        // The press brings a to the front, and the drag starts: the drag stops the timer.
        f.mouse.down(at: CGPoint(x: 200, y: 110), in: f.canvas)
        f.mouse.drag(to: CGPoint(x: 240, y: 410), in: f.canvas)
        await clock.waitUntilNoSleepers()
        clock.advance(by: .seconds(5))
        f.mouse.drag(to: CGPoint(x: 250, y: 420), in: f.canvas)
        #expect(clock.sleeperCount == 0)
        #expect(try readSaved(file) == before)
        f.mouse.up(at: CGPoint(x: 250, y: 420), in: f.canvas)
        #expect(f.frame(a)?.rect == rect(150, 410, 400, 300))
        #expect(store.state.current == f.model.layout.snapshot)
        // The end of the drag starts the timer again. The save comes 500 ms later.
        await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(500))
        await waitUntil { (try? readSaved(file)) != before }
        f.store = nil
        f.model.apply(.minimise(a))
        #expect(store.state.current != f.model.layout.snapshot)
    }

    // The window does not update its cursor rects from the press of a drag or a resize to its
    // end (row W15 of the windows port). A release, a cancel and the loss of the key state of
    // the window each turn them on again.
    @Test func theCursorRectsWaitUntilTheEndOfADrag() throws {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 100, 400, 300))
        #expect(f.window.areCursorRectsEnabled)
        // A move: the press, the steps and the release.
        f.mouse.down(at: CGPoint(x: 200, y: 110), in: f.canvas)
        #expect(!f.window.areCursorRectsEnabled)
        f.mouse.drag(to: CGPoint(x: 260, y: 140), in: f.canvas)
        #expect(!f.window.areCursorRectsEnabled)
        f.mouse.up(at: CGPoint(x: 260, y: 140), in: f.canvas)
        #expect(f.window.areCursorRectsEnabled)
        // A resize on the right edge, then a cancel.
        let r = try #require(f.frame(a)?.rect)
        let edge = CGPoint(x: r.x + r.w - 3, y: r.y + r.h / 2)
        f.mouse.down(at: edge, in: f.canvas)
        #expect(f.model.drag != nil)
        #expect(!f.window.areCursorRectsEnabled)
        f.model.endDrag(at: nil)
        #expect(f.window.areCursorRectsEnabled)
        f.mouse.up(at: edge, in: f.canvas)
        // A move during which the window stops being the key window. The drag continues.
        f.mouse.down(at: CGPoint(x: r.x + 100, y: r.y + 10), in: f.canvas)
        #expect(!f.window.areCursorRectsEnabled)
        // The owner of the window gives the loss of the key state (the window delegate).
        f.canvas.windowResignedKey()
        #expect(f.window.areCursorRectsEnabled)
        f.mouse.drag(to: CGPoint(x: r.x + 130, y: r.y + 10), in: f.canvas)
        #expect(f.window.areCursorRectsEnabled)
        #expect(f.model.drag != nil)
        f.mouse.up(at: CGPoint(x: r.x + 130, y: r.y + 10), in: f.canvas)
        #expect(f.model.drag == nil)
        #expect(f.window.areCursorRectsEnabled)
        // The next drag turns them off again.
        f.mouse.down(at: CGPoint(x: r.x + 150, y: r.y + 10), in: f.canvas)
        #expect(!f.window.areCursorRectsEnabled)
        f.mouse.up(at: CGPoint(x: r.x + 150, y: r.y + 10), in: f.canvas)
        #expect(f.window.areCursorRectsEnabled)
    }

    // Each hover view (the title bar buttons, the tabs, the button of the dictation notice and
    // the slider of a chat) makes its tracking area one time. The option inVisibleRect keeps the
    // area on the visible rect, so an update of the tracking areas (at each step of a drag)
    // makes no new area.
    @Test func eachHoverViewKeepsItsTrackingArea() throws {
        let f = CanvasFixture()
        defer { f.close() }
        let a = f.open("settings", at: rect(100, 300, 400, 300))
        let b = f.open("watchlist", at: rect(600, 100, 300, 300))
        f.model.apply(.stack(a, onto: b))
        let bar = f.view(b).titleBar
        #expect(bar.tabViews.count == 2)
        let notice = DictationNoticeView()
        let slider = ScrollSlider()
        f.canvas.addSubview(notice)
        f.canvas.addSubview(slider)
        let views: [NSView] =
            bar.tabViews + [
                bar.menuButton, bar.minimiseButton, bar.closeButton, notice.button, slider,
            ]
        for view in views {
            let before = view.trackingAreas.filter { $0.owner === view }
            #expect(before.count == 1)
            #expect(before.first?.options.contains(.inVisibleRect) == true)
            view.updateTrackingAreas()
            view.setFrameOrigin(CGPoint(x: 40, y: 30))
            view.updateTrackingAreas()
            let after = view.trackingAreas.filter { $0.owner === view }
            #expect(after.count == 1)
            #expect(after.first === before.first)
        }
    }

    // MARK: - The Overviews

    // The title of an Overview shows the name of its tab set in brackets, in the dim text colour,
    // after the title in the text colour. A tab of a stack shows it too, and a rename of the set
    // shows soon, from the Panel menu and from each other change of the config. Another panel
    // has no suffix.
    @Test func theOverviewTitleShowsTheSetNameInTheDimColour() async throws {
        let c = try await OverviewCanvas(rows: [])
        defer { c.close() }
        let frame = c.open("overview:1")
        let view = try #require(c.frameView(frame))
        let label = try #require(view.titleBar.titleLabel)
        #expect(label.stringValue == "Overview (Default)")
        #expect(view.accessibilityLabel() == "Overview (Default)")
        let text = label.attributedStringValue
        #expect(colour(text, at: 0) == ThemeTokens.text.nsColor)
        #expect(colour(text, at: "Overview (".count) == ThemeTokens.textDim.nsColor)
        // The rename of the Panel menu: Up goes to the name field, and Enter saves the name.
        let driver = MenuDriver(menu: c.canvas.bifrostMenu)
        defer { c.canvas.bifrostMenu.close() }
        view.titleBar.menuButton.performClick(nil)
        try driver.key("Up")
        let field = try #require(try driver.row(2).field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Ops", replacementRange: editor.selectedRange())
        try driver.key("Return", in: driver.root)
        #expect(c.model.config(.overview(1)).name == "Ops")
        await waitUntil { view.titleBar.titleLabel?.stringValue == "Overview (Ops)" }
        // A rename through the model, not through the Panel menu.
        c.model.update(.overview(1), .rename("Team"))
        await waitUntil { view.titleBar.titleLabel?.stringValue == "Overview (Team)" }
        #expect(view.accessibilityLabel() == "Overview (Team)")
        // A stack: the tab of the Overview has the suffix in the dim colour, and the tab of
        // Settings has none.
        let settings = c.open("settings")
        c.layout.apply(.stack(frame, onto: settings))
        let tabs = try #require(c.frameView(settings)?.titleBar.tabViews)
        #expect(tabs.map { $0.accessibilityLabel() } == ["Settings", "Overview (Team)"])
        let tab = try #require(tabText(tabs[1]))
        #expect(tab.string == "Overview (Team)")
        #expect(colour(tab, at: "Overview (".count) == ThemeTokens.textDim.nsColor)
        #expect(tabText(tabs[0])?.string == "Settings")
        // overview:2 has its own set.
        let two = c.open("overview:2")
        #expect(c.frameView(two)?.titleBar.titleLabel?.stringValue == "Overview 2 (Default)")
    }

    // Each Overview panel of the canvas shows the Overview, with its own rows view. A
    // double-click on a row runs the open action: the chat of an owned row opens on top, and an
    // external row opens nothing.
    @Test func aDoubleClickOnAnOverviewRowOpensItsChat() async throws {
        let owned = "5a0e0001-0000-4000-8000-000000000001"
        let external = "5a0e0002-0000-4000-8000-000000000002"
        let c = try await OverviewCanvas(rows: [
            SessionRow.test(sessionId: owned, name: "alpha"),
            SessionRow.test(sessionId: external, name: "beta", kind: .external),
        ])
        defer { c.close() }
        let one = c.open("overview:1")
        c.open("overview:2")
        #expect(c.frameView(one)?.shownBody is OverviewPanel)
        let rows = try #require(c.rows(2))
        #expect(rows !== c.rows(1))
        await waitUntil { rows.table.numberOfRows == 2 }
        rows.layoutSubtreeIfNeeded()
        let layout = c.layout.layout
        rows.table.doubleClick(at: rowPoint(rows.table, row: 1))
        #expect(c.selection.selectedId == external)
        #expect(c.layout.layout == layout)
        rows.table.doubleClick(at: rowPoint(rows.table, row: 0))
        #expect(c.selection.selectedId == owned)
        let chat = try #require(SessionID(owned))
        #expect(c.layout.layout.topFrame?.active == .chat(chat))
    }

    @Test
    func eachPanelKindHasAnIcon() {
        let icons: [PanelKind: IconName] = [
            .answer: .messageCircleQuestionMark, .chat: .messageSquare,
            .dailyUpdate: .messageSquareText, .eventLog: .scrollText, .heimdall: .shield,
            .module: .puzzle, .overview: .list, .overviewSettings: .slidersHorizontal,
            .performance: .heartPulse, .reviewDraft: .filePen, .reviews: .gitPullRequest,
            .selectedItem: .crosshair, .serviceStatus: .activity, .settings: .settings,
            .showInfo: .info, .trust: .shieldCheck, .usageHud: .gauge, .watchlist: .eye,
        ]
        #expect(icons.count == PanelKind.allCases.count)
        #expect(PanelKind.allCases.allSatisfy { $0.icon == icons[$0] })
        #expect(Set(PanelKind.allCases.map(\.icon)).count == 18)
    }
}

// The text colour of the attributed string at the index.
@MainActor
private func colour(_ text: NSAttributedString, at index: Int) -> NSColor? {
    text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
}

// A point 40 units into the row, in the coordinates of the table.
@MainActor
private func rowPoint(_ table: NSTableView, row: Int) -> NSPoint {
    let rect = table.rect(ofRow: row)
    return NSPoint(x: rect.minX + 40, y: rect.midY)
}

// The text of a tab, as its view shows it.
@MainActor
private func tabText(_ tab: NSView) -> NSAttributedString? {
    tab.subviews.compactMap { $0 as? NSTextField }.first?.attributedStringValue
}

// The two inner control points of a timing function.
@MainActor
private func controlPoints(_ function: CAMediaTimingFunction?) -> [Float] {
    guard let function else { return [] }
    var values: [Float] = []
    for index in 1...2 {
        var point: [Float] = [0, 0]
        function.getControlPoint(at: index, values: &point)
        values += point
    }
    return values
}

@MainActor
private let textStrong30 = TokenColour(r: 1, g: 1, b: 1, a: 0.3).cgColor
@MainActor
private let accent35: CGColor = {
    var accent = ThemeTokens.accent
    accent.a = 0.35
    return accent.cgColor
}()
