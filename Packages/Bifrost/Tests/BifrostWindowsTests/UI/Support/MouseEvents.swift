import AppKit
import BifrostWindows

// The mouse events of the canvas tests.
//
// NSWindow.sendEvent drops each mouse event of a window that was never ordered in (a probe: no
// mouse down, drag or up came to the view, also with acceptsFirstMouse, a key window and the
// accessory policy). The tests never order a window front. So this driver
// does the dispatch of NSWindow for a mouse event: the hit test of the content view, the gesture
// recognizers of the hit view and its superviews, then the hit view. The view of the press gets
// the drag and the up events, as AppKit gives them to the view of the mouse down.
//
// For a press on an NSControl, the driver gives the event only to the gesture recognizers: a
// control runs its own event loop for a press, and that loop waits for real events. The tests then
// click the control with performClick(_:).
@MainActor
final class MouseDriver {
    let window: NSWindow
    // The view of the last mouse down.
    private(set) var target: NSView?

    init(window: NSWindow) {
        self.window = window
    }

    func event(_ type: NSEvent.EventType, at windowPoint: NSPoint, clicks: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: windowPoint, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
    }

    // The view that a press at the point gets.
    func hitView(at point: CGPoint, in view: NSView) -> NSView? {
        let windowPoint = view.convert(point, to: nil)
        guard let content = window.contentView else { return nil }
        let inSuper = content.superview.map { $0.convert(windowPoint, from: nil) } ?? windowPoint
        return content.hitTest(inSuper)
    }

    // A press at a point in the coordinates of the view. The result is the view that got it.
    @discardableResult
    func down(at point: CGPoint, in view: NSView, type: NSEvent.EventType = .leftMouseDown)
        -> NSView?
    {
        let windowPoint = view.convert(point, to: nil)
        guard let hit = hitView(at: point, in: view), let event = event(type, at: windowPoint)
        else { return nil }
        var ancestor: NSView? = hit
        while let current = ancestor {
            for recognizer in current.gestureRecognizers where recognizer.isEnabled {
                switch type {
                case .rightMouseDown: recognizer.rightMouseDown(with: event)
                case .otherMouseDown: recognizer.otherMouseDown(with: event)
                default: recognizer.mouseDown(with: event)
                }
            }
            ancestor = current.superview
        }
        if hit is NSControl {
            target = nil
            return hit
        }
        switch type {
        case .rightMouseDown: hit.rightMouseDown(with: event)
        case .otherMouseDown: hit.otherMouseDown(with: event)
        default: hit.mouseDown(with: event)
        }
        target = hit
        return hit
    }

    // A move with the button down, to a point in the coordinates of the view.
    func drag(to point: CGPoint, in view: NSView) {
        guard let target, let event = event(.leftMouseDragged, at: view.convert(point, to: nil))
        else { return }
        target.mouseDragged(with: event)
    }

    // The release of the button at a point in the coordinates of the view.
    func up(at point: CGPoint, in view: NSView) {
        guard let target, let event = event(.leftMouseUp, at: view.convert(point, to: nil))
        else { return }
        self.target = nil
        target.mouseUp(with: event)
    }

    // A press, the drag steps and the release.
    func drag(from start: CGPoint, through points: [CGPoint], in view: NSView) {
        down(at: start, in: view)
        for point in points { drag(to: point, in: view) }
        if let last = points.last { up(at: last, in: view) }
    }
}

extension NSTableView {
    // A mouse event on the table at a point in its coordinates. NSWindow drops the mouse events
    // of a window that was never ordered in, and a table is a control, so the test gives each
    // event to the table itself.
    func send(
        _ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1,
        flags: NSEvent.ModifierFlags = []
    ) {
        guard
            let event = NSEvent.mouseEvent(
                with: type, location: convert(point, to: nil), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                clickCount: clicks, pressure: 1)
        else { return }
        switch type {
        case .leftMouseDown: mouseDown(with: event)
        case .leftMouseDragged: mouseDragged(with: event)
        case .leftMouseUp: mouseUp(with: event)
        case .rightMouseDown: rightMouseDown(with: event)
        default: break
        }
    }

    // A click, then the second click of a double-click, at a point in the coordinates of the
    // table.
    func doubleClick(at point: NSPoint) {
        send(.leftMouseDown, at: point)
        send(.leftMouseUp, at: point)
        send(.leftMouseDown, at: point, clicks: 2)
        send(.leftMouseUp, at: point, clicks: 2)
    }
}
