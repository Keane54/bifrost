import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSessions

// The edge cases of the load of a store file. Each case is the text of a store file with one
// field, and the store that the load gives. A value with the wrong type or a bad value goes
// alone, and the other values stay.

private func load(_ text: String) -> RegistryStore { RegistryStore.load(from: Data(text.utf8)) }

private let uuidA = "2f493bf0-1598-4b3b-b419-8acb9cb11bcb"
private let uuidB = "1db82d17-d5fd-4e53-a042-7dd67ea654d8"
private let worktree = "/r/.claude/worktrees/w1"

@Suite("the load of a store file: the text")
struct StoreTextEdgeTests {
    @Test(
        "text that is not a store object gives an empty store",
        arguments: [
            "", " ", "{ not json", "null", "[]", "\"text\"", "7", "true", "{}",
            "\u{FEFF}{}", "[{\"names\":{\"a\":\"x\"}}]", "{\"names\":{\"a\":\"x\"}",
        ])
    func empty(text: String) {
        #expect(load(text) == RegistryStore())
    }

    @Test func anObjectWithOnlyAnUnknownKeyGivesAnEmptyStoreWithThatKey() {
        var expected = RegistryStore()
        expected.unknown = UnknownFields(["x": 1])
        #expect(load("{\"x\":1}") == expected)
    }

    @Test("a file with only the older fields loads and the missing fields are empty")
    func older() {
        #expect(
            load(#"{"names":{"a":"x"},"started":[]}"#) == RegistryStore(names: ["a": "x"]))
    }

    @Test(
        "the row IDs for the prototype and constructor are normal keys",
        arguments: ["__proto__", "constructor", "toString", "7", "10", "2"])
    func plainKeys(key: String) {
        let text = #"{"names":{"\#(key)":"x"},"started":["\#(key)"],"priorities":{"\#(key)":3}}"#
        #expect(
            load(text)
                == RegistryStore(names: [key: "x"], started: [key], priorities: [key: .p3]))
    }
}

@Suite("the load of a store file: the fields")
struct StoreFieldEdgeTests {
    @Test(
        "a field of the wrong shape is empty",
        arguments: [
            "7", "1.5", "\"x\"", "true", "null", "[]", "[\"a\"]", "{\"a\":1}", "{\"a\":null}",
        ])
    func wrongShape(value: String) {
        for key in ["names", "aliases", "current", "jobs", "priorities"]
        where !(key == "priorities" && value == #"{"a":1}"#) {
            #expect(load("{\"\(key)\":\(value)}") == RegistryStore(), "\(key) \(value)")
        }
        for key in ["started", "lastActive", "prSessions", "prNames", "watch", "worktrees"]
        where !value.hasPrefix("[\"a\"]") {
            #expect(load("{\"\(key)\":\(value)}") == RegistryStore(), "\(key) \(value)")
        }
    }

