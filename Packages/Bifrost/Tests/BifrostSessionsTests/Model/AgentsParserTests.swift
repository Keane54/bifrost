import BifrostTestSupport
import Testing

@testable import BifrostSessions

// The parser of the output of "claude agents --json". The input is the text that the program
// wrote. The result is a parsed list (the entries and the partial flag) or the reason of the
// failure. The text of a JSON syntax error comes from Foundation, so a test checks only that the
// detail has a text.

private func ids(_ list: AgentList) -> [String] { list.entries.map(\.sessionId) }

private let entryA = #"{"sessionId":"a","pid":3}"#

@Suite("the parser of claude agents --json")
struct AgentsParserTests {
    @Test(
        "an output with no text is an empty output",
        arguments: ["", "   \n\t ", "  ", "\n", "\u{A0}\u{2028}", "\u{3000}"])
    func empty(stdout: String) {
        #expect(AgentList(output: stdout) == .failed(.emptyOutput))
    }

    @Test(
        "text with no line that starts with a bracket has no JSON array",
        arguments: [
            "no array here", "note\n  [1]\n", #"{"sessionId":"x"}"#, "\u{FEFF}[]", " []",
            "text [1]", "warning: [x]",
        ])
    func noArray(stdout: String) {
        #expect(AgentList(output: stdout) == .failed(.noArray))
    }

    @Test(
        "text after the array or a broken array is a parse error",
        arguments: [
            "[", "[}", #"[{"sessionId":"x"}] trailing"#, "[{\"sessionId\":\"a\"}]\n\nmore text",
            #"[{"sessionId":"a""#,
        ])
    func syntax(stdout: String) {
        guard case .failed(.badJSON(let detail)) = AgentList(output: stdout) else {
            Issue.record("The output parsed, or failed for another reason.")
            return
        }
        #expect(!detail.isEmpty)
    }

    @Test(
        "the array starts at the first line that begins with a bracket",
        arguments: [
            "[\(entryA)]", "[\(entryA)]\n", "warning: old version\n[\(entryA)]",
            "x\r\n[\(entryA)]", "line one\nline two\n[\(entryA)]\n", "[\n  \(entryA)\n]",
            "note\n  [1]\n[\(entryA)]",
        ])
    func start(stdout: String) {
        let list = AgentList(output: stdout)
        #expect(list.error == nil)
        #expect(ids(list) == ["a"])
        #expect(!list.partial)
    }

    @Test("an empty array is a list with no entries", arguments: ["[]", "[ ]", "warning\n[]\n"])
    func emptyArray(stdout: String) {
        let list = AgentList(output: stdout)
        #expect(list.error == nil)
        #expect(list.entries.isEmpty)
        #expect(!list.partial)
    }

    @Test(
        "an item that is not an entry is skipped and the list is partial",
        arguments: [
            // An empty session ID, a session ID of the wrong type, no session ID, no object.
            #"[\#(entryA),{"sessionId":""}]"#,
            #"[\#(entryA),{"sessionId":7}]"#,
            #"[\#(entryA),{"cwd":"/p"}]"#,
            "[\(entryA),null,1,\"s\",[]]",
            "[null,\(entryA)]",
            "[\(entryA),{}]",
        ])
    func partial(stdout: String) {
        let list = AgentList(output: stdout)
        #expect(list.error == nil)
        #expect(ids(list) == ["a"])
        #expect(list.partial)
    }

