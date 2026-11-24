import BifrostFoundation
import BifrostLive
import BifrostSessions
import Foundation
import Testing

// The lines of the Live details mod: each kind and each bad field, and the Swift rules of
// docs/ports/live/DELIBERATE-DIFFERENCES.md. LiveLineEdgeTests has the edge cases of each field.

private let S = "73b5ca76-a4a8-4f97-9764-e41657296414"
private let R = 1005

// The JSON text of a line: at 1000, seq 3, the session S and v 1, then the fields.
private func line(_ fields: [String: JSONValue]) -> String {
    let base: [String: JSONValue] = ["at": 1000, "seq": 3, "sid": .string(S), "v": 1]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(JSONValue.object(base.merging(fields) { _, new in new })))
    return String(decoding: data ?? Data(), as: UTF8.self)
}

private func parse(_ text: String) -> LiveEvent? { LiveEvent(line: text, receivedAt: R) }

private func stateEvent(_ text: String) -> HookEvent? {
    guard case .state(let event)? = parse(text) else { return nil }
    return event
}

private func usage(_ text: String) -> LiveUsage? {
    guard case .usage(_, _, let usage)? = parse(text) else { return nil }
    return usage
}

// A state event of the session S at 1000 with seq 3.
private func state(
    _ name: HookEventName, tool: String? = nil, message: String? = nil, reason: String? = nil
) -> LiveEvent {
    .state(
        HookEvent(
            name, S, at: 1000, seq: 3, toolName: tool, lastAssistantMessage: message,
            reason: reason))
}

// Date.parse('2026-11-07T02:00:00.000Z').
private let resetMs = 1_794_016_800_000
private let resetsAt: JSONValue = "2026-11-07T02:00:00.000Z"

// A usage line with a good value in each field, and its result.
private let goodContext: [String: JSONValue] = ["percent": 6, "tokens": 58151, "window": 1_000_000]
private let usageFields: [String: JSONValue] = [
    "kind": "usage", "model": "claude-haiku-5-5", "context": .object(goodContext),
    "costUsd": 0.00691591,
    "rateLimits": [
        ["kind": "five_hour", "percentUsed": 42.5, "resetsAt": resetsAt],
        ["kind": "seven_day", "percentUsed": 15, "resetsAt": resetsAt],
    ],
    "version": "2.1.318", "effort": "xhigh", "permissionMode": "plan",
    "transcriptPath": "/h/.claude/projects/p/S.jsonl",
]
private let fullUsage = LiveUsage(
    model: "claude-haiku-5-5", contextPercent: 6, contextTokens: 58151,
    contextWindow: 1_000_000, costUsd: 0.00691591,
    rateLimits: RateLimits(
        fiveHour: RateWindow(usedPercent: 42.5, resetsAt: resetMs),
        sevenDay: RateWindow(usedPercent: 15, resetsAt: resetMs)),
    version: "2.1.318", effort: "xhigh", permissionMode: "plan",
    transcriptPath: "/h/.claude/projects/p/S.jsonl")

// The usage line with the changed fields, and the usage result with the change.
private func badUsage(
    _ fields: [String: JSONValue], _ change: (inout LiveUsage) -> Void
) -> ([String: JSONValue], LiveEvent?) {
    var expected = fullUsage
    change(&expected)
    return (usageFields.merging(fields) { _, new in new }, .usage(sessionId: S, at: 1000, expected))
}

// The good context with the changed fields.
private func context(_ fields: [String: JSONValue]) -> [String: JSONValue] {
    ["context": .object(goodContext.merging(fields) { _, new in new })]
}

