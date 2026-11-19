// The texts and the names of Hand over (docs/behaviour/actions.md, "Hand over"): the request
// prompt to the old session, the first prompt of the new session, the name of the new session
// and the name of the note file. The rules text comes from the file of the bifrost-hand-over
// skill, so the skill and the button cannot differ. The note file name follows the rule of that
// skill, so a note from the button and a note from the skill get the same form of name.
import BifrostFoundation
import Foundation

package enum HandOverText {
    // Claude puts the note between these two lines. Each marker is on a line of its own.
    package static let noteStart = "[[BIFROST-HAND-OVER-NOTE-START]]"
    package static let noteEnd = "[[BIFROST-HAND-OVER-NOTE-END]]"

    // The name part of a note file name has this many characters or less.
    package static let maxFileName = 64

    // The first line of the request prompt. The reply reader finds the request by this line.
    package static func requestLine(_ id: String) -> String {
        "Bifrost hand-over request \(id)"
    }

    // The prompt that asks the old session for the note. The rules text is in it unchanged. One
    // line break at the end of the rules goes, so that line break is not there two times. Each
    // paragraph is on one line.
    package static func prompt(rules: String, requestID: String) -> String {
        let ask = [
            "Write a hand-over note for this session now.",
            "Use no tool, write no file, and change nothing.",
            "A new session continues the work from the note.",
            "The rules for the note follow.",
        ].joined(separator: " ")
        let form = [
            "Put the note in your reply between the two marker lines below.",
            "Put each marker on a line of its own, exactly as shown.",
            "Write nothing else between the markers.",
        ].joined(separator: " ")
        var body = rules.unicodeScalars
        if body.last == "\n" { body.removeLast() }
        return [
            requestLine(requestID), "", ask, "", String(body), "", form, "", noteStart,
            "<the note>", noteEnd,
        ].joined(separator: "\n")
    }

    // The first prompt of the new session. The note is last.
    package static func continuePrompt(note: String, notePath: String) -> String {
        let intro = [
            "Continue the work of an earlier session.",
            "Its hand-over note follows. The note is also saved at \(notePath).",
            "Read the note first, then continue with its next steps.",
            "Ask the user when something is not clear.",
        ].joined(separator: " ")
        return "\(intro)\n\n\(note)"
    }

    // The name of the new session: the old name with the next free number. "x" gives "x (2)",
    // and "x (2)" gives "x (3)", never "x (2) (2)". Each taken name is skipped, so "x (2)" gives
    // "x (4)" while "x (3)" is taken. The base is cut, and the white space at the end of the cut
    // goes, so that the name has NewSessionSpec.maxName Characters or less. A number that the
    // count could take past Int.max is no number.
    package static func newName(_ old: String, taken: Set<String>) -> String {
        var base = old
        var number = 2
        let pattern = /(.*) \(([0-9]+)\)/.dotMatchesNewlines()
        if let match = try? pattern.wholeMatch(in: old), let last = Int(match.output.2),
            last < Int.max - taken.count - 1
        {
            base = String(match.output.1)
            number = last + 1
        }
        while true {
            let suffix = " (\(number))"
            var cut = String(base.prefix(NewSessionSpec.maxName - suffix.count))
            while cut.last?.isWhitespace == true { cut.removeLast() }
            let name = cut + suffix
            if !taken.contains(name) { return name }
            number += 1
        }
    }

    // The name of the note file: <safe name>-<YYYYMMDD-HHmmss>.md, at the time in the time zone
    // of the calendar. In the session name, each run of characters other than ASCII letters,
    // digits, ".", "_" and "-" becomes one "-". A "-" at the start or the end goes. The name part
    // has maxFileName characters or less, and an empty name gives "session".
    package static func noteFileName(_ session: String, at: Date, calendar: Calendar) -> String {
        var dashed = String.UnicodeScalarView()
        var inRun = false
        for scalar in session.unicodeScalars {
            if isSafeInAFileName(scalar) {
                dashed.append(scalar)
                inRun = false
            } else if !inRun {
                dashed.append("-")
                inRun = true
            }
        }
        // The cut can leave a "-" at the end.
        let trimmed = trimmingDashes(dashed)
        let safe = trimmingDashes(String.UnicodeScalarView(trimmed.prefix(maxFileName)))
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: at)
        let date = "\(parts.year ?? 0)\(twoDigits(parts.month))\(twoDigits(parts.day))"
        let time = "\(twoDigits(parts.hour))\(twoDigits(parts.minute))\(twoDigits(parts.second))"
        return "\(safe.isEmpty ? "session" : String(safe))-\(date)-\(time).md"
    }

    // An ASCII letter or digit, ".", "_" or "-".
    private static func isSafeInAFileName(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-": true
        default: false
        }
    }

    private static func trimmingDashes(_ text: String.UnicodeScalarView)
        -> String.UnicodeScalarView
    {
        guard let first = text.firstIndex(where: { $0 != "-" }),
            let last = text.lastIndex(where: { $0 != "-" })
        else { return String.UnicodeScalarView() }
        return String.UnicodeScalarView(text[first...last])
    }

    // The number with two digits at least. No number gives "00".
    private static func twoDigits(_ number: Int?) -> String {
        let text = String(number ?? 0)
        return text.count < 2 ? "0" + text : text
    }
}
