// The state of the window layout: the frames, the stacks of tabs and the memory of the rects
// (docs/behaviour/windows.md). The layout is a value. Each action changes the value in place and
// tells if it changed.

// A frame on the canvas. It holds one panel, or a stack of tabs.
public struct LayoutFrame: Sendable, Equatable {
    public let id: FrameID
    public var panels: [PanelID]
    public var active: PanelID
    // The rect that the user set. The screen shows Geometry.shownRect(rect, bounds).
    public var rect: LayoutRect
    public var minimised: Bool
    public var locked: Bool

    package init(
        id: FrameID, panels: [PanelID], active: PanelID, rect: LayoutRect, minimised: Bool,
        locked: Bool
    ) {
        self.id = id
        self.panels = panels
        self.active = active
        self.rect = rect
        self.minimised = minimised
        self.locked = locked
    }

    // The frame after a panel leaves it, or nil when no panel stays. The active panel becomes
    // the tab to the left, or else the first tab.
    fileprivate func without(_ panel: PanelID) -> LayoutFrame? {
        guard let index = panels.firstIndex(of: panel) else { return self }
        var next = self
        next.panels.remove(at: index)
        guard let first = next.panels.first else { return nil }
        if active == panel { next.active = index > 0 ? next.panels[index - 1] : first }
        return next
    }
}

// A frame of a saved layout: a frame with no ID. A load gives each frame a new ID.
package struct SavedFrame: Sendable, Equatable {
    package var panels: [PanelID]
    package var active: PanelID
    package var rect: LayoutRect
    package var minimised: Bool
    package var locked: Bool

    package init(
        panels: [PanelID], active: PanelID, rect: LayoutRect, minimised: Bool, locked: Bool
    ) {
        self.panels = panels
        self.active = active
        self.rect = rect
        self.minimised = minimised
        self.locked = locked
    }
}

// A saved layout: the frames in z-order and the memory.
public struct LayoutSnapshot: Sendable, Equatable {
    package var frames: [SavedFrame]
    package var memory: [PanelID: LayoutRect]

    package init(frames: [SavedFrame], memory: [PanelID: LayoutRect]) {
        self.frames = frames
        self.memory = memory
    }
}

public enum WindowAction: Sendable, Equatable {
    case open(PanelID), close(PanelID), replace(PanelID, with: PanelID), closeActive
    case focus(FrameID), setRect(FrameID, LayoutRect), stack(FrameID, onto: FrameID)
    case unstack(PanelID, LayoutRect), activate(PanelID), minimise(FrameID), restore(FrameID)
    case lock(FrameID, Bool), bounds(LayoutSize), load(LayoutSnapshot)
}

public struct WindowLayout: Sendable, Equatable {
    // A new panel with no memory moves this distance down and right while a frame that shows
    // has its rect.
    private static let step = 24.0

    // In z-order: the last frame is on top.
    public private(set) var frames: [LayoutFrame] = []
    // The rect of each panel when it left a frame. A panel that opens again gets this rect.
    package private(set) var memory: [PanelID: LayoutRect] = [:]
    package private(set) var bounds: LayoutSize
    package private(set) var nextFrame = 1

    public init(bounds: LayoutSize) {
        self.bounds = bounds
    }

    // Applies the action. The result is false when the layout does not change, so no observer
    // acts and no save starts. A load always gives true.
    @discardableResult
    package mutating func apply(_ action: WindowAction) -> Bool {
        switch action {
        case .open(let panel): open(panel)
        case .close(let panel): close(panel)
        case .replace(let panel, let other): replace(panel, with: other)
        case .closeActive: closeActive()
        case .focus(let id): focus(id)
        case .setRect(let id, let rect): setRect(id, rect)
        case .stack(let id, let target): stack(id, onto: target)
        case .unstack(let panel, let rect): unstack(panel, rect)
        case .activate(let panel): activate(panel)
        case .minimise(let id): minimise(id)
        case .restore(let id): restore(id)
        case .lock(let id, let locked): lock(id, locked)
        case .bounds(let size): setBounds(size)
        case .load(let snapshot): load(snapshot)
        }
    }

