import BifrostFoundation
import Foundation

// The state of What's new, release-notes.json in the support folder: the version of the last
// What's new, or of the first start. The file keeps the name and the form of the file of the
// Electron app.
package struct ReleaseNotesState: Sendable, Equatable {
    package var lastSeenVersion: String?
    // The top-level fields of the file that this app does not know. A save writes them again.
    package var unknown = UnknownFields()

    package init(lastSeenVersion: String? = nil) {
        self.lastSeenVersion = lastSeenVersion
    }
}

extension ReleaseNotesState: Codable {
    private enum Key: String, CodingKey {
        case lastSeenVersion
    }

    // A value that is not a text gives no stored version.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        unknown = try UnknownFields(from: decoder, known: Key.self)
        lastSeenVersion = try? container.decode(String.self, forKey: .lastSeenVersion)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(lastSeenVersion, forKey: .lastSeenVersion)
        try unknown.encode(to: encoder)
    }
}

// The store of release-notes.json. It holds the state on the main actor, and the one save task of
// the file writes it off the main actor. A missing or damaged file gives no stored version. A file
// that cannot be read gives no stored version, and the store does not save, so it cannot write
// over a file that it did not read (FileSaver).
@MainActor
package final class ReleaseNotesStore {
    package private(set) var state: ReleaseNotesState
    // nil after a read error. Then the store does not save.
    private let queue: SaveQueue<ReleaseNotesState>?
    // True after the first call of takeWhatsNew.
    private var taken = false

    private init(_ opened: FileSaver.Opened<ReleaseNotesState>) {
        state = opened.value
        queue = opened.saver.map(SaveQueue.init)
    }

    package static func open(
        file: URL, log: any StoreLog = SystemStoreLog(), steps: WriteSteps = .system
    ) async -> ReleaseNotesStore {
        let opened = await FileSaver.open(
            file, default: ReleaseNotesState(), what: "the state of What's new", steps: steps,
            log: log)
        return ReleaseNotesStore(opened)
    }

    // The What's new of this start, from the rule (WhatsNewRule). Only the first call of the
    // process decides: each later call gives nil. The store writes the current version first and
    // waits for the write. So the dialog opens once for a version, also when its load fails. A
    // failed write keeps the new state in memory and logs the error.
    package func takeWhatsNew(current: String, setupDone: Bool) async -> WhatsNewRange? {
        guard !taken else { return nil }
        taken = true
        let decision = WhatsNewRule.decide(
            current: current, lastSeen: state.lastSeenVersion, setupDone: setupDone)
        if decision.store {
            state.lastSeenVersion = current
            await queue?.save(state).value
        }
        return decision.open
    }
}
