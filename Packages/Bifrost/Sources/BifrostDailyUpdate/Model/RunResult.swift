import BifrostFoundation
import BifrostSessions
import Foundation

// The result of a run (docs/behaviour/daily-update.md, "The run"). claude -p with
// --output-format json prints one JSON object. Its "result" field is the final reply of the run,
// and the reply holds the result JSON between two fixed marker lines. The run read text from the
// board and from the PRs, so Bifrost trusts none of it: the check is strict, and one failed rule
// fails the whole result.

// The result of a good run.
package struct DailyResult: Sendable, Equatable {
    // One result for each area that is on, in the order of the input.
    package var areas: [DailyAreaResult]
    // The items that fit no area.
    package var unplaced: [DailyItem]
    // The start of the period of each area, by its ID.
    package var since: [String: Date]

    package init(areas: [DailyAreaResult], unplaced: [DailyItem], since: [String: Date]) {
        self.areas = areas
        self.unplaced = unplaced
        self.since = since
    }
}

// Why a run gave no result.
package enum RunFailure: Error, Sendable, Equatable {
    // No ticket source and no merged PRs: the run has nothing to read.
    case nothingToRead
    // The ticket source is not connected. status is the reason, for example "not found" or
    // "failed", or nil when the skill found it.
    case sourceUnavailable(server: String?, status: String?)
    case noUser
    case toolDenied
    case badResult
    case timeout
    // claude did not run to its end. reason is the short reason, or nil.
    case claudeFailed(String?)
    // The caller stopped the run. A stopped run is no result: it changes no state.
    case stopped

    // The code of the state file, or nil for stopped, which does not change the state.
    package var code: FailureCode? {
        switch self {
        case .nothingToRead: .nothingToRead
        case .sourceUnavailable: .sourceUnavailable
        case .noUser: .noUser
        case .toolDenied: .toolDenied
        case .badResult: .badResult
        case .timeout: .timeout
        case .claudeFailed: .claudeFailed
        case .stopped: nil
        }
    }

    // The detail of the state file: the status of the source, or the reason of a failed claude.
    package var detail: String? {
        switch self {
        case .sourceUnavailable(_, let status): status
        case .claudeFailed(let reason): reason
        default: nil
        }
    }

    package var message: String {
        switch self {
        case .stopped: "Bifrost stopped writing your daily update."
        case .sourceUnavailable(let server, let status):
            FailureCode.sourceUnavailable.text(detail: status, server: server)
        default: code.map { $0.text(detail: detail) } ?? ""
        }
    }
}

// The lines of a run for the Event log. A stopped run writes no line.
package enum DailyRunEvent: Sendable, Equatable {
    case started, finished
    case failed(RunFailure)
    // The run tried tool calls that it may not make. Only the count: the names stay out of the log.
    case callsDenied(Int)
    // gh gave no merged PRs, so the drafts leave them out.
    case mergedPRsMissing(MergedPRsError)

    package var line: String {
        switch self {
        case .started: "Daily update: Bifrost is writing the drafts."
        case .finished: "Daily update: the drafts are ready."
        case .failed(let failure): "Daily update: \(failure.message)"
        case .callsDenied(let count):
            "Daily update: Claude tried \(count == 1 ? "1 tool call" : "\(count) tool calls") "
                + "that the run isn't allowed to make."
        case .mergedPRsMissing(let error):
            "Daily update: Bifrost couldn't read your merged PRs, so the drafts leave them out. "
                + error.message
        }
    }
}

// The JSON object that claude -p prints, in the parts that the run reads.
package struct ClaudeReply: Sendable, Equatable {
    // is_error, or nil when the field is not a Bool.
    package var isError: Bool?
    // The final reply of the run, or nil when the field is not a text.
    package var result: String?
    // The number of tool calls that the permissions refused.
    package var denials: Int
}