// Each kind with good fields, then each bad field. A bad header or a bad field of a state kind
// drops the line. A bad seq, a bad answer and a bad usage field go, and the line stays.
private let kindRows: [([String: JSONValue], LiveEvent?)] = [
    (["kind": "session.start"], state(.sessionStart)),
    (["kind": "session.end", "reason": "clear"], state(.sessionEnd, reason: "clear")),
    (["kind": "session.end", "reason": "logout"], state(.sessionEnd, reason: "logout")),
    (["kind": "turn.start"], state(.userPromptSubmit)),
    (["kind": "ask"], state(.preToolUse, tool: "AskUserQuestion")),
    (["kind": "tool.done", "tool": "Read"], state(.postToolUse, tool: "Read")),
    (["kind": "permission", "tool": "Bash"], state(.permissionRequest, tool: "Bash")),
    (
        ["answer": "ALPHA", "kind": "turn.complete", "reason": "answer"],
        state(.stop, message: "ALPHA")
    ),
    (["answer": "NO", "kind": "turn.complete", "reason": "refusal"], state(.stop, message: "NO")),
    (["answer": "", "kind": "turn.complete", "reason": "answer"], state(.stop)),
    (
        ["answer": "1\n2", "kind": "turn.complete", "reason": "aborted"],
        state(.turnAborted, message: "1\n2")
    ),
    (["answer": "A", "kind": "turn.complete", "reason": "error"], state(.stopFailure)),
    (["error": "boom", "kind": "stop.failure"], state(.stopFailure)),
    (["kind": "stop.failure"], state(.stopFailure)),
    (usageFields, .usage(sessionId: S, at: 1000, fullUsage)),
    (["kind": "usage"], .usage(sessionId: S, at: 1000, LiveUsage())),
    (["kind": "prompt", "person": true], .prompt(sessionId: S, at: 1000, person: true)),
    (["kind": "prompt", "person": false], .prompt(sessionId: S, at: 1000, person: false)),
    // The header.
    (["kind": "turn.start", "v": 2], nil),
    (["kind": "turn.start", "sid": "abc"], nil),
    (["at": "x", "kind": "turn.start"], nil),
    ([:], nil),
    (["kind": "hello"], nil),
    (["kind": "turn.start", "seq": -1], .state(HookEvent(.userPromptSubmit, S, at: 1000))),
    (["kind": "turn.start", "seq": 1.5], .state(HookEvent(.userPromptSubmit, S, at: 1000))),
    // The fields of a state kind.
    (["kind": "session.end"], nil),
    (["kind": "session.end", "reason": 7], nil),
    (["kind": "tool.done"], nil),
    (["kind": "tool.done", "tool": .null], nil),
    (["kind": "permission"], nil),
    (["kind": "permission", "tool": 7], nil),
    (["answer": "A", "kind": "turn.complete"], nil),
    (["answer": "A", "kind": "turn.complete", "reason": "other"], nil),
    (["answer": "A", "kind": "turn.complete", "reason": 7], nil),
    (["answer": 7, "kind": "turn.complete", "reason": "answer"], state(.stop)),
    // The flag of a prompt line is a JSON true or false.
    (["kind": "prompt"], nil),
    (["kind": "prompt", "person": "true"], nil),
    (["kind": "prompt", "person": 1], nil),
    (["kind": "prompt", "person": .null], nil),
    // The fields of a usage line.
    badUsage(["model": 7]) { $0.model = nil },
    badUsage(["model": ""]) { $0.model = nil },
    badUsage(["context": "x"]) {
        $0.contextPercent = nil
        $0.contextTokens = nil
        $0.contextWindow = nil
    },
    badUsage(context(["percent": 101])) { $0.contextPercent = nil },
    badUsage(context(["tokens": -1])) { $0.contextTokens = nil },
    badUsage(context(["window": 0])) { $0.contextWindow = nil },
    badUsage(["costUsd": -1]) { $0.costUsd = nil },
    badUsage(["costUsd": "1"]) { $0.costUsd = nil },
    badUsage(["rateLimits": "x"]) { $0.rateLimits = nil },
    badUsage(["rateLimits": [["kind": "seven_day", "percentUsed": 15, "resetsAt": "soon"]]]) {
        $0.rateLimits = nil
    },
    badUsage(["rateLimits": [["kind": "spend_limit", "percentUsed": 5, "resetsAt": resetsAt]]]) {
        $0.rateLimits = nil
    },
    badUsage(["rateLimits": [["kind": "five_hour", "percentUsed": 101, "resetsAt": resetsAt]]]) {
        $0.rateLimits = nil
    },
    badUsage(["version": ""]) { $0.version = nil },
    badUsage(["effort": .null]) { $0.effort = nil },
    badUsage(["permissionMode": 3]) { $0.permissionMode = nil },
    badUsage(["transcriptPath": "rel/p.jsonl"]) { $0.transcriptPath = nil },
    badUsage(["transcriptPath": 42]) { $0.transcriptPath = nil },
]