    // The top frame that shows (not minimised).
    package var topFrame: LayoutFrame? { frames.last { !$0.minimised } }

    // The frame that holds the panel.
    package func frame(of panel: PanelID) -> LayoutFrame? {
        frames.first { $0.panels.contains(panel) }
    }

    // The frames as the screen shows them, with each rect inside the current bounds.
    package var shownFrames: [LayoutFrame] {
        frames.map { frame in
            var shown = frame
            shown.rect = Geometry.shownRect(frame.rect, bounds: bounds)
            return shown
        }
    }

    // The layout to save: the frames with no IDs, and the memory. The rects are the rects that
    // the user set, not the shown rects.
    package var snapshot: LayoutSnapshot {
        LayoutSnapshot(
            frames: frames.map {
                SavedFrame(
                    panels: $0.panels, active: $0.active, rect: $0.rect, minimised: $0.minimised,
                    locked: $0.locked)
            }, memory: memory)
    }

    private func index(of id: FrameID) -> Int? { frames.firstIndex { $0.id == id } }

    private func index(holding panel: PanelID) -> Int? {
        frames.firstIndex { $0.panels.contains(panel) }
    }

    private var lastIndex: Int { frames.count - 1 }

    private mutating func moveToTop(_ index: Int, as frame: LayoutFrame) {
        frames.remove(at: index)
        frames.append(frame)
    }

    private mutating func open(_ panel: PanelID) -> Bool {
        if let i = index(holding: panel) {
            var frame = frames[i]
            if frame.active == panel && !frame.minimised && i == lastIndex { return false }
            frame.active = panel
            frame.minimised = false
            moveToTop(i, as: frame)
            return true
        }
        let rect: LayoutRect
        if let saved = memory[panel], saved.isFinite {
            rect = Geometry.clampRect(saved, bounds: bounds)
        } else {
            let centre = Geometry.centreRect(panel.kind.defaultSize, bounds: bounds)
            rect = freeRect(from: Geometry.clampRect(centre, bounds: bounds))
        }
        frames.append(
            LayoutFrame(
                id: FrameID(number: nextFrame), panels: [panel], active: panel, rect: rect,
                minimised: false, locked: false))
        nextFrame += 1
        return true
    }

    // The first rect from the start rect, in steps down and right, that no frame that shows has.
    // The steps stop at the edge of the area.
    private func freeRect(from start: LayoutRect) -> LayoutRect {
        let shown = shownFrames.filter { !$0.minimised }.map(\.rect)
        var rect = start
        while shown.contains(rect) {
            let moved = LayoutRect(
                x: rect.x + Self.step, y: rect.y + Self.step, w: rect.w, h: rect.h)
            let next = Geometry.clampRect(moved, bounds: bounds)
            if next == rect { break }
            rect = next
        }
        return rect
    }

    private mutating func closeActive() -> Bool {
        guard let top = topFrame else { return false }
        return close(top.active)
    }

    private mutating func close(_ panel: PanelID) -> Bool {
        guard let i = index(holding: panel) else { return false }
        let frame = frames[i]
        memory[panel] = frame.rect
        if let rest = frame.without(panel) { frames[i] = rest } else { frames.remove(at: i) }
        return true
    }

    // Puts the other panel in the place of the panel. The frame keeps its ID, rect and z-order.
    // When the other panel has a frame already, only the panel closes.
    private mutating func replace(_ panel: PanelID, with other: PanelID) -> Bool {
        guard panel != other, let i = index(holding: panel) else { return false }
        if index(holding: other) != nil { return close(panel) }
        var frame = frames[i]
        frame.panels = frame.panels.map { $0 == panel ? other : $0 }
        if frame.active == panel { frame.active = other }
        memory[panel] = frames[i].rect
        frames[i] = frame
        return true
    }

