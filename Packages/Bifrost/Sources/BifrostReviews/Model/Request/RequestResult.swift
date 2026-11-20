// The result file of a request round, result-<round ID>.json (docs/behaviour/reviews.md, "Request
// rounds", and skills/bifrost-resolve-comments/bifrost-mode.md, "The result file"). The session
// writes it after it read the comments of the PR, so Bifrost trusts none of it. The check is
// strict: one failed rule refuses the whole file, and Bifrost then commits nothing and posts
// nothing. A refusal names a known field or a limit only; it never holds text from the file,
// because the row shows it and the log keeps it.
import BifrostFoundation
import Foundation

// The result of the checks of the repository that the session ran on the final files.
package enum ChecksState: String, Sendable, Equatable {
    // A check failed, and the reason is not the sandbox.
    case failed
    // No check failed, but a check couldn't run or failed only because of the sandbox. The fix
    // still goes: CI runs the checks on GitHub after the push.
    case blocked
    case passed
    // The session ran no check.
    case none
}

// What Claude decided for one item.
package enum ItemOutcome: Sendable, Equatable {
    // Claude changed the code. by is an earlier commit of the PR that already did the fix; nil is
    // the fix commit of the round.
    case fixed(by: CommitID?)
    // The code needs no change: the reply in the voice of the user.
    case noFix(reply: String)
    // Nothing to post: an approval, a "thanks", a note to another person.
    case noAction
    // A question for the user. Bifrost posts nothing for the item.
    case needsYou(question: String)
}

package struct ItemResult: Sendable, Equatable {
    package var id: NodeID
    package var outcome: ItemOutcome

    package init(id: NodeID, outcome: ItemOutcome) {
        self.id = id
        self.outcome = outcome
    }
}

// The fix commit of the round: its message and the paths of the worktree, each one time.
package struct CommitPlan: Sendable, Equatable {
    package var message: String
    package var paths: [String]

    package init(message: String, paths: [String]) {
        self.message = message
        self.paths = paths
    }
}

// What a good result file holds: only the known fields, so nothing else from the file goes
// further. Each item of the round has one result, in the order of the file.
package struct RequestOutcome: Sendable, Equatable {
    package var items: [ItemResult]
    package var commit: CommitPlan?
    package var checks: ChecksState

    package init(items: [ItemResult], commit: CommitPlan?, checks: ChecksState) {
        self.items = items
        self.commit = commit
        self.checks = checks
    }

    // The results whose outcome is a fix by the commit of the round.
    package var fixedByRound: [NodeID] {
        items.compactMap { if case .fixed(nil) = $0.outcome { $0.id } else { nil } }
    }
}

