import BifrostFoundation
import Foundation

// The store file of the registry, registry.json.
package enum StoreFile {
    // The name of the data of the file in the logs (StoreEvent).
    package static let what = "the registry store"

    // Open the store for the registry service, on the current thread (FileSaver). If the file
    // cannot be read, the service uses an empty store and does not save. Then it cannot write
    // over a file that it did not read. A file that does not parse at all gives an empty store,
    // and the saver keeps a copy of the file before its first save (docs/behaviour/stores.md,
    // Loading a file). The store keeps the unknown fields of the file, so each save writes them
    // again.
    package static func open(
        path: String, log: any StoreLog = SystemStoreLog()
    ) -> (store: RegistryStore, saver: StoreSaver) {
        let opened = FileSaver.openNow(
            URL(fileURLWithPath: path, isDirectory: false), default: RegistryStore(),
            what: what, log: log)
        return (opened.value, StoreSaver(opened.saver))
    }
}

// The save function of an opened store: the shared FileSaver with its rules. With no file (a
// read error, or a test), a save does nothing.
package struct StoreSaver: Sendable {
    private let saver: FileSaver?

    package init(_ saver: FileSaver?) {
        self.saver = saver
    }

    // A failed write throws a RegistryFailure with the text of the error. The registry service
    // runs one save at a time on the blocking executor, so the save runs at once on the current
    // thread.
    package func save(_ store: RegistryStore) throws(RegistryFailure) {
        guard let saver else { return }
        if case .failed(let failure) = saver.write(store) {
            throw RegistryFailure(failure.message)
        }
    }
}
