import Foundation

// Any JSON value, for the host's lines and for the report. The check app has no dependencies, so
// it can't share the host's own type, and JSON has one number type, so every number is a Double.
enum JSON: Codable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByDictionaryLiteral
{
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }

    init(from decoder: any Decoder) throws {
        if let object = try? decoder.container(keyedBy: Field.self) {
            var fields: [String: JSON] = [:]
            for key in object.allKeys {
                fields[key.stringValue] = try object.decode(JSON.self, forKey: key)
            }
            self = .object(fields)
        } else if var array = try? decoder.unkeyedContainer() {
            var items: [JSON] = []
            while !array.isAtEnd { items.append(try array.decode(JSON.self)) }
            self = .array(items)
        } else {
            let scalar = try decoder.singleValueContainer()
            if scalar.decodeNil() {
                self = .null
            } else if let flag = try? scalar.decode(Bool.self) {
                self = .bool(flag)
            } else if let number = try? scalar.decode(Double.self) {
                self = .number(number)
            } else {
                self = .string(try scalar.decode(String.self))
            }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let flag): try container.encode(flag)
        case .number(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        case .array(let items): try container.encode(items)
        case .object(let fields): try container.encode(fields)
        }
    }

    subscript(key: String) -> JSON? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    subscript(index: Int) -> JSON? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    var number: Double? {
        if case .number(let number) = self { return number }
        return nil
    }

    var array: [JSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    // One line of JSON with sorted keys, so the same value always gives the same text.
    func encodedLine() -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Only a number that isn't finite fails to encode, and the check app makes none.
        return (try? Array(encoder.encode(self))) ?? Array("null".utf8)
    }

    private struct Field: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
