import BifrostLayout
import BifrostTestSupport
import Testing

// The layout of the window: the frames, the panels and the actions (docs/behaviour/windows.md).
// An action that changes nothing makes apply give false, and the layout stays the same. A panel
// ID or a frame ID that is not good cannot reach apply: the types refuse it.

private let bounds = size(h: 800, w: 1200)
private let chat = "chat:123e4567-e89b-12d3-a456-426614174000"

private func run(
    _ actions: [WindowAction], from start: WindowLayout = WindowLayout(bounds: bounds)
) -> WindowLayout {
    var layout = start
    for action in actions { layout.apply(action) }
    return layout
}

private func open(_ raw: String) -> WindowAction { .open(panel(raw)) }

// True when the action changes nothing: apply gives false and the layout stays the same.
private func unchanged(_ layout: WindowLayout, _ action: WindowAction) -> Bool {
    var copy = layout
    return !copy.apply(action) && copy == layout
}

// A layout with this memory and no frames.
private func withMemory(_ memory: [PanelID: LayoutRect], bounds area: LayoutSize = bounds)
    -> WindowLayout
{
    run([.load(LayoutSnapshot(frames: [], memory: memory))], from: WindowLayout(bounds: area))
}

private func kind(_ raw: String) -> PanelKind? { PanelID(raw)?.kind }

// The active panel and the tabs of a frame, to compare both in one check.
private struct Tabs: Equatable {
    var active: PanelID
    var panels: [PanelID]
}

private func tabs(_ frame: LayoutFrame?) -> Tabs? {
    frame.map { Tabs(active: $0.active, panels: $0.panels) }
}

private func tabs(_ active: String, _ panels: [String]) -> Tabs {
    Tabs(active: panel(active), panels: panels.map(panel))
}

private func defaultSize(_ kind: PanelKind) -> LayoutSize { kind.defaultSize }

private func openedSize(_ raw: String) -> LayoutSize? {
    run([open(raw)]).frames.first.map { size(h: $0.rect.h, w: $0.rect.w) }
}

@Suite("the layout actions")
struct WindowLayoutTests {
    @Test
    func selectedItemSize() {
        #expect(defaultSize(.selectedItem) == size(h: 300, w: 360))
        #expect(openedSize("selected-item") == size(h: 300, w: 360))
    }

    @Test("the event log is a panel kind")
    func eventLog() {
        #expect(kind("event-log") == .eventLog)
        #expect(defaultSize(.eventLog) == size(h: 360, w: 640))
        #expect(openedSize("event-log") == size(h: 360, w: 640))
    }

    @Test("the service status is a panel kind")
    func serviceStatus() {
        #expect(kind("service-status") == .serviceStatus)
        #expect(defaultSize(.serviceStatus) == size(h: 240, w: 420))
        #expect(openedSize("service-status") == size(h: 240, w: 420))
    }

    @Test("the review draft is a panel kind")
    func reviewDraft() {
        #expect(kind("review-draft") == .reviewDraft)
        #expect(defaultSize(.reviewDraft) == size(h: 560, w: 620))
    }

    @Test("the answer is a panel kind")
    func answer() {
        #expect(kind("answer") == .answer)
        #expect(defaultSize(.answer) == size(h: 420, w: 560))
        #expect(openedSize("answer") == size(h: 420, w: 560))
    }

    @Test("trust is a panel kind")
    func trust() {
        #expect(kind("trust") == .trust)
        #expect(defaultSize(.trust) == size(h: 380, w: 640))
        #expect(openedSize("trust") == size(h: 380, w: 640))
    }

    @Test("reviews is a panel kind")
    func reviews() {
        #expect(kind("reviews") == .reviews)
        #expect(defaultSize(.reviews) == size(h: 420, w: 480))
        #expect(openedSize("reviews") == size(h: 420, w: 480))
    }

    @Test("performance is a panel kind")
    func performance() {
        #expect(kind("performance") == .performance)
        #expect(defaultSize(.performance) == size(h: 460, w: 520))
        #expect(openedSize("performance") == size(h: 460, w: 520))
    }

    @Test("the daily update is a panel kind")
    func dailyUpdate() {
        #expect(kind("daily-update") == .dailyUpdate)
        #expect(defaultSize(.dailyUpdate) == size(h: 520, w: 560))
        #expect(openedSize("daily-update") == size(h: 520, w: 560))
    }

