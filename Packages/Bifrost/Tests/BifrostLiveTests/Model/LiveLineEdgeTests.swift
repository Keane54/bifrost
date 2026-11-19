import BifrostFoundation
import BifrostLive
import BifrostSessions
import Foundation
import Testing

// The edge cases of a Live details line: the forms of each field of the header, the usage
// fields and the cuts. Each case is a small line with the value that matters.

private let S = "73b5ca76-a4a8-4f97-9764-e41657296414"
private let R = 1_794_016_800_000

private func json(_ fields: [String: JSONValue]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try? encoder.encode(JSONValue.object(fields))
    return String(decoding: data ?? Data(), as: UTF8.self)
}

// A turn.start line with the header values of the arguments. A nil value leaves the key out.
private func header(
    v: JSONValue? = 1, sid: JSONValue? = .string(S), at: JSONValue? = .int(R),
    seq: JSONValue? = 3, kind: JSONValue = "turn.start"
) -> String {
    var fields: [String: JSONValue] = ["kind": kind]
    fields["v"] = v
    fields["sid"] = sid
    fields["at"] = at
    fields["seq"] = seq
    return json(fields)
}

private func state(_ text: String) -> HookEvent? {
    guard case .state(let event)? = LiveEvent(line: text, receivedAt: R) else { return nil }
    return event
}

private func usage(_ extra: [String: JSONValue]) -> LiveUsage? {
    var fields: [String: JSONValue] = ["v": 1, "sid": .string(S), "at": .int(R), "kind": "usage"]
    fields.merge(extra) { _, new in new }
    guard case .usage(_, _, let usage)? = LiveEvent(line: json(fields), receivedAt: R) else {
        return nil
    }
    return usage
}

private let x4000 = String(repeating: "x", count: 4000)
private let answerCases: [(String, String?)] = [
    ("", nil), ("ALPHA", "ALPHA"), ("1\n2", "1\n2"), (x4000, x4000),
    (x4000 + "x", x4000),
    (String(repeating: "😀", count: 4001), String(repeating: "😀", count: 4000)),
    (
        String(repeating: "x", count: 3999) + "e\u{301}z",
        String(repeating: "x", count: 3999) + "e\u{301}"
    ),
]

@Suite("a Live details line: the header")
struct LiveHeaderEdgeTests {
    @Test(
        "a line that is not a JSON object gives no event",
        arguments: ["not json", "", "[]", "null", "7", "\"x\"", "{\"v\":1", "{\"v\":1}}", "{} x"])
    func notObject(text: String) {
        #expect(LiveEvent(line: text, receivedAt: R) == nil)
    }

    @Test(
        "the version must be the number 1",
        arguments: [
            (JSONValue?.some(1), true), (.some(2), false), (.some(0), false), (.some(-1), false),
            (.some(1.5), false), (.some("1"), false), (.some(true), false), (.some(.null), false),
            (nil, false),
        ])
    func version(v: JSONValue?, accepted: Bool) {
        #expect((state(header(v: v)) != nil) == accepted)
    }

    @Test(
        "the session ID must be a UUID in any letter case",
        arguments: [
            (JSONValue?.some(.string(S)), true),
            (.some("a1b2c3d4-0000-4000-8000-000000000001"), true),
            (.some("ffffffff-ffff-4fff-bfff-ffffffffffff"), true),
            (.some("73B5CA76-A4A8-4F97-9764-E41657296414"), true),
            (.some("abc"), false), (.some(""), false),
            (.some("73b5ca76a4a84f979764e41657296414"), false),
            (.some("73b5ca76-a4a8-4f97-9764-e4165729641"), false),
            (.some("73b5ca76-a4a8-4f97-9764-e41657296414 "), false),
            (.some("g3b5ca76-a4a8-4f97-9764-e41657296414"), false), (.some(7), false),
            (.some(.null), false), (nil, false),
        ])
    func sessionId(sid: JSONValue?, accepted: Bool) {
        #expect((state(header(sid: sid)) != nil) == accepted)
    }

