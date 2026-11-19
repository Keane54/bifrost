import BifrostFoundation
import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostWindows

// The state of What's new, release-notes.json (docs/behaviour/updates.md, "What's new").
@MainActor
@Suite("release notes store", .timeLimit(.minutes(1)))
struct ReleaseNotesStoreTests {
    private func stored(_ file: URL) throws -> String? {
        let data = try Data(contentsOf: file)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["lastSeenVersion"] as? String
    }

    @Test func aMissingFileGivesNoStoredVersion() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = await ReleaseNotesStore.open(
            file: folder.url.appending(path: "release-notes.json"), log: Recorder<StoreEvent>())
        #expect(store.state == ReleaseNotesState())
    }

    @Test func aFileOfTheElectronAppKeepsItsVersionAndItsOtherFields() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "release-notes.json")
        try Data(#"{"lastSeenVersion":"1.1.0","later":[1,2]}"#.utf8).write(to: file)
        let store = await ReleaseNotesStore.open(file: file, log: Recorder<StoreEvent>())
        #expect(store.state.lastSeenVersion == "1.1.0")
        _ = await store.takeWhatsNew(current: "1.2.0", setupDone: true)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"lastSeenVersion\" : \"1.2.0\""))
        #expect(text.contains("\"later\""))
    }

    @Test func aValueThatIsNotATextGivesNoStoredVersion() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "release-notes.json")
        try Data(#"{"lastSeenVersion":7}"#.utf8).write(to: file)
        let store = await ReleaseNotesStore.open(file: file, log: Recorder<StoreEvent>())
        #expect(store.state.lastSeenVersion == nil)
    }

    @Test func theVersionIsStoredBeforeTheDialogOpens() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "release-notes.json")
        let gate = WriteGate()
        defer { gate.openAll() }
        let store = await ReleaseNotesStore.open(
            file: file, log: Recorder<StoreEvent>(), steps: gate.steps)
        let range = ResultBox()
        let task = Task {
            let decided = await store.takeWhatsNew(current: "1.3.0", setupDone: true)
            range.set(decided)
        }
        await gate.waitUntilWriting()
        // The write waits at the gate, so the answer has not come, and the file has no version.
        #expect(range.value == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        gate.open()
        await task.value
        #expect(range.value == WhatsNewRange(since: nil, version: version("1.3.0")))
        #expect(try stored(file) == "1.3.0")
    }

    @Test func aFreshInstallStoresTheVersionAndOpensNothing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "release-notes.json")
        let store = await ReleaseNotesStore.open(file: file, log: Recorder<StoreEvent>())
        #expect(await store.takeWhatsNew(current: "1.0.0", setupDone: false) == nil)
        #expect(try stored(file) == "1.0.0")
    }

    @Test func onlyTheFirstCallOfTheProcessDecides() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "release-notes.json")
        try Data(#"{"lastSeenVersion":"1.0.0"}"#.utf8).write(to: file)
        let store = await ReleaseNotesStore.open(file: file, log: Recorder<StoreEvent>())
        #expect(await store.takeWhatsNew(current: "1.1.0", setupDone: true) != nil)
        #expect(await store.takeWhatsNew(current: "1.1.0", setupDone: true) == nil)
        #expect(await store.takeWhatsNew(current: "1.2.0", setupDone: true) == nil)
        #expect(try stored(file) == "1.1.0")
    }

    @Test func theSameVersionWritesNothing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "release-notes.json")
        let original = Data(#"{"lastSeenVersion":"1.1.0"}"#.utf8)
        try original.write(to: file)
        let store = await ReleaseNotesStore.open(file: file, log: Recorder<StoreEvent>())
        #expect(await store.takeWhatsNew(current: "1.1.0", setupDone: true) == nil)
        #expect(try Data(contentsOf: file) == original)
    }

    // A file that cannot be read gives no stored version, and the store does not write over it.
    @Test func aFileThatCannotBeReadIsNeverWrittenOver() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        // A folder at the path of the file cannot be read as a file.
        let file = folder.url.appending(path: "release-notes.json", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let store = await ReleaseNotesStore.open(file: file, log: Recorder<StoreEvent>())
        let range = await store.takeWhatsNew(current: "1.0.0", setupDone: true)
        // The rule still decides, and the folder stays a folder.
        #expect(range == WhatsNewRange(since: nil, version: version("1.0.0")))
        var isFolder: ObjCBool = false
        let path = file.path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isFolder))
        #expect(isFolder.boolValue)
    }
}

// The answer of a task, for a check while the task waits.
private final class ResultBox: Sendable {
    private let stored = Mutex<WhatsNewRange?>(nil)

    var value: WhatsNewRange? { stored.withLock { $0 } }
    func set(_ value: WhatsNewRange?) { stored.withLock { $0 = value } }
}
