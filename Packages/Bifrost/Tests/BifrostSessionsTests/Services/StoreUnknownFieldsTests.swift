import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation
@testable import BifrostSessions

// The unknown top-level fields of registry.json. A registry.json from a newer app can have fields
// that this app does not know. The store keeps them, and each save writes them again.

private func fields(_ file: String) throws -> [String: JSONValue] {
    let value = try JSONDecoder().decode(
        JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
    guard case .object(let fields) = value else { return [:] }
    return fields
}

@Suite("registry.json unknown fields", .timeLimit(.minutes(1)))
struct StoreUnknownFieldsTests {
    @Test func unknownTopLevelKeysOfRegistryJsonSurviveASave() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        let future: JSONValue = ["deep": [1, ["x": .null]], "on": true]
        try String(
            #"{"names":{"s1":"alpha"},"started":["s1"],"futureField":{"deep":[1,{"x":null}],"#
                + #""on":true},"zoom":2}"#
        ).write(toFile: file, atomically: false, encoding: .utf8)
        let log = Recorder<StoreEvent>()
        let opened = StoreFile.open(path: file, log: log)
        var loaded = RegistryStore(names: ["s1": "alpha"], started: ["s1"])
        loaded.unknown = UnknownFields(["futureField": future, "zoom": 2])
        #expect(opened.store == loaded)
        // The registry keeps the unknown fields of its store, so each later store has them.
        var registry = SessionRegistry(store: opened.store, escalation: .seconds(600))
        registry.forget("s1")
        #expect(registry.store().unknown == loaded.unknown)
        try opened.saver.save(registry.store())
        var next = RegistryStore(names: ["s3": "gamma"], started: ["s3"])
        next.unknown = loaded.unknown
        try opened.saver.save(next)
        let saved = try fields(file)
        #expect(saved["futureField"] == future)
        #expect(saved["zoom"] == 2)
        #expect(saved["names"] == ["s3": "gamma"])
        #expect(saved["started"] == ["s3"])
        #expect(StoreFile.open(path: file, log: log).store == next)
        #expect(log.values.isEmpty)
    }

    // The unknown fields hold only the keys that the store does not know. So a key of the store
    // that the new store leaves out (an empty prSessions) does not come back from the load.
    @Test func aKnownKeyOfTheLoadDoesNotComeBack() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        try String(#"{"names":{},"prSessions":["s1"],"prNames":["n-review"],"other":1}"#)
            .write(toFile: file, atomically: false, encoding: .utf8)
        let opened = StoreFile.open(path: file, log: Recorder<StoreEvent>())
        #expect(opened.store.prSessions == ["s1"])
        #expect(opened.store.unknown.values == ["other": 1])
        var empty = RegistryStore()
        empty.unknown = opened.store.unknown
        try opened.saver.save(empty)
        let saved = try fields(file)
        #expect(saved["prSessions"] == nil)
        #expect(saved["prNames"] == nil)
        #expect(saved["other"] == 1)
    }
}

private func names(_ dir: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
}

private func text(_ file: String) throws -> String {
    try String(contentsOfFile: file, encoding: .utf8)
}

// A file that does not parse at all holds the local names that the
// user typed. Before the first save over it, the saver keeps one copy at registry.json.unreadable.
@Suite("registry.json that does not parse", .timeLimit(.minutes(1)))
struct UnreadableRegistryTests {
    @Test func aRegistryJsonThatDoesNotParseIsKeptAsUnreadable() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        let stored = #"{"names":{"s1":"alpha"},"started":["s1"]"#
        try stored.write(toFile: file, atomically: false, encoding: .utf8)
        let copy = "\(file).unreadable"
        try "old".write(toFile: copy, atomically: false, encoding: .utf8)
        let log = Recorder<StoreEvent>()
        let opened = StoreFile.open(path: file, log: log)
        #expect(opened.store == RegistryStore())
        // The open itself writes nothing.
        #expect(try text(copy) == "old")
        try opened.saver.save(RegistryStore(names: ["s2": "beta"]))
        // The new copy replaces the old copy.
        #expect(try text(copy) == stored)
        #expect(StoreFile.open(path: file, log: log).store == RegistryStore(names: ["s2": "beta"]))
        #expect(log.values == [.keptUnreadableCopy(file: file, copy: copy)])
        // The second save does not copy again.
        try FileManager.default.removeItem(atPath: copy)
        try opened.saver.save(RegistryStore(names: ["s3": "gamma"]))
        #expect(try names(dir) == ["registry.json"])
    }

    // A value with no JSON form in a field of the store is a bad value: the decode drops only
    // that value, as for any bad value, and the file is JSON. So no copy is kept. In an unknown
    // field, the value would be lost at the save, so the file counts as a file that does not
    // parse.
    @Test func aValueWithNoJSONFormIsDroppedOrKeepsTheFile() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        for stored in [
            #"{"names":{"s1":"alpha"},"priorities":{"s1":1e400},"started":["s1"]}"#,
            #"{"aliases":{"s1":"\ud800"},"names":{"s1":"alpha"},"started":["s1"]}"#,
        ] {
            try stored.write(toFile: file, atomically: false, encoding: .utf8)
            let opened = StoreFile.open(path: file, log: Recorder<StoreEvent>())
            #expect(opened.store == RegistryStore(names: ["s1": "alpha"], started: ["s1"]))
            try opened.saver.save(opened.store)
            #expect(try names(dir) == ["registry.json"])
        }
        let future = #"{"names":{"s1":"alpha"},"future":[1e400]}"#
        try future.write(toFile: file, atomically: false, encoding: .utf8)
        let opened = StoreFile.open(path: file, log: Recorder<StoreEvent>())
        #expect(opened.store == RegistryStore())
        try opened.saver.save(opened.store)
        #expect(try text("\(file).unreadable") == future)
    }

    // A failed copy turns the save off and logs it. So the file that does not parse stays.
    @Test func aFailedRegistryCopyTurnsTheSaveOff() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        let stored = #"{"names":{"s1":"alpha"}"#
        try stored.write(toFile: file, atomically: false, encoding: .utf8)
        // A folder with the name of the copy makes the copy fail.
        let copy = "\(file).unreadable"
        try FileManager.default.createDirectory(atPath: copy, withIntermediateDirectories: false)
        let log = Recorder<StoreEvent>()
        let opened = StoreFile.open(path: file, log: log)
        try opened.saver.save(RegistryStore(names: ["s2": "beta"]))
        #expect(try text(file) == stored)
        let error = FileError.system(.copy(to: copy), path: file, code: EISDIR)
        #expect(
            log.values == [
                .copyFailed(file: file, copy: copy, what: "the registry store", error: error)
            ])
        try opened.saver.save(RegistryStore(names: ["s3": "gamma"]))
        #expect(try text(file) == stored)
        #expect(log.values.count == 1)
    }
}