    // A time after the receipt gives the receipt time (L4).
    @Test(
        "the send time stays up to 10 s before the receive time, or the receive time is used",
        arguments: [
            // (at, expected time of the event)
            (JSONValue.int(R), R), (.int(R + 1), R), (.int(R + 9_999), R),
            (.int(R - 9_999), R - 9_999), (.int(R + 10_000), R), (.int(R - 10_000), R - 10_000),
            (.int(R + 10_001), R), (.int(R - 10_001), R), (.int(R + 1_000_000_000), R),
            (.int(0), R), (.int(-1), R),
            (.double(R.asDouble + 10_000.5), R), (.double(R.asDouble - 10_000.5), R),
            // A fraction inside the drift gives the whole millisecond toward zero (L3).
            (.double(R.asDouble + 0.5), R), (.double(R.asDouble + 9_999.9), R),
            (.double(R.asDouble - 0.5), R - 1), (.double(R.asDouble - 9_999.9), R - 10_000),
            (.double(1.5), R), (.double(1e300), R), (.double(-1e300), R),
            (.double(Double.greatestFiniteMagnitude), R),
        ])
    func sendTime(at: JSONValue, expected: Int) {
        #expect(state(header(at: at))?.at == expected)
    }

    @Test(
        arguments: [JSONValue?.some("1000"), .some(.null), .some(true), .some([]), .some([:]), nil])
    func sendTimeBad(at: JSONValue?) {
        #expect(state(header(at: at)) == nil)
    }

    @Test(
        "a seq stays when it is a whole number of 0 or more in the Int range",
        arguments: [
            (JSONValue.int(0), Int?.some(0)), (.int(5000), 5000),
            (.int(9_007_199_254_740_991), 9_007_199_254_740_991),
            (.int(9_007_199_254_740_992), 9_007_199_254_740_992), (.int(Int.max), Int.max),
            (.int(-1), nil), (.double(1.5), nil), (.double(1e19), nil), (.double(1e20), nil),
            (.string("3"), nil), (.null, nil), (.bool(true), nil),
        ])
    func seq(seq: JSONValue, expected: Int?) {
        let event = state(header(seq: seq))
        #expect(event != nil)
        #expect(event?.seq == expected)
    }

    @Test("a line with no seq gives an event with no seq")
    func noSeq() {
        #expect(state(header(seq: nil))?.seq == nil)
    }

    @Test(
        "each state kind gives its event name",
        arguments: [
            ("session.start", HookEventName.sessionStart, [String: JSONValue]()),
            ("session.end", .sessionEnd, ["reason": "clear"]),
            ("turn.start", .userPromptSubmit, [:]), ("ask", .preToolUse, [:]),
            ("tool.done", .postToolUse, ["tool": "Read"]),
            ("permission", .permissionRequest, ["tool": "Bash"]),
            ("turn.complete", .stop, ["reason": "answer", "answer": "A"]),
            ("stop.failure", .stopFailure, [:]),
        ])
    func kinds(kind: String, name: HookEventName, extra: [String: JSONValue]) {
        var fields: [String: JSONValue] = [
            "v": 1, "sid": .string(S), "at": .int(R), "kind": .string(kind),
        ]
        fields.merge(extra) { _, new in new }
        guard case .state(let event)? = LiveEvent(line: json(fields), receivedAt: R) else {
            Issue.record("no event for \(kind)")
            return
        }
        #expect(event.name == name)
    }

    @Test(
        "an unknown kind gives no event",
        arguments: [
            JSONValue.string("hello"), "", "Usage", "turn.Start", "session.start ", 7, .null,
        ])
    func badKind(kind: JSONValue) {
        #expect(state(header(kind: kind)) == nil)
    }
}

@Suite("a Live details line: the texts of a state")
struct LiveStateTextEdgeTests {
    private func complete(reason: JSONValue, answer: JSONValue?) -> HookEvent? {
        var fields: [String: JSONValue] = [
            "v": 1, "sid": .string(S), "at": .int(R), "kind": "turn.complete", "reason": reason,
        ]
        fields["answer"] = answer
        return state(json(fields))
    }

    @Test(
        "each turn complete reason gives its event",
        arguments: [
            ("answer", HookEventName?.some(.stop)), ("refusal", .some(.stop)),
            ("aborted", .some(.turnAborted)), ("error", .some(.stopFailure)),
            ("other", nil), ("Answer", nil),
        ])
    func completeReasons(reason: String, expected: HookEventName?) {
        #expect(complete(reason: .string(reason), answer: "A")?.name == expected)
    }

