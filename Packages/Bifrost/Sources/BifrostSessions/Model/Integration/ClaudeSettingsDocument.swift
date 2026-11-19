import Foundation

// A JSON object of the settings file of Claude Code, with its keys in the order of the file
// (docs/behaviour/live.md, "The edit of the Claude Code settings file"). Bifrost changes only its
// own entries, and each other part of the file keeps its place and its text:
// - each object keeps the order of its keys;
// - a number keeps its text, for example 1.0, 1e3 or -0;
// - a string keeps its text between the quotes, with each escape as the file has it.
//
// The parse follows the JSON grammar (RFC 8259), and it reads the file as Claude Code reads it:
// - the bytes must be UTF-8, and a byte order mark at the start is skipped;
// - a key that the object has already keeps its first place and gets the last value;
// - two keys are the same key when their texts have the same UTF-16 code units. So a key with an
//   escape and the same key with no escape are one key, and a precomposed "é" and "e" with a
//   combining accent are two keys.
// A value with more than maxDepth levels of objects and arrays is refused. The parse, the text
// and the compare are recursive, so the limit keeps their use of the stack small, also for a
// hostile file.
//
// text gives two spaces of indent for each level, ": " after a key, "{}" or "[]" for an empty
// object or array, and a newline at the end.
package struct ClaudeSettingsDocument: Sendable, Equatable {
    // The most levels of objects and arrays in a file. The object of the file is level 1. A
    // settings file of Claude Code has about 7 levels. A debug build uses up to 2 KB of stack for
    // each level of the parse, and a thread of the blocking executor has 512 KB.
    package static let maxDepth = 64

    // Why a parse failed.
    package enum ParseError: Error, Sendable, Equatable {
        // The bytes are not UTF-8, or the text is not JSON.
        case notJSON
        // The text is JSON, but the value is not an object.
        case notObject
        // The value has more than maxDepth levels of objects and arrays.
        case tooDeep
    }

    // One JSON value, as the file has it.
    package enum Value: Sendable, Equatable {
        case object(ClaudeSettingsDocument)
        case array([Value])
        case string(Text)
        // The text of the number in the file.
        case number(String)
        case bool(Bool)
        case null

        package var object: ClaudeSettingsDocument? {
            if case .object(let object) = self { object } else { nil }
        }

        package var array: [Value]? {
            if case .array(let items) = self { items } else { nil }
        }

        package var text: Text? {
            if case .string(let text) = self { text } else { nil }
        }
    }

    // A JSON string: the text between the quotes as the file has it, and the UTF-16 code units of
    // its value. A lone surrogate (for example "\ud83d") stays in both.
    package struct Text: Sendable, Equatable {
        package let raw: String
        package let units: [UInt16]

        fileprivate init(raw: String, units: [UInt16]) {
            self.raw = raw
            self.units = units
        }

        // The JSON string of a value: a quote, a backslash and each control character get an
        // escape (\b, \f, \n, \r and \t, else \u00xx). Each other character stays.
        package init(_ value: String) {
            var raw = ""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": raw += "\\\""
                case "\\": raw += "\\\\"
                case "\u{08}": raw += "\\b"
                case "\u{0C}": raw += "\\f"
                case "\n": raw += "\\n"
                case "\r": raw += "\\r"
                case "\t": raw += "\\t"
                case _ where scalar.value < 0x20:
                    let hex = String(scalar.value, radix: 16)
                    raw += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                default: raw.unicodeScalars.append(scalar)
                }
            }
            self.init(raw: raw, units: Array(value.utf16))
        }

        // True when the value is this text, by UTF-16 code units.
        package func `is`(_ value: String) -> Bool {
            units.elementsEqual(value.utf16)
        }
    }

    // A key and its value.
    package struct Member: Sendable, Equatable {
        package var key: Text
        package var value: Value
    }

    // The members in the order of the file. A key is in the list one time.
    package private(set) var members: [Member] = []

    // An empty object.
    package init() {}

    package var isEmpty: Bool { members.isEmpty }

    // The value of the key, or nil when the object has no such key.
    package subscript(key: String) -> Value? {
        members.first { $0.key.is(key) }?.value
    }

    // Give the key this value. A key of the object keeps its place. A new key goes at the end.
    package mutating func setValue(_ value: Value, forKey key: String) {
        setValue(value, forKey: Text(key))
    }

    package mutating func setValue(_ value: Value, forKey key: Text) {
        if let place = members.firstIndex(where: { $0.key.units == key.units }) {
            members[place].value = value
        } else {
            members.append(Member(key: key, value: value))
        }
    }

    // Remove the key and its value. A key that the object does not have changes nothing.
    package mutating func removeValue(forKey key: String) {
        members.removeAll { $0.key.is(key) }
    }

    package mutating func removeValue(forKey key: Text) {
        members.removeAll { $0.key.units == key.units }
    }

    // The object with the value that the transform gives for each member, in the same order. A
    // nil value removes the member. The transform runs one time for each member.
    package func compactMapValues(_ transform: (Member) -> Value?) -> ClaudeSettingsDocument {
        var result = ClaudeSettingsDocument()
        result.members.reserveCapacity(members.count)
        for member in members {
            if let value = transform(member) {
                result.members.append(Member(key: member.key, value: value))
            }
        }
        return result
    }
}

