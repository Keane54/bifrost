// The result file of a CI round, result-<round ID>.json (docs/behaviour/reviews.md, "My PRs", and
// skills/bifrost-fix-ci/bifrost-mode.md, "The result file"). The session that writes it reads the
// CI logs and also holds review text from other people, so Bifrost trusts none of it. The check
// is as strict as the check of a conflict round: one failed rule refuses the whole file, and
// Bifrost then commits nothing, pushes nothing and re-runs nothing. A refusal names a known field
// or a limit only; it never holds text from the file, because the row shows it and the log keeps
// it.
import BifrostFoundation
import Foundation

// What Claude decided for the failed jobs of a round.
package enum CIDecision: Sendable, Equatable {
    // Claude fixed a fault in the code in the worktree: the commit of the fix and the result of
    // the checks that the session ran. The checks never failed.
    case fix(CommitPlan, ChecksState)
    // The failure is flaky or comes from the infrastructure: Bifrost re-runs the failed jobs.
    case retry
    // A question for the user, for the Answer panel.
    case needsYou(String)
}

// What a good result file holds: only the known fields, so nothing else from the file goes
// further. The reason is one line about the failure and the decision.
package struct CIOutcome: Sendable, Equatable {
    package var decision: CIDecision
    package var reason: String

    package init(decision: CIDecision, reason: String) {
        self.decision = decision
        self.reason = reason
    }
}

package enum CIResult {
    package static let version = 1
    package static let maxBytes = RequestResult.maxBytes
    // The longest reason, in UTF-16 units.
    package static let maxReason = 300

    // The fields that each file has, in the order of the checks.
    private static let needed = ["version", "pr", "headSha", "round", "outcome", "reason"]
    // Also the fields of the outcomes: commit and checks for fix, question for needs-you.
    private static let known = Set(needed + ["commit", "checks", "question"])

    // Check the bytes of the file against the input of the round: the PR, the head, the token and
    // the allowed outcomes. changed holds the paths that changed in the worktree; with nil (the
    // check at the end of the turn, before Bifrost reads the worktree), the paths of the commit
    // are not compared with it.
    package static func check(
        _ data: Data, input: CIInput, changed: Set<String>? = nil
    ) -> Result<CIOutcome, ResultRefusal> {
        Result { () throws(ResultRefusal) in try outcome(data, input, changed) }
    }

    private static func outcome(_ data: Data, _ input: CIInput, _ changed: Set<String>?)
        throws(ResultRefusal) -> CIOutcome
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
        guard fields["round"]?.string == input.round else {
            throw ResultRefusal("the round field is not this CI round")
        }
        let kind = fields["outcome"]?.string
        let action: CIAction? =
            switch kind {
            case "fix": .fix
            case "retry": .retry
            case "needs-you": nil
            default: throw ResultRefusal("the outcome field is not fix, retry or needs-you")
            }
        if let action, !input.allowed.contains(action) {
            throw ResultRefusal("the outcome field is not allowed in this round")
        }
        let why = try reason(fields["reason"])
        // A field that the outcome does not have can be absent or null.
        func has(_ key: String) -> Bool { fields[key].map { $0 != .null } ?? false }
        switch action {
        case .fix:
            guard let plan = try RequestResult.commitPlan(fields["commit"], changed: changed)
            else { throw ResultRefusal("a fix result has no commit") }
            let checks = fields["checks"]?.string.flatMap(ChecksState.init(rawValue:))
            guard let checks, checks != .failed else {
                throw ResultRefusal("the checks field of a fix is not passed, blocked or none")
            }
            if has("question") { throw ResultRefusal("a fix result has a question field") }
            return CIOutcome(decision: .fix(plan, checks), reason: why)
        case .retry:
            if let other = ["commit", "checks", "question"].first(where: has) {
                throw ResultRefusal("a retry result has a \(other) field")
            }
            return CIOutcome(decision: .retry, reason: why)
        case nil:
            if let other = ["commit", "checks"].first(where: has) {
                throw ResultRefusal("a needs-you result has a \(other) field")
            }
            return CIOutcome(decision: .needsYou(try question(fields["question"])), reason: why)
        }
    }

    // The reason, with the white space at its ends trimmed: not empty, on one line, with no
    // control character and no character that changes the direction of the text, and at most
    // maxReason UTF-16 units.
    private static func reason(_ value: JSONValue?) throws(ResultRefusal) -> String {
        guard let text = value?.string else { throw ResultRefusal("the reason field is not text") }
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

    // The question of a needs-you result for the Answer panel: text that is not blank, at most
    // Question.maxText UTF-16 units, with no control or text-direction character other than a
    // line break.
    private static func question(_ value: JSONValue?) throws(ResultRefusal) -> String {
        guard let value, value != .null else {
            throw ResultRefusal("a needs-you result has no question")
        }
        guard let text = value.string else { throw ResultRefusal("the question field is not text") }
        guard !text.trimmed().isEmpty else { throw ResultRefusal("the question field is empty") }
        guard text.utf16.count <= Question.maxText else {
            throw ResultRefusal(
                "the question field is longer than \(ReviewResult.count(Question.maxText)) "
                    + "characters")
        }
        guard !text.unicodeScalars.contains(where: { $0 != "\n" && $0.isControlOrDirection })
        else { throw ResultRefusal("the question field has a control character") }
        return text
    }
}