    @Test("the usage HUD is a panel kind")
    func usageHUD() {
        #expect(kind("usage-hud") == .usageHud)
        #expect(defaultSize(.usageHud) == size(h: 180, w: 360))
        #expect(openedSize("usage-hud") == size(h: 180, w: 360))
    }

    @Test
    func usageHUDMargin() {
        // A hand check measured 146 px of content. The frame has the title bar and a 1 px
        // border at the top and at the bottom. The margin is at least 4 px.
        let contentHeight = 146.0
        let area = defaultSize(.usageHud).h - Geometry.titleHeight - 2
        #expect(area >= contentHeight + 4)
    }

    @Test
    func fixedIDs() {
        #expect(kind("overview:1") == .overview)
        #expect(kind("overview:99") == .overview)
        #expect(kind("overview-settings:1") == .overviewSettings)
        #expect(kind("overview-settings:99") == .overviewSettings)
        #expect(kind("selected-item") == .selectedItem)
        #expect(kind("watchlist") == .watchlist)
        #expect(defaultSize(.watchlist) == size(h: 280, w: 320))
        #expect(kind("settings") == .settings)
        #expect(kind(chat) == .chat)
        let upper = chat.uppercased().replacing("CHAT", with: "chat", maxReplacements: 1)
        #expect(kind(upper) == .chat)
        let bad = [
            "overview:0", "overview:100", "overview:x", "chat:abc", "foo", "overview:01",
            "overview-settings:0", "overview-settings:100", "overview-settings",
        ]
        #expect(bad.allSatisfy { PanelID($0) == nil })
    }

    @Test("show info takes a session ID and refuses a bad one")
    func showInfo() {
        let id = "0f8fad5b-d9cb-469f-a165-70867728950e"
        #expect(kind("show-info:\(id)") == .showInfo)
        #expect(kind("show-info:\(id.uppercased())") == .showInfo)
        let bad = ["show-info:x", "show-info:", "show-info", "show-info:\(id)0", "info:\(id)"]
        #expect(bad.allSatisfy { PanelID($0) == nil })
        #expect(defaultSize(.showInfo) == size(h: 560, w: 460))
    }

    @Test("the overview settings panel has its own ID and the size 360 by 420")
    func overviewSettings() {
        #expect(panel("overview-settings:12") == .overviewSettings(12))
        #expect(defaultSize(.overviewSettings) == size(h: 420, w: 360))
        let s = run([open("overview-settings:2")])
        #expect(s.frames.first?.rect == Geometry.centreRect(size(h: 420, w: 360), bounds: bounds))
    }