// MARK: - The parse

extension ClaudeSettingsDocument {
    // The object of a file.
    package static func parse(_ data: Data) throws(ParseError) -> ClaudeSettingsDocument {
        guard case .object(let document) = try parseValue(data) else { throw .notObject }
        return document
    }

    // The value of a file of any type.
    package static func parseValue(_ data: Data) throws(ParseError) -> Value {
        let bytes = [UInt8](data)
        guard String(validating: bytes, as: UTF8.self) != nil else { throw .notJSON }
        let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
        var parser = Parser(bytes: bytes, index: bytes.starts(with: byteOrderMark) ? 3 : 0)
        return try parser.document()
    }

    // A parse of UTF-8 bytes. Each structural character of JSON is one ASCII byte, and the byte of
    // an ASCII character is never a part of a longer UTF-8 sequence. So a range between two such
    // bytes is valid UTF-8 too.
    private struct Parser {
        let bytes: [UInt8]
        var index: Int

        // The one value of the text, with only white space around it.
        mutating func document() throws(ParseError) -> Value {
            skipSpace()
            let value = try value(depth: 0)
            skipSpace()
            guard index == bytes.count else { throw .notJSON }
            return value
        }

        private var next: UInt8? { index < bytes.count ? bytes[index] : nil }

        // Skip the white space of JSON: space, tab, line feed and carriage return.
        private mutating func skipSpace() {
            while let byte = next, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            }
        }

        // The value at the index. depth is the count of the objects and arrays around it.
        private mutating func value(depth: Int) throws(ParseError) -> Value {
            switch next {
            case UInt8(ascii: "{"): return .object(try object(depth: depth + 1))
            case UInt8(ascii: "["): return .array(try array(depth: depth + 1))
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"):
                try literal("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try literal("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try literal("null")
                return .null
            case nil: throw .notJSON
            default: return .number(try number())
            }
        }

        private mutating func object(depth: Int) throws(ParseError) -> ClaudeSettingsDocument {
            guard depth <= ClaudeSettingsDocument.maxDepth else { throw .tooDeep }
            index += 1
            var object = ClaudeSettingsDocument()
            // The place of each key in the members.
            var places: [[UInt16]: Int] = [:]
            skipSpace()
            if next == UInt8(ascii: "}") {
                index += 1
                return object
            }
            while true {
                skipSpace()
                guard next == UInt8(ascii: "\"") else { throw .notJSON }
                let key = try string()
                skipSpace()
                guard next == UInt8(ascii: ":") else { throw .notJSON }
                index += 1
                skipSpace()
                let value = try value(depth: depth)
                if let place = places[key.units] {
                    object.members[place].value = value
                } else {
                    places[key.units] = object.members.count
                    object.members.append(Member(key: key, value: value))
                }
                skipSpace()
                switch next {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "}"):
                    index += 1
                    return object
                default: throw .notJSON
                }
            }
        }

