import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSessions

private func write(_ text: String, _ file: String) throws {
    try text.write(toFile: file, atomically: false, encoding: .utf8)
}

// The store of a file, as the registry service opens it.
private func load(_ file: String) throws -> RegistryStore {
    StoreFile.open(path: file, log: Recorder<StoreEvent>()).store
}

// Write the store with the safe write, in the text form of the stores.
private func save(_ file: String, _ store: RegistryStore) throws {
    try JSONFile.write(try JSONFile.encode(store), to: URL(fileURLWithPath: file))
}

@Suite("the registry store file", .testTimeLimit)
struct StoreFileTests {
    @Test
    func emptyForBad() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        #expect(try load("\(dir)/missing.json") == RegistryStore())
        let bad = "\(dir)/bad.json"
        try write("{ not json", bad)
        #expect(try load(bad) == RegistryStore())
        for text in ["null", "[]", "\"text\"", "7"] {
            try write(text, bad)
            #expect(try load(bad) == RegistryStore())
        }
    }

    @Test
    func removesWrongTypes() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        try write(
            #"{"names":{"s1":"alpha","s2":7,"s3":null},"priorities":{},"started":["s1",4,null],"#
                + #""watch":[],"worktrees":[]}"#,
            file)
        #expect(try load(file) == RegistryStore(names: ["s1": "alpha"], started: ["s1"]))
        try write(#"{"names":["x"],"priorities":{},"started":"x"}"#, file)
        #expect(try load(file) == RegistryStore())
    }

    @Test("a saved store loads back the same")
    func roundTrip() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        let store = RegistryStore(
            aliases: ["s1": "Work"], names: ["s1": "alpha", "s2": "beta"], started: ["s2"])
        try save(file, store)
        #expect(try load(file) == store)
        let next = RegistryStore(names: ["s3": "gamma"])
        try save(file, next)
        #expect(try load(file) == next)
    }

    @Test("saving makes the directory and leaves no temporary file")
    func makesDirectory() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/user-data/registry.json"
        try save(file, RegistryStore())
        try save(file, RegistryStore(names: ["s1": "alpha"]))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: "\(dir)/user-data") == [
                "registry.json"
            ])
        let mode = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int
        #expect(mode.map { $0 & 0o777 } == 0o600)
    }

    @Test("loading logs the error of a file that it cannot read")
    func rejectsFolder() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: false)
        let log = Recorder<StoreEvent>()
        #expect(StoreFile.open(path: file, log: log).store == RegistryStore())
        let error = FileError.system(.read, path: file, code: EISDIR)
        #expect(
            log.values == [.readFailed(file: file, what: "the registry store", error: error)])
    }

    @Test
    func openLoadsAndSaves() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        try save(file, RegistryStore(names: ["s1": "alpha"]))
        let log = Recorder<StoreEvent>()
        let opened = StoreFile.open(path: file, log: log)
        #expect(opened.store == RegistryStore(names: ["s1": "alpha"]))
        try opened.saver.save(RegistryStore(names: ["s2": "beta"], started: ["s2"]))
        #expect(try load(file) == RegistryStore(names: ["s2": "beta"], started: ["s2"]))
        #expect(log.values.isEmpty)
    }

    @Test("opening uses an empty store and does not save when the file cannot be read")
    func openUnreadable() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: false)
        let log = Recorder<StoreEvent>()
        let opened = StoreFile.open(path: file, log: log)
        #expect(opened.store == RegistryStore())
        #expect(log.values.count == 1)
        try opened.saver.save(RegistryStore(names: ["s1": "alpha"]))
        var isDir: ObjCBool = false
        #expect(
            FileManager.default.fileExists(atPath: file, isDirectory: &isDir) && isDir.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file) == [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["registry.json"])
    }

    @Test("a file of the first milestone without priorities loads")
    func m1File() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        try write(#"{"names":{"a":"x"},"started":[]}"#, file)
        #expect(try load(file) == RegistryStore(names: ["a": "x"]))
    }

    // Only a whole number from 1 to 5 is a priority: 7, the text "2" and 1.5 drop.
    @Test func aPriorityOutOfRangeAsTextOrWithAFractionDrops() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        try write(#"{"names":{},"priorities":{"a":3,"b":7,"c":"2","d":1.5},"started":[]}"#, file)
        #expect(try load(file).priorities == ["a": .p3])
    }

    @Test
    func withoutLastActive() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        try write(#"{"names":{"a":"x"},"priorities":{"a":2},"started":[]}"#, file)
        #expect(try load(file) == RegistryStore(names: ["a": "x"], priorities: ["a": .p2]))
    }

    @Test
    func lastActiveStrings() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        try write(#"{"lastActive":["a",3,"a",null,"b"]}"#, file)
        #expect(try load(file).lastActive == ["a", "b"])
    }

    @Test("a file without a watchlist gives an empty watchlist")
    func noWatch() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        try write(#"{"names":{},"started":[]}"#, file)
        #expect(try load(file).watch == [])
    }

    @Test("good watch entries keep their order")
    func watchOrder() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        try write(
            #"{"names":{},"started":[],"watch":[{"colour":"dark-blue","sessionId":"s2"},"#
                + #"{"colour":"amber","sessionId":"s1"}]}"#,
            file)
        #expect(try load(file).watch == [WatchEntry("s2", .darkBlue), WatchEntry("s1", .amber)])
    }

    @Test("the old watch colours map to the new ones")
    func oldColours() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        let names = ["orange", "cyan", "purple", "pink", "teal", "constructor", "__proto__"]
        let watch = names.enumerated().map { #"{"colour":"\#($1)","sessionId":"s\#($0 + 1)"}"# }
            .joined(separator: ",")
        try write(#"{"names":{},"started":[],"watch":[\#(watch)]}"#, file)
        #expect(
            try load(file).watch
                == [
                    WatchEntry("s1", .amber), WatchEntry("s2", .lightBlue),
                    WatchEntry("s3", .darkBlue), WatchEntry("s4", .red),
                ])
    }

    @Test("watch entries with a bad colour, a bad ID or a repeated ID drop")
    func badWatch() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        let watch =
            #"[{"colour":"dark-blue","sessionId":"s1"},{"colour":"teal","sessionId":"s2"},"#
                + #"{"colour":"pink","sessionId":7},{"colour":"green","sessionId":"s1"},null,"#
                + #""text",{"colour":"white","sessionId":"s3"}]"#
        try write(#"{"names":{},"started":[],"watch":\#(watch)}"#, file)
        #expect(try load(file).watch == [WatchEntry("s1", .darkBlue), WatchEntry("s3", .white)])
        try write(#"{"names":{},"started":[],"watch":"x"}"#, file)
        #expect(try load(file).watch == [])
    }

    @Test("a full file of the third milestone with no watchlist loads")
    func fullM3() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        try write(
            #"{"lastActive":["s1","s2"],"names":{"s1":"alpha","s2":"beta"},"priorities":{"s1":2,"#
                + #""s2":5},"started":["s1"]}"#,
            file)
        #expect(
            try load(file)
                == RegistryStore(
                    lastActive: ["s1", "s2"], names: ["s1": "alpha", "s2": "beta"], started: ["s1"],
                    priorities: ["s1": .p2, "s2": .p5]))
    }

    @Test("a damaged watchlist keeps the other fields")
    func damagedWatch() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        let rest =
            #""lastActive":["s1"],"names":{"s1":"alpha"},"priorities":{"s1":3},"started":["s1"]"#
        let want = RegistryStore(
            lastActive: ["s1"], names: ["s1": "alpha"], started: ["s1"], priorities: ["s1": .p3])
        try write(#"{\#(rest),"watch":"broken"}"#, file)
        #expect(try load(file) == want)
        try write(#"{\#(rest),"watch":[1,null,{"colour":"red"},[]]}"#, file)
        #expect(try load(file) == want)
    }

    @Test("a file without worktrees gives no worktrees")
    func noWorktrees() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        try write(#"{"names":{},"started":[],"watch":[]}"#, file)
        #expect(try load(file).worktrees == [:])
        try write(#"{"names":{},"started":[],"worktrees":"x"}"#, file)
        #expect(try load(file).worktrees == [:])
    }

    @Test("only worktree entries with a string ID and a worktree path stay")
    func worktreeEntries() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        let worktrees = """
            [{"path":"/r/.claude/worktrees/a","sessionId":"s1"},{"path":"/r/.claude/worktrees/b",\
            "sessionId":7},\
            {"path":"r/.claude/worktrees/c","sessionId":"s3"},{"path":"/r/src","sessionId":"s4"},\
            {"path":"/r/.claude/worktrees/../x","sessionId":"s5"},{"path":7,"sessionId":"s6"},\
            {"path":"/r/.claude/worktrees/d","sessionId":"s1"},null,"text",\
            {"path":"/q/.claude/worktrees/e","sessionId":"s7"}]
            """
        try write(#"{"names":{},"started":[],"worktrees":\#(worktrees)}"#, file)
        #expect(
            try load(file).worktrees == [
                "s1": "/r/.claude/worktrees/a", "s7": "/q/.claude/worktrees/e",
            ])
    }

    @Test
    func worktreesRoundTrip() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        let store = RegistryStore(started: ["s1"], worktrees: ["s1": "/r/.claude/worktrees/a"])
        try save(file, store)
        #expect(try load(file) == store)
    }

    @Test("a file without aliases gives no aliases")
    func noAliases() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/old.json"
        try write(#"{"names":{},"priorities":{},"started":[]}"#, file)
        #expect(try load(file).aliases == [:])
    }

    @Test("good aliases stay and bad values drop")
    func aliases() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/aliases.json"
        let long = String(repeating: "x", count: 65)
        try write(
            #"{"aliases":{"s1":"Work","s2":7,"s3":"","s4":"a\u001bb","s5":"\#(long)","#
                + #""s6":"  pad  "},"names":{}}"#,
            file)
        #expect(try load(file).aliases == ["s1": "Work", "s6": "pad"])
        try write(#"{"aliases":["x"],"names":{}}"#, file)
        #expect(try load(file).aliases == [:])
    }

    @Test("a file without current IDs and short IDs gives none")
    func noCurrent() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/old.json"
        try write(#"{"names":{},"started":[]}"#, file)
        let store = try load(file)
        #expect(store.current == [:])
        #expect(store.jobs == [:])
    }

    @Test
    func currentAndJobs() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let A = "2f493bf0-1598-4b3b-b419-8acb9cb11bcb"
        let B = "1db82d17-d5fd-4e53-a042-7dd67ea654d8"
        let file = "\(dir)/current.json"
        // Two processes can run one conversation, so r1 and r2 keep one current ID. A has its own
        // row ID, r4 is not a UUID and r5 is no text.
        try write(
            #"{"current":{"r1":"\#(B)","r2":"\#(B)","\#(A)":"\#(A)","r4":"not-a-uuid","r5":7},"#
                + #""jobs":{"\#(A)":"2f493bf0","r2":"ABCDEF12","r3":"123","r4":9,"r5":""},"#
                + #""names":{}}"#,
            file)
        let store = try load(file)
        #expect(store.current == ["r1": B, "r2": B])
        #expect(store.jobs == [A: "2f493bf0"])
        try write(#"{"current":["x"],"jobs":"x","names":{}}"#, file)
        let other = try load(file)
        #expect(other.current == [:])
        #expect(other.jobs == [:])
    }

    @Test
    func currentRoundTrip() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        let store = RegistryStore(
            current: [
                "2f493bf0-1598-4b3b-b419-8acb9cb11bcb": "1db82d17-d5fd-4e53-a042-7dd67ea654d8"
            ],
            jobs: ["2f493bf0-1598-4b3b-b419-8acb9cb11bcb": "2f493bf0"])
        try save(file, store)
        #expect(try load(file) == store)
    }

    @Test("PR sessions survive a save and a load and an empty list adds no key")
    func prSessions() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        var base = try load(file)
        #expect(base.prSessions.isEmpty)
        try save(file, base)
        #expect(!(try String(contentsOfFile: file, encoding: .utf8)).contains("prSessions"))
        base[row: "s1"].prSession = true
        base[row: "s2"].prSession = true
        try save(file, base)
        #expect(try load(file).prSessions == ["s1", "s2"])
    }

    // The Swift type cannot hold the number 3, so the test writes the same JSON text.
    @Test("PR session names survive a save and a load")
    func prNames() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        #expect(try load(file).prNames.isEmpty)
        try write(#"{"names":{},"prNames":["a-1-review","a-1-review",3]}"#, file)
        #expect(try load(file).prNames == ["a-1-review"])
    }

    // The Swift type cannot hold the number 7, so the test writes the same JSON text.
    @Test("deferred deletes survive a save and a load and a bad entry drops")
    func deferred() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let dir = folder.path
        let file = "\(dir)/registry.json"
        // An old store has no deferred deletes, and an empty list adds no key.
        #expect(try load(file).deferred.isEmpty)
        let wt = "/r/.claude/worktrees/w1"
        let good = DeferredDelete(
            sessionId: "s1", shortId: "2f493bf0", worktree: wt, job: "2f493bf0")
        let later = DeferredDelete(sessionId: "s2", shortId: "1db82d17", worktree: wt)
        let entries = [
            #"{"job":"2f493bf0","sessionId":"s1","shortId":"2f493bf0","worktree":"\#(wt)"}"#,
            // A repeated ID, a bad short ID, a path that is not a worktree root and a missing ID.
            #"{"job":"2f493bf0","sessionId":"s1","shortId":"1db82d17","worktree":"\#(wt)"}"#,
            #"{"sessionId":"s3","shortId":"ABCDEF12","worktree":"\#(wt)"}"#,
            #"{"sessionId":"s4","shortId":"1db82d17","worktree":"\#(wt)/src"}"#,
            #"{"sessionId":"","shortId":"1db82d17","worktree":"\#(wt)"}"#,
            "7",
            #"{"sessionId":"s2","shortId":"1db82d17","worktree":"\#(wt)"}"#,
            #"{"job":"ABCDEF12","sessionId":"s5","shortId":"1db82d17","worktree":"\#(wt)"}"#,
        ]
        try write(#"{"deferred":[\#(entries.joined(separator: ","))]}"#, file)
        let withoutJob = DeferredDelete(sessionId: "s5", shortId: "1db82d17", worktree: wt)
        #expect(try load(file).deferred == [good, later, withoutJob])
        try write(#"{"deferred":"x","names":{}}"#, file)
        #expect(try load(file).deferred.isEmpty)
    }
}

