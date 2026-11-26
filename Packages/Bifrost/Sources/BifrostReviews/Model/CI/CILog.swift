// The cleaner of the log of a GitHub Actions job (task C1 of the CI watcher). The text goes to a
// file for Claude, so it has no escape sequence and no control character, and it has a size
// limit. The cleaner is pure: it does no I/O.
import Foundation

package enum CILog {
    // The most bytes of the cleaned log that a file keeps.
    package static let keptBytes = 200_000
    // The first line of a cut log. It does not count in the limit.
    package static let cutNote = "[Bifrost cut the start of this log.]\n"

    // The cleaned text of the bytes of a log, and true when the start was cut. An invalid byte
    // becomes U+FFFD. A longer text keeps its tail of keep bytes at most. The tail starts at its
    // own start when a line break comes just before it, else after its first line break, else at
    // the first whole character.
    package static func text(_ data: Data, keep: Int = CILog.keptBytes) -> (text: String, cut: Bool)
    {
        let decoded = String(decoding: data, as: UTF8.self)
        let clean = removeControls(removeEscapes(decoded))
        let bytes = Array(clean.utf8)
        guard bytes.count > keep else { return (clean, false) }
        var start = bytes.count - max(keep, 0)
        if start > 0, bytes[start - 1] == 0x0A {
            // The tail already starts at a line start: keep it from its start.
        } else if let lineBreak = bytes[start...].firstIndex(of: 0x0A) {
            start = lineBreak + 1
        } else {
            // Skip the continuation bytes of a character that the cut split.
            while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
        }
        return (cutNote + String(decoding: bytes[start...], as: UTF8.self), true)
    }

    // Removes CSI (ESC [ ... final byte), OSC (ESC ] ... BEL or ESC \) and two-byte ESC
    // sequences. The scan runs on unicode scalars.
    private static func removeEscapes(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\u{1B}" else {
                out.append(scalar)
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count else { break }
            let kind = scalars[index]
            // A line feed or an ESC after an ESC is not a part of this sequence.
            if kind == "\n" || kind == "\u{1B}" { continue }
            index += 1
            if kind == "[" {
                // CSI: parameter and intermediate bytes (0x20 to 0x3F), then one final byte
                // (0x40 to 0x7E). Any other scalar ends the scan and stays in the text.
                while index < scalars.count, (0x20...0x3F).contains(scalars[index].value) {
                    index += 1
                }
                if index < scalars.count, (0x40...0x7E).contains(scalars[index].value) {
                    index += 1
                }
            } else if kind == "]" {
                index = endOfOSC(scalars, from: index)
            }
            // Any other kind is a two-byte sequence: ESC and its one character are gone.
        }
        return String(out)
    }

    // The index after an OSC. It ends at BEL or ESC \ (both go). It stops before any other ESC,
    // so the main loop removes that sequence, and before a line feed, so the line stays.
    private static func endOfOSC(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            switch scalars[index] {
            case "\u{7}": return index + 1
            case "\u{1B}":
                let isTerminator = index + 1 < scalars.count && scalars[index + 1] == "\\"
                return isTerminator ? index + 2 : index
            case "\n": return index
            default: index += 1
            }
        }
        return index
    }

    // Removes CR and each other control character except LF and tab.
    private static func removeControls(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\t" || scalar.properties.generalCategory != .control {
                out.append(scalar)
            }
        }
        return String(out)
    }
}
