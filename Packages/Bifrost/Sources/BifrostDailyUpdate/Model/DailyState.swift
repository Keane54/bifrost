import BifrostFoundation
import Foundation

// The state of the Daily update: state.json in the folder of the Daily update. The file keeps the
// form of the file of the Electron app. A time in the file is milliseconds since 1970 (Stamps);
// in the code it is a Date. Each change is a mutating method with no I/O.

// One ticket or one merged PR in a draft.
package struct DailyItem: Sendable, Equatable, Codable {
    package enum Kind: String, Sendable, Codable {
        case ticket, pr
    }

    package var kind: Kind
    package var id: String
    package var title: String
    package var from: String?
    package var to: String?
    package var url: String?

    package init(
        kind: Kind, id: String, title: String, from: String? = nil, to: String? = nil,
        url: String? = nil
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.from = from
        self.to = to
        self.url = url
    }

    private enum Key: String, CodingKey {
        case kind, id, title, from, to, url
    }

    // A bad optional text is dropped. A bad kind, id or title throws, and the list drops the item.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        from = try? container.decode(String.self, forKey: .from)
        to = try? container.decode(String.self, forKey: .to)
        url = try? container.decode(String.self, forKey: .url)
    }
}

// What the panel shows for one area.
package struct AreaView: Sendable, Equatable, Codable {
    package var items: [DailyItem]
    package var moved: Bool
    package var draft: String
    // True when the user changed the draft.
    package var edited: Bool
    // A newer draft that Bifrost keeps apart from the draft that the user changed.
    package var pending: String?
    // The start of the run that made the items.
    package var since: Date?

    package init(
        items: [DailyItem] = [], moved: Bool = false, draft: String, edited: Bool = false,
        pending: String? = nil, since: Date? = nil
    ) {
        self.items = items
        self.moved = moved
        self.draft = draft
        self.edited = edited
        self.pending = pending
        self.since = since
    }

    private enum Key: String, CodingKey {
        case items, moved, draft, edited, pending, since
    }

    // A view with no draft text is not a view: the decode throws, and the state drops it.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        draft = try container.decode(String.self, forKey: .draft)
        edited = (try? container.decode(Bool.self, forKey: .edited)) ?? false
        moved = (try? container.decode(Bool.self, forKey: .moved)) ?? false
        items = Lists.items(container, forKey: .items)
        pending = try? container.decode(String.self, forKey: .pending)
        since = Stamps.decodeOne(container, forKey: .since)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(items, forKey: .items)
        try container.encode(moved, forKey: .moved)
        try container.encode(draft, forKey: .draft)
        try container.encode(edited, forKey: .edited)
        try container.encodeIfPresent(pending, forKey: .pending)
        try container.encodeIfPresent(since.map(Stamps.milliseconds), forKey: .since)
    }
}

// The result of a run for one area.
package struct DailyAreaResult: Sendable, Equatable {
    package var id: String
    package var moved: Bool
    package var items: [DailyItem]
    package var draft: String

    package init(id: String, moved: Bool, items: [DailyItem], draft: String) {
        self.id = id
        self.moved = moved
        self.items = items
        self.draft = draft
    }
}

// The reason that a run failed.
package enum FailureCode: String, Sendable, Codable, CaseIterable {
    case noUser = "no-user"
    case sourceUnavailable = "source-unavailable"
    case toolDenied = "tool-denied"
    case badResult = "bad-result"
    case timeout
    case claudeFailed = "claude-failed"
    case nothingToRead = "nothing-to-read"

    // The text for the panel and the Event log. server is the name of the ticket source. detail is
    // the status of the server, or the short reason of a failed claude.
    package func text(detail: String? = nil, server: String? = nil) -> String {
        let place = "Settings > Daily update"
        let detail = detail.flatMap { $0.isEmpty ? nil : $0 }
        switch self {
        case .nothingToRead:
            return "Choose a ticket source or turn on merged PRs in \(place)."
        case .sourceUnavailable:
            let name = server.flatMap { $0.isEmpty ? nil : $0 } ?? "the ticket source"
            let reason = detail.map { " (\($0))" } ?? ""
            return "Bifrost couldn't reach \(name)\(reason). Check it in Claude Code with /mcp."
        case .noUser:
            return "Claude couldn't find you on the board. Add your name, email or ID in \(place)."
        case .toolDenied:
            return
                "The run needed a tool that it isn't allowed to use. Check the tools in \(place)."
        case .badResult:
            return
                "Claude's answer didn't have the right shape, so Bifrost didn't use it. "
                + "Try Refresh."
        case .timeout:
            return "The run took more than 5 minutes, so Bifrost stopped it."
        case .claudeFailed:
            let text = "Claude Code couldn't run the daily update."
            return detail.map { "\(text) \($0)" } ?? text
        }
    }
}

