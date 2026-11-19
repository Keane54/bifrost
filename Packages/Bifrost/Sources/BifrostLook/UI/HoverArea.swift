// The hover area of a view: one tracking area for the enter and the exit of the pointer, for
// the life of the view. The option inVisibleRect keeps the area on the visible rect of the view,
// so a move or a resize needs no new area. A view that makes a new area at each call of
// updateTrackingAreas does main-thread work at each step of a drag (phase-3-performance.md,
// Step 4).
import AppKit

extension NSView {
    // Add the hover area. Call it one time, in the init of the view. active tells when the area
    // acts: for example only in the key window, or always.
    package func addHoverArea(_ active: NSTrackingArea.Options) {
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, active, .inVisibleRect],
                owner: self, userInfo: nil))
    }
}
