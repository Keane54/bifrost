// The result file of a review round, result.json (docs/behaviour/reviews.md, "Review rounds", and
// skills/bifrost-review/bifrost-mode.md, "The result file"). The session writes it after it read
// text from the PR, so Bifrost trusts none of it. The check is strict: one failed rule refuses the
// whole file, and Bifrost then posts nothing. A refusal names a known field or a limit only; it
// never holds text from the file, because the row shows it and the log keeps it.
import BifrostFoundation
import Foundation

// What a good result file holds: only the known fields, so nothing else from the file goes further.
package struct ReviewOutcome: Sendable, Equatable {
    package var recommendation: Recommendation
    // The reason of the recommendation, on one line. The row shows it. File: why.
    package var reason: String
    // The body of the review. An empty text is no summary.
    package var summary: String
    package var comments: [DraftComment]

    package init(
        recommendation: Recommendation, reason: String, summary: String,
        comments: [DraftComment]
    ) {
        self.recommendation = recommendation
        self.reason = reason
        self.summary = summary
        self.comments = comments
    }
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
    package static let version = 1
    package static let maxBytes = 1_048_576
    package static let maxComments = 50
    package static let maxCommentBody = 10_000
    package static let maxSummary = 20_000
    package static let maxReason = 300
    // GitHub refuses a review body that is longer than this.
    package static let maxReviewBody = 65_536

    private static let resultOrder = [
        "version", "pr", "headSha", "recommendation", "why", "summary", "comments",
    ]
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
        // A round with a token needs the round field; a round with no token (a round of the
        // Electron app) allows none.
        let order =
            input.round == nil
            ? resultOrder : Array(resultOrder.prefix(3)) + ["round"] + resultOrder.dropFirst(3)
        if let problem = keyProblem(fields, allowed: Set(order), needed: order, missing: {
            "the \($0) field is missing"
        }) {
            throw ResultRefusal(problem)
        }
        guard fields["version"]?.wholeNumber == version else {
            throw ResultRefusal("the version field is not 1")
        }
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
        let reason = try reasonOf(fields["why"])
        guard let summary = fields["summary"]?.string else {
            throw ResultRefusal("the summary field is not text")
        }
        guard summary.utf16.count <= maxSummary else {
            throw ResultRefusal("the summary field is longer than \(count(maxSummary)) characters")
        }
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
        let clean = summary.trimmed().isEmpty ? "" : summary
        if recommendation == .approve && !comments.isEmpty {
            throw ResultRefusal("an Approve recommendation has line comments")
        }
        if recommendation != .approve && clean.isEmpty && comments.isEmpty {
            throw ResultRefusal("a \(name(recommendation)) recommendation has no text")
        }
        let outcome = ReviewOutcome(
            recommendation: recommendation, reason: reason, summary: clean, comments: comments)
        if PendingReviewPlan.place(outcome, diff: input.diff).summary.utf16.count > maxReviewBody {
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
        guard !line.unicodeScalars.contains(where: isControl) else {
            throw ResultRefusal("the why field has a control character")
        }
        guard line.utf16.count <= maxReason else {
            throw ResultRefusal("the why field is longer than \(count(maxReason)) characters")
        }
        return line
    }

    // One comment: a known path of the diff that is not binary, a line of 1 or more, a side, an
    // optional first line below the line on the same side, and a body that is not empty.
    private static func comment(_ value: JSONValue, number n: Int, diff: [DiffFile])
        throws(ResultRefusal) -> DraftComment
    {
        guard let fields = value.object else {
            throw ResultRefusal("comment \(n) is not a JSON object")
        }
        if let problem = keyProblem(fields, allowed: commentKeys, needed: commentNeeds, missing: {
            "comment \(n) has no \($0) field"
        }) {
            throw ResultRefusal(problem)
        }
        guard let path = fields["path"]?.string, let file = diff.first(where: { $0.path == path })
        else { throw ResultRefusal("comment \(n) is on a file that is not in the diff") }
        guard !file.binary else { throw ResultRefusal("comment \(n) is on a binary file") }
        guard let line = lineNumber(fields["line"]) else {
            throw ResultRefusal("the line of comment \(n) is not a whole number of 1 or more")
        }
        guard let side = fields["side"]?.string.flatMap(DiffSide.init(rawValue:)) else {
            throw ResultRefusal("the side of comment \(n) is not LEFT or RIGHT")
        }
        var start: Int?
        if let value = fields["startLine"] {
            guard let first = lineNumber(value) else {
                throw ResultRefusal(
                    "the startLine of comment \(n) is not a whole number of 1 or more")
            }
            guard first < line else {
                throw ResultRefusal("the startLine of comment \(n) is not below its line")
            }
            if let startSide = fields["startSide"], startSide != .string(side.rawValue) {
                throw ResultRefusal("the startSide of comment \(n) is not its side")
            }
            start = first
        } else if fields["startSide"] != nil {
            throw ResultRefusal("comment \(n) has a startSide with no startLine")
        }
        guard let body = fields["body"]?.string else {
            throw ResultRefusal("the body of comment \(n) is not text")
        }
        guard !body.trimmed().isEmpty else {
            throw ResultRefusal("the body of comment \(n) is empty")
        }
        guard body.utf16.count <= maxCommentBody else {
            throw ResultRefusal(
                "the body of comment \(n) is longer than \(count(maxCommentBody)) characters")
        }
        return DraftComment(path: path, line: line, side: side, startLine: start, body: body)
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

    // A control character (Cc), or a character that changes the direction of the text.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || scalar.properties.isBidiControl
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