    @Test
    func openAddsACentredFrame() {
        let s = run([open("settings")])
        #expect(s.frames.count == 1)
        // A frame has no opacity field.
        #expect(
            s.frames.first
                == LayoutFrame(
                    id: frameID(1), panels: [panel("settings")], active: panel("settings"),
                    rect: Geometry.centreRect(defaultSize(.settings), bounds: bounds),
                    minimised: false, locked: false))
        #expect(s.nextFrame == 2)
    }

    // No integration panel exists. The Settings panel has the Live details section.
    @Test("integration is not a panel kind")
    func refusesIntegration() {
        #expect(PanelID("integration") == nil)
        #expect(PanelKind(rawValue: "integration") == nil)
        // open ignores a panel ID that is not valid: the type refuses it, so no open can run and
        // no frame opens.
        #expect(run(PanelID("integration").map { [.open($0)] } ?? []).frames.isEmpty)
    }

    @Test("settings is a panel kind")
    func acceptsSettings() {
        #expect(kind("settings") == .settings)
        #expect(PanelID("settings:2") == nil)
    }

    @Test("opening settings uses the default size 720 x 540")
    func settingsSize() {
        #expect(defaultSize(.settings) == size(h: 540, w: 720))
        let s = run([open("settings")])
        #expect(s.frames.first?.rect == Geometry.centreRect(size(h: 540, w: 720), bounds: bounds))
    }

    @Test
    func openUsesTheMemory() {
        let base = withMemory([panel("overview:1"): rect(h: 360, w: 760, x: 1000, y: 10)])
        let s = run([open("overview:1")], from: base)
        #expect(s.frames.first?.rect == rect(h: 360, w: 760, x: 440, y: 10))
    }

    @Test
    func openFocusesAnOpenPanel() {
        var s = run([open("overview:1"), open("overview:2")])
        s = run([.stack(frameID(1), onto: frameID(2))], from: s)
        s = run([.minimise(frameID(2)), open("overview:1")], from: s)
        let f = s.frame(of: panel("overview:1"))
        #expect(f?.active == panel("overview:1"))
        #expect(f?.minimised == false)
        #expect(s.frames.count == 1)

        var t = run([open("overview:1"), open("overview:2"), .minimise(frameID(1))])
        t = run([open("overview:1")], from: t)
        #expect(t.frames.map(\.id) == [frameID(2), frameID(1)])
        #expect(t.frames.last?.minimised == false)
    }

    @Test("a new panel without memory opens 24 pixels from a frame with the same rect")
    func openSteps24() {
        let centre = Geometry.centreRect(defaultSize(.overview), bounds: bounds)
        let s = run([open("overview:1"), open("overview:2"), open("overview:3")])
        #expect(
            s.frames.map(\.rect) == [
                centre,
                LayoutRect(x: centre.x + 24, y: centre.y + 24, w: centre.w, h: centre.h),
                LayoutRect(x: centre.x + 48, y: centre.y + 48, w: centre.w, h: centre.h),
            ])
        // A minimised frame is not on the screen, so it does not count.
        let min = run([open("overview:1"), .minimise(frameID(1)), open("overview:2")])
        #expect(min.frames.last?.rect == centre)
        // A saved position from memory does not move.
        let saved = withMemory([panel("overview:2"): centre])
        let reopened = run([open("overview:1"), open("overview:2")], from: saved)
        #expect(reopened.frames.last?.rect == centre)
    }

    @Test
    func openStopsAtTheEdge() {
        let area = size(h: 380, w: 780)
        let s = run(
            [open("overview:1"), open("overview:2"), open("overview:3")],
            from: WindowLayout(bounds: area))
        #expect(
            s.frames.map(\.rect) == [
                rect(h: 360, w: 760, x: 10, y: 10),
                rect(h: 360, w: 760, x: 20, y: 20),
                rect(h: 360, w: 760, x: 20, y: 20),
            ])
    }

    @Test
    func openIgnoresABadID() {
        // The type refuses the ID, so no open can run.
        #expect(PanelID("nope") == nil)
    }

    @Test
    func closeKeepsTheMemory() {
        let s = run([open("settings")])
        let r = s.frames.first?.rect
        let c = run([.close(panel("settings"))], from: s)
        #expect(c.frames.isEmpty)
        #expect(c.memory[panel("settings")] == r)
        #expect(run([open("settings")], from: c).frame(of: panel("settings"))?.rect == r)
    }

    @Test
    func closeOfOneTab() {
        var s = run([open("overview:1"), open("overview:2"), open("overview:3")])
        s = run(
            [.stack(frameID(2), onto: frameID(1)), .stack(frameID(3), onto: frameID(1))], from: s)
        #expect(s.frames.first?.panels == ["overview:1", "overview:2", "overview:3"].map(panel))
        s = run([.close(panel("overview:3"))], from: s)
        #expect(tabs(s.frames.first) == tabs("overview:2", ["overview:1", "overview:2"]))
        s = run([.activate(panel("overview:1")), .close(panel("overview:1"))], from: s)
        #expect(tabs(s.frames.first) == tabs("overview:2", ["overview:2"]))
    }

    @Test("close active closes the active panel of the top frame")
    func closeActive() {
        let s = run([open("overview:1"), open("settings"), .minimise(frameID(2))])
        let c = run([.closeActive], from: s)
        #expect(c.frames.map(\.id) == [frameID(2)])
        #expect(s.topFrame?.id == frameID(1))
    }

    @Test("focusing a frame moves it to the top")
    func focus() {
        let s = run([open("overview:1"), open("overview:2"), .focus(frameID(1))])
        #expect(s.frames.map(\.id) == [frameID(2), frameID(1)])
    }

    // A click on the background takes the focus from the frames. The frames keep their z-order.
    // A second drop changes nothing. A close, a minimise, a tab change, a load and a focus of a
    // minimised frame keep the frames without the focus. A focus, an open and a restore give the
    // focus back, also for the frame that is on top already.
    @Test func aDroppedFocusStaysUntilAFrameComesToTheFront() {
        // Frame 2 is on top, with the tabs overview:2 and settings (active).
        let s = run([
            open("overview:1"), open("overview:2"), open("settings"),
            .stack(frameID(3), onto: frameID(2)),
        ])
        #expect(s.hasFocus)
        #expect(s.focusedFrame?.id == frameID(2))
        let dropped = run([.dropFocus], from: s)
        #expect(!dropped.hasFocus)
        #expect(dropped.focusedFrame == nil)
        #expect(dropped.topFrame?.id == frameID(2))
        #expect(dropped.frames == s.frames)
        #expect(unchanged(dropped, .dropFocus))
        let kept: [WindowAction] = [
            .close(panel("settings")), .closeActive, .minimise(frameID(2)),
            .activate(panel("overview:2")), .load(s.snapshot),
        ]
        for action in kept {
            var next = dropped
            let changed = next.apply(action)
            #expect(changed)
            #expect(!next.hasFocus)
        }
        var hidden = run([.minimise(frameID(1))], from: dropped)
        hidden.apply(.focus(frameID(1)))
        #expect(!hidden.hasFocus)
        let back: [WindowAction] = [
            .focus(frameID(2)), .focus(frameID(1)), open("settings"), open("event-log"),
            .restore(frameID(2)),
        ]
        for action in back {
            var next = dropped
            let changed = next.apply(action)
            #expect(changed)
            #expect(next.focusedFrame != nil)
            #expect(next.focusedFrame == next.topFrame)
        }
        #expect(unchanged(dropped, .focus(frameID(99))))
    }

    @Test("setting a rect clamps it and ignores a locked or minimised frame")
    func setRect() {
        var s = run([open("overview:1")])
        s = run([.setRect(frameID(1), rect(h: 300, w: 400, x: 5000, y: -20))], from: s)
        #expect(s.frames.first?.rect == rect(h: 300, w: 400, x: 800, y: 0))
        let locked = run([.lock(frameID(1), true)], from: s)
        let move = WindowAction.setRect(frameID(1), rect(h: 300, w: 400, x: 1, y: 1))
        #expect(unchanged(locked, move))
        let min = run([.minimise(frameID(1))], from: s)
        #expect(unchanged(min, move))
    }

    @Test("stacking moves the panels of the source into the target")
    func stack() {
        let s = run([open("overview:1"), open("overview:2"), open("overview:3")])
        let t = run([.stack(frameID(1), onto: frameID(2))], from: s)
        #expect(t.frames.map(\.id) == [frameID(3), frameID(2)])
        #expect(tabs(t.frames.last) == tabs("overview:1", ["overview:2", "overview:1"]))
    }

    @Test
    func stackKeepsTheMemory() {
        var s = run([open("overview:1"), open("settings")])
        let own = rect(h: 356, w: 420, x: 700, y: 40)
        s = run([.setRect(frameID(2), own)], from: s)
        s = run([.stack(frameID(2), onto: frameID(1))], from: s)
        #expect(s.memory[panel("settings")] == own)
        #expect(s.memory[panel("overview:1")] == nil)
    }

    @Test("stacking refuses the same frame, a minimised frame or a locked source")
    func stackRefusals() {
        let s = run([open("overview:1"), open("overview:2")])
        #expect(unchanged(s, .stack(frameID(1), onto: frameID(1))))
        let min = run([.minimise(frameID(2))], from: s)
        #expect(unchanged(min, .stack(frameID(1), onto: frameID(2))))
        #expect(unchanged(min, .stack(frameID(2), onto: frameID(1))))
        let locked = run([.lock(frameID(1), true)], from: s)
        #expect(unchanged(locked, .stack(frameID(1), onto: frameID(2))))
    }

    @Test("unstacking makes a new frame on top")
    func unstack() {
        var s = run([open("overview:1"), open("overview:2"), .stack(frameID(2), onto: frameID(1))])
        let old = s.frames.first?.rect
        s = run([.unstack(panel("overview:2"), rect(h: 300, w: 400, x: 50, y: 60))], from: s)
        #expect(s.frames.map(\.id) == [frameID(1), frameID(3)])
        #expect(tabs(s.frames.first) == tabs("overview:1", ["overview:1"]))
        let created = s.frames.last
        #expect(
            created?.locked == false && created?.panels == [panel("overview:2")]
                && created?.rect == rect(h: 300, w: 400, x: 50, y: 60))
        #expect(s.memory[panel("overview:2")] == old)
        #expect(s.nextFrame == 4)
    }

    @Test("unstacking refuses a frame with one panel or a locked frame")
    func unstackRefusals() {
        let r = rect(h: 300, w: 400, x: 50, y: 60)
        let one = run([open("overview:1")])
        #expect(unchanged(one, .unstack(panel("overview:1"), r)))
        let two = run([
            open("overview:1"), open("overview:2"), .stack(frameID(2), onto: frameID(1)),
        ])
        let locked = run([.lock(frameID(1), true)], from: two)
        #expect(unchanged(locked, .unstack(panel("overview:2"), r)))
    }

    @Test
    func boundsKeepsTheRects() {
        let before = run([open("overview:1"), open("settings")])
        let s = run([.bounds(size(h: 400, w: 600))], from: before)
        #expect(s.bounds == size(h: 400, w: 600))
        #expect(s.frames.map(\.rect) == before.frames.map(\.rect))
        for f in s.frames {
            let shown = Geometry.shownRect(f.rect, bounds: s.bounds)
            #expect(shown.x >= 0)
            #expect(shown.y >= 0)
            #expect(shown.x + shown.w <= 600)
            #expect(shown.y + shown.h <= 400)
        }
    }

    @Test
    func layoutFromALargeArea() {
        let large = size(h: 900, w: 1440)
        let small = size(h: 500, w: 800)
        let saved = [
            rect(h: 360, w: 760, x: 16, y: 16),
            rect(h: 356, w: 420, x: 1004, y: 528),
            rect(h: 900, w: 1440, x: 0, y: 0),
        ]
        let frames = saved.enumerated().map { i, r in
            SavedFrame(
                panels: [panel("overview:\(i + 1)")], active: panel("overview:\(i + 1)"), rect: r,
                minimised: false, locked: false)
        }
        var s = run(
            [.load(LayoutSnapshot(frames: frames, memory: [:]))], from: WindowLayout(bounds: small))
        #expect(s.frames.map(\.rect) == saved)
        for f in s.shownFrames {
            #expect(f.rect.x + f.rect.w <= small.w)
            #expect(f.rect.y + f.rect.h <= small.h)
        }
        #expect(s.shownFrames.map(\.rect) != saved)
        // The save keeps the saved rects, not the shown rects.
        #expect(s.snapshot.frames.map(\.rect) == saved)
        s = run([.bounds(large)], from: s)
        #expect(s.shownFrames.map(\.rect) == saved)
    }

    @Test
    func shownFramesKeepTheFrames() {
        var s = run([open("overview:1"), open("settings")])
        s = run([.setRect(frameID(2), rect(h: 300, w: 400, x: 700, y: 400))], from: s)
        let shown = run([.bounds(size(h: 600, w: 1000))], from: s).shownFrames
        // A frame is a value: the same frame is an equal frame.
        #expect(shown.first == s.frames.first)
        #expect(shown.last?.rect == rect(h: 300, w: 400, x: 600, y: 300))
    }

    @Test("loading replaces the frames, drops invalid and repeated panels and keeps the rects")
    func load() {
        let base = run([open("settings")])
        let r = rect(h: 300, w: 400, x: 5000, y: 5000)
        let mk = { (panels: [String], active: String) in
            SavedFrame(
                panels: panels.map(panel), active: panel(active), rect: r, minimised: false,
                locked: false)
        }
        let memory = [panel("overview:9"): rect(h: 200, w: 200, x: 1, y: 1)]
        // The saved frames are [overview:1, bad] (active bad), [bad], [overview:1] and
        // [overview:2, selected-item]. A SavedFrame cannot hold "bad", so the first frame has
        // only overview:1, and the frame [bad] is not there. The active panel of the first frame
        // is a panel that the frame does not hold (as "bad"), so the load makes the first panel
        // active.
        var s = base
        let changed = s.apply(
            .load(
                LayoutSnapshot(
                    frames: [
                        mk(["overview:1"], "settings"),
                        mk(["overview:1"], "overview:1"),
                        mk(["overview:2", "selected-item"], "selected-item"),
                    ], memory: memory)))
        #expect(changed)
        #expect(s.frames.map(\.id) == [frameID(2), frameID(3)])
        #expect(tabs(s.frames.first) == tabs("overview:1", ["overview:1"]))
        #expect(s.frames.first?.rect == r)
        #expect(s.shownFrames.first?.rect == rect(h: 300, w: 400, x: 800, y: 500))
        #expect(s.frames.last?.panels == [panel("overview:2"), panel("selected-item")])
        #expect(s.memory == memory)
        #expect(s.nextFrame == 4)
    }

    @Test("an action that changes nothing returns the same state")
    func noChange() throws {
        let s = run([open("overview:1"), open("overview:2")])
        let f2 = try #require(s.frames.last)
        // An ID that is not good cannot reach apply. An unknown frame is f99,
        // and an unknown panel is a panel with no frame.
        let actions: [WindowAction] = [
            open("overview:2"),
            .close(panel("settings")),
            .focus(frameID(99)),
            .focus(frameID(2)),
            .setRect(frameID(2), f2.rect),
            .stack(frameID(2), onto: frameID(99)),
            .unstack(panel("settings"), f2.rect),
            .activate(panel("overview:2")),
            .restore(frameID(2)),
            .lock(frameID(2), false),
            .bounds(bounds),
        ]
        #expect(actions.allSatisfy { unchanged(s, $0) })
        #expect(unchanged(WindowLayout(bounds: bounds), .closeActive))
        let min = run([.minimise(frameID(1))], from: s)
        #expect(unchanged(min, .minimise(frameID(1))))
    }

    @Test
    func closeOfAStackTab() {
        var s = run([open("overview:1"), open("settings")])
        s = run([.stack(frameID(2), onto: frameID(1))], from: s)
        let moved = rect(h: 300, w: 400, x: 120, y: 90)
        s = run([.setRect(frameID(1), moved)], from: s)
        let rectAtClose = s.frames.first?.rect
        s = run([.close(panel("settings"))], from: s)
        #expect(s.frames.count == 1)
        s = run([open("settings")], from: s)
        #expect(s.frame(of: panel("settings"))?.rect == rectAtClose)
        #expect(s.frame(of: panel("settings"))?.rect == moved)
    }

    @Test("apply does not change its input")
    func noMutation() {
        // A layout is a value. Each action changes only its own copy.
        let base = run([open("overview:1"), open("settings"), open("selected-item")])
        let stacked = run([.stack(frameID(2), onto: frameID(1))], from: base)
        let s = run([.close(panel("selected-item"))], from: stacked)
        #expect(s.frames.count == 1)
        #expect(!s.memory.isEmpty)
        let second = run([open("overview:2")], from: s)
        let first = second.frames[0].id
        let other = second.frames[1].id
        let r = rect(h: 250, w: 350, x: 40, y: 50)
        let actions: [WindowAction] = [
            open(chat),
            open("selected-item"),
            .close(panel("settings")),
            .closeActive,
            .focus(first),
            .setRect(first, r),
            .stack(other, onto: first),
            .unstack(panel("settings"), r),
            .activate(panel("settings")),
            .minimise(first),
            .restore(first),
            .lock(first, true),
            .bounds(size(h: 400, w: 500)),
            .load(LayoutSnapshot(frames: [], memory: [:])),
        ]
        let copy = second
        var results: [WindowLayout] = []
        for action in actions {
            var changed = second
            changed.apply(action)
            results.append(changed)
        }
        #expect(second == copy)
        #expect(results.count == actions.count)
    }

    @Test("bounds under 1 in width or height change nothing")
    func boundsUnder1() {
        let s = run([open("settings")])
        let sizes = [
            size(h: 800, w: 0), size(h: 0, w: 1200), size(h: -5, w: -5), size(h: 0.5, w: 900),
        ]
        #expect(sizes.allSatisfy { unchanged(s, .bounds($0)) })
    }
}

