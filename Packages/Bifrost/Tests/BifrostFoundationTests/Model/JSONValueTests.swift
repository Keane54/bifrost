import Foundation
import Testing

@testable import BifrostFoundation

// The JSON value type and the unknown fields of a stored object. The store files keep each field
// that the app does not read.

private func decode(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite("JSON value")
struct JSONValueTests {
    @Test func theDecodeGivesEachKindOfValue() throws {
        let value = try decode(#"[null, true, false, 7, -0, 1.5, 1e2, "x", [1], {"a": {"b": []}}]"#)
        #expect(
            value
                == .array([
                    .null, .bool(true), .bool(false), .int(7), .int(0), .double(1.5), .int(100),
                    .string("x"), .array([.int(1)]), .object(["a": .object(["b": .array([])])]),
                ]))
    }

    // A number that Double cannot hold and a lone surrogate throw the error of the parser.
    @Test func aValueWithNoJSONFormThrows() {
        for text in ["[1e400]", #"{"a": "\ud800"}"#] {
            #expect(throws: DecodingError.self) { try decode(text) }
        }
    }

    // JSON has one number type. A whole number that does not fit in Int stays a Double.
    @Test func aNumberIsAnIntWhenItIsWholeAndFits() throws {
        #expect(try decode("1.0") == .int(1))
        #expect(try decode("12345678901234567890") == .double(12_345_678_901_234_567_168))
        #expect(try decode("0.5") == .double(0.5))
    }

    @Test func wholeNumberAcceptsAnIntAndAWholeDouble() {
        #expect(JSONValue.int(3).wholeNumber == 3)
        #expect(JSONValue.double(3).wholeNumber == 3)
        #expect(JSONValue.double(-0.0).wholeNumber == 0)
        let others: [JSONValue] = [
            .double(3.5), .double(1e20), .double(-1e20), .double(.infinity), .double(.nan),
            .string("3"), .bool(true), .null, .array([.int(3)]), .object([:]),
        ]
        #expect(others.allSatisfy { $0.wholeNumber == nil })
    }

    @Test func finiteNumberAcceptsAnIntAndAFiniteDouble() {
        #expect(JSONValue.int(3).finiteNumber == 3)
        #expect(JSONValue.double(2.5).finiteNumber == 2.5)
        let others: [JSONValue] = [
            .double(.infinity), .double(-.infinity), .double(.nan), .string("3"), .bool(true),
            .null, .array([.int(3)]), .object([:]),
        ]
        #expect(others.allSatisfy { $0.finiteNumber == nil })
    }

    @Test func eachPartGivesOnlyTheValueOfItsKind() {
        let values: [JSONValue] = [
            .null, .bool(true), .int(1), .double(1.5), .string("x"), .array([.int(1)]),
            .object(["a": .int(1)]),
        ]
        #expect(values.compactMap(\.object) == [["a": .int(1)]])
        #expect(values.compactMap(\.array) == [[.int(1)]])
        #expect(values.compactMap(\.string) == ["x"])
    }

    @Test func anEncodeThenADecodeGivesTheSameValue() throws {
        let value: JSONValue = [
            "a": [1, 2.5, "two", true, .null],
            "b": ["c": [:], "d": []],
            "e": "/path/é😀",
        ]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test func theLiteralsGiveTheSameCases() {
        let value: JSONValue = ["a": [true, 1, 1.5, "x"]]
        #expect(value == .object(["a": .array([.bool(true), .int(1), .double(1.5), .string("x")])]))
    }
}

// A stored type with two known keys and the unknown fields of its file.
private struct Stored: Codable, Equatable {
    enum Key: String, CodingKey { case version, labels }

    var labels = "plain"
    var unknown = UnknownFields()

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        unknown = try UnknownFields(from: decoder, known: Key.self)
        labels = (try? container.decode(String.self, forKey: .labels)) ?? "plain"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(1, forKey: .version)
        try container.encode(labels, forKey: .labels)
        try unknown.encode(to: encoder)
    }
}

@Suite("unknown fields")
struct UnknownFieldsTests {
    @Test func theDecodeKeepsOnlyTheKeysThatTheTypeDoesNotName() throws {
        let text = #"{"version": 1, "labels": "space", "theme": "light", "zoom": [2]}"#
        let stored = try JSONDecoder().decode(Stored.self, from: Data(text.utf8))
        #expect(stored.labels == "space")
        #expect(stored.unknown.values == ["theme": "light", "zoom": [2]])
    }

    // One encode writes the known keys and then the unknown fields, in the text form of the
    // stores.
    @Test func theEncodeWritesTheUnknownFieldsAfterTheKnownKeys() throws {
        var stored = Stored()
        stored.labels = "space"
        stored.unknown = UnknownFields(["theme": "light", "zoom": [2]])
        let text = String(decoding: try JSONFile.encode(stored), as: UTF8.self)
        #expect(
            text == """
                {
                  "labels" : "space",
                  "theme" : "light",
                  "version" : 1,
                  "zoom" : [
                    2
                  ]
                }

                """)
        #expect(try JSONDecoder().decode(Stored.self, from: Data(text.utf8)) == stored)
    }

    // A type that parses a JSON value keeps the fields whose keys it does not know.
    @Test func theFieldsOfAParsedObjectKeepOnlyTheKeysThatAreNotKnown() {
        let object: [String: JSONValue] = ["name": "a", "theme": "light", "zoom": [2]]
        let unknown = UnknownFields(object, known: ["name", "tabs"])
        #expect(unknown.values == ["theme": "light", "zoom": [2]])
    }

    @Test func aMergeAddsTheUnknownFieldsAndAKnownKeyWins() {
        let unknown = UnknownFields(["name": "old", "theme": "light"])
        #expect(unknown.merged(with: ["name": "new"]) == ["name": "new", "theme": "light"])
        #expect(UnknownFields().merged(with: ["name": "new"]) == ["name": "new"])
    }

    // A value with no JSON form makes the decode throw NoJSONForm, whatever error the decoder
    // gives: the store then keeps a copy of the file.
    @Test func anUnknownValueWithNoJSONFormMakesTheFileUnparsable() {
        for text in [#"{"big": 1e400}"#, #"{"text": ["\ud800"]}"#] {
            #expect(throws: NoJSONForm()) {
                try JSONDecoder().decode(Stored.self, from: Data(text.utf8))
            }
        }
    }
}

// The compact size of a store text, with no second encode.
@Suite("the compact size of a store text")
struct CompactSizeTests {
    @Test func theCountIsTheSizeOfTheCompactJSON() throws {
        let value: JSONValue = [
            "a b": ["x y", " ", "\"quoted\" \\ back", "line\nbreak", "/path/é😀"],
            "c": [1, 2.5, true, .null, [:], []],
            "d": ["e": ["f": "  spaces  "]],
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let compact = try encoder.encode(value)
        #expect(JSONFile.compactSize(ofStoreText: try JSONFile.encode(value)) == compact.count)
    }
}
