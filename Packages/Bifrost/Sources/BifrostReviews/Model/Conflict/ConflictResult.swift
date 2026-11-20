// The result file of a conflict round, result-<round ID>.json (docs/behaviour/reviews.md, "Merging
// the base branch", and skills/bifrost-resolve-conflicts/bifrost-mode.md, "The result file"). The
// session that writes it also holds review text from other people, so Bifrost trusts none of it.
// The check is as strict as the check of a request round: one failed rule refuses the whole file,
// and Bifrost then commits nothing and pushes nothing. A refusal names a known field or a limit
// only; it never holds text from the file, because the row shows it and the log keeps it. A good
// file does not make the merge good: Bifrost then checks the merge itself (ConflictMerge.commit).
import BifrostFoundation
import Foundation

// What Claude decided for the conflicts of a round.
package enum ConflictAnswer: Sendable, Equatable {
    // Claude resolved each conflicted file in the worktree.
    case resolved
    // Claude could not resolve the conflicts. The text is the reason, on one line, for the row
    // (ConflictFailure.claude).
    case needsYou(String)
}

package enum ConflictResult {
    package static let version = 1
    package static let maxBytes = 1_048_576
    // The longest reason, in UTF-16 units.
    package static let maxReason = ConflictFailure.maxReason

    // The fields that each file has, in the order of the checks.
    private static let needed = ["version", "pr", "headSha", "baseSha", "round", "outcome"]
    // Also the field of each outcome: files for resolved, reason for needs-you.
    private static let known = Set(needed + ["files", "reason"])

    // Check the bytes of the file against the input of the round: the PR, the head, the base,
    // the token and the conflicted paths.
    package static func check(_ data: Data, input: ConflictInput)
        -> Result<ConflictAnswer, ResultRefusal>
    {
        Result { () throws(ResultRefusal) in try answer(data, input) }
    }

    private static func answer(_ data: Data, _ input: ConflictInput) throws(ResultRefusal)
        -> ConflictAnswer
    {
        guard data.count <= maxBytes else {
            throw ResultRefusal("the result is larger than \(ReviewResult.count(maxBytes)) bytes")
        }
        // The error of the decoder can hold a part of the file, so it never shows.
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ResultRefusal("the result is not valid JSON")
        }
        guard let fields = value.object else {
            throw ResultRefusal("the result is not a JSON object")
        }
        if fields.keys.contains(where: { !known.contains($0) }) {
            throw ResultRefusal("an unknown field")
        }
        if let missing = needed.first(where: { fields[$0] == nil }) {
            throw ResultRefusal("the \(missing) field is missing")
        }
        guard fields["version"]?.wholeNumber == version else {
            throw ResultRefusal("the version field is not 1")
        }
        guard fields["pr"]?.string == input.pr.text else {
            throw ResultRefusal("the pr field is not this pull request")
        }
        guard fields["headSha"]?.string == input.headSHA.hex else {
            throw ResultRefusal("the headSha field is not the head commit of the round")
        }
        guard fields["baseSha"]?.string == input.baseSHA.hex else {
            throw ResultRefusal("the baseSha field is not the base commit of the round")
        }
        guard fields["round"]?.string == input.round else {
            throw ResultRefusal("the round field is not this conflict round")
        }
        // A field that the outcome does not have is refused, also as null.
        switch fields["outcome"]?.string {
        case "resolved":
            if fields["reason"] != nil {
                throw ResultRefusal("a resolved result has a reason field")
            }
            try files(fields["files"], expected: input.conflicts)
            return .resolved
        case "needs-you":
            if fields["files"] != nil {
                throw ResultRefusal("a needs-you result has a files field")
            }
            return .needsYou(try reason(fields["reason"]))
        default:
            throw ResultRefusal("the outcome field is not resolved or needs-you")
        }
    }

    // The files of a resolved result: each conflicted path exactly as the input gives it, each one
    // time, and no other path. The order does not count.
    private static func files(_ value: JSONValue?, expected: [String]) throws(ResultRefusal) {
        guard let value else { throw ResultRefusal("a resolved result has no files field") }
        guard let list = value.array else { throw ResultRefusal("the files field is not a list") }
        let wanted = Set(expected)
        var seen: Set<String> = []
        for (index, item) in list.enumerated() {
            let n = index + 1
            guard let path = item.string else { throw ResultRefusal("file \(n) is not text") }
            guard wanted.contains(path) else {
                throw ResultRefusal("file \(n) is not a conflicted file")
            }
            guard seen.insert(path).inserted else {
                throw ResultRefusal("file \(n) shows more than one time")
            }
        }
        // Each path in seen is a wanted one, so a smaller set means a missing path.
        if seen.count < wanted.count {
            throw ResultRefusal("the files field lacks a conflicted file")
        }
    }

    // The reason of a needs-you result, with the white space at its ends trimmed: not empty, on
    // one line, with no control character and no character that changes the direction of the
    // text, and at most maxReason UTF-16 units.
    private static func reason(_ value: JSONValue?) throws(ResultRefusal) -> String {
        guard let value else { throw ResultRefusal("a needs-you result has no reason field") }
        guard let text = value.string else { throw ResultRefusal("the reason field is not text") }
        let line = text.trimmed()
        guard !line.isEmpty else { throw ResultRefusal("the reason field is empty") }
        guard !line.contains(where: \.isNewline) else {
            throw ResultRefusal("the reason field has more than one line")
        }
        guard !line.unicodeScalars.contains(where: \.isControlOrDirection) else {
            throw ResultRefusal("the reason field has a control character")
        }
        guard line.utf16.count <= maxReason else {
            throw ResultRefusal(
                "the reason field is longer than \(ReviewResult.count(maxReason)) characters")
        }
        return line
    }
}