// The last run: when it ran, and why it failed.
package struct DailyRun: Sendable, Equatable, Codable {
    package var at: Date
    package var ok: Bool
    package var failure: FailureCode?
    package var detail: String?

    package init(at: Date, ok: Bool, failure: FailureCode? = nil, detail: String? = nil) {
        self.at = at
        self.ok = ok
        self.failure = failure
        self.detail = detail
    }

    private enum Key: String, CodingKey {
        case at, ok, failure, detail
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard let at = Stamps.decodeOne(container, forKey: .at) else {
            throw DecodingError.dataCorruptedError(
                forKey: .at, in: container, debugDescription: "Not a time.")
        }
        self.at = at
        ok = try container.decode(Bool.self, forKey: .ok)
        failure = try? container.decode(FailureCode.self, forKey: .failure)
        detail = try? container.decode(String.self, forKey: .detail)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(Stamps.milliseconds(at), forKey: .at)
        try container.encode(ok, forKey: .ok)
        try container.encodeIfPresent(failure, forKey: .failure)
        try container.encodeIfPresent(detail, forKey: .detail)
    }
}

package struct DailyState: Sendable, Equatable, Codable {
    package var marks: DayMarks
    // The area ID to the time of the last send, and of the send before it (for Undo).
    package var lastSent: [String: Date]
    package var prevSent: [String: Date]
    package var areas: [String: AreaView]
    // The items that no area claimed.
    package var unplaced: [DailyItem]
    package var lastRun: DailyRun?
    // The fields of the file that this app does not know. A save writes them again.
    package var unknown = UnknownFields()

    package static let empty = DailyState(marks: .fresh(""))

    package init(
        marks: DayMarks, lastSent: [String: Date] = [:], prevSent: [String: Date] = [:],
        areas: [String: AreaView] = [:], unplaced: [DailyItem] = [], lastRun: DailyRun? = nil
    ) {
        self.marks = marks
        self.lastSent = lastSent
        self.prevSent = prevSent
        self.areas = areas
        self.unplaced = unplaced
        self.lastRun = lastRun
    }

    // MARK: The changes

    // A new day gives fresh marks. A draft that the user changed on an earlier day is not kept
    // apart any more, so the run of the new day replaces it.
    package mutating func rollDay(to today: String) {
        guard marks.date != today else { return }
        for id in areas.keys {
            areas[id]?.pending = nil
            areas[id]?.edited = false
        }
        marks = .fresh(today)
    }

    // A run replaces the items of each area and its draft. A draft that the user changed stays,
    // and a different new draft waits beside it as the pending draft. since gives the start of
    // the run for an area.
    package mutating func apply(
        run results: [DailyAreaResult], unplaced: [DailyItem], at: Date,
        since: [String: Date] = [:]
    ) {
        for result in results {
            var view = AreaView(
                items: result.items, moved: result.moved, draft: result.draft,
                since: since[result.id])
            if let old = areas[result.id], old.edited {
                view.draft = old.draft
                view.edited = true
                if result.draft != old.draft { view.pending = result.draft }
            }
            areas[result.id] = view
        }
        self.unplaced = unplaced
        lastRun = DailyRun(at: at, ok: true)
    }

    // Redo replaces the area of its own tab, also a draft that the user changed.
    package mutating func redo(_ result: DailyAreaResult, since: Date? = nil) {
        areas[result.id] = AreaView(
            items: result.items, moved: result.moved, draft: result.draft, since: since)
    }

    package mutating func editDraft(_ id: String, text: String) {
        areas[id]?.draft = text
        areas[id]?.edited = true
    }

    // Take the pending draft in place of the draft of the user.
    package mutating func usePending(_ id: String) {
        guard let pending = areas[id]?.pending else { return }
        areas[id]?.draft = pending
        areas[id]?.pending = nil
        areas[id]?.edited = false
    }

    // Keep the draft of the user and drop the pending draft.
    package mutating func keepMine(_ id: String) {
        areas[id]?.pending = nil
    }

    package mutating func markSent(_ id: String, at: Date) {
        prevSent[id] = lastSent[id]
        lastSent[id] = at
        marks.sent[id] = at
    }

    package mutating func undoSent(_ id: String) {
        lastSent[id] = prevSent[id]
        prevSent[id] = nil
        marks.sent[id] = nil
    }

    // Skip today for all areas.
    package mutating func setSkipped(_ skipped: Bool) { marks.skipped = skipped }

    package mutating func setFirstShown() { marks.firstShown = true }

    package mutating func setSecondShown() { marks.secondShown = true }

    package mutating func failRun(at: Date, _ failure: FailureCode, detail: String? = nil) {
        lastRun = DailyRun(at: at, ok: false, failure: failure, detail: detail)
    }

    // MARK: Codable

    private enum Key: String, CodingKey {
        case version, marks, lastSent, prevSent, areas, unplaced, lastRun
    }

    // The decode never fails on a bad part: a bad part gives its empty value, and a bad item or a
    // bad area is dropped. A file whose version is not 1 gives the empty state.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        self = .empty
        unknown = try UnknownFields(from: decoder, known: Key.self)
        guard (try? container.decode(Int.self, forKey: .version)) == 1 else { return }
        marks = (try? container.decode(DayMarks.self, forKey: .marks)) ?? .fresh("")
        lastSent = Stamps.decode(container, forKey: .lastSent)
        prevSent = Stamps.decode(container, forKey: .prevSent)
        let views = try? container.decode([String: Lenient<AreaView>].self, forKey: .areas)
        areas = (views ?? [:]).compactMapValues(\.decoded)
        unplaced = Lists.items(container, forKey: .unplaced)
        lastRun = try? container.decode(DailyRun.self, forKey: .lastRun)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(1, forKey: .version)
        try container.encode(marks, forKey: .marks)
        try container.encode(Stamps.milliseconds(lastSent), forKey: .lastSent)
        try container.encode(Stamps.milliseconds(prevSent), forKey: .prevSent)
        try container.encode(areas, forKey: .areas)
        try container.encode(unplaced, forKey: .unplaced)
        // The file has "lastRun": null for no run.
        try container.encode(lastRun, forKey: .lastRun)
        try unknown.encode(to: encoder)
    }
}