// The steer of the gate: one bad field must not make the whole file fail.
@Suite("damaged store files", .testTimeLimit)
struct DamagedStoreTests {
    private let good = #""names":{"s1":"alpha"},"started":["s1"],"priorities":{"s1":2}"#
    private var want: RegistryStore {
        RegistryStore(names: ["s1": "alpha"], started: ["s1"], priorities: ["s1": .p2])
    }

    @Test("each damaged field drops alone and the other fields stay", arguments: [
        #""aliases":7"#, #""aliases":{"s1":["x"]}"#, #""current":"x""#, #""current":{"s1":null}"#,
            #""jobs":[1]"#, #""lastActive":{"a":1}"#, #""watch":{"colour":"red"}"#,
            #""watch":[{"colour":"red","sessionId":["s1"]}]"#,
        #""worktrees":[{"path":null}]"#, #""deferred":[{"sessionId":"x"}]"#, #""prSessions":"s1""#,
        #""prNames":[null]"#,
    ])
    func oneBadField(field: String) {
        #expect(RegistryStore.load(from: Data("{\(good),\(field)}".utf8)) == want)
    }

    // An unknown field stays in the store, and the known fields load as before.
    @Test func anUnknownFieldStaysWithTheGoodFields() {
        var expected = want
        expected.unknown = UnknownFields(["unknown": ["deep": [1, 2, ["x": .null]]]])
        let field = #""unknown":{"deep":[1,2,{"x":null}]}"#
        #expect(RegistryStore.load(from: Data("{\(good),\(field)}".utf8)) == expected)
    }

