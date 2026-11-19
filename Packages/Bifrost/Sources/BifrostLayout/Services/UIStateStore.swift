import BifrostFoundation
import Foundation
import Observation

// The store of ui-state.json and its save timer. The store holds the state on the main actor. A
// change starts the save timer, so the save comes saveDelay after the last change. A drag holds
// the saves. The one save task of the file writes off the main actor, one write at a time.
//
// The state is observable: a reader of state, for example a view of the saved layouts or of an
// Overview config, gets each change from each writer.
@MainActor
@Observable
public final class UIStateStore {
    // The time from the last change to the save (docs/behaviour/stores.md).
    static let saveDelay = Duration.milliseconds(500)

    public private(set) var state: UIState
    // nil after a read error. Then the store does not save.
    @ObservationIgnored private let queue: SaveQueue<UIState>?
    // True when the state changed after the last save.
    @ObservationIgnored private var dirty = false
    // True during a drag.
    @ObservationIgnored private var held = false
    // The save timer.
    @ObservationIgnored private let timer: TimerSlot

    private init(_ opened: FileSaver.Opened<UIState>, clock: any Clock<Duration>) {
        state = opened.value
        queue = opened.saver.map(SaveQueue.init)
        timer = TimerSlot(clock: clock)
    }

    // Open ui-state.json. The read and the decode run off the main actor (FileSaver).
    // - A missing file, bad JSON or a value that the decode refuses gives the empty state, and a
    //   save works.
    // - A file that does not parse at all is copied to <file>.unreadable one time, before the
    //   first save over it (docs/behaviour/stores.md, Loading a file).
    // - If the file cannot be read, the store uses the empty state and does not save. Then it
    //   cannot write over a file that it did not read.
    // A test gives its own log, and the steps of the safe write to hold a write.
    package static func open(
        file: URL, clock: any Clock<Duration>, log: any StoreLog = SystemStoreLog(),
        steps: WriteSteps = .system
    ) async -> UIStateStore {
        let opened = await FileSaver.open(
            file, default: UIState(), what: "the UI state", maxBytes: UIState.maxBytes,
            steps: steps, log: log)
        return UIStateStore(opened, clock: clock)
    }

    // Change the state. The save timer starts again, so the save comes saveDelay after the last
    // change. A change that changes nothing does nothing.
    package func change(_ make: (inout UIState) -> Void) {
        var next = state
        make(&next)
        guard next != state else { return }
        state = next
        dirty = true
        scheduleSave()
    }

    // Hold the saves: true during a drag. The hold stops the timer. Its end starts the timer
    // again when a change waits.
    package func holdSaves(_ hold: Bool) {
        held = hold
        scheduleSave()
    }

    // Save the state now if it changed after the last save: at a window close and at quit. A
    // hold does not stop this save. The call waits until the write of the newest state ends.
    // With no change, it waits for the save task, because a save of the timer can still write.
    // So the quit can stop the app after this call.
    public func saveNow() async {
        await (startSave() ?? queue?.task)?.value
    }

    // Start the save of the state now if it changed after the last save. The save task writes
    // the state after the write that runs, and it ends after the write of the newest state.
    func startSave() -> Task<Void, Never>? {
        timer.stop()
        guard let queue, dirty else { return nil }
        dirty = false
        return queue.save(state)
    }

    // The task of the save timer, or nil when no timer waits.
    var timerTask: Task<Void, Never>? { timer.task }

    private func scheduleSave() {
        timer.stop()
        guard queue != nil, dirty, !held else { return }
        timer.start(after: Self.saveDelay) { await self.saveNow() }
    }
}
