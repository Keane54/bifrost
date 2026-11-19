// The rules of one drag of a frame: a move, a resize, or a press on a tab of a stack. The section
// "Drag, snap and stack" of docs/behaviour/windows.md has the rules. The shell gives the pointer
// positions in layout units, in the coordinates of the canvas, and applies the end of the drag
// to the layout.

// What the press started: a move of the frame, a resize at an edge or a corner, or a press on a
// tab. A press on the only tab of a frame is a move.
package enum DragMode: Sendable, Equatable { case move, resize(FrameEdge), tab(PanelID) }

// What the canvas draws during the drag. live is the raw rect of the frame (nil before the first
// step: the frame then shows its own rect). marks are the snap marks of a release here.
// dropTarget is the frame whose title bar would get the frame as a stack.
package struct DragView: Sendable, Equatable {
    package var frame: FrameID
    package var live: LayoutRect?
    package var marks: [SnapMark]
    package var dropTarget: FrameID?

    package init(frame: FrameID, live: LayoutRect?, marks: [SnapMark], dropTarget: FrameID?) {
        self.frame = frame
        self.live = live
        self.marks = marks
        self.dropTarget = dropTarget
    }
}

// The action that the end of a drag gives to the layout.
package enum DragEnd: Sendable, Equatable {
    case nothing, setRect(FrameID, LayoutRect), stack(FrameID, onto: FrameID)
}

// The phase of a drag.
private enum DragPhase: Sendable, Equatable {
    // A press on a tab of a stack waits for a tear-out of the tab.
    case pressingTab(PanelID)
    // A move or a resize waits for the first step away from the press point.
    case waiting
    // The tab left its stack as a new frame. No step has drawn the new frame yet.
    case tornOut
    // The last step drew the frame at this raw rect.
    case moving(drawn: LayoutRect)
    // The drag stopped before its end: a tear-out that cannot apply, or a frame that closed,
    // became minimised or became locked.
    case stopped
}

