// The conflict markers of git in the bytes of a file (docs/behaviour/reviews.md, "Merging the base
// branch"). git puts a line of 7 "<" before the text of one side and a line of 7 ">" after the text
// of the other side. The diff3 style also puts a line of 7 "|" before the text of the merge base.
// An attribute can make the markers longer. A line of exactly 7 "=" goes between the two sides.
// git writes a "<" line for each conflict, so the "<", ">" and "|" lines show a text conflict. A
// line of 7 "=" can also be the line under a heading, or a line that the file had before, so a
// marker line of the merge counts as left only when the merge has more marker lines than the head
// and the base of the file.
import Foundation

package enum ConflictMarkers {
    // The least count of the marker character at the start of a line.
    package static let size = 7

    private static let markers: Set<UInt8> = [
        UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "|"),
    ]
    private static let newline = UInt8(ascii: "\n"), space = UInt8(ascii: " ")
    private static let carriageReturn = UInt8(ascii: "\r"), equals = UInt8(ascii: "=")

    // True when a line of the bytes starts with size or more of one of "<", ">" and "|", and the
    // character after them is a space, a carriage return or the end of the line.
    package static func found(in data: Data) -> Bool {
        data.split(separator: newline).contains(where: isMarker)
    }

    // The count of the marker lines of the bytes: the lines that found counts, and each line of
    // exactly size "=" (with a carriage return or not).
    package static func lines(in data: Data) -> Int {
        data.split(separator: newline).count(where: { isMarker($0) || isSeparator($0) })
    }

    // True when the merged file has more marker lines than the head and the base each have, so
    // the merge added a marker line. nil is a file that the head or the base does not have.
    package static func added(merged: Data, head: Data?, base: Data?) -> Bool {
        lines(in: merged) > max(head.map { lines(in: $0) } ?? 0, base.map { lines(in: $0) } ?? 0)
    }

    private static func isMarker(_ line: Data) -> Bool {
        guard let first = line.first, markers.contains(first) else { return false }
        let run = line.prefix { $0 == first }.count
        guard run >= size else { return false }
        guard let next = line.dropFirst(run).first else { return true }
        return next == space || next == carriageReturn
    }

    private static func isSeparator(_ line: Data) -> Bool {
        let run = line.prefix { $0 == equals }.count
        guard run == size else { return false }
        let rest = line.dropFirst(run)
        return rest.isEmpty || (rest.count == 1 && rest.first == carriageReturn)
    }
}