    private mutating func focus(_ id: FrameID) -> Bool {
        guard let i = index(of: id), i != lastIndex else { return false }
        let frame = frames[i]
        moveToTop(i, as: frame)
        return true
    }

    private mutating func setRect(_ id: FrameID, _ rect: LayoutRect) -> Bool {
        guard let i = index(of: id), !frames[i].locked, !frames[i].minimised, rect.isFinite else {
            return false
        }
        let clamped = Geometry.clampRect(rect, bounds: bounds)
        if clamped == frames[i].rect { return false }
        frames[i].rect = clamped
        return true
    }

    private mutating func stack(_ id: FrameID, onto targetID: FrameID) -> Bool {
        guard id != targetID, let s = index(of: id), let t = index(of: targetID) else {
            return false
        }
        let source = frames[s]
        var target = frames[t]
        if source.minimised || target.minimised || source.locked { return false }
        target.active = source.active
        target.panels += source.panels
        // Keep the rect of each source panel. A tear-out gives the panel this size again.
        for panel in source.panels { memory[panel] = source.rect }
        frames.removeAll { $0.id == id || $0.id == targetID }
        frames.append(target)
        return true
    }

    private mutating func unstack(_ panel: PanelID, _ rect: LayoutRect) -> Bool {
        guard let i = index(holding: panel), frames[i].panels.count >= 2, !frames[i].locked,
            rect.isFinite, let rest = frames[i].without(panel)
        else { return false }
        memory[panel] = frames[i].rect
        frames[i] = rest
        frames.append(
            LayoutFrame(
                id: FrameID(number: nextFrame), panels: [panel], active: panel,
                rect: Geometry.clampRect(rect, bounds: bounds), minimised: false, locked: false))
        nextFrame += 1
        return true
    }

    private mutating func activate(_ panel: PanelID) -> Bool {
        guard let i = index(holding: panel), frames[i].active != panel else { return false }
        frames[i].active = panel
        return true
    }

    private mutating func minimise(_ id: FrameID) -> Bool {
        guard let i = index(of: id), !frames[i].minimised else { return false }
        frames[i].minimised = true
        return true
    }

    private mutating func restore(_ id: FrameID) -> Bool {
        guard let i = index(of: id) else { return false }
        if !frames[i].minimised && i == lastIndex { return false }
        var frame = frames[i]
        frame.minimised = false
        moveToTop(i, as: frame)
        return true
    }

    private mutating func lock(_ id: FrameID, _ locked: Bool) -> Bool {
        guard let i = index(of: id), frames[i].locked != locked else { return false }
        frames[i].locked = locked
        return true
    }

    // The bounds ignore a size that is not finite or that is below 1. The frame rects do not
    // change. A smaller area changes only the shown rects.
    private mutating func setBounds(_ size: LayoutSize) -> Bool {
        guard size.w.isFinite, size.h.isFinite, size.w >= 1, size.h >= 1, size != bounds else {
            return false
        }
        bounds = size
        return true
    }

    // Replaces the frames and the memory. A panel that an earlier frame has goes. A frame with
    // no panel or with a rect that is not finite goes, but its panels still count as seen. Each
    // frame keeps its rect as saved: the screen shows it inside the current bounds.
    private mutating func load(_ snapshot: LayoutSnapshot) -> Bool {
        var seen = Set<PanelID>()
        var loaded: [LayoutFrame] = []
        var number = nextFrame
        for item in snapshot.frames {
            var panels: [PanelID] = []
            for panel in item.panels where seen.insert(panel).inserted { panels.append(panel) }
            guard let first = panels.first, item.rect.isFinite else { continue }
            loaded.append(
                LayoutFrame(
                    id: FrameID(number: number), panels: panels,
                    active: panels.contains(item.active) ? item.active : first, rect: item.rect,
                    minimised: item.minimised, locked: item.locked))
            number += 1
        }
        frames = loaded
        memory = snapshot.memory
        nextFrame = number
        return true
    }
}