    @Test
    func completeReasonNotText() {
        #expect(complete(reason: 7, answer: "A") == nil)
    }

    @Test(
        "the answer stays up to 4000 characters and an empty answer is no message",
        arguments: answerCases)
    func answer(text: String, expected: String?) {
        #expect(complete(reason: "answer", answer: .string(text))?.lastAssistantMessage == expected)
    }

    @Test(
        "a tool name stays up to 200 characters and a bad one gives no event",
        arguments: [
            (JSONValue?.some("Read"), true), (.some("AskUserQuestion"), true),
            (.some("mcp__docs__read"), true), (.some(""), true), (.some(7), false),
            (.some(.null), false), (.some(true), false), (.some([]), false), (nil, false),
        ])
    func toolName(tool: JSONValue?, accepted: Bool) {
        var fields: [String: JSONValue] = [
            "v": 1, "sid": .string(S), "at": .int(R), "kind": "tool.done",
        ]
        fields["tool"] = tool
        #expect((state(json(fields)) != nil) == accepted)
    }

    @Test(
        "a tool name over 200 characters is cut by characters",
        arguments: [
            (String(repeating: "x", count: 200), String(repeating: "x", count: 200)),
            (String(repeating: "x", count: 201), String(repeating: "x", count: 200)),
            (String(repeating: "😀", count: 201), String(repeating: "😀", count: 200)),
            (
                String(repeating: "x", count: 199) + "e\u{301}x",
                String(repeating: "x", count: 199) + "e\u{301}"
            ),
            (
                String(repeating: "x", count: 199) + "👨\u{200D}👩\u{200D}👧x",
                String(repeating: "x", count: 199) + "👨\u{200D}👩\u{200D}👧"
            ),
            (String(repeating: "x", count: 199) + "🇬🇧x", String(repeating: "x", count: 199) + "🇬🇧"),
            // The clean takes the line break away before the cut (cleanText).
            (String(repeating: "x", count: 199) + "\r\nx", String(repeating: "x", count: 200)),
        ])
    func toolCut(text: String, expected: String) {
        let fields: [String: JSONValue] = [
            "v": 1, "sid": .string(S), "at": .int(R), "kind": "tool.done", "tool": .string(text),
        ]
        #expect(state(json(fields))?.toolName == expected)
    }

    @Test("a field of another kind does not change the event")
    func otherFields() {
        let fields: [String: JSONValue] = [
            "v": 1, "sid": .string(S), "at": .int(R), "kind": "turn.start", "answer": "x",
            "tool": "Read", "reason": "clear",
        ]
        #expect(state(json(fields)) == HookEvent(.userPromptSubmit, S, at: R))
    }
}

@Suite("a Live details line: the usage fields")
struct LiveUsageEdgeTests {
    @Test(
        "context percent, tokens and window stay when they pass their checks",
        arguments: [
            ("percent", JSONValue.int(0), Double?.some(0)), ("percent", .int(6), 6),
            ("percent", .double(6.5), 6.5), ("percent", .int(100), 100),
            ("percent", .double(100.5), nil), ("percent", .double(-0.1), nil),
            ("percent", .string("6"), nil), ("percent", .null, nil),
        ])
    func contextPercent(key: String, value: JSONValue, expected: Double?) {
        let result = usage(["context": ["percent": value]])
        #expect(result != nil)
        #expect(result?.contextPercent == expected)
    }

    @Test(
        "context tokens stay for a whole number of 0 or more in the Int range",
        arguments: [
            (JSONValue.int(0), Int?.some(0)), (.int(58151), 58151),
            (.int(9_007_199_254_740_992), 9_007_199_254_740_992), (.int(Int.max), Int.max),
            (.int(-1), nil), (.double(1.5), nil), (.string("5"), nil), (.null, nil),
            (.double(1e19), nil),
        ])
    func contextTokens(value: JSONValue, expected: Int?) {
        #expect(usage(["context": ["tokens": value]])?.contextTokens == expected)
    }