package enum RunResult {
    package static let version = 1
    package static let begin = "BIFROST-DAILY-RESULT-BEGIN"
    package static let end = "BIFROST-DAILY-RESULT-END"
    // The most bytes of the output of a run.
    package static let maxOutput = 1_048_576
    // The longest reason of an error reply.
    package static let maxReason = 200

    static let maxItems = 100
    static let maxID = 100
    static let maxTitle = 300
    static let maxState = 60
    static let maxURL = 2000
    static let maxDraft = 8000

    private static let itemKeys: Set = ["kind", "id", "title", "from", "to", "url"]
    private static let areaKeys: Set = ["id", "moved", "items", "draft"]
    private static let topKeys: Set = ["version", "areas", "unplaced"]

    // The JSON object of the output, or nil: more than maxOutput bytes, or no JSON object.
    package static func reply(_ output: Data) -> ClaudeReply? {
        guard output.count <= maxOutput,
            let value = try? JSONDecoder().decode(JSONValue.self, from: output),
            let fields = value.object
        else { return nil }
        var isError: Bool?
        if case .bool(let flag)? = fields["is_error"] { isError = flag }
        return ClaudeReply(
            isError: isError, result: fields["result"]?.string,
            denials: fields["permission_denials"]?.array?.count ?? 0)
    }

    // The reason of an error reply: the first line of its result that is not empty, cut to
    // maxReason. nil for a reply that is not an error.
    package static func errorLine(_ reply: ClaudeReply?) -> String? {
        guard let reply, reply.isError == true, let result = reply.result else { return nil }
        return lines(result).map { $0.trimmed() }.first { !$0.isEmpty }
            .map { String($0.prefix(maxReason)) }
    }

    // Check the output of a good run against its input. Each area of the input shows exactly
    // once. The result holds only the known fields.
    package static func check(_ output: Data, input: RunInput) -> Result<DailyResult, RunFailure> {
        guard let text = extract(output),
            let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
            let fields = value.object, fields["version"]?.wholeNumber == version
        else { return .failure(.badResult) }
        if let failure = fields["failure"] {
            // A failure of the skill has only the two fields.
            guard fields.count == 2 else { return .failure(.badResult) }
            switch failure.string {
            case "no-user": return .failure(.noUser)
            case "tool-denied": return .failure(.toolDenied)
            case "source-unavailable":
                return .failure(.sourceUnavailable(server: input.source.server, status: nil))
            default: return .failure(.badResult)
            }
        }
        guard Set(fields.keys).isSubset(of: topKeys), let list = fields["areas"]?.array,
            let unplaced = items(fields["unplaced"])
        else { return .failure(.badResult) }
        var areas: [DailyAreaResult] = []
        for entry in list {
            guard let area = area(entry), !areas.contains(where: { $0.id == area.id }) else {
                return .failure(.badResult)
            }
            areas.append(area)
        }
        let ids = input.areas.map(\.id)
        guard areas.count == ids.count, areas.allSatisfy({ ids.contains($0.id) }) else {
            return .failure(.badResult)
        }
        return .success(DailyResult(areas: areas, unplaced: unplaced, since: input.since))
    }

    // The text between the last line that is only the begin marker and the next line that is
    // only the end marker, in the result of a reply that is not an error. nil when a part is
    // missing.
    static func extract(_ output: Data) -> String? {
        guard let reply = reply(output), reply.isError == false, let result = reply.result else {
            return nil
        }
        let all = lines(result)
        guard let first = all.lastIndex(where: { $0.trimmed() == begin }),
            let last = all[(first + 1)...].firstIndex(where: { $0.trimmed() == end })
        else { return nil }
        return all[(first + 1)..<last].joined(separator: "\n")
    }

    // The lines of a text, split at each LF and at each CR LF. A CR LF is one Character, so the
    // split names both.
    private static func lines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
            .map(String.init)
    }

    private static func area(_ value: JSONValue) -> DailyAreaResult? {
        guard let fields = value.object, Set(fields.keys).isSubset(of: areaKeys),
            let id = fields["id"]?.string, case .bool(let moved)? = fields["moved"],
            let draft = fields["draft"]?.string, (1...maxDraft).contains(draft.count),
            let items = items(fields["items"])
        else { return nil }
        return DailyAreaResult(id: id, moved: moved, items: items, draft: draft)
    }

    // A list of items. Two items with the same kind and ID in one list fail the list, so a click
    // can never open the wrong item.
    private static func items(_ value: JSONValue?) -> [DailyItem]? {
        guard let list = value?.array, list.count <= maxItems else { return nil }
        var items: [DailyItem] = []
        for entry in list {
            guard let item = item(entry),
                !items.contains(where: { $0.kind == item.kind && $0.id == item.id })
            else { return nil }
            items.append(item)
        }
        return items
    }

    private static func item(_ value: JSONValue) -> DailyItem? {
        guard let fields = value.object, Set(fields.keys).isSubset(of: itemKeys),
            let kind = fields["kind"]?.string.flatMap(DailyItem.Kind.init(rawValue:)),
            let id = text(fields["id"], max: maxID),
            let title = text(fields["title"], max: maxTitle)
        else { return nil }
        var item = DailyItem(kind: kind, id: id, title: title)
        for (key, path) in [("from", \DailyItem.from), ("to", \DailyItem.to)] {
            guard let value = fields[key] else { continue }
            guard let state = text(value, max: maxState) else { return nil }
            item[keyPath: path] = state
        }
        if let value = fields["url"] {
            guard let url = text(value, max: maxURL), url.hasPrefix("https://") else { return nil }
            item.url = url
        }
        return item
    }

    // A text of at most max characters, or nil.
    private static func text(_ value: JSONValue?, max: Int) -> String? {
        guard let text = value?.string, text.count <= max else { return nil }
        return text
    }
}
