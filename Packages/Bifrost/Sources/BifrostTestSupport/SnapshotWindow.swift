import AppKit

// A window of the snapshot tests: it reports the scale of the snapshots (Snapshot.scale) as its
// backing scale. AppKit, SwiftUI and the icons draw at the backing scale of the window, which
// macOS takes from the screen: 2 on a Retina Mac, 1 on the virtual screen of a CI runner. At 1,
// the image at scale 2 scaled each glyph and icon up, and the snapshots failed on the runner.
// The snapshot check refuses a view in a window that is not SnapshotScaled.
package protocol SnapshotScaled: NSWindow {}

// A plain window of a snapshot test. A test of a BifrostWindow uses a subclass of it in its own
// test target with the same backing scale.
package class SnapshotWindow: NSWindow, SnapshotScaled {
    override package var backingScaleFactor: CGFloat { CGFloat(Snapshot.scale) }
}