    @Test(
        "a context window stays for a whole number of 1 or more",
        arguments: [
            (JSONValue.int(1), Int?.some(1)), (.int(200_000), 200_000),
            (.int(1_000_000), 1_000_000), (.double(1e18), 1_000_000_000_000_000_000),
            (.int(0), nil), (.int(-1), nil), (.double(-0.5), nil), (.string("1"), nil),
            (.null, nil),
            // A window that is not a whole number in the Int range goes (L3).
            (.double(1.5), nil), (.double(1e19), nil),
        ])
    func contextWindow(value: JSONValue, expected: Int?) {
        #expect(usage(["context": ["window": value]])?.contextWindow == expected)
    }

    @Test(
        "a context that is not an object is left out",
        arguments: [JSONValue.string("x"), .array([]), .null, .int(7)])
    func contextBad(value: JSONValue) {
        let result = usage(["context": value])
        #expect(result != nil)
        #expect(result?.contextPercent == nil)
        #expect(result?.contextTokens == nil)
    }

    @Test(
        "a cost stays for a number of 0 or more",
        arguments: [
            (JSONValue.int(0), Double?.some(0)), (.double(0.00691591), 0.00691591),
            (.double(12.5), 12.5), (.double(1e300), 1e300), (.int(-1), nil), (.string("1"), nil),
            (.null, nil),
        ])
    func cost(value: JSONValue, expected: Double?) {
        #expect(usage(["costUsd": value])?.costUsd == expected)
    }

    @Test(
        "a rate item gives its window by kind and a bad percent drops the item",
        arguments: [
            ("five_hour", JSONValue.double(42.5), true), ("seven_day", .int(99), true),
            ("five_hour", .int(0), true), ("five_hour", .int(100), true),
            ("five_hour", .int(101), false), ("five_hour", .int(-1), false),
            ("five_hour", .string("5"), false), ("five_hour", .null, false),
            ("spend_limit", .int(5), false), ("", .int(5), false),
        ])
    func rateItem(kind: String, percent: JSONValue, kept: Bool) {
        let item: JSONValue = [
            "kind": .string(kind), "percentUsed": percent, "resetsAt": "2026-11-07T02:00:00Z",
        ]
        let limits = usage(["rateLimits": [item]])?.rateLimits
        let window = kind == "seven_day" ? limits?.sevenDay : limits?.fiveHour
        #expect((window != nil) == kept)
    }

    @Test(arguments: [JSONValue.string("x"), .object([:]), .null, .int(7)])
    func rateLimitsBad(value: JSONValue) {
        #expect(usage(["rateLimits": value])?.rateLimits == nil)
        let mixed = usage(["rateLimits": [.null, .int(7), .string("x"), .array([])]])
        #expect(mixed != nil)
        #expect(mixed?.rateLimits?.fiveHour == nil)
        #expect(mixed?.rateLimits?.sevenDay == nil)
    }

    @Test(
        "a text field stays up to 200 characters and an empty or bad one drops out",
        arguments: ["model", "version", "effort", "permissionMode"])
    func shortTexts(key: String) {
        func read(_ value: JSONValue) -> String? {
            guard let result = usage([key: value]) else { return nil }
            switch key {
            case "model": return result.model
            case "version": return result.version
            case "effort": return result.effort
            default: return result.permissionMode
            }
        }
        #expect(read("x") == "x")
        #expect(
            read(.string(String(repeating: "x", count: 200))) == String(repeating: "x", count: 200))
        #expect(
            read(.string(String(repeating: "😀", count: 201))) == String(repeating: "😀", count: 200))
        #expect(read("") == nil)
        for bad in [JSONValue.int(7), .null, .bool(true), .array([]), .object([:])] {
            #expect(read(bad) == nil)
        }
    }

    // An unsafe character (isUnsafeInText) is a control, a separator, a bidi control or mark, or
    // a default-ignorable character such as U+200B.
    @Test(
        "a transcript path stays when it is absolute and has no unsafe character",
        arguments: [
            ("/h/.claude/projects/p/S.jsonl", true),
            ("/Users/dev-user/Mes projets été/日本/S.jsonl", true),
            ("rel/p.jsonl", false), ("", false), ("/", true),
            // The first byte is the slash. With a combining mark, the two are one Character.
            ("/\u{301}x.jsonl", true),
            ("/" + String(repeating: "p", count: 1023), true),
            ("/" + String(repeating: "p", count: 1024), false),
            ("/" + String(repeating: "😀", count: 511) + "x", true),
            ("/" + String(repeating: "😀", count: 512), false),
            ("/h/p\u{0}x.jsonl", false), ("/h/p\u{7}x.jsonl", false), ("/h/p\nx.jsonl", false),
            ("/h/p\rx.jsonl", false), ("/h/p\u{1B}x.jsonl", false), ("/h/p\u{1F}x.jsonl", false),
            ("/h/p\u{7F}x.jsonl", false), ("/h/p\u{202A}x.jsonl", false),
            ("/h/p\u{202E}x.jsonl", false), ("/h/p\u{2066}x.jsonl", false),
            ("/h/p\u{2067}x.jsonl", false), ("/h/p\u{2069}x.jsonl", false),
            ("/h/p\u{200B}x.jsonl", false), ("/h/p\u{2028}x.jsonl", false),
            ("/h/p\u{85}x.jsonl", false), ("/h/p\u{E0041}x.jsonl", false),
            ("/h/p\u{AD}x.jsonl", false), ("/h/p\u{200D}x.jsonl", true),
            ("/h/p\u{FE0F}x.jsonl", true),
        ])
    func transcriptPath(path: String, kept: Bool) {
        let result = usage(["transcriptPath": .string(path)])
        #expect(result != nil)
        #expect((result?.transcriptPath != nil) == kept)
    }
}

