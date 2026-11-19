import BifrostFoundation
import Foundation

// The bold text of a draft. A draft is Markdown with **bold** parts, and the panel shows the bold
// parts bold. A bold part is **text** on one line, with one or more characters between the pairs.
// All other text, also a single *, is plain text. The draft comes from a Claude run, so the text
// is never read as anything but this one rule.
package enum DailyMarkup {
    // The draft with each bold part in a bold run and the stars removed.
    package static func attributed(_ markdown: String) -> AttributedString {
        var result = AttributedString()
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            for part in parts(of: line) {
                var run = AttributedString(part.text)
                if part.bold { run.inlinePresentationIntent = .stronglyEmphasized }
                result.append(run)
            }
        }
        return result
    }

    // Standard Markdown for Copy: each bold run is **text** again. White space at the edge of a
    // bold run goes outside the stars, and a bold run never spans a line break.
    package static func markdown(_ text: AttributedString) -> String {
        var output = ""
        for run in text.runs {
            let piece = String(text[run.range].characters)
            guard run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true else {
                output += piece
                continue
            }
            for (index, line) in piece.components(separatedBy: "\n").enumerated() {
                if index > 0 { output += "\n" }
                let core = line.trimmed()
                guard !core.isEmpty, let start = line.range(of: core) else {
                    output += line
                    continue
                }
                output += line[..<start.lowerBound] + "**" + core + "**" + line[start.upperBound...]
            }
        }
        return output
    }

    private struct Part {
        var text: String
        var bold: Bool
    }

    // The plain and bold parts of one line. The first ** opens a bold part, and the next **
    // closes it. The bold part needs one character at least.
    private static func parts(of line: String) -> [Part] {
        var parts: [Part] = []
        var rest = Substring(line)
        while let open = rest.range(of: "**") {
            let afterOpen = rest[open.upperBound...]
            // The bold part has one character at least, so the close is searched after it.
            guard afterOpen.startIndex < afterOpen.endIndex,
                let close = afterOpen.range(
                    of: "**",
                    range: afterOpen.index(after: afterOpen.startIndex)..<afterOpen.endIndex)
            else { break }
            if open.lowerBound > rest.startIndex {
                parts.append(Part(text: String(rest[..<open.lowerBound]), bold: false))
            }
            parts.append(Part(text: String(afterOpen[..<close.lowerBound]), bold: true))
            rest = afterOpen[close.upperBound...]
        }
        if !rest.isEmpty { parts.append(Part(text: String(rest), bold: false)) }
        return parts
    }
}
