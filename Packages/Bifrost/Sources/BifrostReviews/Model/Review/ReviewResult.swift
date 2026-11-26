// The result file of a review round, result.json (docs/behaviour/reviews.md, "Review rounds", and
// skills/bifrost-review/bifrost-mode.md, "The result file"). The session writes it after it read
// text from the PR, so Bifrost trusts none of it. The check is strict: one failed rule refuses the
// whole file, and Bifrost then posts nothing. A refusal names a known field or a limit only; it
// never holds text from the file, because the row shows it and the log keeps it.
// Version 2 lists each finding with its kind and its place, and holds a note for the user. The
// check also reads version 1, because a round that started before an update has the old mode
// file in its input folder.
import BifrostFoundation
import Foundation

// What a good result file holds: only the known fields, so nothing else from the file goes further.
package struct ReviewOutcome: Sendable, Equatable {
    package var recommendation: Recommendation
    // The reason of the recommendation, on one line. The row shows it. File: why.
    package var reason: String
    // The text for the user only: what the PR does and what Claude checked. Bifrost never posts
    // it. A version 1 result has no note.
    package var note: String
    // The body of the review. An empty text is no summary. An Approve has no summary.
    package var summary: String
    // Each finding of the review, of all kinds, in the order of the file.
    package var findings: [Finding]

    package init(
        recommendation: Recommendation, reason: String, note: String, summary: String,
        findings: [Finding]
    ) {
        self.recommendation = recommendation
        self.reason = reason
        self.note = note
        self.summary = summary
        self.findings = findings
    }

    // The findings of a draft review: the bug and minor findings. A nit never goes to GitHub in
    // a round.
    package var draftFindings: [Finding] { findings.filter { $0.kind != .nit } }
}

// Why Bifrost refused a result file. field names the field or the limit that failed. The texts
// hold no text of the file.
package struct ResultRefusal: Error, Sendable, Equatable {
    package var field: String

    package init(_ field: String) {
        self.field = field
    }

    package var message: String { field }
}

