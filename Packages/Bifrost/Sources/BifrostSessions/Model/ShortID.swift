// The short ID of a session in "claude agents --json": 8 lower-case hex digits. Bifrost passes it
// to "claude attach <short id>". The parse reads the bytes of the text, so a short ID can never
// start with "-" and can never be an option of claude.
package struct ShortID: Hashable, Sendable {
    // The 8 hex digits: the stored form in the store file and the argument of claude attach.
    package let text: String

    // nil when the text is not 8 lower-case hex digits.
    package init?(_ text: some StringProtocol) {
        guard text.utf8.count == 8, text.utf8.allSatisfy(Self.isLowerHexDigit) else { return nil }
        self.text = String(text)
    }

    private static func isLowerHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"): true
        default: false
        }
    }
}

extension ShortID: CustomStringConvertible {
    package var description: String { text }
}

// The order of the texts.
extension ShortID: Comparable {
    package static func < (a: ShortID, b: ShortID) -> Bool { a.text < b.text }
}

// In a file, a short ID is a JSON text. The decode refuses a text that is not a short ID.
extension ShortID: Codable {
    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let id = ShortID(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "The text is not a short ID.")
        }
        self = id
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}
