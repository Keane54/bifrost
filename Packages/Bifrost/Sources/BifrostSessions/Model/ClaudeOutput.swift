// The read of the output of the claude commands that the session actions run
// (docs/behaviour/actions.md, "The output of claude"). The patterns read Unicode scalars, because
// claude writes them as plain bytes: a combining mark after a character does not change a match.
import BifrostFoundation

// A worktree that "claude rm" kept because it has commits on no remote: the value of
// --discard-unpushed, and the short ID and the worktree that the kept line names.
package struct KeptWorktree: Sendable, Equatable {
    package var discard: String
    package var shortId: ShortID
    package var worktree: String
}

// A worktree that "claude rm" kept because it has changes that are not committed: the short ID
// and the worktree that the kept line names.
package struct KeptChanges: Sendable, Equatable {
    package var shortId: ShortID
    package var worktree: String
}

package enum ClaudeOutput {
    // The longest raw text of a failed command, in Characters.
    package static let maxFailure = 300

    // The first start of the background service writes this line to stderr. It is not an error.
    private static let serviceBanner = "Starting background service"

    // The text of the changes refusal of "claude rm".
    private static let changesText = "The worktree has uncommitted changes"

    // "claude --bg" prints "backgrounded \u{B7} <short id> \u{B7} <name>", and a resume prints
    // "backgrounded \u{B7} <short id> (idle ...)". The short ID is the first one that the text
    // gives, with no letter, digit or "_" after it. nil when the text has none.
    package static func shortId(_ text: String) -> ShortID? {
        let pattern = /backgrounded \u{B7} ([0-9a-f]{8})(?![A-Za-z0-9_])/
        guard let match = text.firstMatch(of: pattern.matchingSemantics(.unicodeScalar)) else {
            return nil
        }
        return ShortID(match.output.1)
    }

    // True when the text has the trust error of "claude --bg".
    package static func isTrustError(_ text: String) -> Bool {
        text.unicodeScalars.contains("Workspace not trusted".unicodeScalars)
    }

    // The instruction for the trust error.
    package static func trustMessage(_ dir: String) -> String {
        "Claude Code doesn't trust this folder yet. Run claude in \(dir) once, accept the trust "
            + "prompt, then try again."
    }

    // Read a "claude rm" refusal for a worktree with commits on no remote. The output has one
    // kept line, "kept <short id> \u{2014} its worktree is still at \u{201C}<path>\u{201D}", and
    // a command with "--discard-unpushed <value>". The value goes into a claude argument, so it
    // must be 40 hex digits, "@" and 32 hex digits, and nothing more. nil for an output with no
    // kept line or with more than one, for a kept line of another form, for no value, for a
    // value of another form and for two different values.
    package static func kept(_ stdout: String) -> KeptWorktree? {
        let lines = lines(of: stdout)
        let keptLines = lines.filter(isKeptLine)
        guard keptLines.count == 1, let line = keptLine(keptLines[0]) else { return nil }
        let flag = /--discard-unpushed (\S+)/.matchingSemantics(.unicodeScalar)
        var values = Set<Substring>()
        for line in lines {
            for match in line.matches(of: flag) { values.insert(match.output.1) }
        }
        let value = /[0-9a-f]{40}@[0-9a-f]{32}/.matchingSemantics(.unicodeScalar)
        guard values.count == 1, let discard = values.first, discard.wholeMatch(of: value) != nil
        else { return nil }
        return KeptWorktree(
            discard: String(discard), shortId: line.shortId, worktree: line.worktree)
    }

    // Read a "claude rm" refusal for a worktree with changes that are not committed. The output
    // has the kept line first and the changes text on a later line, and no discard value. nil
    // when the first line is not a kept line of the correct form, when another line starts with
    // "kept ", and for an output with no changes text.
    package static func keptChanges(_ stdout: String) -> KeptChanges? {
        let lines = lines(of: stdout)
        guard lines.filter(isKeptLine).count == 1, let line = keptLine(lines[0]),
            lines.dropFirst().contains(where: hasChangesText)
        else { return nil }
        return line
    }

    // The refusal of a failed claude command. A raw text of claude gets the lead sentence of
    // claudeReported, so the user knows that the text comes from Claude Code. An exit code with
    // no text gives claudeExited, with no command line. A command that the runner ended gives
    // the plain text of claudeFailed.
    package static func claudeFailure(_ result: ExecResult) -> ActionRefusal {
        guard case .exited(let code) = result.end else { return .claudeFailed }
        let raw = rawText(result)
        return raw.isEmpty ? .claudeExited(code: code) : .claudeReported(raw)
    }

    // The raw text of a failed command: the stderr, else the stdout, cut to maxFailure, or "" when
    // both are empty. The visible text comes first, so an escape sequence or a bidi control
    // cannot reach the text of a notice. A stderr line that is only the start line of the
    // background service does not count.
    private static func rawText(_ result: ExecResult) -> String {
        let stderr = lines(of: visible(result.stderr))
            .filter { !$0.trimmed().unicodeScalars.starts(with: serviceBanner.unicodeScalars) }
            .joined(separator: "\n")
            .trimmed()
        let text = stderr.isEmpty ? visible(result.stdout).trimmed() : stderr
        return String(text.prefix(maxFailure))
    }

    // The text with no control characters (the clean of the session input) and no hidden
    // characters of a name (isHiddenInAName). A bidi control could reverse the text of the
    // notice after it. The tab and the LF stay.
    private static func visible(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in InputPlan.clean(text).unicodeScalars
        where scalar == "\t" || scalar == "\n" || !isHiddenInAName(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    // The lines of a text, split at each LF. A CR stays at the end of its line.
    private static func lines(of text: String) -> [Substring] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map(Substring.init)
    }

    private static func isKeptLine(_ line: Substring) -> Bool {
        line.unicodeScalars.starts(with: "kept ".unicodeScalars)
    }

    private static func hasChangesText(_ line: Substring) -> Bool {
        line.unicodeScalars.contains(changesText.unicodeScalars)
    }

    // The short ID and the worktree of a whole kept line, or nil for a line of another form. The
    // pattern uses the extended syntax, so each space of the line is "\ ".
    private static func keptLine(_ line: Substring) -> KeptChanges? {
        let pattern = #/
            kept\ ([0-9a-f]{8})\ \u{2014}\ its\ worktree\ is\ still\ at
            \ \u{201C}([^\u{201C}\u{201D}]+)\u{201D}
            /#
        guard let match = line.wholeMatch(of: pattern.matchingSemantics(.unicodeScalar)),
            let shortId = ShortID(match.output.1)
        else { return nil }
        return KeptChanges(shortId: shortId, worktree: String(match.output.2))
    }
}
