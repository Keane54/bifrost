import BifrostFoundation
import BifrostSessions
import Foundation

// The lines of the Live details mod.
//
// The mod sends one JSON object for each event. Each object has v (always 1), kind, sid, at
// (milliseconds) and seq (the order number of the session). This table is the wire contract with
// the mod. The mod sends facts. This file maps the facts to events.
//
// | kind          | Other fields                                   | Result                       |
// | ------------- | ---------------------------------------------- | ---------------------------- |
// | session.start | none                                           | SessionStart                 |
// | session.end   | reason (string)                                | SessionEnd                   |
// | turn.start    | none                                           | UserPromptSubmit             |
// | ask           | none                                           | PreToolUse (AskUserQuestion) |
// | tool.done     | tool (string)                                  | PostToolUse                  |
// | permission    | tool (string)                                  | PermissionRequest            |
// | turn.complete | reason: answer or refusal, answer (string)     | Stop                         |
// | turn.complete | reason: aborted, answer (string)               | TurnAborted                  |
// | turn.complete | reason: error                                  | StopFailure                  |
// | stop.failure  | error (string, optional)                       | StopFailure                  |
// | usage         | model, context { tokens?, window, percent? },  | usage line                   |
// |               | costUsd?, rateLimits [{ kind, percentUsed,     |                              |
// |               | resetsAt }], version?, effort?,                |                              |
// |               | permissionMode?, transcriptPath?               |                              |
//
// A bad line gives nil. A bad field of a usage line is left out and the line stays. A rate
// limit item needs resetsAt (an ISO 8601 time): an item without it is left out. Each text loses
// its unsafe characters (cleanText); the answer keeps its tabs and line breaks.
// docs/ports/live/DELIBERATE-DIFFERENCES.md lists each place where Swift differs.

package enum LiveLimits {
    package static let version = 1, answerMax = 4000, textMax = 200
    package static let transcriptPathMax = 1024, atDriftMs = 10_000
}

// The one decoder of the lines. A decode does not change its options, so the threads of the
// connections can share it.
private let decoder = JSONDecoder()

extension LiveEvent {
    // Read one line of the mod from the bytes of the body of its request. A byte that is not
    // UTF-8 becomes U+FFFD, and the line stays. receivedAt is the time of receipt in
    // milliseconds. The bytes go to the decoder with one copy: the repair of the UTF-8 and of
    // the lone surrogates runs only when the body needs it.
    package init?(body: some Collection<UInt8>, receivedAt: Int) {
        var bytes = Data(body)
        if !isValidUTF8(bytes) {
            bytes = Data(String(decoding: bytes, as: UTF8.self).utf8)
        }
        if bytes.contains(backslash) { bytes = Data(withoutLoneSurrogates(Array(bytes))) }
        guard let mod = try? decoder.decode(ModLine.self, from: bytes) else { return nil }
        let at = mod.time(receivedAt: receivedAt)
        switch mod.content {
        case .usage(let usage):
            self = .usage(sessionId: mod.sessionId, at: at, usage)
        case .state(let name, let toolName, let message, let reason):
            self = .state(
                HookEvent(
                    name, mod.sessionId, at: at, seq: mod.seq, toolName: toolName,
                    lastAssistantMessage: message, reason: reason))
        }
    }

    // Read one line of the mod from its text.
    package init?(line: String, receivedAt: Int) {
        self.init(body: line.utf8, receivedAt: receivedAt)
    }
}

// MARK: - The line

// One line of the mod. A bad header (v, sid or at), an unknown kind or a bad field of a state
// kind makes the decode fail.
private struct ModLine: Decodable {
    enum Kind: String, Decodable {
        case sessionStart = "session.start", sessionEnd = "session.end"
        case turnStart = "turn.start", ask, toolDone = "tool.done", permission
        case turnComplete = "turn.complete", stopFailure = "stop.failure", usage
    }

    // The reason of a turn.complete line.
    enum Ending: String, Decodable { case answer, refusal, aborted, error }

    // The event of the line with the fields of its kind.
    enum Content {
        case state(
            HookEventName, toolName: String? = nil, message: String? = nil,
            reason: String? = nil)
        case usage(LiveUsage)
    }

    enum Key: String, CodingKey {
        case v, sid, at, seq, kind, reason, tool, answer
        case model, context, costUsd, rateLimits, version, effort, permissionMode, transcriptPath
    }

