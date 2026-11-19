// The read and the write of the objects of state.json (docs/behaviour/reviews.md, "The state").
// Each stored type reads from a JSON value and writes a JSON value, with the field names and the
// forms of the Electron file. The read never throws: a field of the wrong form is dropped and its
// name goes in the dropped names, so one bad field costs only that field.
import BifrostFoundation
import Foundation

// The names of the fields that a read dropped, for example "queue" or "prs.round". A name is a
// known field name and never a key of the file (a PR key, an item ID or a login), so the log can
// show it.
package struct DroppedFields: Sendable, Equatable {
    package private(set) var names: Set<String> = []

    package init() {}

    package mutating func add(_ name: String) {
        names.insert(name)
    }

    package var sorted: [String] { names.sorted() }
}

// A stored form of state.json. Its Codable conformance reads and writes its JSON value, so a
// decode drops each bad field with no error. Each type is at one place in the file, so it knows
// the names of its dropped fields.
package protocol StoredValue: Codable {
    // nil when the value is not a whole value of the type. A type that is lenient inside drops
    // only its bad fields.
    init?(stored value: JSONValue, dropped: inout DroppedFields)
    var stored: JSONValue { get }
}

extension StoredValue {
    package init(from decoder: any Decoder) throws {
        var dropped = DroppedFields()
        guard let value = Self(stored: try JSONValue(from: decoder), dropped: &dropped) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Not a stored value."))
        }
        self = value
    }

    package func encode(to encoder: any Encoder) throws {
        try stored.encode(to: encoder)
    }
}

// The fields of one stored object, and its place in the file: "" for the state, "prs" for a PR.
struct StoredObject {
    let fields: [String: JSONValue]
    let place: String

    init?(_ value: JSONValue, place: String) {
        guard let fields = value.object else { return nil }
        self.fields = fields
        self.place = place
    }

    // The name of a field in the dropped names.
    func name(_ key: String) -> String {
        place.isEmpty ? key : "\(place).\(key)"
    }

    // The value of a field. A missing field and null give nil.
    subscript(_ key: String) -> JSONValue? {
        guard let value = fields[key], value != .null else { return nil }
        return value
    }

    // The value that make gives from a field. A missing field or null gives nil. A value that
    // make refuses gives nil and drops the field.
    func read<Value>(
        _ key: String, _ dropped: inout DroppedFields,
        _ make: (JSONValue, inout DroppedFields) -> Value?
    ) -> Value? {
        guard let value = self[key] else { return nil }
        guard let made = make(value, &dropped) else {
            dropped.add(name(key))
            return nil
        }
        return made
    }

    // A field whose value needs no dropped names of its own.
    func read<Value>(
        _ key: String, _ dropped: inout DroppedFields, _ make: (JSONValue) -> Value?
    ) -> Value? {
        read(key, &dropped) { value, _ in make(value) }
    }

    // A flag. A missing field or null is false.
    func flag(_ key: String, _ dropped: inout DroppedFields) -> Bool {
        read(key, &dropped, \.flag) ?? false
    }

    // The items of a list that make accepts, in their order. A bad item goes, and so does a value
    // that is not a list. Each loss drops the field.
    func list<Item>(
        _ key: String, _ dropped: inout DroppedFields, _ make: (JSONValue) -> Item?
    ) -> [Item] {
        guard let value = self[key] else { return [] }
        guard let items = value.array else {
            dropped.add(name(key))
            return []
        }
        let kept = items.compactMap(make)
        if kept.count != items.count { dropped.add(name(key)) }
        return kept
    }

    // The entries of a map whose keys makeKey accepts and whose values make accepts. A bad entry
    // goes, and so does a value that is not an object. Two texts that give one key (two spellings
    // of one PR) keep the first text in sorted order. Each loss drops the field.
    func map<Key: Hashable, Value>(
        _ key: String, _ dropped: inout DroppedFields, key makeKey: (String) -> Key?,
        _ make: (JSONValue, inout DroppedFields) -> Value?
    ) -> [Key: Value] {
        guard let value = self[key] else { return [:] }
        guard let object = value.object else {
            dropped.add(name(key))
            return [:]
        }
        var map: [Key: Value] = [:]
        for text in object.keys.sorted() {
            guard let entryKey = makeKey(text), map[entryKey] == nil, let entry = object[text],
                let made = make(entry, &dropped)
            else {
                dropped.add(name(key))
                continue
            }
            map[entryKey] = made
        }
        return map
    }

    // A map whose values need no dropped names of their own.
    func map<Key: Hashable, Value>(
        _ key: String, _ dropped: inout DroppedFields, key makeKey: (String) -> Key?,
        _ make: (JSONValue) -> Value?
    ) -> [Key: Value] {
        map(key, &dropped, key: makeKey) { value, _ in make(value) }
    }
}

// The values of the stored fields.
extension JSONValue {
    // The largest wall time of the file, in milliseconds from 1970: the limit of a JavaScript
    // date. A larger number is not a time, so a save never meets a number that Int cannot hold.
    static let maxTime = 8.64e15

    // A wall time: a number of milliseconds since 1970, at most maxTime from 1970.
    var time: Date? {
        guard let milliseconds = finiteNumber, abs(milliseconds) <= Self.maxTime else {
            return nil
        }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    var flag: Bool? {
        if case .bool(let flag) = self { flag } else { nil }
    }

    var nodeID: NodeID? { string.flatMap(NodeID.init) }

    var commitID: CommitID? { string.flatMap(CommitID.init) }

    var prKey: PRKey? { string.flatMap { PRKey(text: $0) } }

    // The stored form of a wall time: whole milliseconds since 1970, rounded to the nearest, so a
    // read and a write give the same number.
    static func time(_ date: Date) -> JSONValue {
        .int(Int((date.timeIntervalSince1970 * 1000).rounded()))
    }

    // A wall time, or null.
    static func time(_ date: Date?) -> JSONValue {
        date.map { time($0) } ?? .null
    }

    // A text, or null.
    static func text(_ text: String?) -> JSONValue {
        text.map(JSONValue.string) ?? .null
    }

    // A map of keys and wall times, with the text of each key.
    static func times<Key: CustomStringConvertible>(_ map: [Key: Date]) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: map.map { ($0.key.description, time($0.value)) }))
    }

    // A map of keys and stored values, with the text of each key.
    static func stored<Key: CustomStringConvertible, Value: StoredValue>(
        _ map: [Key: Value]
    ) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: map.map { ($0.key.description, $0.value.stored) }))
    }
}