package struct FrameDrag: Sendable {
    // The frame that the drag moves. A tear-out changes it to the new frame. The frame changes
    // only when a tear-out applies .unstack to the layout, so a change of frame after a move
    // tells the caller that the layout changed.
    package private(set) var frame: FrameID

    // The edge of a resize, or nil for a move.
    private let edge: FrameEdge?
    private let snap: Double
    // The press point. A tear-out does not change it.
    private let down: LayoutPoint
    private var phase: DragPhase
    // The start of the deltas: the press point, or the pointer at the tear-out.
    private var start: LayoutPoint
    // The drag starts from the rect that the screen shows.
    private var startRect: LayoutRect
    // The rects that the snap uses: the shown rects of the other frames that show.
    private var others: [LayoutRect]
    // The last pointer position.
    private var last: LayoutPoint
    // True after the pointer went Hit.stackDistance or more from the press point, in any phase.
    // Only a move that went that far can stack the frame.
    private var farEnough = false
    private var view: DragView

    // nil for an unknown, locked or minimised frame.
    package init?(
        layout: WindowLayout, frame id: FrameID, mode: DragMode, at p: LayoutPoint, snap: Double
    ) {
        guard let frame = layout.frames.first(where: { $0.id == id }), !frame.locked,
            !frame.minimised
        else { return nil }
        self.frame = id
        switch mode {
        case .move:
            edge = nil
            phase = .waiting
        case .resize(let side):
            edge = side
            phase = .waiting
        case .tab(let panel):
            // A press on a tab of a stack waits for a tear-out. A drag of the only tab is a move.
            edge = nil
            phase = frame.panels.count > 1 ? .pressingTab(panel) : .waiting
        }
        self.snap = snap
        down = p
        start = p
        last = p
        startRect = Geometry.shownRect(frame.rect, bounds: layout.bounds)
        others = Self.visibleRects(layout, excluding: id)
        view = DragView(frame: id, live: nil, marks: [], dropTarget: nil)
    }

    // One pointer step. A tear-out applies .unstack to the layout, and the drag goes on with the
    // new frame. The layout gets no other change before the end.
    package mutating func move(to p: LayoutPoint, layout: inout WindowLayout) -> DragView {
        guard phase != .stopped else { return view }
        guard canGoOn(in: layout) else {
            stop()
            return view
        }
        last = p
        if !farEnough { farEnough = Hit.movedToStack(from: down, to: p) }
        switch phase {
        case .pressingTab(let tab):
            tearOut(tab, layout: &layout)
        case .waiting:
            if p != start { draw(in: layout) }
        case .tornOut, .moving:
            draw(in: layout)
        case .stopped:
            // The guard above returns.
            break
        }
        return view
    }

    // The end of the drag. nil is a cancel: it keeps the last drawn rect, with no snap. A
    // release stacks the frame on a title bar, or puts it at the snapped rect. A tab press that
    // ends before a tear-out gives nothing: the click activates the tab.
    package func end(at p: LayoutPoint?, layout: WindowLayout) -> DragEnd {
        guard canGoOn(in: layout) else { return .nothing }
        guard let p else {
            if case .moving(let drawn) = phase { return .setRect(frame, drawn) }
            return .nothing
        }
        switch phase {
        case .stopped, .pressingTab:
            return .nothing
        case .waiting:
            // A release at the press point did not move the frame.
            guard p != start else { return .nothing }
        case .tornOut, .moving:
            break
        }
        var release = self
        release.last = p
        if !release.farEnough { release.farEnough = Hit.movedToStack(from: down, to: p) }
        if let target = release.stackTarget(in: layout) { return .stack(frame, onto: target) }
        return .setRect(frame, release.place(in: layout).snapped)
    }

    // The shown rects of the frames that show, with no excluded frame.
    private static func visibleRects(_ layout: WindowLayout, excluding id: FrameID?)
        -> [LayoutRect]
    {
        layout.shownFrames.filter { $0.id != id && !$0.minimised }.map(\.rect)
    }

    // A drag ends when its frame closes, becomes minimised or becomes locked.
    private func canGoOn(in layout: WindowLayout) -> Bool {
        guard let current = layout.frames.first(where: { $0.id == frame }) else { return false }
        return !current.locked && !current.minimised
    }

    private mutating func stop() {
        phase = .stopped
        view = DragView(frame: frame, live: nil, marks: [], dropTarget: nil)
    }

    // The raw rect follows the pointer with no snap. The snapped rect is the rect that a release
    // gives. Both come from the start rect and the total delta, not from the last rect. So the
    // snap is stable.
    private func place(in layout: WindowLayout) -> (raw: LayoutRect, snapped: LayoutRect) {
        let dx = last.x - start.x
        let dy = last.y - start.y
        func rect(_ snap: Double) -> LayoutRect {
            if let edge {
                return Geometry.resizeRect(
                    startRect, edge: edge, dx: dx, dy: dy, others: others, bounds: layout.bounds,
                    snap: snap)
            }
            return Geometry.moveRect(
                startRect, dx: dx, dy: dy, others: others, bounds: layout.bounds, snap: snap)
        }
        return (rect(0), rect(snap))
    }

    // A move that ends on the title bar of a different frame stacks the two frames. The callers
    // ask only after the frame moved.
    private func stackTarget(in layout: WindowLayout) -> FrameID? {
        guard edge == nil, farEnough else { return nil }
        return Hit.titleBarAt(layout.shownFrames, last, excluding: frame)?.id
    }

    // One step at the raw rect, with the marks of the snap. A drop on a title bar stacks the
    // frame and applies no snap, so no mark shows.
    private mutating func draw(in layout: WindowLayout) {
        let (raw, snapped) = place(in: layout)
        let target = stackTarget(in: layout)
        let marks =
            target == nil
            ? Geometry.snapMarks(raw: raw, snapped: snapped, others: others, bounds: layout.bounds)
            : []
        phase = .moving(drawn: raw)
        view = DragView(frame: frame, live: raw, marks: marks, dropTarget: target)
    }

    // The tab went more than Hit.tearDistance from the title bar. It leaves the stack as a new
    // frame. Then the same drag moves the new frame.
    private mutating func tearOut(_ panel: PanelID, layout: inout WindowLayout) {
        guard let source = layout.frames.first(where: { $0.id == frame }),
            source.panels.count >= 2, source.panels.contains(panel)
        else {
            // The layout refuses these cases, so the drag stops here.
            stop()
            return
        }
        let sourceRect = Geometry.shownRect(source.rect, bounds: layout.bounds)
        guard Hit.tornOut(bar: Geometry.titleBar(sourceRect), last) else { return }
        // The new frame gets the saved size of the panel, or else the size of the stack.
        let rect = Hit.tearOutRect(
            at: last, saved: layout.memory[panel], stack: sourceRect, bounds: layout.bounds)
        // The new frame is not in the layout yet, so all frames that show are the others.
        let visible = Self.visibleRects(layout, excluding: nil)
        // The layout gives the new frame the ID f<nextFrame>.
        let created = FrameID(number: layout.nextFrame)
        guard layout.apply(.unstack(panel, rect)) else {
            stop()
            return
        }
        frame = created
        phase = .tornOut
        startRect = rect
        start = last
        others = visible
        view = DragView(frame: created, live: nil, marks: [], dropTarget: nil)
    }
}
