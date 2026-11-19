import BifrostFoundation
import Observation

// The window layout on the main actor. The model holds the layout and the drag. The rules are in
// the Model folder (WindowLayout, FrameDrag). SwiftUI views, such as the side bar, observe the
// layout. The model is in this module, so each feature module that opens or closes a panel, for
// example the Settings panel, can use it.
// The owner of the model sets one receiver, onChange, that gets each change at once and in order:
// the canvas must move the bodies before the chats get the layout, and the UI store must hold its
// saves from the press of a drag.
@MainActor
@Observable
public final class WindowLayoutModel {
    // A change that the receiver gets.
    nonisolated public enum Change: Equatable, Sendable {
        // The layout changed. The model has the new layout.
        case layout
        // A drag started. Only one drag runs at a time.
        case dragStarted
        // The drag ended. A release applied its rect or its stack first.
        case dragEnded
    }

    public private(set) var layout: WindowLayout
    // What the canvas draws during a drag, or nil when no drag runs.
    package private(set) var drag: DragView?
    // The snap distance of the next drag, in layout units (the Snap distance setting). A drag
    // keeps the value of its start (row W9).
    package var snapDistance = Geometry.snapDistance
    // The one receiver of the changes. The owner sets it (the shell in the app).
    @ObservationIgnored public var onChange: ((Change) -> Void)?

    // The rules of the drag that runs.
    @ObservationIgnored private var core: FrameDrag?

    public init(layout: WindowLayout) {
        self.layout = layout
    }

    // Apply the action to the layout. An action that changes nothing sends no change. A drag
    // ends when its frame closes, goes to the side bar or becomes locked (row W7). The end is a
    // cancel, so it applies no rect.
    public func apply(_ action: WindowAction) {
        var next = layout
        guard next.apply(action) else { return }
        layout = next
        onChange?(.layout)
        if let core, !canDrag(core.frame) { endDrag(at: nil) }
    }

    // Start a drag at a point in layout units, in the coordinates of the canvas. The result is
    // false when a drag runs, or when the frame is unknown, locked or minimised.
    package func beginDrag(frame: FrameID, mode: DragMode, at point: LayoutPoint) -> Bool {
        guard core == nil,
            let started = FrameDrag(
                layout: layout, frame: frame, mode: mode, at: point, snap: snapDistance)
        else { return false }
        core = started
        drag = DragView(frame: frame, live: nil, marks: [], dropTarget: nil)
        onChange?(.dragStarted)
        return true
    }

    // One pointer step. Only a tear-out changes the layout during a drag. It applies .unstack,
    // and the receiver gets the new layout at once.
    package func moveDrag(to point: LayoutPoint) {
        guard var current = core else { return }
        var next = layout
        let frame = current.frame
        let view = current.move(to: point, layout: &next)
        core = current
        // FrameDrag changes its frame only when the tear-out applied .unstack.
        if current.frame != frame {
            layout = next
            onChange?(.layout)
        }
        if view != drag { drag = view }
    }

    // The end of the drag at a point, or a cancel for nil. A release applies the stack or the
    // snapped rect. A cancel applies the last drawn rect with no snap.
    package func endDrag(at point: LayoutPoint?) {
        guard let current = core else { return }
        let end = current.end(at: point, layout: layout)
        core = nil
        drag = nil
        switch end {
        case .nothing: break
        case .setRect(let id, let rect): apply(.setRect(id, rect))
        case .stack(let id, let target): apply(.stack(id, onto: target))
        }
        onChange?(.dragEnded)
    }

    private func canDrag(_ id: FrameID) -> Bool {
        guard let frame = layout.frames.first(where: { $0.id == id }) else { return false }
        return !frame.locked && !frame.minimised
    }
}

extension WindowLayoutModel {
    // Open the chat of a session, or bring the frame of its chat to the front: the open action
    // of a row and of the open key. A text that is not a session ID opens nothing.
    package func openChat(_ sessionId: String) {
        guard let session = SessionID(sessionId) else { return }
        apply(.open(.chat(session)))
    }
}

extension WindowLayoutModel {
    // Keep the current layout in the store (behaviour list: docs/behaviour/windows.md). Each new
    // layout goes into the store, and the store saves 500 ms after the last change. A drag
    // holds the saves, so a drag writes no file.
    public func save(_ change: Change, to store: UIStateStore) {
        switch change {
        case .layout: store.change { $0.current = layout.snapshot }
        case .dragStarted: store.holdSaves(true)
        case .dragEnded: store.holdSaves(false)
        }
    }
}

// The layout at the start of the app: the current layout of ui-state.json, else the default
// layout. The default layout is overview:1 at the Overview rect, then the Selected Item at the
// Selected Item rect, on top. The canvas must have its size first, so the opens and the rects
// apply to the bounds of the area.
extension WindowLayoutModel {
    // The rect of overview:1 in the default layout.
    package static let overviewRect = LayoutRect(x: 16, y: 16, w: 760, h: 360)
    // The rect of the Selected Item in the default layout: at the right of the Overview, with a
    // gap of 16, at the default size of the panel.
    package static let selectedRect = LayoutRect(
        x: overviewRect.x + overviewRect.w + 16, y: overviewRect.y,
        w: PanelKind.selectedItem.defaultSize.w, h: PanelKind.selectedItem.defaultSize.h)

    public func applyStartLayout(_ current: LayoutSnapshot?) {
        if let current {
            apply(.load(current))
            return
        }
        let frames: [(PanelID, LayoutRect)] = [
            (.overview(1), Self.overviewRect), (.selectedItem, Self.selectedRect),
        ]
        for (panel, rect) in frames {
            apply(.open(panel))
            if let frame = layout.frame(of: panel) { apply(.setRect(frame.id, rect)) }
        }
    }
}
