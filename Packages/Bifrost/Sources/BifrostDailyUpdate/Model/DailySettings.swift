import BifrostFoundation
import BifrostSessions

// The settings of the Daily update: the block "dailyUpdate" of settings.json. The block keeps the
// field names and the meaning of the file of the Electron app (docs/behaviour/daily-update.md).

// A time of the day on the wall clock, as "HH:MM" with 24 hours.
package struct ClockTime: Sendable, Equatable, Hashable, Comparable, Codable {
    package var hour: Int
    package var minute: Int

    package init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    // The time of the text "HH:MM" (two digits each, 00:00 to 23:59). Other text gives nil.
    package init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
            parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
            let hour = Int(parts[0]), let minute = Int(parts[1]),
            (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        self.init(hour: hour, minute: minute)
    }

    package var text: String {
        "\(hour < 10 ? "0" : "")\(hour):\(minute < 10 ? "0" : "")\(minute)"
    }

    // The minutes since midnight of the wall clock. A day with a time change has the same value.
    package var minutes: Int { hour * 60 + minute }

    package init(minutes: Int) {
        self.init(hour: minutes / 60, minute: minutes % 60)
    }

    package static func < (left: ClockTime, right: ClockTime) -> Bool {
        left.minutes < right.minutes
    }

    package init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let time = ClockTime(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Not an HH:MM time."))
        }
        self = time
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

// One work area of the update: a channel and the work that goes there.
package struct WorkArea: Sendable, Equatable, Codable, Identifiable {
    package var id: String
    package var on: Bool
    package var name: String
    package var channel: String
    package var description: String
    // The area that gets all work that no other area claims. At most one area has it.
    package var takesRest: Bool

    package init(
        id: String, on: Bool = true, name: String, channel: String = "", description: String = "",
        takesRest: Bool = false
    ) {
        self.id = id
        self.on = on
        self.name = name
        self.channel = channel
        self.description = description
        self.takesRest = takesRest
    }
}

// The board of the tickets: the name of one MCP server, and the read tools that the run may use.
package struct DailySource: Sendable, Equatable, Codable {
    // The name of the MCP server, or nil when the user chose none.
    package var server: String?
    // The full tool names: mcp__<prefix>__<tool>.
    package var tools: [String]

    package init(server: String? = nil, tools: [String] = []) {
        self.server = server
        self.tools = tools
    }

    // The prefix of the tool names of a server, as Claude Code names the tools: each UTF-16 unit
    // that is not an ASCII letter, a digit, _ or - becomes _. For a name that starts with
    // "claude.ai " (a connector of claude.ai), each run of _ then becomes one _, and a _ at the
    // start or at the end goes: "claude.ai Atlassian (Jira)" gives mcp__claude_ai_Atlassian_Jira__.
    package static func toolPrefix(of server: String) -> String {
        var name = String(
            decoding: server.utf16.map { unit in
                let scalar = Unicode.Scalar(unit).map(Character.init)
                return scalar.flatMap { isNameCharacter($0) ? $0.asciiValue : nil } ?? 95
            }, as: UTF8.self)
        if server.utf16.starts(with: "claude.ai ".utf16) {
            name = name.replacing(/_+/, with: "_")
            if name.hasPrefix("_") { name.removeFirst() }
            if name.hasSuffix("_") { name.removeLast() }
        }
        return "mcp__\(name)__"
    }

    // The characters of a server name or of a tool name: ASCII letters and digits, _ and -.
    static func isNameCharacter(_ character: Character) -> Bool {
        character == "_" || character == "-"
            || (character.isASCII && (character.isLetter || character.isNumber))
    }

    private enum Key: String, CodingKey {
        case server, tools
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        server = try container.decodeIfPresent(String.self, forKey: .server)
        tools = try container.decode([String].self, forKey: .tools)
    }

    // The file has "server": null for no server.
    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(server, forKey: .server)
        try container.encode(tools, forKey: .tools)
    }
}

// How a draft looks: a template, and at most three examples of past updates.
package struct DailyFormat: Sendable, Equatable, Codable {
    package var template: String
    package var examples: [String]

    package init(template: String, examples: [String] = []) {
        self.template = template
        self.examples = examples
    }
}

