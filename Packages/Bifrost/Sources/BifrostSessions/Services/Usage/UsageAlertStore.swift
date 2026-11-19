import BifrostFoundation
import Foundation

// The store of usage-alerts.json in the support folder: the notified periods of the usage
// notification (docs/behaviour/usage.md, "The usage notification"). The file keeps them across
// restarts, so a restart, for example after an update, does not notify again for the same period.
//
// The store holds the periods on the main actor. A set changes them at once, so the monitor reads
// the new periods at its next check, also while the write runs. The one save task of the file
// (SaveQueue) writes the newest periods off the main actor, one write at a time.
@MainActor
package final class UsageAlertStore {
    // The name of the data in the log.
    private static let what = "the usage alerts"

    // The periods that the store read at the open, with each later set.
    package private(set) var periods: NotifiedPeriods
    // nil after a read error. Then the store does not save.
    private let queue: SaveQueue<NotifiedPeriods>?

    private init(periods: NotifiedPeriods, saver: FileSaver?) {
        self.periods = periods
        queue = saver.map(SaveQueue.init)
    }

    // Open usage-alerts.json. The read and the decode run off the main actor (FileSaver).
    // - A missing file, JSON that is not an object or a file that does not parse gives no
    //   period, and a save works. A file that does not parse is copied to <file>.unreadable one
    //   time, before the first save over it (docs/behaviour/stores.md, Loading a file).
    // - now is the time for the check of each kept value (UsageAlertRules.parse).
    // - If the file cannot be read, the store uses no period and does not save. Then it cannot
    //   write over a file that it did not read.
    // A test gives its own log, and the steps of the safe write to hold or count a write.
    package static func open(
        file: URL, now: Date, log: any StoreLog = SystemStoreLog(), steps: WriteSteps = .system
    ) async -> UsageAlertStore {
        let opened = await FileSaver.open(
            file, default: JSONValue.null, what: what, steps: steps, log: log)
        let periods = UsageAlertRules.parse(opened.value, now: now.millisecondsSince1970)
        return UsageAlertStore(periods: periods, saver: opened.saver)
    }

    // Set the periods at once and save them. The task ends after the write of the newest
    // periods. A failed write keeps the new periods and logs the error. nil when the store does
    // not save.
    @discardableResult
    package func set(_ next: NotifiedPeriods) -> Task<Void, Never>? {
        periods = next
        return queue?.save(next)
    }
}