@Suite("Live line parsing")
struct LiveLineTests {
    @Test(arguments: kindRows)
    func eachKindAndEachBadField(fields: [String: JSONValue], expected: LiveEvent?) {
        #expect(parse(line(fields)) == expected)
    }

    // A later good window of the same kind replaces an earlier one. A bad item does not.
    @Test func theLastGoodWindowOfAKindStays() {
        let text = line([
            "kind": "usage",
            "rateLimits": [
                ["kind": "five_hour", "percentUsed": 10, "resetsAt": resetsAt],
                ["kind": "five_hour", "percentUsed": 20, "resetsAt": resetsAt],
                ["kind": "five_hour", "percentUsed": 30, "resetsAt": "soon"],
                .null, 7,
            ],
        ])
        let expected = RateLimits(fiveHour: RateWindow(usedPercent: 20, resetsAt: resetMs))
        #expect(usage(text)?.rateLimits == expected)
    }

    // JSON has one number type. 1.0 and 1e0 are 1, and -0 is a zero.
    @Test func eachFormOfAJSONNumberGivesTheSameValue() {
        let sid = "\"sid\":\"\(S)\""
        let text = "{\"v\":1.0,\(sid),\"at\":1.0e3,\"seq\":3.0,\"kind\":\"turn.start\"}"
        #expect(parse(text) == .state(HookEvent(.userPromptSubmit, S, at: 1000, seq: 3)))
        let other = "{\"v\":1e0,\(sid),\"at\":1000,\"seq\":-0,\"kind\":\"turn.start\"}"
        #expect(stateEvent(other)?.seq == 0)
        let tokens = "{\"v\":1,\(sid),\"at\":1000,\"kind\":\"usage\",\"context\":{\"tokens\":-0}}"
        #expect(usage(tokens)?.contextTokens == 0)
    }

    // L1: the mod cuts an answer at 4,000 UTF-16 units, so a cut can split a surrogate pair.
    // JSON.stringify writes the lone half as an escape. JSONDecoder refuses such an escape, so
    // the parse first makes it U+FFFD. The Stop event then stays.
    @Test func aLoneSurrogateEscapeBecomesAReplacementCharacter() {
        let head = "{\"v\":1,\"sid\":\"\(S)\",\"at\":1000,\"kind\":\"turn.complete\""
        let cut = head + ",\"reason\":\"answer\",\"answer\":\"ab\\ud83d\"}"
        let stop = HookEvent(.stop, S, at: 1000, lastAssistantMessage: "ab\u{FFFD}")
        #expect(stateEvent(cut) == stop)
        let low = head + ",\"reason\":\"answer\",\"answer\":\"\\uDE00x\\ud83d\\u0041\"}"
        #expect(stateEvent(low)?.lastAssistantMessage == "\u{FFFD}x\u{FFFD}A")
        let pair = head + ",\"reason\":\"answer\",\"answer\":\"\\ud83d\\ude00\\uD83D\\uDE00\"}"
        #expect(stateEvent(pair)?.lastAssistantMessage == "😀😀")
        let escaped = head + ",\"reason\":\"answer\",\"answer\":\"\\\\ud83d\"}"
        #expect(stateEvent(escaped)?.lastAssistantMessage == "\\ud83d")
    }

    // The body of a request goes to the decoder as bytes. A byte that is not UTF-8 becomes
    // U+FFFD, and the line stays.
    @Test func aBodyWithABadByteGivesAReplacementCharacter() {
        let head = "{\"v\":1,\"sid\":\"\(S)\",\"at\":1000,\"kind\":\"turn.complete\""
        let body = Array((head + ",\"reason\":\"answer\",\"answer\":\"a").utf8) + [0xFF]
            + Array("b\"}".utf8)
        let event = LiveEvent(body: body, receivedAt: R)
        #expect(event == .state(HookEvent(.stop, S, at: 1000, lastAssistantMessage: "a\u{FFFD}b")))
        #expect(LiveEvent(body: Array(head.utf8), receivedAt: R) == nil)
    }