package struct DailySettings: Sendable, Equatable, Codable {
    package var source: DailySource
    // The name, email or ID of the user on the board.
    package var you: String
    package var mergedPrs: Bool
    package var draftTime: ClockTime
    package var deadline: ClockTime
    // 0 is Sunday and 6 is Saturday. The file has them in sorted order.
    package var days: Set<Int>
    package var model: ModelChoice
    package var format: DailyFormat
    package var areas: [WorkArea]
    // The fields of the block that this app does not know. A save writes them again.
    package var unknown = UnknownFields()

    // The limits of the settings.
    package static let maxAreas = 10
    package static let maxName = 60
    package static let maxChannel = 80
    package static let maxDescription = 500
    package static let maxTemplate = 2000
    package static let maxExamples = 3
    package static let maxExample = 4000
    package static let maxYou = 200
    package static let maxTools = 500
    package static let maxServer = 200
    package static let maxID = 100
    // The least time between the draft time and the deadline.
    package static let minGap = 10

    // The plain template. It names no board, no company and no person.
    package static let defaultTemplate =
        "**Daily update**\n**Done since my last update**\n**Next**\n**Blocked or at risk**"

    package static let defaults = DailySettings(
        source: DailySource(), you: "", mergedPrs: true,
        draftTime: ClockTime(hour: 9, minute: 30), deadline: ClockTime(hour: 10, minute: 0),
        days: [1, 2, 3, 4, 5], model: .standard,
        format: DailyFormat(template: defaultTemplate), areas: [])

    package init(
        source: DailySource, you: String, mergedPrs: Bool, draftTime: ClockTime,
        deadline: ClockTime, days: Set<Int>, model: ModelChoice, format: DailyFormat,
        areas: [WorkArea]
    ) {
        self.source = source
        self.you = you
        self.mergedPrs = mergedPrs
        self.draftTime = draftTime
        self.deadline = deadline
        self.days = days
        self.model = model
        self.format = format
        self.areas = areas
    }
}

// MARK: - The lenient read

extension DailySettings {
    private enum Key: String, CodingKey {
        case source, you, mergedPrs, draftTime, deadline, days, model, format, areas
    }

    // The settings of a stored value. A value that is not an object gives nil. In an object, a bad
    // field gets its default and the other fields stay (one bad field costs only that field). The
    // unknown fields stay for the next save.
    package init?(json: JSONValue) {
        guard let object = json.object else { return nil }
        self = Self.defaults
        unknown = UnknownFields(object, known: Set(Self.knownKeys))
        if let source = object["source"]?.object { readSource(source) }
        if let you = object["you"]?.string, you.count <= Self.maxYou { self.you = you }
        if case .bool(let merged)? = object["mergedPrs"] { mergedPrs = merged }
        if let time = object["draftTime"]?.string.flatMap(ClockTime.init) { draftTime = time }
        if let time = object["deadline"]?.string.flatMap(ClockTime.init) { deadline = time }
        if deadline.minutes - draftTime.minutes < Self.minGap {
            draftTime = Self.defaults.draftTime
            deadline = Self.defaults.deadline
        }
        if let list = object["days"]?.array, let days = Self.readDays(list) { self.days = days }
        if let text = object["model"]?.string, let model = ModelChoice(rawValue: text) {
            self.model = model
        }
        if let format = object["format"]?.object { readFormat(format) }
        if let list = object["areas"]?.array { readAreas(list) }
    }

    private static let knownKeys = [
        "source", "you", "mergedPrs", "draftTime", "deadline", "days", "model", "format", "areas",
    ]

    private mutating func readSource(_ object: [String: JSONValue]) {
        guard let server = object["server"]?.string, !server.isEmpty,
            server.count <= Self.maxServer
        else { return }
        source.server = server
        // One bad tool drops the whole list: the run never gets a tool that was not checked.
        let prefix = DailySource.toolPrefix(of: server)
        if let list = object["tools"]?.array, list.count <= Self.maxTools {
            let names = list.compactMap(\.string)
            if names.count == list.count, names.allSatisfy({ Self.isToolName($0, prefix: prefix) })
            {
                source.tools = names
            }
        }
    }

