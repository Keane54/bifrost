import BifrostFoundation
import BifrostLayout
import Foundation

// The store of window-state.json. The store holds the state on the main actor. Each update
// saves the state. The one save task of the file writes the newest state off the main actor, one
// write at a time. The shell waits WindowPlacement.saveDelay after the last move or resize before
// it updates the bounds.
@MainActor
public final class WindowStateStore {
    // The state that the store read at the open, with each later update.
    public private(set) var state: WindowState
    // nil after a read error. Then the store does not save.
    private let queue: SaveQueue<WindowState>?

    private init(_ opened: FileSaver.Opened<WindowState>) {
        state = opened.value
        queue = opened.saver.map(SaveQueue.init)
    }

    // Open window-state.json. The read and the decode run off the main actor (FileSaver). A
    // missing or damaged file gives the defaults. A file that does not parse at all is copied to
    // <file>.unreadable one time, before the first save over it (docs/behaviour/stores.md,
    // Loading a file). If the file cannot be read, the store does not write over it. A test
    // gives its own log, and the steps of the safe write to hold a write.
    package static func open(
        file: URL, log: any StoreLog = SystemStoreLog(), steps: WriteSteps = .system
    ) async -> WindowStateStore {
        let opened = await FileSaver.open(
            file, default: WindowState(), what: "the window state", steps: steps, log: log)
        return WindowStateStore(opened)
    }

    // Change a part of the state and write the file. A part that is nil keeps its value. The
    // call waits until the write of the newest state ends. A failed write keeps the new state
    // and logs the error.
    public func update(mode: DisplayMode? = nil, bounds: WindowBounds? = nil) async {
        if let mode { state.mode = mode }
        if let bounds { state.bounds = bounds }
        await queue?.save(state).value
    }
}
