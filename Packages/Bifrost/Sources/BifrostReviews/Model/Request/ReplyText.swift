// The fixed texts of the writes of a request round (docs/behaviour/reviews.md, "The push and the
// writes"): the "Fixed by" reply, the quote of a top-level request, and the break of each
// mention. Bifrost puts a zero-width space after each @ that can start a mention, in the quote
// and in the reply, so GitHub sends no new mention notification. The space shows nothing.
import BifrostFoundation
import Foundation

package enum ReplyText {
    // The longest quote of a request, in UTF-16 units, and its most lines.
    package static let maxQuote = 300, quoteLines = 3
    // The zero-width space after an @.
    package static let mentionBreak: Unicode.Scalar = "\u{200B}"

    // The fixed reply of a Fixed item.
    package static func fixedBy(_ commit: CommitID) -> String { "Fixed by \(commit.short)" }

    // The quote of a request for a PR comment: its first quoteLines lines, cut at maxQuote, each
    // with "> " before it, with each mention broken. An empty request gives an empty quote.
    package static func quoted(_ request: String) -> String {
        let lines = flatLines(request).trimmed()
            .split(separator: "\n", omittingEmptySubsequences: false).prefix(quoteLines)
        let text = trimmedEnd(lines.joined(separator: "\n")).cut(utf16: maxQuote)
        guard !text.trimmed().isEmpty else { return "" }
        let quote = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { trimmedEnd("> " + $0) }.joined(separator: "\n")
        return breakMentions(quote)
    }

    // The body of a PR comment: the quote, an empty line and the reply. An empty quote gives the
    // reply only.
    package static func comment(quote: String, reply: String) -> String {
        quote.isEmpty ? reply : quote + "\n\n" + reply
    }

    // Put a zero-width space after each @ that can start a mention. An HTML entity that makes an
    // @ becomes an @ with the space. These stay as they are: an @ before white space or at the
    // end, an @ right after a word (an email address), and an @ inside a link that GitHub makes
    // from a bare address (GitHub sends no notification there). A text with an HTML tag keeps no
    // link, because GitHub makes no link in an HTML block. A second pass changes nothing.
    package static func breakMentions(_ text: String) -> String {
        let plain = text.replacing(/&(?:#0*64|#[xX]0*40|commat);?/, with: "@\u{200B}")
        let scalars = Array(plain.unicodeScalars)
        let links = plain.contains(/<[A-Za-z\/!?]/) ? [] : linkRanges(plain)
        var out = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            out.append(scalar)
            guard scalar == "@", index + 1 < scalars.count,
                !scalars[index + 1].properties.isWhitespace, scalars[index + 1] != mentionBreak,
                !afterWord(scalars, index),
                !links.contains(where: { index > $0.lowerBound && index < $0.upperBound })
            else { continue }
            out.append(mentionBreak)
        }
        return String(out)
    }

    // True when GitHub holds the text that Bifrost sent. GitHub can change the line ends and drop
    // the zero-width spaces.
    package static func isSame(_ posted: String, as sent: String) -> Bool {
        flat(posted) == flat(sent)
    }

    // MARK: - The parts

    // The text with "\n" for each line end.
    private static func flatLines(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var afterReturn = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" && afterReturn {
                afterReturn = false
                continue
            }
            afterReturn = scalar == "\r"
            out.append(afterReturn ? "\n" : scalar)
        }
        return String(out)
    }

    private static func flat(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in flatLines(text).unicodeScalars where scalar != mentionBreak {
            scalars.append(scalar)
        }
        return String(scalars).trimmed()
    }

    private static func trimmedEnd(_ text: some StringProtocol) -> String {
        guard let last = text.lastIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(text[...last])
    }

    // True when the @ at the index comes right after an ASCII letter or digit, as in an email
    // address. A word right after "&" or "&#" can be the end of an entity, so it does not count.
    private static func afterWord(_ scalars: [Unicode.Scalar], _ at: Int) -> Bool {
        var start = at
        while start > 0, isWordScalar(scalars[start - 1]) { start -= 1 }
        guard start < at else { return false }
        if start >= 1, scalars[start - 1] == "&" { return false }
        if start >= 2, scalars[start - 2] == "&", scalars[start - 1] == "#" { return false }
        return true
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar))
    }

    // The ranges (in scalar offsets) of the links that GitHub makes from a bare address. The
    // rule is stricter than the rule of GitHub: a text that it does not find gets the space, and
    // that is safe. A link starts at the start of the text or after an ASCII space (http and
    // https also after "*", "_", "~" or "("). The host has a dot and no "_" in its last two parts,
    // and ends at "/", "?", "#" or ":". The path ends at a space, a bracket, a quote, a backtick
    // or a backslash.
    private static func linkRanges(_ text: String) -> [Range<Int>] {
        let link = #/
            (https?:\/\/|www\.) (?:[A-Za-z0-9_\-]+\.)* [A-Za-z0-9\-]+ \. [A-Za-z0-9\-]+
            [\/?\x23:] [^\s<>()\[\]"'`\\]*
            /#
        let scalars = text.unicodeScalars
        var ranges: [Range<Int>] = []
        for match in text.matches(of: link) {
            let start = scalars.distance(from: scalars.startIndex, to: match.range.lowerBound)
            let end = scalars.distance(from: scalars.startIndex, to: match.range.upperBound)
            let before: Unicode.Scalar? =
                start == 0 ? nil : scalars[scalars.index(scalars.startIndex, offsetBy: start - 1)]
            let allowed: String = match.output.1.hasPrefix("www") ? " \t\n\r" : " \t\n\r*_~("
            if let before, !allowed.unicodeScalars.contains(before) { continue }
            ranges.append(start..<end)
        }
        return ranges
    }
}