    @Test
    func badValueInField() {
        let text =
            #"{"names":{"s1":"alpha","s2":false,"s3":{"x":1}},"started":["s1",[],{}],"#
                + #""priorities":{"s1":2,"s2":"high","s3":9}}"#
        #expect(RegistryStore.load(from: Data(text.utf8)) == want)
    }

    @Test("a cut file or a file that is not an object gives an empty store")
    func cutFile() {
        let text = "{\(good)}"
        for end in [1, 10, text.count / 2, text.count - 1] {
            #expect(RegistryStore.load(from: Data(text.prefix(end).utf8)) == RegistryStore())
        }
        #expect(RegistryStore.load(from: Data("[\(text)]".utf8)) == RegistryStore())
    }

    @Test("a full file of the earlier app loads with all values")
    func electronFile() throws {
        let text = """
            {"aliases":{"s1":"Work"},"current":{"s1":"1db82d17-d5fd-4e53-a042-7dd67ea654d8"},
            "deferred":[{"job":"aa000000","sessionId":"s9","shortId":"aa000000",\
            "worktree":"/r/.claude/worktrees/w"}],
            "jobs":{"s1":"2f493bf0"},"lastActive":["s1"],"names":{"s1":"alpha"},\
            "prNames":["n-review"],
            "prSessions":["s2"],"priorities":{"s1":1},"started":["s1"],"watch":[{"colour":"orange",\
            "sessionId":"s1"}],
            "worktrees":[{"path":"/r/.claude/worktrees/w","sessionId":"s1"}]}
            """
        let store = RegistryStore.load(from: Data(text.utf8))
        #expect(
            store
                == RegistryStore(
                    aliases: ["s1": "Work"],
                    current: ["s1": "1db82d17-d5fd-4e53-a042-7dd67ea654d8"],
                    deferred: [
                        DeferredDelete(
                            sessionId: "s9", shortId: "aa000000",
                            worktree: "/r/.claude/worktrees/w", job: "aa000000")
                    ],
                    jobs: ["s1": "2f493bf0"], lastActive: ["s1"], names: ["s1": "alpha"],
                    prSessions: ["s2"],
                    prNames: ["n-review"], started: ["s1"], priorities: ["s1": .p1],
                    watch: [WatchEntry("s1", .amber)],
                    worktrees: ["s1": "/r/.claude/worktrees/w"]))
    }
}
