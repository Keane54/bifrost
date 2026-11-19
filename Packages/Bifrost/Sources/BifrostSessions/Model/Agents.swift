import BifrostFoundation
import Foundation

// The parser reads each entry of "claude agents --json" with these rules. A field with the wrong
// type gets its empty value. The name and waitingFor lose each unsafe character (cleanText), and
// a cwd with an unsafe character is empty. Only the kind "background" is a background job. An
// entry with no session ID, or an empty one, is not an entry. A session ID in the UUID form is
// kept in lower case (SessionID), so the row of the session and its chat panel have the same ID.
extension AgentEntry: Decodable {
    private enum Key: String, CodingKey {
        case sessionId, cwd, kind, startedAt, name, status, pid, id, waitingFor
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let text = try c.decode(String.self, forKey: .sessionId)
        sessionId = SessionID(text)?.text ?? text
        if sessionId.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionId, in: c, debugDescription: "empty session ID")
        }
        func value<T: Decodable>(_ key: Key) -> T? { try? c.decode(T.self, forKey: key) }
        // A folder with an unsafe character is no folder: a clean would name another folder.
        cwd = (value(.cwd) as String?).flatMap { hasUnsafeCharacter($0) ? nil : $0 } ?? ""
        isBackground = value(.kind) as String? == "background"
        startedAt = value(.startedAt) ?? 0
        // The texts lose each unsafe character (cleanText).
        name = cleanText(value(.name) ?? "")
        status = value(.status) ?? .unknown
        // A PID that is not a whole number in the range of pid_t has the wrong type (row D1).
        pid = (value(.pid) as Int?).flatMap { pid_t(exactly: $0) }
        // An id that is not a short ID (for example a text that starts with "-") is no short ID,
        // so it can never reach claude attach.
        id = (value(.id) as String?).flatMap { ShortID($0) }
        waitingFor = (value(.waitingFor) as String?).map { cleanText($0) }
    }
}

// The one decoder of the lists. A decode does not change its options, so the polls can share it.
private let decoder = JSONDecoder()

extension AgentList {
    // Read the output of "claude agents --json". The parser starts at the first line that begins
    // with "[". It skips an entry that has no session ID, and then marks the list as partial.
    // It keeps an entry that has no pid. The JSON goes to the decoder with one copy of the bytes.
    package init(output: String) {
        if output.trimmed().isEmpty {
            self = .failed(.emptyOutput)
            return
        }
        // Lines end at "\n". The JSON is the text from the start of the first "[" line to the end.
        let bytes = output.utf8
        var start: String.UTF8View.Index?
        var previous: UInt8?
        for index in bytes.indices {
            if bytes[index] == UInt8(ascii: "[") && (previous == nil || previous == 0x0A) {
                start = index
                break
            }
            previous = bytes[index]
        }
        guard let start else {
            self = .failed(.noArray)
            return
        }
        let values: [Lenient<AgentEntry>]
        do {
            values = try decoder.decode([Lenient<AgentEntry>].self, from: Data(bytes[start...]))
        } catch DecodingError.typeMismatch {
            self = .failed(.notAnArray)
            return
        } catch {
            self = .failed(.badJSON(detail: describe(error)))
            return
        }
        let entries = values.compactMap(\.decoded)
        self.init(entries: entries, partial: entries.count < values.count)
    }
}

// The short text of a decode error for the log.
private func describe(_ error: any Error) -> String {
    if case DecodingError.dataCorrupted(let context) = error {
        let underlying = (context.underlyingError as? NSError)?.userInfo[NSDebugDescriptionErrorKey]
        return (underlying as? String) ?? context.debugDescription
    }
    return error.localizedDescription
}