    // True for a name of the form mcp__<server>__<tool> with the prefix of the server.
    package static func isToolName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let rest = name.dropFirst(prefix.count)
        return !rest.isEmpty && rest.allSatisfy(DailySource.isNameCharacter)
    }

    private static func readDays(_ list: [JSONValue]) -> Set<Int>? {
        let numbers = list.compactMap(\.wholeNumber)
        guard !list.isEmpty, numbers.count == list.count,
            numbers.allSatisfy({ (0...6).contains($0) })
        else { return nil }
        return Set(numbers)
    }

    private mutating func readFormat(_ object: [String: JSONValue]) {
        if let template = object["template"]?.string,
            (1...Self.maxTemplate).contains(template.count)
        {
            format.template = template
        }
        if let list = object["examples"]?.array, list.count <= Self.maxExamples {
            let examples = list.compactMap(\.string)
            if examples.count == list.count, examples.allSatisfy({ $0.count <= Self.maxExample }) {
                format.examples = examples
            }
        }
    }

    // A bad area, a repeated ID and an area after the limit are dropped. Only the first area that
    // takes the rest keeps that flag.
    private mutating func readAreas(_ list: [JSONValue]) {
        var seen = Set<String>()
        var restTaken = false
        for item in list {
            guard var area = Self.readArea(item), seen.insert(area.id).inserted,
                areas.count < Self.maxAreas
            else { continue }
            if area.takesRest && restTaken { area.takesRest = false }
            restTaken = restTaken || area.takesRest
            areas.append(area)
        }
    }

    private static func readArea(_ value: JSONValue) -> WorkArea? {
        guard let object = value.object, let id = object["id"]?.string,
            (1...maxID).contains(id.count),
            case .bool(let on)? = object["on"], case .bool(let takesRest)? = object["takesRest"],
            let name = object["name"]?.string, (1...maxName).contains(name.count),
            let channel = object["channel"]?.string, channel.count <= maxChannel,
            let description = object["description"]?.string, description.count <= maxDescription
        else { return nil }
        return WorkArea(
            id: id, on: on, name: name, channel: channel, description: description,
            takesRest: takesRest)
    }

    // True when each field is inside its limits: the check of an edit. A block that the lenient
    // read gives is always valid.
    package var isValid: Bool {
        guard you.count <= Self.maxYou, deadline.minutes - draftTime.minutes >= Self.minGap,
            !days.isEmpty, days.allSatisfy({ (0...6).contains($0) }),
            (1...Self.maxTemplate).contains(format.template.count),
            format.examples.count <= Self.maxExamples,
            format.examples.allSatisfy({ $0.count <= Self.maxExample }),
            areas.count <= Self.maxAreas, areas.filter(\.takesRest).count <= 1,
            Set(areas.map(\.id)).count == areas.count
        else { return false }
        if let server = source.server {
            let prefix = DailySource.toolPrefix(of: server)
            guard (1...Self.maxServer).contains(server.count),
                source.tools.count <= Self.maxTools,
                source.tools.allSatisfy({ Self.isToolName($0, prefix: prefix) })
            else { return false }
        } else if !source.tools.isEmpty {
            return false
        }
        return areas.allSatisfy {
            (1...Self.maxID).contains($0.id.count) && (1...Self.maxName).contains($0.name.count)
                && $0.channel.count <= Self.maxChannel
                && $0.description.count <= Self.maxDescription
        }
    }

    // MARK: Codable

    package init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        self = Self(json: value) ?? Self.defaults
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(source, forKey: .source)
        try container.encode(you, forKey: .you)
        try container.encode(mergedPrs, forKey: .mergedPrs)
        try container.encode(draftTime, forKey: .draftTime)
        try container.encode(deadline, forKey: .deadline)
        try container.encode(days.sorted(), forKey: .days)
        try container.encode(model, forKey: .model)
        try container.encode(format, forKey: .format)
        try container.encode(areas, forKey: .areas)
        try unknown.encode(to: encoder)
    }
}