    let sessionId: String
    // The send time in milliseconds. A JSON number can have a fraction.
    let sentAt: Double
    // A whole number of 0 or more. A bad seq goes, and the line stays.
    let seq: Int?
    let content: Content

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard try c.decode(Int.self, forKey: .v) == LiveLimits.version else {
            throw DecodingError.dataCorruptedError(
                forKey: .v, in: c, debugDescription: "The version is not 1.")
        }
        // The session ID is kept in lower case (SessionID), as the registry keeps it.
        guard let session = SessionID(try c.decode(String.self, forKey: .sid)) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sid, in: c, debugDescription: "The session ID is not a UUID.")
        }
        sessionId = session.text
        sentAt = try c.decode(Double.self, forKey: .at)
        seq = c.field(.seq) { $0 >= 0 }
        content = try Self.content(of: c.decode(Kind.self, forKey: .kind), in: c)
    }

    private static func content(of kind: Kind, in c: KeyedDecodingContainer<Key>) throws
        -> Content
    {
        switch kind {
        case .sessionStart: return .state(.sessionStart)
        case .sessionEnd: return .state(.sessionEnd, reason: try c.requiredText(.reason))
        case .turnStart: return .state(.userPromptSubmit)
        case .ask: return .state(.preToolUse, toolName: "AskUserQuestion")
        case .toolDone: return .state(.postToolUse, toolName: try c.requiredText(.tool))
        case .permission: return .state(.permissionRequest, toolName: try c.requiredText(.tool))
        case .stopFailure: return .state(.stopFailure)
        case .turnComplete:
            let answer = c.shortText(.answer, max: LiveLimits.answerMax, lines: true)
            switch try c.decode(Ending.self, forKey: .reason) {
            case .answer, .refusal: return .state(.stop, message: answer)
            case .aborted: return .state(.turnAborted, message: answer)
            case .error: return .state(.stopFailure)
            }
        case .usage:
            let context: Context? = c.field(.context)
            return .usage(
                LiveUsage(
                    model: c.shortText(.model), contextPercent: context?.percent,
                    contextTokens: context?.tokens, contextWindow: context?.window,
                    costUsd: c.field(.costUsd) { $0 >= 0 },
                    rateLimits: rateLimits(c.field(.rateLimits) ?? []),
                    version: c.shortText(.version), effort: c.shortText(.effort),
                    permissionMode: c.shortText(.permissionMode),
                    transcriptPath: c.field(.transcriptPath, where: isTranscriptPath)))
        }
    }

    // The time of the line. A line time is never after the receipt: a later time gives the
    // receipt time, so a line with a time in the future cannot hide the later events of its
    // session (row L4). A time more than 10 s before the receipt also gives the receipt time. A
    // time with a fraction gives the whole millisecond toward zero (row L3).
    func time(receivedAt: Int) -> Int {
        let received = Double(receivedAt)
        guard sentAt <= received, received - sentAt <= Double(LiveLimits.atDriftMs) else {
            return receivedAt
        }
        return Int(exactly: sentAt.rounded(.towardZero)) ?? receivedAt
    }
}

extension KeyedDecodingContainer {
    // The value of key when it has the type and obeys the rule, or nil. The field then goes.
    fileprivate func field<T: Decodable>(_ key: Key, where rule: (T) -> Bool = { _ in true })
        -> T?
    {
        guard let value = try? decode(T.self, forKey: key), rule(value) else { return nil }
        return value
    }

    // A text that the kind needs, clean (cleanText) and cut to 200 Characters (V1). A missing
    // text or a value that is not a text makes the line bad.
    fileprivate func requiredText(_ key: Key) throws -> String {
        String(cleanText(try decode(String.self, forKey: key)).prefix(LiveLimits.textMax))
    }

    // A text that is not empty after the clean (cleanText), cut to max Characters (V1), or nil.
    // With lines, the tabs and the line breaks stay.
    fileprivate func shortText(
        _ key: Key, max: Int = LiveLimits.textMax, lines: Bool = false
    ) -> String? {
        guard let text = field(key).map({ (text: String) in cleanText(text, lines: lines) }),
            !text.isEmpty
        else { return nil }
        return String(text.prefix(max))
    }
}

// MARK: - Usage lines

// The context of a usage line. Each bad value goes.
private struct Context: Decodable {
    let tokens: Int?
    let window: Int?
    let percent: Double?

    enum Key: String, CodingKey { case tokens, window, percent }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        tokens = c.field(.tokens) { $0 >= 0 }
        window = c.field(.window) { $0 > 0 }
        percent = c.field(.percent) { (0...100).contains($0) }
    }
}

