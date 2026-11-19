// One JSON value of any form. The stores keep the unknown fields of a file and the raw values of
// later phases as JSON values.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // The value as a whole number: an int, or a double with an integral value in the Int range.
    // JSON has one number type, so 5.0 is the whole number 5.
    package var wholeNumber: Int? {
        switch self {
        case .int(let number): number
        case .double(let number): Int(exactly: number)
        default: nil
        }
    }

    // The value as a finite number: an int or a finite double. JSON has one number type, so an
    // int gives its Double value.
    package var finiteNumber: Double? {
        switch self {
        case .int(let number): Double(number)
        case .double(let number) where number.isFinite: number
        default: nil
        }
    }

    // The fields of an object, or nil for each other kind of value.
    package var object: [String: JSONValue]? {
        if case .object(let fields) = self { fields } else { nil }
    }

    // The items of an array, or nil for each other kind of value.
    package var array: [JSONValue]? {
        if case .array(let items) = self { items } else { nil }
    }

    // The text of a string, or nil for each other kind of value.
    package var string: String? {
        if case .string(let text) = self { text } else { nil }
    }

    // The JSON value of a number, in the form that the decode gives: a number with an integral
    // value in the Int range is an int (-0 gives 0), and each other number is a double. So a
    // value that a store makes is equal to the value of its file after a load.
    public static func number(_ value: Double) -> JSONValue {
        Int(exactly: value).map(JSONValue.int) ?? .double(value)
    }
}

extension JSONValue: Codable {
    // The decode reads an object or an array first, then a scalar: null, Bool, Int, Double,
    // String. A number with an integral value that fits in Int is an int. Each other number is a
    // double. A number that Double cannot hold (1e400) and a string with a lone surrogate throw
    // the error of the JSON parser, so a store treats the file as a file that does not parse.
    public init(from decoder: any Decoder) throws {
        if let object = try? decoder.container(keyedBy: DynamicKey.self) {
            var fields: [String: JSONValue] = [:]
            for key in object.allKeys {
                fields[key.stringValue] = try object.decode(JSONValue.self, forKey: key)
            }
            self = .object(fields)
        } else if var array = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            while !array.isAtEnd { items.append(try array.decode(JSONValue.self)) }
            self = .array(items)
        } else {
            self = try Self.scalar(decoder.singleValueContainer())
        }
    }

    private static func scalar(_ container: any SingleValueDecodingContainer) throws -> JSONValue {
        if container.decodeNil() { return .null }
        if let flag = try? container.decode(Bool.self) { return .bool(flag) }
        if let number = try? container.decode(Int.self) { return .int(number) }
        do {
            return .double(try container.decode(Double.self))
        } catch DecodingError.typeMismatch(_, _) {
            // Not a number, so a string.
        }
        return .string(try container.decode(String.self))
    }

    // A double that is not finite has no JSON form, so the encode throws.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let flag): try container.encode(flag)
        case .int(let number): try container.encode(number)
        case .double(let number): try container.encode(number)
        case .string(let text): try container.encode(text)
        case .array(let items): try container.encode(items)
        case .object(let fields): try container.encode(fields)
        }
    }
}

// The literals make the JSON values in code and in tests easy to read.
extension JSONValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }

    // A repeated key keeps its first value, as the JSON decode does.
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements) { first, _ in first })
    }
}