    @Test(
        "a name keeps only text values and an empty name stays",
        arguments: [
            (#"{"a":"x"}"#, ["a": "x"]), (#"{"a":"x","b":7,"c":null,"d":[],"e":{}}"#, ["a": "x"]),
            (#"{"a":""}"#, ["a": ""]), (#"{"a":true,"b":"y"}"#, ["b": "y"]),
        ])
    func names(json: String, expected: [String: String]) {
        #expect(load("{\"names\":\(json)}").names == expected)
    }

    @Test(
        "a local name is trimmed and a bad or empty name drops",
        arguments: [
            (#"{"a":"Work"}"#, ["a": "Work"]), (#"{"a":" pad "}"#, ["a": "pad"]),
            (#"{"a":""}"#, [:]), (#"{"a":"   "}"#, [:]), (#"{"a":"a\u001bb"}"#, [:]),
            (#"{"a":"a\u200bb"}"#, [:]), (#"{"a":"\u200bx"}"#, [:]), (#"{"a":7}"#, [:]),
            (
                #"{"a":"\#(String(repeating: "x", count: 64))"}"#,
                ["a": String(repeating: "x", count: 64)]
            ),
            (#"{"a":"\#(String(repeating: "x", count: 65))"}"#, [:]),
            (#"{"a":"Work","b":"","c":7,"d":"Home"}"#, ["a": "Work", "d": "Home"]),
        ] as [(String, [String: String])])
    func aliases(json: String, expected: [String: String]) {
        #expect(load("{\"aliases\":\(json)}").aliases == expected)
    }

    @Test(
        "a current ID must be a UUID that is not its row ID, and it is kept in lower case",
        arguments: [
            (#"{"s1":"\#(uuidA)"}"#, ["s1": uuidA]),
            (#"{"s1":"\#(uuidA.uppercased())"}"#, ["s1": uuidA]),
            (#"{"\#(uuidA)":"\#(uuidA)"}"#, [:]),
            (#"{"\#(uuidA)":"\#(uuidB)"}"#, [uuidA: uuidB]),
            (#"{"s1":"not-a-uuid"}"#, [:]), (#"{"s1":""}"#, [:]), (#"{"s1":7}"#, [:]),
            (#"{"s1":"\#(uuidA)x"}"#, [:]),
            (#"{"s1":"\#(uuidA)","s2":"nope","s3":"\#(uuidB)"}"#, ["s1": uuidA, "s3": uuidB]),
        ] as [(String, [String: String])])
    func current(json: String, expected: [String: String]) {
        #expect(load("{\"current\":\(json)}").current == expected)
    }

    @Test(
        "the short ID of a job has 8 lower-case hex digits",
        arguments: [
            (#"{"s1":"2f493bf0"}"#, ["s1": "2f493bf0"]), (#"{"s1":"ABCDEF12"}"#, [:]),
            (#"{"s1":"2f493bf"}"#, [:]), (#"{"s1":"2f493bf00"}"#, [:]), (#"{"s1":"aa"}"#, [:]),
            (#"{"s1":"123"}"#, [:]), (#"{"s1":7}"#, [:]), (#"{"s1":""}"#, [:]),
            (#"{"s1":"2f493bf0","s2":"zz"}"#, ["s1": "2f493bf0"]),
        ] as [(String, [String: String])])
    func jobs(json: String, expected: [String: String]) {
        #expect(load("{\"jobs\":\(json)}").jobs.mapValues(\.text) == expected)
    }

    @Test(
        "a priority is a whole number from 1 to 5",
        arguments: [
            (
                #"{"a":1,"b":2,"c":3,"d":4,"e":5}"#,
                ["a": SessionPriority.p1, "b": .p2, "c": .p3, "d": .p4, "e": .p5]
            ),
            (#"{"a":0}"#, [:]), (#"{"a":6}"#, [:]), (#"{"a":-1}"#, [:]), (#"{"a":1.5}"#, [:]),
            (#"{"a":"2"}"#, [:]), (#"{"a":null}"#, [:]), (#"{"a":true}"#, [:]),
            (#"{"a":2,"b":9}"#, ["a": .p2]),
        ] as [(String, [String: SessionPriority])])
    func priorities(json: String, expected: [String: SessionPriority]) {
        #expect(load("{\"priorities\":\(json)}").priorities == expected)
    }

    @Test(
        "a list of session IDs keeps the text values once each",
        arguments: [
            (#"["s1","s2"]"#, Set(["s1", "s2"])), (#"["s1","s1"]"#, Set(["s1"])),
            (#"["s1",7,null,[],{},true,"s2"]"#, Set(["s1", "s2"])), ("[]", Set<String>()),
            (#"[""]"#, Set([""])),
        ])
    func lists(json: String, expected: Set<String>) {
        let all = load(
            "{\"started\":\(json),\"lastActive\":\(json),\"prSessions\":\(json),"
                + "\"prNames\":\(json)}")
        #expect(all.started == expected)
        #expect(all.lastActive == expected)
        #expect(all.prSessions == expected)
        #expect(all.prNames == expected)
    }

    @Test(
        "a watch entry needs a text ID and a known colour and the first entry of an ID stays",
        arguments: [
            (#"[{"colour":"red","sessionId":"a"}]"#, [WatchEntry("a", .red)]),
            (#"[{"colour":"teal","sessionId":"a"}]"#, []),
            (
                #"[{"colour":"constructor","sessionId":"a"},"#
                    + #"{"colour":"__proto__","sessionId":"b"}]"#,
                []
            ),
            (#"[{"colour":7,"sessionId":"a"},{"colour":"red","sessionId":7}]"#, []),
            (#"[{"colour":"red"},{"sessionId":"a"},{},null,"x"]"#, []),
            (
                #"[{"colour":"red","sessionId":"a"},{"colour":"green","sessionId":"a"}]"#,
                [WatchEntry("a", .red)]
            ),
            (
                #"[{"colour":"red","sessionId":"__proto__"},"#
                    + #"{"colour":"green","sessionId":"constructor"}]"#,
                [WatchEntry("__proto__", .red), WatchEntry("constructor", .green)]
            ),
            (
                #"[{"colour":"green","sessionId":"b"},{"colour":"red","sessionId":"a"}]"#,
                [WatchEntry("b", .green), WatchEntry("a", .red)]
            ),
            (
                #"[{"colour":"cyan","sessionId":"a"},{"colour":"lime","sessionId":"b"}]"#,
                [WatchEntry("a", .lightBlue), WatchEntry("b", .green)]
            ),
        ] as [(String, [WatchEntry])])
    func watch(json: String, expected: [WatchEntry]) {
        #expect(load("{\"watch\":\(json)}").watch == expected)
    }

    @Test(
        "a worktree entry needs a text ID and a path in a worktree and the first entry stays",
        arguments: [
            (#"[{"path":"\#(worktree)","sessionId":"a"}]"#, ["a": worktree]),
            (#"[{"path":"\#(worktree)/src","sessionId":"a"}]"#, ["a": worktree + "/src"]),
            (#"[{"path":"/r","sessionId":"a"}]"#, [:]),
            (#"[{"path":"r/.claude/worktrees/w","sessionId":"a"}]"#, [:]),
            (#"[{"path":"/r/.claude/worktrees/../x","sessionId":"a"}]"#, [:]),
            (#"[{"path":"/q/.claude/worktrees/","sessionId":"a"}]"#, [:]),
            (#"[{"path":7,"sessionId":"a"},{"path":"\#(worktree)","sessionId":7}]"#, [:]),
            (
                #"[{"path":"\#(worktree)","sessionId":"a"},"#
                    + #"{"path":"/q/.claude/worktrees/w2","sessionId":"a"}]"#,
                ["a": worktree]
            ),
            (#"[{"path":"\#(worktree)","sessionId":"a"},{"sessionId":"b"},null]"#, ["a": worktree]),
        ] as [(String, [String: String])])
    func worktrees(json: String, expected: [String: String]) {
        #expect(load("{\"worktrees\":\(json)}").worktrees == expected)
    }

    @Test(
        "a deferred delete needs an ID, a short ID and a worktree root and no ID repeats",
        arguments: [
            (
                #"[{"sessionId":"a","shortId":"2f493bf0","worktree":"\#(worktree)"}]"#,
                [DeferredDelete(sessionId: "a", shortId: "2f493bf0", worktree: worktree)]
            ),
            (
                #"[{"sessionId":"a","shortId":"2f493bf0","worktree":"\#(worktree)","#
                    + #""job":"1db82d17"}]"#,
                [
                    DeferredDelete(
                        sessionId: "a", shortId: "2f493bf0", worktree: worktree, job: "1db82d17")
                ]
            ),
            // A job of the wrong form or the wrong type goes, and the delete stays.
            (
                #"[{"sessionId":"a","shortId":"2f493bf0","worktree":"\#(worktree)","job":"zz"}]"#,
                [DeferredDelete(sessionId: "a", shortId: "2f493bf0", worktree: worktree)]
            ),
            (
                #"[{"sessionId":"a","shortId":"2f493bf0","worktree":"\#(worktree)","job":7}]"#,
                [DeferredDelete(sessionId: "a", shortId: "2f493bf0", worktree: worktree)]
            ),
            (#"[{"sessionId":"","shortId":"2f493bf0","worktree":"\#(worktree)"}]"#, []),
            (#"[{"sessionId":7,"shortId":"2f493bf0","worktree":"\#(worktree)"}]"#, []),
            (#"[{"sessionId":"a","shortId":"aa","worktree":"\#(worktree)"}]"#, []),
            (#"[{"sessionId":"a","shortId":"ABCDEF12","worktree":"\#(worktree)"}]"#, []),
            // The path must be the root itself, not a folder below it, and a real worktree.
            (#"[{"sessionId":"a","shortId":"2f493bf0","worktree":"\#(worktree)/src"}]"#, []),
            (#"[{"sessionId":"a","shortId":"2f493bf0","worktree":"/r"}]"#, []),
            (#"[{"sessionId":"a","shortId":"2f493bf0","worktree":"r/.claude/worktrees/w"}]"#, []),
            (
                #"[{"sessionId":"a","shortId":"2f493bf0","worktree":"/r/.claude/worktrees/../x"}]"#,
                []
            ),
            (#"[{"sessionId":"a","shortId":"2f493bf0"},{"sessionId":"b"},null,7]"#, []),
            (
                #"[{"sessionId":"a","shortId":"2f493bf0","worktree":"\#(worktree)"},"#
                    + #"{"sessionId":"a","shortId":"1db82d17","#
                    + #""worktree":"/q/.claude/worktrees/w2"}]"#,
                [DeferredDelete(sessionId: "a", shortId: "2f493bf0", worktree: worktree)]
            ),
        ] as [(String, [DeferredDelete])])
    func deferred(json: String, expected: [DeferredDelete]) {
        #expect(load("{\"deferred\":\(json)}").deferred == expected)
    }

    // A row ID in the UUID form is lower case at the load (row D25), in each map key and each
    // list. Two keys of one map for one row: the lower-case key wins, then the first key in sort
    // order. In a list, the first entry of the row wins. Another ID keeps its case.
    @Test func eachRowIDInTheUUIDFormIsLowerCaseAndTheFirstValueWins() {
        let upper = uuidA.uppercased()
        let mixed = uuidA.prefix(24) + uuidA.suffix(12).uppercased()
        let second = "/q/.claude/worktrees/w2"
        let fields = [
            #""names":{"\#(upper)":"old","\#(uuidA)":"new","Plain":"p"}"#,
            #""aliases":{"\#(upper)":"Alpha"}"#,
            #""jobs":{"\#(upper)":"2f493bf0"}"#,
            #""priorities":{"\#(mixed)":4,"\#(upper)":2}"#,
            #""current":{"\#(upper)":"\#(uuidB.uppercased())"}"#,
            #""started":["\#(upper)","\#(uuidA)"],"lastActive":["\#(upper)"]"#,
            #""prSessions":["\#(upper)"]"#,
            #""watch":[{"colour":"red","sessionId":"\#(upper)"},"#
                + #"{"colour":"green","sessionId":"\#(uuidA)"}]"#,
            #""worktrees":[{"path":"\#(worktree)","sessionId":"\#(upper)"},"#
                + #"{"path":"\#(second)","sessionId":"\#(uuidA)"}]"#,
            #""deferred":[{"sessionId":"\#(upper)","shortId":"2f493bf0","#
                + #""worktree":"\#(worktree)"},{"sessionId":"\#(uuidA)","#
                + #""shortId":"1db82d17","worktree":"\#(second)"}]"#,
        ]
        let store = load("{" + fields.joined(separator: ",") + "}")
        #expect(store.names == [uuidA: "new", "Plain": "p"])
        #expect(store.aliases == [uuidA: "Alpha"])
        #expect(store.jobs == [uuidA: "2f493bf0"])
        #expect(store.priorities == [uuidA: .p2])
        #expect(store.current == [uuidA: uuidB])
        #expect(store.started == [uuidA])
        #expect(store.lastActive == [uuidA])
        #expect(store.prSessions == [uuidA])
        #expect(store.watch == [WatchEntry(uuidA, .red)])
        #expect(store.worktrees == [uuidA: worktree])
        #expect(
            store.deferred
                == [DeferredDelete(sessionId: uuidA, shortId: "2f493bf0", worktree: worktree)])
    }
}

@Suite("the save of a store file")
struct StoreSaveEdgeTests {
    // The file as JSON values, so that the escape of "/" and the order of the keys do not count.
    private func fields(_ store: RegistryStore) throws -> [String: Any] {
        let data = try JSONEncoder().encode(store)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("the sets and the worktrees go out sorted and load back the same")
    func sorted() throws {
        let store = RegistryStore(
            lastActive: ["s2", "s1"], names: ["s1": "alpha"], prSessions: ["p2", "p1"],
            prNames: ["n2", "n1"], started: ["s3", "s1", "s2"],
            worktrees: ["s2": worktree, "s1": "/q/.claude/worktrees/w2"])
        let file = try fields(store)
        #expect(file["started"] as? [String] == ["s1", "s2", "s3"])
        #expect(file["lastActive"] as? [String] == ["s1", "s2"])
        #expect(file["prSessions"] as? [String] == ["p1", "p2"])
        #expect(file["prNames"] as? [String] == ["n1", "n2"])
        let lines = try #require(file["worktrees"] as? [[String: String]])
        #expect(lines.map { $0["sessionId"] } == ["s1", "s2"])
        #expect(lines.map { $0["path"] } == ["/q/.claude/worktrees/w2", worktree])
        #expect(RegistryStore.load(from: try JSONEncoder().encode(store)) == store)
    }

    @Test("an empty value adds no key")
    func emptyKeys() throws {
        let file = try fields(RegistryStore())
        for key in ["prSessions", "prNames", "deferred"] { #expect(file[key] == nil) }
        for key in ["aliases", "current", "jobs", "lastActive", "names", "priorities", "started"] {
            #expect(file[key] != nil, "\(key)")
        }
        #expect((file["watch"] as? [Any])?.isEmpty == true)
        #expect((file["worktrees"] as? [Any])?.isEmpty == true)
    }

    @Test("a repeated value of a loaded file counts and saves once")
    func repeated() throws {
        let file = try fields(load(#"{"started":["a","a","b"],"prSessions":["p","p"]}"#))
        #expect(file["started"] as? [String] == ["a", "b"])
        #expect(file["prSessions"] as? [String] == ["p"])
    }

    @Test
    func fullRoundTrip() throws {
        let store = RegistryStore(
            aliases: ["s1": "Work"], current: ["s1": uuidA],
            deferred: [
                DeferredDelete(
                    sessionId: "s9", shortId: "2f493bf0", worktree: worktree, job: "1db82d17")
            ],
            jobs: ["s1": "2f493bf0"], lastActive: ["s1"], names: ["s1": "alpha"],
            prSessions: ["s2"], prNames: ["n-review"], started: ["s1"], priorities: ["s1": .p4],
            watch: [WatchEntry("s2", .darkBlue), WatchEntry("s1", .amber)],
            worktrees: ["s1": worktree])
        #expect(RegistryStore.load(from: try JSONEncoder().encode(store)) == store)
    }
}