// One item of the rate limits. An item of another form gives no window.
private struct RateItem: Decodable {
    enum Kind: String, Decodable { case fiveHour = "five_hour", sevenDay = "seven_day" }

    let kind: Kind
    let percentUsed: Double
    let resetsAt: String
}

// The windows of the plan. A later good window of the same kind replaces an earlier one.
private func rateLimits(_ items: [Lenient<RateItem>]) -> RateLimits? {
    var limits = RateLimits()
    for item in items.compactMap(\.decoded) {
        guard (0...100).contains(item.percentUsed),
            let resetsAt = RateWindow.resetTime(item.resetsAt)
        else { continue }
        let window = RateWindow(usedPercent: item.percentUsed, resetsAt: resetsAt)
        switch item.kind {
        case .fiveHour: limits.fiveHour = window
        case .sevenDay: limits.sevenDay = window
        }
    }
    return limits == RateLimits() ? nil : limits
}

// A transcript path is absolute, has no unsafe character (isUnsafeInText: the controls, the
// separators and the bidi controls, which can make a path look like another path) and has at most
// 1,024 UTF-16 units, as the mod counts them. The parser does not cut or clean a path, because
// that gives a different file. The first byte must be a slash: a Character check would see a
// slash and a combining mark as one Character. No code uses the path yet. A later use must first
// resolve the links and accept only a regular .jsonl file of this user below
// <shared home>/.claude/projects/, and must never give the path to a shell
// (docs/behaviour/live.md, The lines of the mod).
private func isTranscriptPath(_ path: String) -> Bool {
    path.utf8.first == UInt8(ascii: "/") && path.utf16.count <= LiveLimits.transcriptPathMax
        && !hasUnsafeCharacter(path)
}

// MARK: - UTF-8 and lone surrogates

// True when the bytes are valid UTF-8. The check makes no copy.
private func isValidUTF8(_ bytes: Data) -> Bool {
    var iterator = bytes.makeIterator()
    var parser = Unicode.UTF8.ForwardParser()
    while true {
        switch parser.parseScalar(from: &iterator) {
        case .valid: continue
        case .emptyInput: return true
        case .error: return false
        }
    }
}

// The JSON decoder of Foundation refuses a \u escape of a lone surrogate. The mod cuts an answer
// by UTF-16 units, so the cut can split a surrogate pair, and the JSON encoder of the mod then
// writes the lone half as an escape. Thus each such escape becomes U+FFFD before the decode (row
// L1), and the line stays. This pass goes when the mod of phase 4d cuts its
// texts on Character bounds.

private let backslash = UInt8(ascii: "\\")
private let replacementCharacter = Array("\u{FFFD}".utf8)

// The value of the four hex digits of a \u escape at index, or nil.
private func escapeUnit(_ bytes: [UInt8], at index: Int) -> UInt16? {
    guard index + 6 <= bytes.count, bytes[index] == backslash,
        bytes[index + 1] == UInt8(ascii: "u")
    else { return nil }
    var unit: UInt16 = 0
    for byte in bytes[(index + 2)..<(index + 6)] {
        guard let digit = hexValue(byte) else { return nil }
        unit = unit * 16 + digit
    }
    return unit
}

private func hexValue(_ byte: UInt8) -> UInt16? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt16(byte - UInt8(ascii: "0"))
    case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt16(byte - UInt8(ascii: "a") + 10)
    case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt16(byte - UInt8(ascii: "A") + 10)
    default: nil
    }
}

// The bytes with each \u escape of a lone surrogate replaced by U+FFFD. A pair of a high and a
// low surrogate stays. A backslash before another character starts an escape of two bytes, so
// "\\u" is a backslash and a letter u, not an escape. Outside a string, a backslash is bad JSON
// before and after the change.
private func withoutLoneSurrogates(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var index = 0
    while index < bytes.count {
        guard bytes[index] == backslash else {
            out.append(bytes[index])
            index += 1
            continue
        }
        guard let unit = escapeUnit(bytes, at: index) else {
            out.append(contentsOf: bytes[index..<min(index + 2, bytes.count)])
            index += 2
            continue
        }
        if UTF16.isLeadSurrogate(unit), let next = escapeUnit(bytes, at: index + 6),
            UTF16.isTrailSurrogate(next)
        {
            out.append(contentsOf: bytes[index..<(index + 12)])
            index += 12
        } else if UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) {
            out.append(contentsOf: replacementCharacter)
            index += 6
        } else {
            out.append(contentsOf: bytes[index..<(index + 6)])
            index += 6
        }
    }
    return out
}
