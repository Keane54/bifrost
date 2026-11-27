import Foundation

// The lines between the module host and its parent, protocol version 0. Every line is one JSON
// object with a "type": the parent sends the module's code once, then pings and events, and the
// host answers with its hello first, then batches of screen changes, pongs and log lines.

// The longest line the host takes from its parent, newline not counted. The module's code comes
// as one line, so it gets far more room than the pings and events after it.
package enum HostLimits {
    package static let codeLineBytes = 8 * 1024 * 1024
    package static let lineBytes = 64 * 1024
}

// Any JSON value. BifrostFoundation has its own, but the host links nothing but Foundation and
// JavaScriptCore, so this one lives here. JSON has one number type, so every number is a Double.
package enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    package init(from decoder: any Decoder) throws {
        if let object = try? decoder.container(keyedBy: Key.self) {
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

    // A number that isn't finite has no JSON form, so the encode throws on it.
    package func encode(to encoder: any Encoder) throws {
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

    // The keys of an object, which can be any string.
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

// A line from the parent. A type the host doesn't know is refused rather than skipped, so a
// parent that speaks another version of the protocol finds out on its first line.
package enum HostMessage: Decodable, Equatable, Sendable {
    case code(String)
    case ping(Int)
    case event(handler: Int, value: JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type, source, id, handler, value
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "code":
            self = .code(try container.decode(String.self, forKey: .source))
        case "ping":
            self = .ping(try container.decode(Int.self, forKey: .id))
        case "event":
            self = .event(
                handler: try container.decode(Int.self, forKey: .handler),
                value: try container.decode(JSONValue.self, forKey: .value))
        case let type:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown message type \(type)")
        }
    }
}

// A line from the host. The keys go out sorted, so the same reply always gives the same bytes.
package enum HostReply: Encodable, Sendable {
    case hello(SelfTestResult)
    case batch([JSONValue])
    case pong(Int)
    case log(String)

    package static let protocolVersion = 0

    private enum CodingKeys: String, CodingKey {
        case type, `protocol`, selfTest, ops, id, text
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let result):
            try container.encode("hello", forKey: .type)
            try container.encode(Self.protocolVersion, forKey: .protocol)
            try container.encode(result, forKey: .selfTest)
        case .batch(let ops):
            try container.encode("batch", forKey: .type)
            try container.encode(ops, forKey: .ops)
        case .pong(let id):
            try container.encode("pong", forKey: .type)
            try container.encode(id, forKey: .id)
        case .log(let text):
            try container.encode("log", forKey: .type)
            try container.encode(text, forKey: .text)
        }
    }

    // The reply as one line of JSON, without its newline. JSON escapes a newline inside a
    // string, so the bytes never hold one.
    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }
}
