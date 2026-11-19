// The lines that a unified diff shows, for each file and each side (docs/behaviour/reviews.md,
// "Review rounds"). GitHub refuses a whole pending review when one comment is on a line that the
// diff does not show, so Bifrost checks each comment of Claude against the hunks of the diff of the
// round first.
import Foundation

// The lines of one hunk on each side, as closed ranges. A side with no lines has an empty range.
package struct Hunk: Sendable, Equatable {
    package var left: ClosedRange<Int>?
    package var right: ClosedRange<Int>?

    package init(left: ClosedRange<Int>?, right: ClosedRange<Int>?) {
        self.left = left
        self.right = right
    }

    // The lines of the side.
    package func lines(_ side: DiffSide) -> ClosedRange<Int>? {
        side == .left ? left : right
    }
}

// One file of a diff: its path (the new path, or the old path of a deleted file), whether git
// shows it as binary, and its hunks.
package struct DiffFile: Sendable, Equatable {
    package var path: String
    package var binary: Bool
    package var hunks: [Hunk]

    package init(path: String, binary: Bool = false, hunks: [Hunk] = []) {
        self.path = path
        self.binary = binary
        self.hunks = hunks
    }
}

package enum DiffLines {
    // The files of the text of git diff, in their order.
    package static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var inHunk = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                files.append(DiffFile(path: headerPath(line.dropFirst(11))))
                inHunk = false
                continue
            }
            guard !files.isEmpty else { continue }
            if let hunk = hunk(line) {
                files[files.count - 1].hunks.append(hunk)
                inHunk = true
                continue
            }
            if inHunk { continue }
            if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                files[files.count - 1].binary = true
            } else if line.hasPrefix("+++ "), let path = markerPath(line.dropFirst(4)) {
                // A deleted file has /dev/null as its new path, so it keeps its old path.
                files[files.count - 1].path = path
            }
        }
        return files
    }

    // True when the comment is on lines that one hunk of its file shows: its line, and its first
    // line for a range. GitHub refuses a range whose first line is not below its last line.
    package static func shows(_ files: [DiffFile], _ comment: DraftComment) -> Bool {
        guard let file = files.first(where: { $0.path == comment.path }) else { return false }
        if let start = comment.startLine, start >= comment.line { return false }
        return file.hunks.contains { hunk in
            guard let lines = hunk.lines(comment.side), lines.contains(comment.line) else {
                return false
            }
            return comment.startLine.map(lines.contains) ?? true
        }
    }

    // MARK: - The parts of a line

    // "@@ -<left>[,<count>] +<right>[,<count>] @@". A count of 0 gives no lines on that side.
    private static func hunk(_ line: Substring) -> Hunk? {
        guard
            let match = line.prefixMatch(
                of: /@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/)
        else { return nil }
        let output = match.output
        guard let leftStart = Int(output.1), let rightStart = Int(output.3) else { return nil }
        let leftCount = output.2.flatMap { Int($0) } ?? 1
        let rightCount = output.4.flatMap { Int($0) } ?? 1
        return Hunk(left: range(leftStart, leftCount), right: range(rightStart, rightCount))
    }

    private static func range(_ start: Int, _ count: Int) -> ClosedRange<Int>? {
        count > 0 ? start...(start + count - 1) : nil
    }

    // The path of a "--- " or "+++ " line without its a/ or b/ prefix, or nil for /dev/null.
    private static func markerPath(_ rest: Substring) -> String? {
        let raw = rest.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let path = unquote(raw)
        guard path != "/dev/null" else { return nil }
        return withoutPrefix(path)
    }

    // The new path of a "diff --git a/<old> b/<new>" line, for a file with no marker lines (a
    // binary file).
    private static func headerPath(_ rest: Substring) -> String {
        if rest.hasPrefix("\"") {
            guard let end = rest.dropFirst().range(of: "\" ") else {
                return withoutPrefix(unquote(rest), "b/")
            }
            let second = rest[end.upperBound...]
            return withoutPrefix(unquote(second.isEmpty ? rest[...end.lowerBound] : second), "b/")
        }
        guard let at = rest.range(of: " b/") else { return String(rest) }
        return withoutPrefix(unquote(rest[rest.index(after: at.lowerBound)...]), "b/")
    }

    private static func withoutPrefix(_ path: String, _ prefixes: String...) -> String {
        for prefix in prefixes.isEmpty ? ["a/", "b/"] : prefixes where path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    // The path of a C-style quoted name of git ("a\303\251.txt"): each octal escape is one byte
    // of UTF-8. A name with no quotes stays as it is.
    private static func unquote(_ raw: Substring) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return String(raw) }
        let escapes: [Character: UInt8] = [
            "\"": 0x22, "\\": 0x5c, "a": 7, "b": 8, "f": 12, "n": 10, "r": 13, "t": 9, "v": 11,
        ]
        var bytes: [UInt8] = []
        var rest = raw.dropFirst().dropLast()[...]
        while let character = rest.first {
            rest = rest.dropFirst()
            guard character == "\\", let next = rest.first else {
                bytes += Array(String(character).utf8)
                continue
            }
            let digits = rest.prefix(3)
            if digits.count == 3, digits.allSatisfy({ ("0"..."7").contains($0) }),
                let byte = UInt8(String(digits), radix: 8)
            {
                bytes.append(byte)
                rest = rest.dropFirst(3)
            } else if let byte = escapes[next] {
                bytes.append(byte)
                rest = rest.dropFirst()
            } else {
                bytes += Array(String(next).utf8)
                rest = rest.dropFirst()
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