// MARK: - The edges of the file

// A time in the file is milliseconds since 1970. A value that is not a number, or that is
// larger than the limit, is dropped.
enum Stamps {
    static func date(_ milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }

    // The largest size of a stored time: the range of a JavaScript Date, so each value of the
    // Electron app fits. A larger value is read as missing.
    static let limit = 8.64e15

    // A Date outside the limit gives the limit, so the conversion to Int never traps.
    static func milliseconds(_ date: Date) -> Int {
        let value = (date.timeIntervalSince1970 * 1000).rounded()
        guard value.isFinite else { return 0 }
        return Int(max(-limit, min(limit, value)))
    }

    static func milliseconds(_ dates: [String: Date]) -> [String: Int] {
        dates.mapValues(milliseconds)
    }

    static func decode<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>, forKey key: Key
    ) -> [String: Date] {
        let numbers = try? container.decode([String: Lenient<Double>].self, forKey: key)
        return (numbers ?? [:]).compactMapValues {
            $0.decoded.flatMap { abs($0) <= limit ? $0 : nil }
        }
        .mapValues(date)
    }

    static func decodeOne<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>, forKey key: Key
    ) -> Date? {
        guard let number = try? container.decode(Double.self, forKey: key), abs(number) <= limit
        else { return nil }
        return date(number)
    }
}

enum Lists {
    // The good items of a list. A bad item is dropped. A value that is no list gives no items.
    static func items<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>, forKey key: Key
    ) -> [DailyItem] {
        let list = try? container.decode([Lenient<DailyItem>].self, forKey: key)
        return (list ?? []).compactMap(\.decoded)
    }
}