extension Int {
    fileprivate var asDouble: Double { Double(self) }
}

// A line with a time in the future cannot hide the later events of its session: its time is the
// receipt time, so the registry applies a real event that comes after it.
@Test func aLineWithATimeAheadDoesNotHideALaterRealEvent() throws {
    let sid = "73b5ca76-a4a8-4f97-9764-e41657296414"
    var registry = SessionRegistry(store: RegistryStore(), escalation: .seconds(600))
    registry.applyAgents(
        [AgentEntry(sessionId: sid, cwd: "/p", isBackground: true, startedAt: 1, pid: 4242)],
        sampledAt: R - 60_000)
    let forged = #"{"v":1,"sid":"\#(sid)","at":\#(R + 10_000),"seq":9,"kind":"turn.complete","#
        + #""reason":"answer","answer":"x"}"#
    guard case .state(let first)? = LiveEvent(line: forged, receivedAt: R) else {
        Issue.record("no event")
        return
    }
    #expect(first.at == R)
    registry.applyEvents([first], now: R)
    let real = #"{"v":1,"sid":"\#(sid)","at":\#(R + 1_000),"seq":1,"kind":"turn.start"}"#
    guard case .state(let second)? = LiveEvent(line: real, receivedAt: R + 1_000) else {
        Issue.record("no event")
        return
    }
    registry.applyEvents([second], now: R + 1_000)
    #expect(registry.rows().first?.state == .working)
}

// Each text of a line loses its hidden characters, and the answer keeps its lines.
@Test func theTextsOfALineAreClean() throws {
    let sid = "73b5ca76-a4a8-4f97-9764-e41657296414"
    let tool = #"{"v":1,"sid":"\#(sid)","at":\#(R),"seq":1,"kind":"tool.done","#
        + #""tool":"Ba\u202Esh\u001b[2J"}"#
    guard case .state(let done)? = LiveEvent(line: tool, receivedAt: R) else {
        Issue.record("no event")
        return
    }
    #expect(done.toolName == "Bash[2J")
    let answer = #"{"v":1,"sid":"\#(sid)","at":\#(R),"seq":2,"kind":"turn.complete","#
        + #""reason":"answer","answer":"line 1\n\tline 2\u2028\u200F"}"#
    guard case .state(let stop)? = LiveEvent(line: answer, receivedAt: R) else {
        Issue.record("no event")
        return
    }
    #expect(stop.lastAssistantMessage == "line 1\n\tline 2")
    let usage = #"{"v":1,"sid":"\#(sid)","at":\#(R),"seq":3,"kind":"usage","#
        + #""model":"\u0085\u2066","effort":"hi\u0007gh"}"#
    guard case .usage(_, _, let values)? = LiveEvent(line: usage, receivedAt: R) else {
        Issue.record("no usage")
        return
    }
    #expect(values.model == nil)
    #expect(values.effort == "high")
}
