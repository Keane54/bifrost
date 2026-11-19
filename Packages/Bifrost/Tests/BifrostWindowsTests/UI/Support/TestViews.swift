// The views of the focus zones of the key scenarios. Each view logs the key downs that it gets,
// and does nothing else with them. Only the rows and the control give Esc to the next responder,
// as the Overview rows and a button of Bifrost do, so the Esc rule can act at the end of the
// responder chain. The marks are the FocusMark identifiers of the app.
import AppKit

@testable import BifrostKeyboard
@testable import BifrostWindows

// The name of the key of an NSEvent in the logs of the scenario file: the name of a named key (a
// space for the space bar), else the key as the filter reads it.
@MainActor
func keyName(_ event: NSEvent) -> String {
    switch KeyEvent(event, isComposing: false)?.key {
    case .named(.space): " "
    case .named(let name): name.rawValue
    case .text(let text): text
    case .dead: "Dead"
    case .modifier(let modifier): "\(modifier)"
    case nil: ""
    }
}

// Log a key down of a view. A view that passes Esc gives it to the next responder, unless the
// state says that a handler (a popover or a drag) takes Esc.
@MainActor
private func viewKeyDown(
    _ view: NSResponder, _ event: NSEvent, zone: String, state: GateState, passesEscape: Bool
) {
    state.record("view:\(zone):\(keyName(event))")
    if passesEscape && event.keyCode == 53 && !state.escTaker {
        view.nextResponder?.keyDown(with: event)
    }
}

final class LoggingTextView: NSTextView {
    var zone = "text"
    weak var gateState: GateState?

    override func keyDown(with event: NSEvent) {
        guard let state = gateState else { return }
        viewKeyDown(self, event, zone: zone, state: state, passesEscape: false)
    }

    override func keyUp(with event: NSEvent) {}
}

final class LoggingButton: NSButton {
    weak var gateState: GateState?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let state = gateState else { return }
        viewKeyDown(self, event, zone: "control", state: state, passesEscape: true)
    }

    override func keyUp(with event: NSEvent) {}
}

// A plain view: a dialog (modal), the key recorder (modal) or the rows of an Overview (other).
class LoggingView: NSView {
    var zone = "other"
    var passesEscape = false
    weak var gateState: GateState?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let state = gateState else { return }
        viewKeyDown(self, event, zone: zone, state: state, passesEscape: passesEscape)
    }

    override func keyUp(with event: NSEvent) {}
}

// The rows of an Overview: three rows S1 to S3, from the top. A click goes to the hold click of
// the filter first, as the rows of the Overview do. A plain click selects the row.
final class RowsView: LoggingView {
    weak var filter: WindowKeyFilter?
    weak var selection: SelectionModel?
    let rows = ["S1", "S2", "S3"]

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func row(at point: NSPoint) -> String? {
        let height = bounds.height / CGFloat(rows.count)
        let index = rows.count - 1 - Int(point.y / height)
        return rows.indices.contains(index) ? rows[index] : nil
    }

    // The point of the middle of a row, in the coordinates of the window.
    func windowPoint(of row: String) -> NSPoint? {
        guard let index = rows.firstIndex(of: row) else { return nil }
        let height = bounds.height / CGFloat(rows.count)
        let local = NSPoint(x: bounds.midX, y: bounds.height - height * (CGFloat(index) + 0.5))
        return convert(local, to: nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard let row = row(at: convert(event.locationInWindow, from: nil)) else { return }
        filter?.rowPress(row)
    }

    override func mouseUp(with event: NSEvent) {
        guard let row = row(at: convert(event.locationInWindow, from: nil)) else { return }
        if filter?.rowClick(row) == true { return }
        selection?.selectedId = row
        gateState?.record("click:\(row)")
    }
}

// A window that counts the calls of cancelOperation(_:): the Esc key that gets to AppKit.
final class RecordingWindow: BifrostWindow {
    private(set) var cancelOperations = 0

    override func cancelOperation(_ sender: Any?) {
        cancelOperations += 1
        super.cancelOperation(sender)
    }
}