package enum ReviewResult {
    package static let version = 2
    // The form with comments and no findings. A round that started before an update has the old
    // mode file in its input folder, so its session writes this form.
    package static let oldVersion = 1
    package static let maxBytes = 1_048_576
    package static let maxFindings = 50
    package static let maxComments = 50
    package static let maxCommentBody = 10_000
    package static let maxNote = 2_000
    package static let maxSummary = 20_000
    package static let maxReason = 300
    // GitHub refuses a review body that is longer than this.
    package static let maxReviewBody = 65_536

    private static let resultOrder = [
        "version", "pr", "headSha", "recommendation", "why", "note", "summary", "findings",
    ]
    private static let oldOrder = [
        "version", "pr", "headSha", "recommendation", "why", "summary", "comments",
    ]
    private static let findingKeys: Set = [
        "kind", "path", "line", "side", "startLine", "startSide", "body",
    ]
    private static let findingNeeds = ["kind", "body"]
    private static let placeKeys = ["path", "line", "side", "startLine", "startSide"]
    private static let commentKeys: Set = [
        "path", "line", "side", "startLine", "startSide", "body",
    ]
    private static let commentNeeds = ["path", "line", "side", "body"]

    // Check the bytes of the file against the input of the round: the PR, the reviewed head and
    // the files of the full diff.
    package static func check(_ data: Data, input: ReviewInput) -> Result<
        ReviewOutcome, ResultRefusal
    > {
        Result { () throws(ResultRefusal) in try outcome(data, input) }
    }

    private static func outcome(_ data: Data, _ input: ReviewInput) throws(ResultRefusal)
        -> ReviewOutcome
    {
        guard data.count <= maxBytes else {
            throw ResultRefusal("the result is larger than \(count(maxBytes)) bytes")
        }
        // The error of the decoder can hold a part of the file, so it never shows.
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ResultRefusal("the result is not valid JSON")
        }
        guard let fields = value.object else {
            throw ResultRefusal("the result is not a JSON object")
        }
        // The version sets the keys of the file, so the check reads it first.
        guard let version = fields["version"] else {
            throw ResultRefusal("the version field is missing")
        }
        switch version.wholeNumber {
        case .some(Self.version): return try newOutcome(fields, input)
        case .some(oldVersion): return try oldOutcome(fields, input)
        default: throw ResultRefusal("the version field is not \(oldVersion) or \(Self.version)")
        }
    }

    // A version 2 file: the note, the summary and each finding with its kind and its place.
    private static func newOutcome(_ fields: [String: JSONValue], _ input: ReviewInput)
        throws(ResultRefusal) -> ReviewOutcome
    {
        try checkKeys(fields, resultOrder, input)
        let (recommendation, reason) = try header(fields, input)
        let note = try noteOf(fields["note"])
        let summary = try summaryOf(fields["summary"])
        if recommendation == .approve && !summary.isEmpty {
            throw ResultRefusal("an Approve recommendation has a summary")
        }
        guard let items = fields["findings"]?.array else {
            throw ResultRefusal("the findings field is not a list")
        }
        guard items.count <= maxFindings else {
            throw ResultRefusal("the findings field has more than \(count(maxFindings)) findings")
        }
        var findings: [Finding] = []
        for (index, item) in items.enumerated() {
            findings.append(try finding(item, number: index + 1, diff: input.diff))
        }
        if recommendation != .approve && summary.isEmpty && !findings.aboveNits {
            throw ResultRefusal("a \(name(recommendation)) recommendation has no text")
        }
        return try fitsGitHub(
            ReviewOutcome(
                recommendation: recommendation, reason: reason, note: note, summary: summary,
                findings: findings))
    }

    // A version 1 file, with the rules of that form. Each comment becomes a bug finding. The
    // summary of an Approve held its minor points, so it becomes one minor finding on the whole
    // PR, and the Review panel shows it before anything goes to GitHub. The file has no note.
    // Any session can write this form, so a comment body gets the control check of a finding
    // body: the Review panel shows it, and the user can post it.
    private static func oldOutcome(_ fields: [String: JSONValue], _ input: ReviewInput)
        throws(ResultRefusal) -> ReviewOutcome
    {
        try checkKeys(fields, oldOrder, input)
        let (recommendation, reason) = try header(fields, input)
        let summary = try summaryOf(fields["summary"])
        guard let items = fields["comments"]?.array else {
            throw ResultRefusal("the comments field is not a list")
        }
        guard items.count <= maxComments else {
            throw ResultRefusal("the comments field has more than \(count(maxComments)) comments")
        }
        var comments: [DraftComment] = []
        for (index, item) in items.enumerated() {
            comments.append(try comment(item, number: index + 1, diff: input.diff))
        }
        if recommendation == .approve && !comments.isEmpty {
            throw ResultRefusal("an Approve recommendation has line comments")
        }
        if recommendation != .approve && summary.isEmpty && comments.isEmpty {
            throw ResultRefusal("a \(name(recommendation)) recommendation has no text")
        }
        var findings = comments.map { comment in
            Finding(
                kind: .bug,
                place: FindingPlace(
                    path: comment.path, line: comment.line, side: comment.side,
                    startLine: comment.startLine),
                body: comment.body, onDiff: DiffLines.shows(input.diff, comment))
        }
        var kept = summary
        if recommendation == .approve {
            let points = Finding(kind: .minor, place: nil, body: summary, onDiff: false)
            findings = summary.isEmpty ? [] : [points]
            kept = ""
        }
        return try fitsGitHub(
            ReviewOutcome(
                recommendation: recommendation, reason: reason, note: "", summary: kept,
                findings: findings))
    }

    // The keys of the file: no unknown key, and each key of order. A round with a token needs
    // the round field after headSha; a round with no token (a round of the Electron app) allows
    // none.
    private static func checkKeys(
        _ fields: [String: JSONValue], _ order: [String], _ input: ReviewInput
    ) throws(ResultRefusal) {
        let keys =
            input.round == nil ? order : Array(order.prefix(3)) + ["round"] + order.dropFirst(3)
        if let problem = keyProblem(fields, allowed: Set(keys), needed: keys, missing: {
            "the \($0) field is missing"
        }) {
            throw ResultRefusal(problem)
        }
    }

    // The fields that tie the file to the round, and the recommendation with its reason.
    private static func header(_ fields: [String: JSONValue], _ input: ReviewInput)
        throws(ResultRefusal) -> (Recommendation, String)
    {
        guard fields["pr"]?.string == input.pr.text else {
            throw ResultRefusal("the pr field is not this pull request")
        }
        guard fields["headSha"]?.string == input.headSHA.hex else {
            throw ResultRefusal("the headSha field is not the reviewed commit")
        }
        if let round = input.round, fields["round"]?.string != round {
            throw ResultRefusal("the round field is not this review round")
        }
        guard let recommendation = fields["recommendation"]?.string.flatMap(
            Recommendation.init(rawValue:))
        else {
            throw ResultRefusal(
                "the recommendation field is not approve, comment or request-changes")
        }
        return (recommendation, try reasonOf(fields["why"]))
    }

    // GitHub refuses a review body that is longer than maxReviewBody, so the summary with the
    // findings that move into it must fit. An Approve posts nothing in a round, so it has no such
    // check.
    private static func fitsGitHub(_ outcome: ReviewOutcome) throws(ResultRefusal)
        -> ReviewOutcome
    {
        if outcome.recommendation != .approve,
            PendingReviewPlan.place(outcome).summary.utf16.count > maxReviewBody
        {
            throw ResultRefusal(
                "the summary with the moved comments is longer than \(count(maxReviewBody)) "
                    + "characters")
        }
        return outcome
    }

    // The reason on one line: each run of white space is one space. It must not be empty, hold a
    // control character or a character that changes the direction of the text, or be longer than
    // maxReason.
    private static func reasonOf(_ value: JSONValue?) throws(ResultRefusal) -> String {
        guard let text = value?.string else { throw ResultRefusal("the why field is not text") }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { throw ResultRefusal("the why field is empty") }
        guard !line.unicodeScalars.contains(where: \.isControlOrDirection) else {
            throw ResultRefusal("the why field has a control character")
        }
        guard line.utf16.count <= maxReason else {
            throw ResultRefusal("the why field is longer than \(count(maxReason)) characters")
        }
        return line
    }

    // The note exactly as Claude wrote it, with its line breaks. It must not be empty, be longer
    // than maxNote, or hold a control character or a character that changes the direction of the
    // text, other than a line break or a tab.
    private static func noteOf(_ value: JSONValue?) throws(ResultRefusal) -> String {
        guard let note = value?.string else { throw ResultRefusal("the note field is not text") }
        guard !note.trimmed().isEmpty else { throw ResultRefusal("the note field is empty") }
        guard note.utf16.count <= maxNote else {
            throw ResultRefusal("the note field is longer than \(count(maxNote)) characters")
        }
        guard !hasControl(note) else {
            throw ResultRefusal("the note field has a control character")
        }
        return note
    }

    // The summary: a text of at most maxSummary, with no control character or character that
    // changes the direction of the text, other than a line break or a tab. It goes to GitHub as
    // the body of the review, or into the Review panel as a finding. A text with only white space
    // is no summary.
    private static func summaryOf(_ value: JSONValue?) throws(ResultRefusal) -> String {
        guard let summary = value?.string else {
            throw ResultRefusal("the summary field is not text")
        }
        guard summary.utf16.count <= maxSummary else {
            throw ResultRefusal("the summary field is longer than \(count(maxSummary)) characters")
        }
        guard !hasControl(summary) else {
            throw ResultRefusal("the summary field has a control character")
        }
        return summary.trimmed().isEmpty ? "" : summary
    }

    // One finding: a kind, a place with the rules of a line comment or no place (a finding on
    // the whole PR), and a body with no control character other than a line break or a tab.
    // onDiff is true when a hunk of the diff of the round shows the place.
    private static func finding(_ value: JSONValue, number n: Int, diff: [DiffFile])
        throws(ResultRefusal) -> Finding
    {
        let item = "finding \(n)"
        guard let fields = value.object else {
            throw ResultRefusal("\(item) is not a JSON object")
        }
        if let problem = keyProblem(fields, allowed: findingKeys, needed: findingNeeds, missing: {
            "\(item) has no \($0) field"
        }) {
            throw ResultRefusal(problem)
        }
        guard let kind = fields["kind"]?.string.flatMap(FindingKind.init(rawValue:)) else {
            throw ResultRefusal("the kind of \(item) is not bug, minor or nit")
        }
        var place: FindingPlace?
        if placeKeys.contains(where: { fields[$0] != nil }) {
            guard fields["path"] != nil, fields["line"] != nil, fields["side"] != nil else {
                throw ResultRefusal("\(item) has only a part of its place")
            }
            place = try placeOf(fields, item: item, diff: diff)
        }
        let body = try bodyOf(fields["body"], item: item)
        guard !hasControl(body) else {
            throw ResultRefusal("the body of \(item) has a control character")
        }
        let onDiff = place.map { DiffLines.shows(diff, $0.comment(body)) } ?? false
        return Finding(kind: kind, place: place, body: body, onDiff: onDiff)
    }

    // One comment of a version 1 file: a place and a body that is not empty, with no control
    // character other than a line break or a tab.
    private static func comment(_ value: JSONValue, number n: Int, diff: [DiffFile])
        throws(ResultRefusal) -> DraftComment
    {
        let item = "comment \(n)"
        guard let fields = value.object else {
            throw ResultRefusal("\(item) is not a JSON object")
        }
        if let problem = keyProblem(fields, allowed: commentKeys, needed: commentNeeds, missing: {
            "\(item) has no \($0) field"
        }) {
            throw ResultRefusal(problem)
        }
        let place = try placeOf(fields, item: item, diff: diff)
        let body = try bodyOf(fields["body"], item: item)
        guard !hasControl(body) else {
            throw ResultRefusal("the body of \(item) has a control character")
        }
        return place.comment(body)
    }

    // The place of a comment or a finding (item names it in a refusal): a known path of the diff
    // that is not binary, a line of 1 or more, a side, and an optional first line below the line
    // on the same side.
    private static func placeOf(_ fields: [String: JSONValue], item: String, diff: [DiffFile])
        throws(ResultRefusal) -> FindingPlace
    {
        guard let path = fields["path"]?.string, let file = diff.first(where: { $0.path == path })
        else { throw ResultRefusal("\(item) is on a file that is not in the diff") }
        guard !file.binary else { throw ResultRefusal("\(item) is on a binary file") }
        guard let line = lineNumber(fields["line"]) else {
            throw ResultRefusal("the line of \(item) is not a whole number of 1 or more")
        }
        guard let side = fields["side"]?.string.flatMap(DiffSide.init(rawValue:)) else {
            throw ResultRefusal("the side of \(item) is not LEFT or RIGHT")
        }
        var start: Int?
        if let value = fields["startLine"] {
            guard let first = lineNumber(value) else {
                throw ResultRefusal(
                    "the startLine of \(item) is not a whole number of 1 or more")
            }
            guard first < line else {
                throw ResultRefusal("the startLine of \(item) is not below its line")
            }
            if let startSide = fields["startSide"], startSide != .string(side.rawValue) {
                throw ResultRefusal("the startSide of \(item) is not its side")
            }
            start = first
        } else if fields["startSide"] != nil {
            throw ResultRefusal("\(item) has a startSide with no startLine")
        }
        return FindingPlace(path: path, line: line, side: side, startLine: start)
    }

    // The body of a comment or a finding: a text that is not empty, of at most maxCommentBody.
    private static func bodyOf(_ value: JSONValue?, item: String) throws(ResultRefusal)
        -> String
    {
        guard let body = value?.string else {
            throw ResultRefusal("the body of \(item) is not text")
        }
        guard !body.trimmed().isEmpty else {
            throw ResultRefusal("the body of \(item) is empty")
        }
        guard body.utf16.count <= maxCommentBody else {
            throw ResultRefusal(
                "the body of \(item) is longer than \(count(maxCommentBody)) characters")
        }
        return body
    }

    // True when the text holds a control character or a character that changes the direction of
    // the text, other than a line break or a tab.
    private static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.isControlOrDirection && $0 != "\n" && $0 != "\t" }
    }

    // The first problem with the keys of an object: an unknown key, then the first missing key in
    // the order of needed.
    private static func keyProblem(
        _ fields: [String: JSONValue], allowed: Set<String>, needed: [String],
        missing: (String) -> String
    ) -> String? {
        if fields.keys.contains(where: { !allowed.contains($0) }) { return "an unknown field" }
        return needed.first { fields[$0] == nil }.map(missing)
    }

    // A whole number of 1 or more.
    private static func lineNumber(_ value: JSONValue?) -> Int? {
        guard let number = value?.wholeNumber, number >= 1 else { return nil }
        return number
    }

    // A number of 0 or more with a comma for each group of 3 digits: 10,000.
    static func count(_ number: Int) -> String {
        let digits = Array(String(number))
        var text = ""
        for (index, digit) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { text.append(",") }
            text.append(digit)
        }
        return text
    }

    // The name of the recommendation in a refusal.
    private static func name(_ value: Recommendation) -> String {
        switch value {
        case .approve: "Approve"
        case .comment: "Comment"
        case .requestChanges: "Request changes"
        }
    }
}

extension Unicode.Scalar {
    // True for a control character (Cc), or a character that changes the direction of the text.
    // The checks of the result files refuse both in a text, because the row and the log show it.
    package var isControlOrDirection: Bool {
        properties.generalCategory == .control || properties.isBidiControl
    }
}
