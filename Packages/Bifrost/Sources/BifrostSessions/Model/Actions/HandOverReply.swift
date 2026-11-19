// The reply of Hand over (docs/behaviour/actions.md, "Hand over"): the note that the old
// session wrote, read from the transcript lines after the baseline. The transcript format is
// internal to Claude Code and can change. So the reader is strict for each line and for each
// entry that it uses: the request, the replies, the turn end and the new messages from the user.
// A form that it does not know is a failure. It skips the metadata entries, because their types
// change between versions of Claude Code.
import BifrostFoundation
import Foundation

package enum HandOverReply: Sendable, Equatable {
    // The permission mode of the request entry.
    package enum RequestMode: Sendable, Equatable {
        // The entry has no permissionMode field.
        case absent
        // A mode that a new session can start with.
        case known(PermissionMode)
        // Another value, for example "default" or "bypassPermissions".
        case other
    }

    // No request yet, or no turn end after it yet.
    case waiting
    // The note of the reply, the model of the reply and the permission mode of the request.
    case done(note: String, model: String?, mode: RequestMode)
    // The reason why Bifrost cannot use the reply. The failure text shows it in parentheses, so
    // each reason is short.
    case failed(String)

    // The block types of an assistant entry that the reader knows.
    private static let blockTypes: Set<String> = [
        "text", "thinking", "redacted_thinking", "tool_use",
    ]
    // Claude Code writes this model on an entry that the API did not make, for example an error.
    private static let synthetic = "<synthetic>"

    private static let unknownLine = "a line of the transcript has an unknown form"
    private static let earlyEnd = "a turn ended before the hand-over request"
    private static let unknownPart = "the reply has a part that Bifrost doesn't know"
    private static let interrupted = "the session was interrupted"
    private static let newMessage = "a new message came in during the hand-over"
    private static let twoNotes = "the reply has more than one note"
    private static let noMarkers = "the reply doesn't have both note markers"
    private static let markerOrder = "the note markers are in the wrong order"
    private static let emptyNote = "the note is empty"

    // Read the reply to the request from the full transcript lines after the baseline. The
    // request entry is the first user entry with the request line. Bifrost reads only the
    // entries after it, so a note from before the request never counts. A new message from the
    // user fails at once, also after the first turn end: a message that the user types while no
    // tool runs waits in the queue, and it starts a new turn after the turn end. The wait reads
    // again until the session is idle, so that read fails.
    package static func read(_ tail: String, requestID: String) -> HandOverReply {
        let wanted = HandOverText.requestLine(requestID)
        let decoder = JSONDecoder()
        var request: [String: JSONValue]?
        // The result at the first turn end.
        var result: HandOverReply?
        var texts: [String] = []
        var model: String?
        for line in lines(tail) where !line.trimmed().isEmpty {
            guard let entry = try? decoder.decode(JSONValue.self, from: Data(line.utf8)).object,
                let type = entry["type"]?.string
            else { return .failed(unknownLine) }
            guard let asked = request else {
                if isTurnEnd(entry) { return .failed(earlyEnd) }
                if type == "user" && holdsRequest(entry, wanted) { request = entry }
                continue
            }
            if isNewMessage(entry) { return .failed(isInterrupt(entry) ? interrupted : newMessage) }
            // After the first turn end, only a new message counts.
            if result != nil { continue }
            if isTurnEnd(entry) {
                let finished = finish(texts.joined(separator: "\n"), model: model, request: asked)
                if case .failed = finished { return finished }
                result = finished
            } else if type == "assistant" {
                // A sidechain entry is the work of a subagent, not the reply.
                if entry["isSidechain"] == .bool(true) { continue }
                guard let blocks = replyTexts(entry) else { return .failed(unknownPart) }
                texts += blocks
                model = modelOf(entry) ?? model
            }
            // Each other entry is metadata.
        }
        return result ?? .waiting
    }

    // The lines of the text, split at each LF. A CR before the LF stays in the line, and the
    // checks trim it.
    private static func lines(_ text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map {
            String(String.UnicodeScalarView($0))
        }
    }

    private static func isTurnEnd(_ entry: [String: JSONValue]) -> Bool {
        entry["type"] == "system" && entry["subtype"] == "turn_duration"
    }

    // The content of the message of an entry.
    private static func content(_ entry: [String: JSONValue]) -> JSONValue? {
        entry["message"]?.object?["content"]
    }

    // The text of a user entry: a string content, or the text blocks of an array content.
    private static func userText(_ entry: [String: JSONValue]) -> String {
        if let text = content(entry)?.string { return text }
        let blocks = content(entry)?.array ?? []
        return blocks.compactMap { block -> String? in
            guard let fields = block.object, fields["type"] == "text" else { return nil }
            return fields["text"]?.string
        }.joined(separator: "\n")
    }

    // True when a line of the user text is the request line. A line ends at a CR, an LF or
    // both. White space at the ends of the line is allowed. A line with other text, for example
    // a longer request ID, is not the request line.
    private static func holdsRequest(_ entry: [String: JSONValue], _ wanted: String) -> Bool {
        userText(entry).unicodeScalars.split { $0 == "\n" || $0 == "\r" }.contains {
            String(String.UnicodeScalarView($0)).trimmed() == wanted
        }
    }

    // True for a user entry that is not a message from the user: a meta entry, or only the
    // results of tools.
    private static func isAllowedUser(_ entry: [String: JSONValue]) -> Bool {
        if entry["isMeta"] == .bool(true) { return true }
        guard let blocks = content(entry)?.array, !blocks.isEmpty else { return false }
        return blocks.allSatisfy { $0.object?["type"] == "tool_result" }
    }

    // True for the entry that Claude Code writes after an Interrupt.
    private static func isInterrupt(_ entry: [String: JSONValue]) -> Bool {
        entry["type"] == "user" && userText(entry).hasPrefix("[Request interrupted by user")
    }

    // True for a message from the user: a user entry that isAllowedUser does not allow, or a
    // queued command. Claude Code writes a message that the user types during a turn as a
    // queued_command attachment, and gives it to Claude in that turn. The note of a background
    // task is also a queued command, with the command mode task-notification. It is not a
    // message from the user.
    private static func isNewMessage(_ entry: [String: JSONValue]) -> Bool {
        if entry["type"] == "user" { return !isAllowedUser(entry) }
        guard entry["type"] == "attachment", let attachment = entry["attachment"]?.object else {
            return false
        }
        return attachment["type"] == "queued_command"
            && attachment["commandMode"] != "task-notification"
    }

    // The texts of the text blocks of an assistant entry. nil for an entry of an unknown form.
    private static func replyTexts(_ entry: [String: JSONValue]) -> [String]? {
        guard let blocks = content(entry)?.array else { return nil }
        var texts: [String] = []
        for block in blocks {
            guard let fields = block.object, let type = fields["type"]?.string,
                blockTypes.contains(type)
            else { return nil }
            guard type == "text" else { continue }
            guard let text = fields["text"]?.string else { return nil }
            texts.append(text)
        }
        return texts
    }

    // The model of an assistant entry: requestedModel, else the model of the message. An empty
    // model and <synthetic> do not count.
    private static func modelOf(_ entry: [String: JSONValue]) -> String? {
        let values = [entry["requestedModel"]?.string, entry["message"]?.object?["model"]?.string]
        return values.lazy.compactMap { $0 }.first { !$0.isEmpty && $0 != synthetic }
    }

    // The result at the turn end: the trimmed text between the two marker lines. White space
    // around a marker is allowed.
    private static func finish(
        _ text: String, model: String?, request: [String: JSONValue]
    ) -> HandOverReply {
        let lines = lines(text)
        let starts = lines.indices.filter { lines[$0].trimmed() == HandOverText.noteStart }
        let ends = lines.indices.filter { lines[$0].trimmed() == HandOverText.noteEnd }
        if starts.count > 1 || ends.count > 1 { return .failed(twoNotes) }
        guard let start = starts.first, let end = ends.first else { return .failed(noMarkers) }
        if start > end { return .failed(markerOrder) }
        let note = lines[(start + 1)..<end].joined(separator: "\n").trimmed()
        if note.isEmpty { return .failed(emptyNote) }
        let mode: RequestMode =
            switch request["permissionMode"] {
            case nil: .absent
            case .string(let text)?: PermissionMode(rawValue: text).map(RequestMode.known) ?? .other
            default: .other
            }
        return .done(note: note, model: model, mode: mode)
    }

    // True when the full transcript lines hold the start of a new turn: a new message from the
    // user, a queued command or an assistant entry. A line of an unknown form also counts, so a
    // change of the transcript format never makes a busy session look quiet.
    package static func startsNewTurn(_ tail: String) -> Bool {
        let decoder = JSONDecoder()
        for line in lines(tail) where !line.trimmed().isEmpty {
            guard let entry = try? decoder.decode(JSONValue.self, from: Data(line.utf8)).object,
                let type = entry["type"]?.string
            else { return true }
            if type == "assistant" || isNewMessage(entry) { return true }
            if type == "attachment" && entry["attachment"]?.object?["type"] == "queued_command" {
                return true
            }
        }
        return false
    }
}

extension HandOverReply.RequestMode {
    // The permission mode of the new session. A known mode stays. Another mode gives no mode, so
    // the new session starts in the default mode of Claude Code, and Bifrost never starts a
    // session in bypassPermissions by itself. Only a request with no mode takes the mode of the
    // row, and only when that mode is one that a new session can start with.
    package func newSessionMode(row: String?) -> PermissionMode? {
        switch self {
        case .known(let mode): mode
        case .other: nil
        case .absent: row.flatMap(PermissionMode.init(rawValue:))
        }
    }
}
