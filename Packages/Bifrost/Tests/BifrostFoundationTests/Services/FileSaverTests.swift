import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation

// The open of a store file and its first save. The store tests of each module cover the rest.

// A stored value whose decode throws NoJSONForm for the key "bad", and a type error for the key
// "wrong".
private struct Probe: Codable, Sendable, Equatable {
    var number = 0

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        if container.contains(DynamicKey(stringValue: "bad")) { throw NoJSONForm() }
        number = try container.decode(Int.self, forKey: DynamicKey(stringValue: "number"))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(number, forKey: DynamicKey(stringValue: "number"))
    }
}

@Suite("the open of a store file", .timeLimit(.minutes(1)))
struct FileSaverTests {
    // NoJSONForm is the one sign of a value with no JSON form: the file counts as a file that
    // does not parse, whatever error the JSON decoder gives. The first save keeps a copy.
    @Test func aDecodeThatThrowsNoJSONFormKeepsACopyBeforeTheFirstSave() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "probe.json")
        let stored = #"{"bad":true,"number":1}"#
        try Data(stored.utf8).write(to: file)
        let log = Recorder<StoreEvent>()
        let opened = await FileSaver.open(file, default: Probe(), what: "the probe", log: log)
        #expect(opened.value == Probe())
        #expect(await opened.saver?.save(Probe()) == .saved)
        let copy = dir.appending(path: "probe.json.unreadable")
        #expect(try String(contentsOf: copy, encoding: .utf8) == stored)
        #expect(log.values == [.keptUnreadableCopy(file: path(file), copy: path(copy))])
    }

    // A value that the type refuses is JSON: the default value, and the save keeps no copy.
    @Test func aValueThatTheTypeRefusesGivesTheDefaultAndNoCopy() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "probe.json")
        try Data(#"{"number":"one"}"#.utf8).write(to: file)
        let log = Recorder<StoreEvent>()
        let opened = await FileSaver.open(file, default: Probe(), what: "the probe", log: log)
        #expect(opened.value == Probe())
        #expect(await opened.saver?.save(Probe()) == .saved)
        #expect(try names(dir) == ["probe.json"])
        #expect(log.values.isEmpty)
    }
}

// The one save task of a store file: the generation of each save and the result of its write.
@MainActor
@Suite("the save queue of a store file", .timeLimit(.minutes(1)))
struct SaveQueueTests {
    // Each save gets the next generation, and saved(_:) gives the result of the first write whose
    // generation is at least that generation. The value of the open counts as saved.
    @Test func savedGivesTheResultOfTheWriteOfEachGeneration() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "probe.json")
        let opened = await FileSaver.open(file, default: Probe(), what: "the probe")
        let queue = SaveQueue<Probe>(try #require(opened.saver))
        #expect(queue.generation == 0)
        #expect(await queue.saved(0))
        var probe = Probe()
        probe.number = 1
        queue.save(probe)
        probe.number = 2
        queue.save(probe)
        #expect(queue.generation == 2)
        #expect(await queue.saved(1))
        #expect(await queue.saved(2))
        #expect(!queue.lastWriteFailed)
        #expect(try readSaved(file) == ["number": 2])
    }

    // A failed write gives false, logs one line, and stays the last failure until the next save.
    @Test func aFailedWriteGivesFalse() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = folder.url.appending(path: "probe.json")
        let failing = WriteSteps(
            sync: { _ in throw POSIXError(.EIO) }, rename: WriteSteps.system.rename)
        let log = Recorder<StoreEvent>()
        let opened = await FileSaver.open(
            file, default: Probe(), what: "the probe", steps: failing, log: log)
        let queue = SaveQueue<Probe>(try #require(opened.saver))
        queue.save(Probe())
        #expect(await !queue.saved(queue.generation))
        #expect(queue.lastWriteFailed)
        #expect(log.values.count == 1)
        #expect(!FileManager.default.fileExists(atPath: path(file)))
    }
}