    // The session ID of a line is kept in lower case, as the registry keeps the ID of a row.
    @Test func anUpperCaseSessionIDIsKeptInLowerCase() {
        let upper = "{\"v\":1,\"sid\":\"\(S.uppercased())\",\"at\":1000,\"kind\":\"turn.start\"}"
        #expect(stateEvent(upper) == HookEvent(.userPromptSubmit, S, at: 1000))
    }

    // V2: a reset time is ISO 8601, as Date.ISO8601FormatStyle reads it. The times of the forms
    // of the mod are the results of Date.parse.
    @Test(arguments: [
            ("2026-11-07T02:00:00.000Z", 1_794_016_800_000),
            ("2026-11-07T02:00:00Z", 1_794_016_800_000),
            ("2026-11-07T02:00:00.1Z", 1_794_016_800_100),
            ("2026-11-07T02:00:00.999Z", 1_794_016_800_999),
            ("2026-11-07T02:00:00.000+02:00", 1_794_009_600_000),
            ("2026-11-07T02:00:00-05:30", 1_794_036_600_000),
            ("2026-11-07T02:00:00.000-00:00", 1_794_016_800_000),
            ("2026-11-07T24:00:00Z", 1_794_096_000_000),
            ("2024-02-29T00:00:00Z", 1_709_164_800_000),
            ("1969-12-31T23:59:59.999Z", -1),
            ("9999-12-31T23:59:59.999Z", 253_402_300_799_999),
            // The other forms of Date.parse give no window.
            ("Sat, 07 Nov 2026 02:00:00 GMT", nil),
            ("2026-11-07", nil),
            ("2026-11-07T02:00Z", nil),
            ("2026-11-07T02:00:00", nil),
            ("2026-11-07t02:00:00z", nil),
            ("2026-11-07 02:00:00Z", nil),
            ("2026-11-07T02:00:00.Z", nil),
            ("2026-11-07T02:00:00,123Z", nil),
            ("٢٠٢٦-11-07T02:00:00Z", nil),
            ("soon", nil),
            ("", nil),
            // The rules of Foundation that differ from Date.parse: a fraction of more than three
            // digits rounds to the nearest millisecond, a time that does not exist moves
            // forward, and an offset of more than 18 hours gives no window.
            ("2026-11-07T02:00:00.1239Z", 1_794_016_800_124),
            ("2026-02-30T00:00:00Z", 1_772_409_600_000),
            ("2026-11-07T23:59:60Z", 1_794_096_000_000),
            ("2026-11-07T02:00:00+19:00", nil),
        ] as [(String, Int?)])
    func aResetTimeIsISO8601(time: String, expected: Int?) {
        let text = line([
            "kind": "usage",
            "rateLimits": [["kind": "five_hour", "percentUsed": 5, "resetsAt": .string(time)]],
        ])
        #expect(usage(text)?.rateLimits?.fiveHour?.resetsAt == expected)
    }

    // L2: the rules of the JSON decoder (S6 of the stores port, D11 of the registry). A number
    // outside the Double range drops only its usage field, as in the old app. In the header, it
    // drops the line.
    @Test func theJSONDecoderReadsTheLine() {
        let head = "{\"v\":1,\"sid\":\"\(S)\",\"kind\":\"usage\""
        #expect(usage(head + ",\"at\":1000,\"costUsd\":1e400}") == LiveUsage())
        #expect(usage(head + ",\"at\":1000,\"other\":1e400,\"costUsd\":1}")?.costUsd == 1)
        #expect(parse(head + ",\"at\":1e400}") == nil)
        #expect(parse(head + ",\"at\":1e-400}") == nil)
        #expect(usage(head + ",\"at\":1000,\"costUsd\":1,\"costUsd\":2}")?.costUsd == 1)
    }
}