private let oldChat = "chat:11111111-1111-4111-8111-111111111111"
private let newChat = "chat:22222222-2222-4222-8222-222222222222"

private func replace(_ old: String, _ new: String) -> WindowAction {
    .replace(panel(old), with: panel(new))
}

@Suite("replacing a panel")
struct ReplaceTests {
    @Test
    func putsTheNewPanel() throws {
        let before = run([open(oldChat)])
        let after = run([replace(oldChat, newChat)], from: before)
        #expect(after.frames.count == 1)
        var expected = try #require(before.frames.first)
        expected.active = panel(newChat)
        expected.panels = [panel(newChat)]
        #expect(after.frames.first == expected)
        #expect(after.frame(of: panel(oldChat)) == nil)
    }

    @Test
    func keepsTheTabPlace() throws {
        let s = run([open("watchlist"), open(oldChat), open("reviews")])
        let id = { (raw: String) in s.frame(of: panel(raw))?.id ?? frameID(0) }
        let stacked = run(
            [
                .stack(id(oldChat), onto: id("watchlist")),
                .stack(id("reviews"), onto: id("watchlist")),
                .activate(panel(oldChat)),
            ], from: s)
        let before = try #require(stacked.frame(of: panel(oldChat)))
        #expect(before.panels.count == 3)
        let after = run([replace(oldChat, newChat)], from: stacked).frame(of: panel(newChat))
        #expect(after?.panels == before.panels.map { $0 == panel(oldChat) ? panel(newChat) : $0 })
        #expect(after?.active == panel(newChat))
        #expect(after?.id == before.id)
    }

