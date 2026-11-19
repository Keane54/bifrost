// The ID of a Claude Code session: a UUID in the 8-4-4-4-12 form. The parse reads the bytes of
// the text and accepts hex digits of either case. The value keeps the ID in lower case, so the
// two forms of one ID are one value. A chat panel, a Show Info panel, the current ID of a stored
// row and the session of a line of the Live details mod hold this form.
public struct SessionID: Hashable, Sendable {
    // The ID in lower case: its stored form in the files and in the test port.
    public let text: String

    // The places of the four hyphens.
    private static let hyphens: Set<Int> = [8, 13, 18, 23]

    // nil when the text is not a UUID in the 8-4-4-4-12 form. A text with a NUL character, a
    // line break or a digit of another script is not a session ID.
    public init?(_ text: some StringProtocol) {
        guard text.utf8.count == 36 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(36)
        for (index, byte) in text.utf8.enumerated() {
            if Self.hyphens.contains(index) {
                guard byte == UInt8(ascii: "-") else { return nil }
                bytes.append(byte)
            } else {
                guard let digit = Self.lowerHexDigit(byte) else { return nil }
                bytes.append(digit)
            }
        }
        self.text = String(decoding: bytes, as: UTF8.self)
    }

    // The hex digit in lower case, or nil for another byte.
    private static func lowerHexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"): byte
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte + 32
        default: nil
        }
    }
}

extension SessionID: CustomStringConvertible {
    public var description: String { text }
}

// The order of the texts.
extension SessionID: Comparable {
    public static func < (a: SessionID, b: SessionID) -> Bool { a.text < b.text }
}