        private mutating func array(depth: Int) throws(ParseError) -> [Value] {
            guard depth <= ClaudeSettingsDocument.maxDepth else { throw .tooDeep }
            index += 1
            var items: [Value] = []
            skipSpace()
            if next == UInt8(ascii: "]") {
                index += 1
                return items
            }
            while true {
                skipSpace()
                items.append(try value(depth: depth))
                skipSpace()
                switch next {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "]"):
                    index += 1
                    return items
                default: throw .notJSON
                }
            }
        }

        // A string from its opening quote. A control character must have an escape.
        private mutating func string() throws(ParseError) -> Text {
            index += 1
            let start = index
            var units: [UInt16] = []
            var plain = index
            while true {
                guard let byte = next else { throw .notJSON }
                switch byte {
                case UInt8(ascii: "\""):
                    units.append(contentsOf: utf16(plain..<index))
                    let raw = String(decoding: bytes[start..<index], as: UTF8.self)
                    index += 1
                    return Text(raw: raw, units: units)
                case UInt8(ascii: "\\"):
                    units.append(contentsOf: utf16(plain..<index))
                    units.append(try escape())
                    plain = index
                case 0..<0x20:
                    throw .notJSON
                default:
                    index += 1
                }
            }
        }

        // The code unit of the escape at the index. The index goes past the escape.
        private mutating func escape() throws(ParseError) -> UInt16 {
            index += 1
            guard let byte = next else { throw .notJSON }
            index += 1
            switch byte {
            case UInt8(ascii: "\""): return 0x22
            case UInt8(ascii: "\\"): return 0x5C
            case UInt8(ascii: "/"): return 0x2F
            case UInt8(ascii: "b"): return 0x08
            case UInt8(ascii: "f"): return 0x0C
            case UInt8(ascii: "n"): return 0x0A
            case UInt8(ascii: "r"): return 0x0D
            case UInt8(ascii: "t"): return 0x09
            case UInt8(ascii: "u"):
                var unit: UInt16 = 0
                for _ in 0..<4 {
                    guard let byte = next, let digit = Self.hexDigit(byte) else { throw .notJSON }
                    unit = unit << 4 | digit
                    index += 1
                }
                return unit
            default: throw .notJSON
            }
        }

        private static func hexDigit(_ byte: UInt8) -> UInt16? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt16(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt16(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt16(byte - UInt8(ascii: "A") + 10)
            default: nil
            }
        }

        // The UTF-16 code units of a range of the bytes with no escape in it.
        private func utf16(_ range: Range<Int>) -> String.UTF16View {
            String(decoding: bytes[range], as: UTF8.self).utf16
        }

        // A number: an optional minus, 0 or digits with no 0 first, an optional fraction, and an
        // optional exponent. The result is the text of the number.
        private mutating func number() throws(ParseError) -> String {
            let start = index
            if next == UInt8(ascii: "-") { index += 1 }
            if next == UInt8(ascii: "0") {
                index += 1
            } else {
                try digits()
            }
            if next == UInt8(ascii: ".") {
                index += 1
                try digits()
            }
            if next == UInt8(ascii: "e") || next == UInt8(ascii: "E") {
                index += 1
                if next == UInt8(ascii: "+") || next == UInt8(ascii: "-") { index += 1 }
                try digits()
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        // One digit or more.
        private mutating func digits() throws(ParseError) {
            guard let byte = next, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else {
                throw .notJSON
            }
            while let byte = next, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                index += 1
            }
        }

        private mutating func literal(_ word: String) throws(ParseError) {
            let word = Array(word.utf8)
            guard bytes[index...].starts(with: word) else { throw .notJSON }
            index += word.count
        }
    }
}

// MARK: - The text

extension ClaudeSettingsDocument {
    // The text of the object for the file.
    package var text: String {
        var text = ""
        Self.write(.object(self), indent: "", to: &text)
        text += "\n"
        return text
    }

    private static func write(_ value: Value, indent: String, to text: inout String) {
        switch value {
        case .object(let object):
            guard !object.members.isEmpty else {
                text += "{}"
                return
            }
            let inner = indent + "  "
            text += "{\n"
            for (place, member) in object.members.enumerated() {
                if place > 0 { text += ",\n" }
                text += inner + "\"" + member.key.raw + "\": "
                write(member.value, indent: inner, to: &text)
            }
            text += "\n" + indent + "}"
        case .array(let items):
            guard !items.isEmpty else {
                text += "[]"
                return
            }
            let inner = indent + "  "
            text += "[\n"
            for (place, item) in items.enumerated() {
                if place > 0 { text += ",\n" }
                text += inner
                write(item, indent: inner, to: &text)
            }
            text += "\n" + indent + "]"
        case .string(let string): text += "\"" + string.raw + "\""
        case .number(let number): text += number
        case .bool(let flag): text += flag ? "true" : "false"
        case .null: text += "null"
        }
    }
}