    @Test
    func keepsAnotherActiveTab() {
        let s = run([open("watchlist"), open(oldChat)])
        let stacked = run([.stack(s.frames[1].id, onto: s.frames[0].id)], from: s)
        let after = run([.activate(panel("watchlist")), replace(oldChat, newChat)], from: stacked)
        #expect(after.frame(of: panel(newChat))?.active == panel("watchlist"))
        #expect(after.frame(of: panel(newChat))?.panels == [panel("watchlist"), panel(newChat)])
    }

    @Test
    func closesOnlyTheOldPanel() {
        let s = run([open(oldChat), open(newChat)])
        let after = run([replace(oldChat, newChat)], from: s)
        #expect(after.frames.map(\.panels) == [[panel(newChat)]])
        #expect(after.frames.first?.id == s.frames.last?.id)
    }

    @Test
    func unknownOldPanel() {
        let s = run([open(newChat)])
        #expect(unchanged(s, replace(oldChat, newChat)))
    }

    @Test
    func refusedNewPanel() {
        // The type refuses the new ID, so no replace can run.
        #expect(PanelID("nonsense") == nil)
    }
}

// The restore of a minimised chat. A double-click on an Overview row runs the
// open action. These tests prove that open restores a minimised chat.
private func minimise(_ layout: WindowLayout, _ raw: String) throws -> WindowLayout {
    let frame = try #require(layout.frame(of: panel(raw)))
    return run([.minimise(frame.id)], from: layout)
}

