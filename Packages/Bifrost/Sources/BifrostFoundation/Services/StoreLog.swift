import OSLog

// An event of a store file for the log. what is the fixed name of the data, for example "the UI
// state". Each path and each error is private in the log.
package enum StoreEvent: Sendable, Equatable {
    // The read of the file failed (not a missing file). The store uses its defaults and does not
    // save, so it never writes over a file that it did not read.
    case readFailed(file: String, what: String, error: FileError)
    // The file does not parse at all. Before its first save, the store kept a copy
    // (docs/behaviour/stores.md, Loading a file).
    case keptUnreadableCopy(file: String, copy: String)
    // The copy before the first save failed. The store does not save, so the old file stays.
    case copyFailed(file: String, copy: String, what: String, error: FileError)
    // The compact JSON of the value is larger than the limit, so the store did not save it.
    case tooLarge(file: String, what: String, limit: Int)
    // A write failed. The next save tries again.
    case saveFailed(what: String, error: FileError)
    // These keys of the file had values that the store cannot use, so they got their defaults
    // (docs/behaviour/stores.md, settings.json). The keys are known field names.
    case defaulted(file: String, keys: [String])
}

// Where a store sends its events. The app uses SystemStoreLog. A test records the events.
package protocol StoreLog: Sendable {
    func record(_ event: StoreEvent)
}

// The log of the stores in the unified log of macOS.
package struct SystemStoreLog: StoreLog {
    private static let logger = Logger(bifrost: "stores")

    package init() {}

    package func record(_ event: StoreEvent) {
        let log = Self.logger
        switch event {
        case .readFailed(let file, let what, let error):
            log.error(
                """
                Bifrost cannot read \(file, privacy: .private), so it does not save \
                \(what, privacy: .public). \(error.message, privacy: .private)
                """)
        case .keptUnreadableCopy(let file, let copy):
            log.notice(
                """
                Bifrost cannot parse \(file, privacy: .private), so it keeps a copy at \
                \(copy, privacy: .private).
                """)
        case .copyFailed(let file, let copy, let what, let error):
            log.error(
                """
                Bifrost cannot copy \(file, privacy: .private) to \(copy, privacy: .private), so \
                it does not save \(what, privacy: .public). \(error.message, privacy: .private)
                """)
        case .tooLarge(let file, let what, let limit):
            log.error(
                """
                Bifrost cannot save \(what, privacy: .public) to \(file, privacy: .private). It \
                is larger than \(limit, privacy: .public) bytes.
                """)
        case .saveFailed(let what, let error):
            log.error(
                "Bifrost cannot save \(what, privacy: .public). \(error.message, privacy: .private)"
            )
        case .defaulted(let file, let keys):
            log.notice(
                """
                Bifrost cannot use these values in \(file, privacy: .private) and uses their \
                defaults: \(keys.joined(separator: ", "), privacy: .public).
                """)
        }
    }
}
