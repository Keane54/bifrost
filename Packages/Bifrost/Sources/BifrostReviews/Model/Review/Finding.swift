// One finding of a review round (docs/behaviour/reviews.md, "Review rounds"): its kind, its place
// and its text. The result file of the round gives the findings, and the mark of the PR keeps them
// for the Review panel. A Request changes draft holds the bug and minor findings. A nit never
// goes to GitHub in a round.
import BifrostFoundation

// The kind of a finding. A bug blocks the PR. A minor finding is a real problem with a small
// effect. A nit is a style, naming, formatting or order point with no failure behind it.
package enum FindingKind: String, Sendable, Equatable {
    case bug, minor, nit
}

// The lines of a finding: one line, or a range from startLine to line on one side.
package struct FindingPlace: Sendable, Equatable {
    package var path: String
    package var line: Int
    package var side: DiffSide
    package var startLine: Int?

    package init(path: String, line: Int, side: DiffSide, startLine: Int? = nil) {
        self.path = path
        self.line = line
        self.side = side
        self.startLine = startLine
    }

    // The line comment on this place with the body.
    package func comment(_ body: String) -> DraftComment {
        DraftComment(path: path, line: line, side: side, startLine: startLine, body: body)
    }
}

package struct Finding: Sendable, Equatable, StoredValue {
    package var kind: FindingKind
    // nil for a finding on the whole PR (a missing goal, an earlier point of a re-review).
    package var place: FindingPlace?
    package var body: String
    // True when the diff of the round shows the place (DiffLines.shows), so the finding can be a
    // line comment. False with no place.
    package var onDiff: Bool

    package init(kind: FindingKind, place: FindingPlace?, body: String, onDiff: Bool) {
        self.kind = kind
        self.place = place
        self.body = body
        self.onDiff = onDiff
    }

    // The line comment of the finding when the diff shows its place. Else nil: GitHub refuses a
    // whole review with a comment on a line that the diff does not show.
    package var comment: DraftComment? {
        guard let place, onDiff else { return nil }
        return place.comment(body)
    }

    // The finding as a paragraph of a review text: its path as code, its line and its body. A
    // finding with no place is its body only.
    package var paragraph: String {
        guard let place else { return body }
        return "\(PendingReviewPlan.codeSpan(place.path)) line \(place.line): \(body)"
    }

    // The place for the user: "src/a.swift line 12", "src/a.swift lines 10-12", or the whole PR.
    package var placeText: String {
        guard let place else { return "The whole pull request" }
        if let start = place.startLine, start != place.line {
            return "\(place.path) lines \(start)-\(place.line)"
        }
        return "\(place.path) line \(place.line)"
    }

    // A finding of state.json reads in full or not at all, so a damaged item never changes the
    // kind or the place of a finding. A null counts as a value of the wrong form. Unknown keys
    // are ignored.
    package init?(stored value: JSONValue, dropped: inout DroppedFields) {
        guard let fields = value.object,
            let kind = fields["kind"]?.string.flatMap(FindingKind.init(rawValue:)),
            let body = fields["body"]?.string
        else { return nil }
        var onDiff = false
        if let flag = fields["onDiff"] {
            guard let known = flag.flag else { return nil }
            onDiff = known
        }
        var place: FindingPlace?
        if ["path", "line", "side"].contains(where: { fields[$0] != nil }) {
            guard let path = fields["path"]?.string,
                let line = fields["line"]?.wholeNumber, line >= 1,
                let side = fields["side"]?.string.flatMap(DiffSide.init(rawValue:))
            else { return nil }
            var start: Int?
            if let value = fields["startLine"] {
                guard let first = value.wholeNumber, first >= 1 else { return nil }
                start = first
            }
            place = FindingPlace(path: path, line: line, side: side, startLine: start)
        } else if fields["startLine"] != nil {
            return nil
        }
        self.init(kind: kind, place: place, body: body, onDiff: onDiff)
    }

    package var stored: JSONValue {
        var fields: [String: JSONValue] = [
            "kind": .string(kind.rawValue), "body": .string(body), "onDiff": .bool(onDiff),
        ]
        if let place {
            fields["path"] = .string(place.path)
            fields["line"] = .int(place.line)
            fields["side"] = .string(place.side.rawValue)
            if let start = place.startLine { fields["startLine"] = .int(start) }
        }
        return .object(fields)
    }
}

extension [Finding] {
    // True when one finding is a bug or a minor finding.
    package var aboveNits: Bool { contains { $0.kind != .nit } }

    // The count of the findings of the kind.
    package func count(_ kind: FindingKind) -> Int {
        reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
    }
}
