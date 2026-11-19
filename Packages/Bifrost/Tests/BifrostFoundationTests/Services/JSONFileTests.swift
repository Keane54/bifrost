import BifrostTestSupport
import Foundation
import Synchronization
import Testing

@testable import BifrostFoundation

// The JSON files of the stores: the read, the safe write and the copy of a bad file. The tests of
// a settings file with values that the model does not read are
// in SettingsFileTests.swift of BifrostSettingsTests.

private func readValue(_ url: URL) throws -> JSONValue? {
    try JSONFile.read(url).map { try JSONDecoder().decode(JSONValue.self, from: $0) }
}

@Suite("the JSON file of a store", .testTimeLimit)
struct JSONFileTests {
    @Test
    func writesWithMode() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "sub/a.json")
        try JSONFile.write(try JSONFile.encode(["a": 1]), to: file)
        #expect(try readValue(file) == ["a": 1])
        let attributes = try FileManager.default.attributesOfItem(
            atPath: file.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? Int).map { $0 & 0o777 } == 0o600)
        #expect(try names(dir.appending(path: "sub")) == ["a.json"])
    }

    @Test
    func removesTempOnRenameFailure() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let target = dir.appending(path: "target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try JSONFile.write(Data("{}".utf8), to: target) }
        #expect(try names(dir) == ["target"])
    }

    // JSONFile.read gives the bytes. The caller decodes them, so bad JSON is a decode error.
    @Test
    func readsMissingBadAndGood() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        #expect(try JSONFile.read(dir.appending(path: "missing.json")) == nil)
        let bad = dir.appending(path: "bad.json")
        try Data("{ no".utf8).write(to: bad)
        #expect(throws: DecodingError.self) { try readValue(bad) }
        let good = dir.appending(path: "good.json")
        try Data(#"{"a":[1]}"#.utf8).write(to: good)
        #expect(try readValue(good) == ["a": [1]])
    }

    @Test
    func rejectsOtherErrors() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        #expect(throws: (any Error).self) { try JSONFile.read(dir) }
    }

    // The steps record their order. The data must be in the temporary file at the sync.
    @Test
    func syncsBeforeRename() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "a.json")
        let data = try JSONFile.encode(["a": 1])
        let calls = Mutex<[String]>([])
        let steps = WriteSteps(
            sync: { handle in
                let temporary = try names(dir).filter { $0.hasSuffix(".tmp") }
                let text = try temporary.map { try Data(contentsOf: dir.appending(path: $0)) }
                calls.withLock { $0.append(text == [data] ? "sync full" : "sync \(temporary)") }
                try WriteSteps.system.sync(handle)
            },
            rename: { from, to in
                calls.withLock { $0.append("rename") }
                try WriteSteps.system.rename(from, to)
            })
        try JSONFile.write(data, to: file, steps: steps)
        #expect(calls.withLock { $0 } == ["sync full", "rename"])
        #expect(try readValue(file) == ["a": 1])
    }

    // The temporary file opens with O_EXCL. The test gives the write a fixed temporary path
    // where the file of another writer already is. The write throws EEXIST, and the file of the
    // other writer and the old file stay as they were (S8).
    @Test func aWriteNeverTakesAFileAtItsTemporaryPath() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "a.json")
        try JSONFile.write(Data("old".utf8), to: file)
        let other = dir.appending(path: "a.json.other.tmp")
        try Data("other".utf8).write(to: other)
        let steps = WriteSteps(
            sync: WriteSteps.system.sync, rename: WriteSteps.system.rename,
            temporaryPath: { "\($0).other.tmp" })
        let error = #expect(throws: POSIXError.self) {
            try JSONFile.write(Data("new".utf8), to: file, steps: steps)
        }
        #expect(error?.code == .EEXIST)
        #expect(try JSONFile.read(other) == Data("other".utf8))
        #expect(try JSONFile.read(file) == Data("old".utf8))
    }

    @Test func aFailedSyncRemovesTheTempFileAndThrowsItsError() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        await confirmation("a rename after a failed sync", expectedCount: 0) { renamed in
            let steps = WriteSteps(
                sync: { _ in throw POSIXError(.EIO) }, rename: { _, _ in renamed() })
            let error = #expect(throws: POSIXError.self) {
                try JSONFile.write(
                    Data("{}".utf8), to: dir.appending(path: "a.json"), steps: steps)
            }
            #expect(error?.code == .EIO)
        }
        #expect(try names(dir) == [])
    }

    @Test func aFailedSyncKeepsTheOldFile() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "a.json")
        try JSONFile.write(Data("old".utf8), to: file)
        await confirmation("a rename after a failed sync", expectedCount: 0) { renamed in
            let steps = WriteSteps(
                sync: { _ in throw POSIXError(.EIO) }, rename: { _, _ in renamed() })
            #expect(throws: POSIXError.self) {
                try JSONFile.write(Data("new".utf8), to: file, steps: steps)
            }
        }
        #expect(try JSONFile.read(file) == Data("old".utf8))
        #expect(try names(dir) == ["a.json"])
    }

    // The order of libuv on macOS: F_FULLFSYNC, then F_BARRIERFSYNC, then fsync. A call stops
    // the order when it works. A failed call gives -1 with errno EIO. The last entry of a sync
    // that throws is the error.
    @Test func theSystemSyncFlushesTheDriveCacheFirst() {
        func run(failing: Set<String>) -> [String] {
            let calls = Mutex<[String]>([])
            func call(_ name: String, _ descriptor: Int32) -> Int32 {
                calls.withLock { $0.append("\(name) \(descriptor)") }
                guard failing.contains(name) else { return 0 }
                errno = EIO
                return -1
            }
            let names = [F_FULLFSYNC: "full", F_BARRIERFSYNC: "barrier"]
            do {
                try WriteSteps.fullSync(
                    7, control: { call(names[$1] ?? "fcntl \($1)", $0) },
                    flush: { call("fsync", $0) })
            } catch {
                let code = (error as? POSIXError)?.code == .EIO ? "EIO" : "other"
                calls.withLock { $0.append("error \(code)") }
            }
            return calls.withLock { $0 }
        }
        #expect(run(failing: []) == ["full 7"])
        #expect(run(failing: ["full"]) == ["full 7", "barrier 7"])
        #expect(run(failing: ["full", "barrier"]) == ["full 7", "barrier 7", "fsync 7"])
        #expect(
            run(failing: ["full", "barrier", "fsync"]) == [
                "full 7", "barrier 7", "fsync 7", "error EIO",
            ])
    }

    // The system steps with the real calls, recorded. The file system of the temporary folder
    // has F_FULLFSYNC, so the first call works and the write makes no other sync call.
    @Test func aWriteWithTheSystemStepsMakesAFullSync() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "a.json")
        let calls = Mutex<[String]>([])
        let steps = WriteSteps.system(
            control: { descriptor, command in
                calls.withLock { $0.append(command == F_FULLFSYNC ? "full" : "fcntl \(command)") }
                return fcntl(descriptor, command)
            },
            flush: { descriptor in
                calls.withLock { $0.append("fsync") }
                return fsync(descriptor)
            })
        try JSONFile.write(Data("data".utf8), to: file, steps: steps)
        #expect(calls.withLock { $0 } == ["full"])
        #expect(try JSONFile.read(file) == Data("data".utf8))
    }

    @Test func aWriteReplacesTheOldFile() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let file = dir.appending(path: "a.json")
        try JSONFile.write(Data("old".utf8), to: file)
        try JSONFile.write(Data("new".utf8), to: file)
        #expect(try JSONFile.read(file) == Data("new".utf8))
        #expect(try names(dir) == ["a.json"])
    }

    // The form of the registry pilot: two spaces, sorted keys, "/" not escaped, a newline at the
    // end.
    @Test func encodeGivesPrettySortedJSONWithANewline() throws {
        let value: JSONValue = ["b": "a/b", "a": [1, 2.5, .null, true]]
        let text = String(decoding: try JSONFile.encode(value), as: UTF8.self)
        #expect(
            text == """
                {
                  "a" : [
                    1,
                    2.5,
                    null,
                    true
                  ],
                  "b" : "a/b"
                }

                """)
    }

    @Test func encodeThrowsForANumberThatJSONCannotHold() {
        let value: JSONValue = ["a": .double(.infinity)]
        #expect(throws: EncodingError.self) { try JSONFile.encode(value) }
    }

    // The first copy is a new file with the mode 0600. A second keep writes nothing over it, also
    // when the item at the path is a link or a folder.
    @Test func theFirstCopyIsNeverWrittenOver() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let copy = dir.appending(path: "state.json.before-native")
        #expect(try JSONFile.keepFirstCopy(Data("first".utf8), at: copy))
        #expect(try JSONFile.keepFirstCopy(Data("second".utf8), at: copy) == false)
        #expect(try JSONFile.read(copy) == Data("first".utf8))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: copy.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? Int).map { $0 & 0o777 } == 0o600)
        let link = dir.appending(path: "link.before-native")
        try FileManager.default.createSymbolicLink(
            atPath: link.path(percentEncoded: false), withDestinationPath: "missing")
        #expect(try JSONFile.keepFirstCopy(Data("x".utf8), at: link) == false)
        #expect(try names(dir) == ["link.before-native", "state.json.before-native"])
    }

    // A copy that another write made between the check and the rename stays: the rename of the
    // keep never replaces it, and its temporary file goes.
    @Test func aCopyThatCameDuringTheKeepStays() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.url
        let copy = dir.appending(path: "state.json.before-native")
        let system = WriteSteps.system
        let steps = WriteSteps(
            sync: { handle in
                try system.sync(handle)
                try Data("other".utf8).write(to: copy)
            }, rename: system.rename)
        #expect(try JSONFile.keepFirstCopy(Data("mine".utf8), at: copy, steps: steps) == false)
        #expect(try JSONFile.read(copy) == Data("other".utf8))
        #expect(try names(dir) == ["state.json.before-native"])
    }
}
