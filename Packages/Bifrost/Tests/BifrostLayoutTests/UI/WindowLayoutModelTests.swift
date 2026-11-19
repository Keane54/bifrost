import BifrostFoundation
import BifrostTestSupport
import Testing

@testable import BifrostLayout

// The model of the layout: it owns the drag and gives each change to its
// one receiver, in order.
@MainActor
@Suite("window layout model", .tags(.window))
struct WindowLayoutModelTests {
    // The changes that the receiver got, in order, and the layout at each layout change.
    @MainActor
    private final class Changes {
        var list: [WindowLayoutModel.Change] = []
        var layouts: [WindowLayout] = []
    }

    private func make() -> (WindowLayoutModel, Changes) {
        let model = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1200, h: 800)))
        let changes = Changes()
        model.onChange = { [weak model] change in
            changes.list.append(change)
            if change == .layout, let model { changes.layouts.append(model.layout) }
        }
        return (model, changes)
    }

    private func open(_ model: WindowLayoutModel, _ raw: String, _ r: LayoutRect) -> FrameID {
        model.apply(.open(panel(raw)))
        let id = model.layout.frame(of: panel(raw))?.id ?? FrameID(number: 0)
        model.apply(.setRect(id, r))
        return id
    }

    // The default layout of the app: overview:1 at 16, 16, 760, 360, and the Selected Item at
    // its right, 16 units away, at its default size of 360 by 300. The Selected Item is on top.
    @Test func theDefaultLayoutHasTheOverviewAndTheSelectedItem() {
        let (model, _) = make()
        model.applyStartLayout(nil)
        #expect(WindowLayoutModel.overviewRect == rect(16, 16, 760, 360))
        #expect(WindowLayoutModel.selectedRect == rect(792, 16, 360, 300))
        #expect(
            model.layout.frames.map(\.panels) == [[panel("overview:1")], [panel("selected-item")]])
        #expect(
            model.layout.frames.map(\.rect) == [rect(16, 16, 760, 360), rect(792, 16, 360, 300)])
        #expect(model.layout.topFrame?.active == panel("selected-item"))
    }

    // The start layout of the app: the current layout of the file, else the default layout.
    @Test func theStartLayoutIsTheFileElseTheDefaultLayout() {
        let (model, _) = make()
        model.applyStartLayout(nil)
        #expect(model.layout.frames.count == 2)
        let other = WindowLayoutModel(layout: WindowLayout(bounds: LayoutSize(w: 1200, h: 800)))
        _ = open(other, "settings", rect(100, 120, 400, 300))
        let saved = other.layout.snapshot
        let (loaded, _) = make()
        loaded.applyStartLayout(saved)
        #expect(loaded.layout.snapshot == saved)
        #expect(loaded.layout.frames.map(\.panels) == [[panel("settings")]])
    }

    // The chat of a row opens only for a session ID of the UUID form (row W1). The panel holds
    // the session ID in lower case.
    @Test func aRowOpensTheChatOfItsSessionIDInLowerCase() {
        let (model, _) = make()
        model.openChat("s9")
        #expect(model.layout.frames.isEmpty)
        let session: SessionID = "73b5ca76-a4a8-4f97-9764-e41657296414"
        model.openChat(session.text.uppercased())
        #expect(model.layout.frames.map(\.panels) == [[.chat(session)]])
    }

    // The receiver gets each new layout and the start and the end of each drag. An action that
    // changes nothing sends nothing. A release applies its rect before the end of the drag, so
    // the UI store gets the new rect while the drag still holds its saves.
    @Test func eachChangeReachesTheReceiverInOrder() {
        let (model, changes) = make()
        let a = open(model, "settings", rect(100, 100, 400, 300))
        #expect(changes.list == [.layout, .layout])
        #expect(changes.layouts.last == model.layout)
        model.apply(.focus(a))
        #expect(changes.list.count == 2)
        #expect(model.beginDrag(frame: a, mode: .move, at: LayoutPoint(x: 200, y: 110)))
        // One drag at a time.
        #expect(!model.beginDrag(frame: a, mode: .move, at: LayoutPoint(x: 200, y: 110)))
        model.moveDrag(to: LayoutPoint(x: 230, y: 140))
        #expect(model.drag?.live == rect(130, 130, 400, 300))
        #expect(changes.list == [.layout, .layout, .dragStarted])
        model.endDrag(at: LayoutPoint(x: 230, y: 140))
        #expect(changes.list == [.layout, .layout, .dragStarted, .layout, .dragEnded])
        #expect(model.layout.frames.first?.rect == rect(130, 130, 400, 300))
        #expect(changes.layouts.last == model.layout)
        // With no receiver, the model sends nothing.
        model.onChange = nil
        model.apply(.minimise(a))
        #expect(changes.list.count == 5)
    }

    // Row W7: a drag ends at once when its frame closes, goes to the side bar or becomes locked.
    // The receiver gets the change first, then the end of the drag.
    @Test func aDragEndsWhenItsFrameClosesLocksOrMinimises() {
        let actions: [(FrameID) -> WindowAction] = [
            { _ in .close(panel("settings")) }, { .minimise($0) }, { .lock($0, true) },
        ]
        for action in actions {
            let (model, changes) = make()
            let a = open(model, "settings", rect(100, 100, 400, 300))
            #expect(model.beginDrag(frame: a, mode: .move, at: LayoutPoint(x: 200, y: 110)))
            model.moveDrag(to: LayoutPoint(x: 260, y: 110))
            model.apply(action(a))
            #expect(model.drag == nil)
            #expect(changes.list == [.layout, .layout, .dragStarted, .layout, .dragEnded])
            // The end applies no rect.
            #expect(model.layout.frames.allSatisfy { $0.rect == rect(100, 100, 400, 300) })
            model.endDrag(at: LayoutPoint(x: 260, y: 110))
            #expect(changes.list.count == 5)
        }
    }

    // A tear-out changes the layout during the drag: the receiver gets it at once. A cancel
    // after the tear-out keeps the new frame at its last drawn rect.
    @Test func aTearOutSendsTheLayoutAtOnceAndACancelKeepsTheNewFrame() throws {
        let (model, changes) = make()
        let a = open(model, "watchlist", rect(600, 100, 300, 300))
        let b = open(model, "settings", rect(100, 450, 400, 250))
        model.apply(.stack(b, onto: a))
        let count = changes.list.count
        let tab = DragMode.tab(panel("watchlist"))
        #expect(model.beginDrag(frame: a, mode: tab, at: LayoutPoint(x: 640, y: 114)))
        model.moveDrag(to: LayoutPoint(x: 640, y: 150))
        #expect(Array(changes.list.dropFirst(count)) == [.dragStarted, .layout])
        #expect(changes.layouts.last == model.layout)
        let torn = try #require(model.layout.frame(of: panel("watchlist")))
        #expect(model.drag?.frame == torn.id)
        model.moveDrag(to: LayoutPoint(x: 600, y: 200))
        #expect(model.drag?.live == rect(540, 186, 300, 300))
        model.endDrag(at: nil)
        #expect(model.layout.frame(of: panel("watchlist"))?.rect == rect(540, 186, 300, 300))
        #expect(model.drag == nil)
        #expect(
            Array(changes.list.dropFirst(count)) == [.dragStarted, .layout, .layout, .dragEnded])
    }

    // Row W8: a tab press whose tear-out cannot apply stops the drag, and nothing changes.
    @Test func aTabPressWhoseTearOutCannotApplyChangesNothing() {
        let (model, changes) = make()
        let a = open(model, "watchlist", rect(600, 100, 300, 300))
        let b = open(model, "settings", rect(100, 450, 400, 250))
        model.apply(.stack(b, onto: a))
        let tab = DragMode.tab(panel("watchlist"))
        #expect(model.beginDrag(frame: a, mode: tab, at: LayoutPoint(x: 640, y: 114)))
        // The tab leaves the frame before the tear-out (for example, a close by a key).
        model.apply(.close(panel("watchlist")))
        let layout = model.layout
        let count = changes.list.count
        model.moveDrag(to: LayoutPoint(x: 640, y: 200))
        #expect(model.layout == layout)
        #expect(changes.list.count == count)
        #expect(model.drag?.live == nil)
        model.endDrag(at: LayoutPoint(x: 640, y: 200))
        #expect(model.layout == layout)
        #expect(Array(changes.list.dropFirst(count)) == [.dragEnded])
    }

    // The snap distance of the setting applies from the next drag.
    @Test func theSnapDistanceComesFromTheModel() {
        let (model, _) = make()
        let a = open(model, "settings", rect(100, 100, 400, 300))
        model.snapDistance = 0
        #expect(model.beginDrag(frame: a, mode: .move, at: LayoutPoint(x: 200, y: 110)))
        model.moveDrag(to: LayoutPoint(x: 103, y: 13))
        model.endDrag(at: LayoutPoint(x: 103, y: 13))
        #expect(model.layout.frames.first?.rect == rect(3, 3, 400, 300))
    }
}
