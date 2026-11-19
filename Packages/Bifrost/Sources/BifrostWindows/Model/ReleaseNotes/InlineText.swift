// The text format of the release notes. Only **bold** and `code` have a format. Each other
// character shows as plain text, so no part of a text is a link or any other markup.
import Foundation

package enum InlineText {
    package struct Part: Sendable, Equatable {
        package enum Kind: Sendable { case text, bold, code }

        package var kind: Kind
        package var text: String
    }

    // The parts of a text, in order. A marker with no end, and a marker with nothing between the
    // pair, stay as text.
    package static func parts(_ text: String) -> [Part] {
        let characters = Array(text)
        var parts: [Part] = []
        var plain = ""
        var index = 0
        while index < characters.count {
            if let pair = pair(in: characters, at: index) {
                if !plain.isEmpty { parts.append(Part(kind: .text, text: plain)) }
                plain = ""
                parts.append(pair.part)
                index = pair.end
                continue
            }
            // Skip a full "**" or "``", so its second character cannot start a pair.
            let double = hasMarker("**", characters, index) || hasMarker("``", characters, index)
            let step = double ? 2 : 1
            plain += String(characters[index..<min(index + step, characters.count)])
            index += step
        }
        if !plain.isEmpty { parts.append(Part(kind: .text, text: plain)) }
        return parts
    }

    // The text with the bold and code parts as attributes. The dialog shows it as it is.
    package static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        for part in parts(text) {
            var piece = AttributedString(part.text)
            switch part.kind {
            case .text: break
            case .bold: piece.inlinePresentationIntent = .stronglyEmphasized
            case .code: piece.inlinePresentationIntent = .code
            }
            result += piece
        }
        return result
    }

    // The pair of markers at the index, or nil. The content of a pair is not empty.
    private static func pair(
        in characters: [Character], at index: Int
    ) -> (part: Part, end: Int)? {
        let marker: [Character]
        let kind: Part.Kind
        if hasMarker("**", characters, index) {
            (marker, kind) = (["*", "*"], .bold)
        } else if characters[index] == "`" {
            (marker, kind) = (["`"], .code)
        } else {
            return nil
        }
        let start = index + marker.count
        guard let close = find(marker, in: characters, from: start), close > start else {
            return nil
        }
        return (Part(kind: kind, text: String(characters[start..<close])), close + marker.count)
    }

    private static func hasMarker(
        _ marker: String, _ characters: [Character], _ index: Int
    ) -> Bool {
        let wanted = Array(marker)
        return index + wanted.count <= characters.count
            && Array(characters[index..<index + wanted.count]) == wanted
    }

    // The index of the first place of the marker at or after `from`.
    private static func find(
        _ marker: [Character], in characters: [Character], from: Int
    ) -> Int? {
        guard from + marker.count <= characters.count else { return nil }
        return (from...(characters.count - marker.count)).first {
            Array(characters[$0..<$0 + marker.count]) == marker
        }
    }
}
