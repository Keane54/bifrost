import AppKit
import BifrostTestSupport

@testable import BifrostWindows

// A BifrostWindow of the tests with the backing scale of the snapshots (SnapshotWindow), so the
// views in it draw at scale 2 also on the 1x screen of a CI runner.
class SnapshotBifrostWindow: BifrostWindow, SnapshotScaled {
    override var backingScaleFactor: CGFloat { CGFloat(Snapshot.scale) }
}