    @Test(arguments: ["[1e5, -0, 0.5]", "[null]", #"[{"sessionId":""}]"#, "[[]]"])
    func onlyBadItems(stdout: String) {
        let list = AgentList(output: stdout)
        #expect(list.error == nil)
        #expect(list.entries.isEmpty)
        #expect(list.partial)
    }

    @Test("a value of the wrong type gets its empty value and the entry stays")
    func wrongTypes() {
        let list = AgentList(output: 
            #"[{"sessionId":"a","pid":1.5,"startedAt":"x","kind":5,"name":null,"cwd":[],"#
                + #""id":3,"waitingFor":"p","status":null}]"#)
        #expect(
            list.entries
                == [
                    AgentEntry(
                        sessionId: "a", cwd: "", isBackground: false, startedAt: 0, name: "",
                        status: .unknown, pid: nil, id: nil, waitingFor: "p")
                ])
        #expect(!list.partial)
    }

    @Test("an entry with no PID, a null PID or no other field stays")
    func missingFields() {
        let list = AgentList(output: 
            #"[{"sessionId":"a"},{"sessionId":"b","pid":null,"status":null,"id":null}]"#)
        #expect(ids(list) == ["a", "b"])
        #expect(list.entries.allSatisfy { $0.pid == nil && $0.id == nil && $0.status == .unknown })
        #expect(!list.partial)
    }

    @Test(
        "a PID that is not a whole number is not read",
        arguments: [#""pid":1.5"#, #""pid":1e400"#, #""pid":"7""#, #""pid":true"#])
    func badPid(field: String) {
        let list = AgentList(output: "[{\"sessionId\":\"a\",\(field)}]")
        #expect(ids(list) == ["a"])
        #expect(list.entries.first?.pid == nil)
    }

    @Test(arguments: [
            #""startedAt":1.5"#, #""startedAt":1e400"#, #""startedAt":true"#,
            #""startedAt":"5""#, #""startedAt":null"#,
        ])
    func badStartedAt(field: String) {
        let list = AgentList(output: "[{\"sessionId\":\"a\",\(field)}]")
        #expect(ids(list) == ["a"])
        #expect(list.entries.first?.startedAt == 0)
    }

    @Test
    func wholeNumbersStay() {
        let list = AgentList(output: 
            #"[{"sessionId":"a","startedAt":-1,"pid":0},{"sessionId":"b","pid":-1}]"#)
        #expect(list.entries.map(\.startedAt) == [-1, 0])
        #expect(list.entries.map(\.pid) == [0, -1])
    }

    @Test(
        "a status reads as busy, waiting, idle or unknown",
        arguments: [
            (#""busy""#, AgentStatus.busy), (#""waiting""#, .waiting), (#""idle""#, .idle),
            (#""unknown""#, .unknown), (#""""#, .unknown), (#""weird""#, .unknown),
            (#""Busy""#, .unknown), (#""IDLE""#, .unknown), (#"" idle""#, .unknown),
            ("5", .unknown), ("null", .unknown),
        ])
    func status(value: String, status: AgentStatus) {
        let list = AgentList(output: "[{\"sessionId\":\"a\",\"status\":\(value)}]")
        #expect(list.entries.map(\.status) == [status])
    }

    @Test(
        "only the kind background is a background job",
        arguments: [
            (#""background""#, true), (#""interactive""#, false), (#""""#, false),
            (#""Background""#, false), ("5", false), ("null", false),
        ])
    func kind(value: String, isBackground: Bool) {
        let list = AgentList(output: "[{\"sessionId\":\"a\",\"kind\":\(value)}]")
        #expect(list.entries.map(\.isBackground) == [isBackground])
        #expect(AgentList(output: #"[{"sessionId":"a"}]"#).entries.first?.isBackground == false)
    }

    @Test("an unknown key is ignored, also the prototype key")
    func unknownKeys() {
        let list = AgentList(output: 
            #"[{"__proto__":{"sessionId":"x"},"sessionId":"y","extra":[1,2]}]"#)
        #expect(ids(list) == ["y"])
    }

    // A line break is an unsafe character, so a cwd with one is no folder.
    @Test("escapes in a session ID read as they are, and a line break in a cwd gives no folder")
    func escapes() {
        let list = AgentList(output: #"[{"sessionId":"é😀","cwd":"/p\n"}]"#)
        #expect(ids(list) == ["é😀"])
        #expect(list.entries.first?.cwd == "")
    }

    @Test("the entries of a real output keep their order and values")
    func realShape() {
        let list = AgentList(output: 
            """
            [
              {"cwd":"/w/alpha","kind":"interactive","name":"alpha","pid":16162,\
            "sessionId":"6fbb3984-0577-4bbb-83a3-001285414f93","startedAt":1793957986743,\
            "status":"busy"},
              {"cwd":"/w/beta","id":"6df6c51a","kind":"background","name":"beta","pid":26100,\
            "sessionId":"6df6c51a-76d6-4042-8979-34fb97655792","startedAt":1793957986800,\
            "status":"waiting","waitingFor":"approval"}
            ]
            """)
        #expect(list.error == nil)
        #expect(!list.partial)
        #expect(
            list.entries == [
                AgentEntry(
                    sessionId: "6fbb3984-0577-4bbb-83a3-001285414f93", cwd: "/w/alpha",
                    isBackground: false, startedAt: 1_793_957_986_743, name: "alpha",
                    status: .busy, pid: 16162, id: nil, waitingFor: nil),
                AgentEntry(
                    sessionId: "6df6c51a-76d6-4042-8979-34fb97655792", cwd: "/w/beta",
                    isBackground: true, startedAt: 1_793_957_986_800, name: "beta",
                    status: .waiting, pid: 26100, id: "6df6c51a", waitingFor: "approval"),
            ])
    }

    // The registry keeps a session ID in lower case, so the row of a session and its chat panel
    // have one ID. A session ID that is not a UUID stays as it is.
    @Test func anUpperCaseSessionIDIsKeptInLowerCase() {
        let list = AgentList(output: 
            #"[{"sessionId":"6FBB3984-0577-4BBB-83A3-001285414F93"},{"sessionId":"Not-A-UUID"}]"#)
        #expect(ids(list) == ["6fbb3984-0577-4bbb-83a3-001285414f93", "Not-A-UUID"])
    }
}

// The reason of a failed session list. The Overview shows its message, and the log gets its
// detail, because a detail can hold a path or the text of claude.
@Suite("the reason of a failed session list")
struct AgentListErrorTests {
    @Test(arguments: [
        AgentListError.emptyOutput, .noArray, .notAnArray,
        .badJSON(detail: "Unexpected character 'x' around line 1, column 2."),
        .commandFailed(detail: "/Users/someone/.local/bin/claude: boom"), .claudeNotFound,
    ])
    func theMessageIsASentenceWithNoDetail(error: AgentListError) {
        #expect(error.message.hasPrefix("Bifrost can't"))
        #expect(error.message.hasSuffix("."))
        for raw in ["Unexpected", "boom", "/", "parse error", "claude not found"] {
            #expect(!error.message.contains(raw))
        }
    }

    // The name and waitingFor lose each unsafe character. A cwd with one is no folder: a clean
    // would name another folder.
    @Test func theTextsOfAnEntryAreCleanAndAFolderWithAnUnsafeCharacterIsEmpty() {
        let output = #"[{"sessionId":"a","name":"x\u202Ey","waitingFor":"ok\u2028?","#
            + #""cwd":"/p\u202E"},{"sessionId":"b","cwd":"/q"}]"#
        let entries = AgentList(output: output).entries
        #expect(entries.map(\.name) == ["xy", ""])
        #expect(entries.first?.waitingFor == "ok?")
        #expect(entries.map(\.cwd) == ["", "/q"])
    }
}