package enum RequestResult {
    package static let version = 1
    package static let maxBytes = 1_048_576
    // The longest reply, first line of the commit message and commit message, in UTF-16 units.
    package static let maxReply = 4_000
    package static let maxSubject = 100
    package static let maxMessage = 4_000
    // The most paths in the commit.
    package static let maxPaths = 200

    private static let order = ["version", "pr", "headSha", "round", "items", "commit", "checks"]
    private static let itemKeys: Set = ["id", "outcome", "by", "reply", "question"]
    private static let commitKeys = ["message", "paths"]

    // Check the bytes of the file against the input of the round: the PR, the head, the token and
    // the items. changed holds the paths that changed in the worktree; with nil (the check at the
    // end of the turn, before Bifrost reads the worktree), the paths of the commit are not
    // compared with it.
    package static func check(
        _ data: Data, input: RequestInput, changed: Set<String>? = nil
    ) -> Result<RequestOutcome, ResultRefusal> {
        Result { () throws(ResultRefusal) in try outcome(data, input, changed) }
    }

    private static func outcome(_ data: Data, _ input: RequestInput, _ changed: Set<String>?)
        throws(ResultRefusal) -> RequestOutcome
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
        if fields.keys.contains(where: { !order.contains($0) }) {
            throw ResultRefusal("an unknown field")
        }
        if let missing = order.first(where: { fields[$0] == nil }) {
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
            throw ResultRefusal("the round field is not this request round")
        }
        let results = try items(fields["items"], expected: input.itemIDs)
        let commit = try commitPlan(fields["commit"], changed: changed)
        guard let checks = fields["checks"]?.string.flatMap(ChecksState.init(rawValue:)) else {
            throw ResultRefusal("the checks field is not passed, failed, blocked or none")
        }
        // Only a Fixed item with no by needs the commit of the round.
        let needsCommit = results.contains { $0.outcome == .fixed(by: nil) }
        if needsCommit && commit == nil { throw ResultRefusal("a Fixed item has no commit") }
        if !needsCommit && commit != nil { throw ResultRefusal("a commit with no Fixed item") }
        if checks == .failed && commit != nil {
            throw ResultRefusal("a commit with failed checks")
        }
        return RequestOutcome(items: results, commit: commit, checks: checks)
    }

    // One result for each item of the round, each one time.
    private static func items(_ value: JSONValue?, expected: [NodeID]) throws(ResultRefusal)
        -> [ItemResult]
    {
        guard let list = value?.array else {
            throw ResultRefusal("the items field is not a list")
        }
        let wanted = Set(expected)
        var seen: Set<NodeID> = []
        var results: [ItemResult] = []
        for (index, item) in list.enumerated() {
            let result = try self.item(item, number: index + 1, expected: wanted)
            guard seen.insert(result.id).inserted else {
                throw ResultRefusal("a second result for one item")
            }
            results.append(result)
        }
        // Each ID in seen is an expected one, so a smaller set means a missing item.
        if seen.count < wanted.count { throw ResultRefusal("a missing item") }
        return results
    }

    private static func item(_ value: JSONValue, number n: Int, expected: Set<NodeID>)
        throws(ResultRefusal) -> ItemResult
    {
        guard let fields = value.object else {
            throw ResultRefusal("item \(n) is not a JSON object")
        }
        if fields.keys.contains(where: { !itemKeys.contains($0) }) {
            throw ResultRefusal("an unknown field")
        }
        guard fields["id"] != nil else { throw ResultRefusal("item \(n) has no id field") }
        guard fields["outcome"] != nil else {
            throw ResultRefusal("item \(n) has no outcome field")
        }
        guard let id = fields["id"]?.string.flatMap(NodeID.init), expected.contains(id) else {
            throw ResultRefusal("an item that is not in the input")
        }
        let field: String?
        switch fields["outcome"]?.string {
        case "fixed": field = "by"
        case "no-fix": field = "reply"
        case "no-action": field = nil
        case "needs-you": field = "question"
        default:
            throw ResultRefusal(
                "the outcome of item \(n) is not fixed, no-fix, no-action or needs-you")
        }
        let kind = fields["outcome"]?.string ?? ""
        // The key is one of itemKeys here, so the text holds nothing from the file.
        if let other = fields.keys.sorted().first(where: {
            $0 != "id" && $0 != "outcome" && $0 != field
        }) {
            throw ResultRefusal(
                "item \(n) has a \(other) field, which a \(kind) item does not have")
        }
        switch kind {
        case "no-action":
            return ItemResult(id: id, outcome: .noAction)
        case "fixed":
            guard let by = fields["by"] else { return ItemResult(id: id, outcome: .fixed(by: nil)) }
            guard let commit = by.string.flatMap(CommitID.init) else {
                throw ResultRefusal("the by field of item \(n) is not a full commit ID")
            }
            return ItemResult(id: id, outcome: .fixed(by: commit))
        case "no-fix":
            guard let reply = fields["reply"] else {
                throw ResultRefusal("item \(n) has no reply field")
            }
            let text = try self.text(reply, "the reply of item \(n)", maxReply)
            return ItemResult(id: id, outcome: .noFix(reply: text))
        default:
            guard let question = fields["question"] else {
                throw ResultRefusal("item \(n) has no question field")
            }
            let text = try self.text(question, "the question of item \(n)", Question.maxText)
            return ItemResult(id: id, outcome: .needsYou(question: text))
        }
    }

    // A reply or a question: text that is not blank, within the limit, with no control or
    // text-direction character other than a line break or a tab.
    private static func text(_ value: JSONValue, _ what: String, _ limit: Int)
        throws(ResultRefusal) -> String
    {
        guard let text = value.string else { throw ResultRefusal("\(what) is not text") }
        guard !text.trimmed().isEmpty else { throw ResultRefusal("\(what) is empty") }
        guard text.utf16.count <= limit else {
            throw ResultRefusal(
                "\(what) is longer than \(ReviewResult.count(limit)) characters")
        }
        guard !hasControl(text, tabs: true) else {
            throw ResultRefusal("\(what) has a control character")
        }
        return text
    }

    // null, or an object with the message and the paths. The own request file of the user uses
    // the same rules (OwnRequestFile).
    package static func commitPlan(_ value: JSONValue?, changed: Set<String>?)
        throws(ResultRefusal) -> CommitPlan?
    {
        guard let value, value != .null else { return nil }
        guard let fields = value.object else {
            throw ResultRefusal("the commit field is not null or a JSON object")
        }
        if fields.keys.contains(where: { !commitKeys.contains($0) }) {
            throw ResultRefusal("an unknown field")
        }
        if let missing = commitKeys.first(where: { fields[$0] == nil }) {
            throw ResultRefusal("the commit has no \(missing) field")
        }
        guard let message = fields["message"]?.string else {
            throw ResultRefusal("the commit message is not text")
        }
        let subject = message.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        guard !subject.trimmed().isEmpty else {
            throw ResultRefusal("the first line of the commit message is empty")
        }
        guard subject.utf16.count <= maxSubject else {
            throw ResultRefusal(
                "the first line of the commit message is longer than "
                    + "\(ReviewResult.count(maxSubject)) characters")
        }
        guard message.utf16.count <= maxMessage else {
            throw ResultRefusal(
                "the commit message is longer than \(ReviewResult.count(maxMessage)) characters")
        }
        guard !hasControl(message, tabs: false) else {
            throw ResultRefusal("the commit message has a control character")
        }
        guard !asksToSkipCI(message) else {
            throw ResultRefusal("the commit message asks to skip CI")
        }
        guard let list = fields["paths"]?.array else {
            throw ResultRefusal("the paths field of the commit is not a list")
        }
        guard !list.isEmpty else { throw ResultRefusal("the commit has no paths") }
        guard list.count <= maxPaths else {
            throw ResultRefusal("the commit has more than \(ReviewResult.count(maxPaths)) paths")
        }
        var paths: [String] = []
        for (index, item) in list.enumerated() {
            let n = index + 1
            guard let path = item.string else {
                throw ResultRefusal("path \(n) of the commit is not text")
            }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            let dots = parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
            let control = path.unicodeScalars.contains(where: \.isControlOrDirection)
            if path.contains("\\") || dots || control {
                throw ResultRefusal("path \(n) of the commit is not a clean relative path")
            }
            // A file system that ignores case finds the .git folder also with another case.
            if parts.contains(where: { $0.lowercased() == ".git" }) {
                throw ResultRefusal("path \(n) of the commit is in a .git folder")
            }
            if let changed, !changed.contains(path) {
                throw ResultRefusal("path \(n) of the commit did not change")
            }
            if paths.contains(path) {
                throw ResultRefusal("path \(n) of the commit shows more than one time")
            }
            paths.append(path)
        }
        return CommitPlan(message: message, paths: paths)
    }

    // True when the text tells GitHub not to run CI or the checks for the commit: [skip ci],
    // [ci skip], [no ci], [skip actions], [actions skip] (with any white space inside the
    // brackets) or skip-checks: true, in any case. The session installs no package, so CI must
    // run on the pushed fix.
    package static func asksToSkipCI(_ message: String) -> Bool {
        let bracket = /\[\s*(?:skip\s+ci|ci\s+skip|no\s+ci|skip\s+actions|actions\s+skip)\s*\]/
        let checks = /skip-checks\s*:\s*true/
        return message.contains(bracket.ignoresCase()) || message.contains(checks.ignoresCase())
    }

    // True when the text has a control character or a text-direction character, other than a
    // line break, and other than a tab with tabs.
    private static func hasControl(_ text: String, tabs: Bool) -> Bool {
        text.unicodeScalars.contains {
            if $0 == "\n" || (tabs && $0 == "\t") { return false }
            return $0.isControlOrDirection
        }
    }
}
