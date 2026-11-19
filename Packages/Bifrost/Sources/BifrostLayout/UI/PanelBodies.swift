import AppKit

// The bodies and the titles of the panels. The canvas asks for the body of a panel when a frame
// shows it as the active panel. The body view stays the same view while the panel is in a frame:
// a stack, a tab change, a minimise and a tear-out move the view, but do not make it again. When
// the panel leaves the last frame (a close, or a load of a layout without it), the canvas calls
// releaseBody. A later open makes a new body.
@MainActor
public protocol PanelBodies: AnyObject {
    // The body view of the panel. The first call makes it. The next calls give the same view
    // until releaseBody.
    func body(for panel: PanelID) -> NSView
    // The title of the panel for its tab, its frame and its side bar button.
    func title(for panel: PanelID) -> String
    // The dim text after the title in the tab and the frame, for example the name of the tab set
    // of an Overview, or nil. The default is nil.
    func titleSuffix(for panel: PanelID) -> String?
    // The panel is in no frame now. The provider can stop the work of the body and drop it.
    func releaseBody(for panel: PanelID)
}

extension PanelBodies {
    public func titleSuffix(for panel: PanelID) -> String? { nil }
}

// One part of the panel bodies, for example the chat terminals. The shell joins the parts into
// the PanelBodies of the canvas. A part gives nil for a panel that it does not make.
@MainActor
public protocol PanelBodiesPart: AnyObject {
    // The body view of the panel. The next calls give the same view until releaseBody.
    func body(for panel: PanelID) -> NSView?
    // The dim text after the title of a panel that the part makes, or nil. The default is nil.
    func titleSuffix(for panel: PanelID) -> String?
    // The panel is in no frame now.
    func releaseBody(for panel: PanelID)
}

extension PanelBodiesPart {
    public func titleSuffix(for panel: PanelID) -> String? { nil }
}