@Suite("open restores a minimised chat")
struct RestoreOpenTests {
    @Test
    func restoresAndFocuses() throws {
        let s = run([open(chat), open("watchlist")])
        let minimised = try minimise(s, chat)
        #expect(minimised.frame(of: panel(chat))?.minimised == true)
        let next = run([open(chat)], from: minimised)
        #expect(next.frame(of: panel(chat))?.minimised == false)
        #expect(next.topFrame?.active == panel(chat))
    }

    @Test
    func restoresABackTab() throws {
        let s = run([open("watchlist"), open(chat)])
        let target = try #require(s.frame(of: panel("watchlist")))
        let source = try #require(s.frame(of: panel(chat)))
        let stacked = run([.stack(source.id, onto: target.id)], from: s)
        let back = run([open("watchlist")], from: stacked)
        #expect(back.frame(of: panel(chat))?.active == panel("watchlist"))
        let minimised = try minimise(back, chat)
        let next = run([open(chat)], from: minimised)
        let frame = next.frame(of: panel(chat))
        #expect(frame?.minimised == false)
        #expect(frame?.active == panel(chat))
        #expect(next.topFrame?.id == frame?.id)
    }

    @Test
    func restoresTheRightFrame() throws {
        let s = run([open(chat), open("watchlist"), open("event-log")])
        let minimised = try minimise(s, chat)
        let next = run([open(chat)], from: minimised)
        #expect(next.topFrame?.active == panel(chat))
        #expect(next.frames.filter(\.minimised).isEmpty)
        #expect(next.frames.count == 3)
    }
}
