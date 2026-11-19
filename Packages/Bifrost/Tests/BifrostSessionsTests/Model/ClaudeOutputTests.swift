// The read of the output of the claude commands of the session actions
// (docs/behaviour/actions.md, "The output of claude"): the short ID of a start, the trust error,
// the two "claude rm" refusals and the text of a failed command.
import BifrostFoundation
import BifrostTestSupport
import Testing

@testable import BifrostSessions

private let dash = "\u{2014}"
private let open = "\u{201C}"
private let close = "\u{201D}"

// The stdout of "claude rm abd71478" for a worktree with a commit on no remote: the form of a
// real run of Claude Code 2.1.318, which exited with code 1.
private let keptShortId: ShortID = "abd71478"
private let keptWorktree = "/Users/dev/Developer/project/.claude/worktrees/bifrost-test-rmx"
private let keptHead = "f7698d38614ba22b41f996fab73124361d2fe389"
private let keptDiscard = "\(keptHead)@598a160a880168020f78fdeda23f998a"
private let keptStdout = [
    "kept abd71478 \(dash) its worktree is still at \(open)\(keptWorktree)\(close)",
    "  169 unpushed commits on \(open)worktree-bifrost-test-rmx\(close): f7698d3 "
        + "\(open)test: bifrost-test commit\(close) and 168 more. They exist on no remote, so "
        + "deleting the worktree would lose them.",
    "  push them and run 'claude rm abd71478' again, or discard the worktree and its commits: "
        + "claude rm abd71478 --discard-unpushed \(keptDiscard)",
    "",
].joined(separator: "\n")

// The stdout of "claude rm 27b87cbf" for a worktree with changes that are not committed. It has
// no --discard-unpushed value.
private let changesShortId: ShortID = "27b87cbf"
private let changesWorktree = "/Users/dev/Developer/project/.claude/worktrees/bifrost-test-wt1"
private let changesStdout = [
    "kept 27b87cbf \(dash) its worktree is still at \(open)\(changesWorktree)\(close)",
    "  The worktree has uncommitted changes. Deleting it would lose them.",
    "  commit or stash them and run 'claude rm 27b87cbf' again, or delete the session from "
        + "'claude agents' (ctrl+x twice)",
    "",
].joined(separator: "\n")

// The output with its first line changed.
private func withFirstLine(_ line: String, of stdout: String) -> String {
    ([line] + stdout.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().map(
        String.init)).joined(separator: "\n")
}

private func firstLine(_ stdout: String) -> String {
    String(stdout.prefix { $0 != "\n" })
}

private let banner = "Starting background service\u{2026}"

@Suite("the output of claude")
struct ClaudeOutputTests {
    @Test(
        "the short ID of a start or a resume",
        arguments: [
            ("backgrounded \u{B7} 4cb23c30 \u{B7} bifrost-test-main", "4cb23c30"),
            ("backgrounded \u{B7} 57ffb4ce (idle \(dash) send a prompt to start)", "57ffb4ce"),
            ("Starting\nbackgrounded \u{B7} 0a1b2c3d\nhint", "0a1b2c3d"),
            ("backgrounded \u{B7} 4cb23c30\u{301}", "4cb23c30"),
            ("backgrounded \u{B7} 4cb23c30-x", "4cb23c30"),
            ("backgrounded \u{B7} 4cb23c3x backgrounded \u{B7} 11112222", "11112222"),
        ] as [(String, ShortID)])
    func shortId(text: String, expected: ShortID) {
        #expect(ClaudeOutput.shortId(text) == expected)
    }

    @Test(
        "no short ID without the backgrounded form",
        arguments: [
            "started 4cb23c30", "backgrounded \u{B7} 4CB23C30", "backgrounded \u{B7} 4cb23c30ff",
            "backgrounded \u{B7} 4cb23c30_", "backgrounded . 4cb23c30", "backgrounded \u{B7} 4cb2",
            "",
        ])
    func noShortId(text: String) {
        #expect(ClaudeOutput.shortId(text) == nil)
    }

    @Test func theTrustErrorIsFoundAnywhereInTheText() {
        let text = "Workspace not trusted. Run `claude` in /x once and accept the trust prompt."
        #expect(ClaudeOutput.isTrustError(text))
        #expect(ClaudeOutput.isTrustError("error: \(text)"))
        #expect(!ClaudeOutput.isTrustError(banner))
    }

    @Test func theTrustTextTellsTheUserToAcceptThePromptOnce() {
        let text =
            "Claude Code doesn't trust this folder yet. Run claude in /p once, accept the trust "
            + "prompt, then try again."
        #expect(ClaudeOutput.trustMessage("/p") == text)
        #expect(ActionRefusal.trust(dir: "/p").message == text)
    }
}

// The refusal of a run with this end and output.
private func claudeFailure(
    _ end: ExecEnd, stdout: String = "", stderr: String = ""
) -> ActionRefusal {
    ClaudeOutput.claudeFailure(ExecResult(end, stdout: stdout, stderr: stderr))
}

@Suite("a failed command")
struct CommandFailureTests {
    // The limit counts Characters, so the cut never splits an emoji.
    @Test(arguments: ["e", "😀"])
    func theRawTextHasAtMost300Characters(unit: String) {
        let long = String(repeating: unit, count: 400)
        let cut = String(repeating: unit, count: 300)
        #expect(claudeFailure(.exited(1), stderr: long) == .claudeReported(cut))
        #expect(ClaudeOutput.maxFailure == 300)
    }

    // The first start of the background service writes the banner to stderr. It is no error.
    @Test func theBannerOfTheBackgroundServiceIsNoText() {
        let realError = claudeFailure(.exited(1), stdout: "real error", stderr: "\(banner)\n")
        #expect(realError == .claudeReported("real error"))
        let boom = ActionRefusal.claudeReported("boom")
        #expect(claudeFailure(.exited(1), stdout: "x", stderr: "\(banner)\nboom\n") == boom)
        #expect(claudeFailure(.exited(1), stdout: "x", stderr: "  \(banner)\nboom") == boom)
    }

    @Test func aRawTextOfClaudeGetsTheLeadSentence() {
        let lead = "Claude Code reported a problem:"
        let bad = claudeFailure(.exited(1), stdout: "out", stderr: " bad \n")
        #expect(bad == .claudeReported("bad"))
        #expect(bad.message == "\(lead) bad")
        let out = claudeFailure(.exited(1), stdout: " out ", stderr: " \n")
        #expect(out.message == "\(lead) out")
        // The raw text keeps its limit. The lead sentence comes in addition.
        let long = claudeFailure(.exited(1), stderr: String(repeating: "e", count: 400))
        #expect(long.message == "\(lead) \(String(repeating: "e", count: 300))")
    }

    // The text names no command line.
    @Test func anExitCodeWithNoTextGetsThePlainText() {
        let none = claudeFailure(.exited(2))
        #expect(none == .claudeExited(code: 2))
        let text = "Claude Code stopped before it finished (code 2). Try again in a moment."
        #expect(none.message == text)
        #expect(claudeFailure(.exited(4), stderr: banner) == .claudeExited(code: 4))
    }

    // An escape sequence or a bell of claude cannot reach the text of a notice.
    @Test func theControlCharactersOfTheTextGo() {
        let stderr = "\u{1B}[31mbad\u{1B}[0m\u{7} \u{9B}x\r\nnext"
        #expect(claudeFailure(.exited(1), stderr: stderr) == .claudeReported("[31mbad[0m x\nnext"))
        #expect(claudeFailure(.exited(1), stdout: "\u{1B}out") == .claudeReported("out"))
        #expect(claudeFailure(.exited(3), stderr: "\u{1B}\u{7}") == .claudeExited(code: 3))
    }

    // A bidi control could reverse the text of the notice after it, and a zero-width character
    // hides in it. Both go, as in a name. A tab and the line breaks stay.
    @Test func theHiddenCharactersOfTheTextGo() {
        let hidden = "\u{202E}b\u{200B}a\u{2066}d\u{FEFF}\u{200F}\tx\nnext\u{2069}"
        #expect(claudeFailure(.exited(1), stderr: hidden) == .claudeReported("bad\tx\nnext"))
        #expect(claudeFailure(.exited(1), stdout: "\u{202E}out") == .claudeReported("out"))
        let onlyHidden = claudeFailure(.exited(3), stderr: "\u{200B}\u{2067}")
        #expect(onlyHidden == .claudeExited(code: 3))
    }

    // The text of such a run comes from Bifrost and can hold the raw arguments, so the user reads
    // a plain text.
    @Test(arguments: [ExecEnd.timedOut, .signal(9), .overflow, .cancelled, .notStarted])
    func aRunThatDidNotEndByItselfGivesThePlainText(end: ExecEnd) {
        let refusal = claudeFailure(end, stdout: "out", stderr: "/x/claude stop abcd1234 stopped.")
        #expect(refusal == .claudeFailed)
        #expect(refusal.message == "A Claude Code command failed. Try again in a moment.")
    }
}

@Suite("a worktree that claude rm keeps")
struct KeptWorktreeTests {
    @Test func theKeptOutputGivesTheDiscardValueTheShortIdAndTheWorktree() {
        let kept = KeptWorktree(discard: keptDiscard, shortId: keptShortId, worktree: keptWorktree)
        #expect(ClaudeOutput.kept(keptStdout) == kept)
    }

    @Test(
        "a kept line of another form gives nothing",
        arguments: [
            "kept abd71478",
            firstLine(keptStdout).replacing("abd71478", with: "ABD71478"),
            firstLine(keptStdout).replacing("abd71478", with: "bd71478"),
            firstLine(keptStdout).replacing("abd71478", with: "abd714780"),
            firstLine(keptStdout).replacing(dash, with: "-"),
            firstLine(keptStdout).replacing(open, with: "\"").replacing(close, with: "\""),
            firstLine(keptStdout).replacing(keptWorktree, with: ""),
            firstLine(keptStdout).replacing(close, with: ""),
            firstLine(keptStdout) + " and more",
            firstLine(keptStdout) + "\r",
            firstLine(keptStdout).replacing("its worktree is still at", with: "its worktree is at"),
            firstLine(keptStdout).replacing(keptWorktree, with: "/a\(open)b"),
            "\(firstLine(keptStdout))\n\(firstLine(keptStdout))",
        ])
    func aKeptLineOfAnotherForm(line: String) {
        #expect(ClaudeOutput.kept(withFirstLine(line, of: keptStdout)) == nil)
    }

    // The value goes into a claude argument, so only 40 hex digits, "@" and 32 hex digits pass.
    @Test(
        "a changed discard value gives nothing",
        arguments: {
            let commit = keptHead
            let token = String(keptDiscard.split(separator: "@")[1])
            return [
                "\(commit.dropFirst())@\(token)", "\(commit)a@\(token)",
                "\(commit)@\(token.dropFirst())", "\(commit)@\(token)0",
                "\(commit.uppercased())@\(token)", "\(commit)\(token)",
                "\(commit)@\(token)@\(token)", "\(commit)@\(token);", "\(commit)@\(token).",
                "\(commit)@\(token)$(id)", "-\(commit)@\(token)",
                "\(commit.prefix(39))g@\(token)",
            ]
        }())
    func aChangedDiscardValue(value: String) {
        #expect(ClaudeOutput.kept(keptStdout.replacing(keptDiscard, with: value)) == nil)
    }

    @Test func twoDifferentValuesGiveNothing() {
        let other = String(repeating: "0", count: 40) + "@" + String(repeating: "1", count: 32)
        #expect(ClaudeOutput.kept("\(keptStdout)--discard-unpushed \(other)\n") == nil)
        // The same value two times is one value.
        #expect(ClaudeOutput.kept("\(keptStdout)--discard-unpushed \(keptDiscard)\n") != nil)
    }

    @Test(
        "other text gives nothing",
        arguments: {
            let discardLine = "claude rm abd71478 --discard-unpushed \(keptDiscard)"
            return [
                "", "removed abd71478", discardLine,
                // The kept line must start the line.
                "  kept abd71478\n\(discardLine)", "not kept abd71478\n\(discardLine)",
                "kept abd71478\nno discard flag here",
                "kept abd71478\n--discard-unpushed\n\(keptDiscard)",
                "kept abd71478\n--discard-unpushed=\(keptDiscard)",
            ]
        }())
    func otherText(text: String) {
        #expect(ClaudeOutput.kept(text) == nil)
    }
}

@Suite("a worktree with changes that claude rm keeps")
struct KeptChangesTests {
    @Test func theChangesOutputGivesTheShortIdAndTheWorktree() {
        let kept = KeptChanges(shortId: changesShortId, worktree: changesWorktree)
        #expect(ClaudeOutput.keptChanges(changesStdout) == kept)
        // The output has no discard value.
        #expect(ClaudeOutput.kept(changesStdout) == nil)
    }

    @Test(
        "a first line of another form gives nothing",
        arguments: [
            "kept 27b87cbf",
            firstLine(changesStdout).replacing("27b87cbf", with: "27B87CBF"),
            firstLine(changesStdout).replacing("27b87cbf", with: "7b87cbf"),
            firstLine(changesStdout).replacing(dash, with: "-"),
            firstLine(changesStdout).replacing(open, with: "\"").replacing(close, with: "\""),
            firstLine(changesStdout).replacing(changesWorktree, with: ""),
            firstLine(changesStdout) + " and more",
            "  " + firstLine(changesStdout),
            "\(firstLine(changesStdout))\n\(firstLine(changesStdout))",
        ])
    func aFirstLineOfAnotherForm(line: String) {
        #expect(ClaudeOutput.keptChanges(withFirstLine(line, of: changesStdout)) == nil)
    }

    @Test func theKeptLineMustComeFirstAndHaveTheChangesText() {
        #expect(ClaudeOutput.keptChanges("removed 27b87cbf\n\(changesStdout)") == nil)
        // The kept text of a worktree with commits on no remote is not the changes text.
        #expect(ClaudeOutput.keptChanges(keptStdout) == nil)
        #expect(ClaudeOutput.keptChanges(firstLine(keptStdout)) == nil)
        let noChanges = changesStdout.replacing("uncommitted changes", with: "changes")
        #expect(ClaudeOutput.keptChanges(noChanges) == nil)
        #expect(ClaudeOutput.keptChanges("") == nil)
        #expect(ClaudeOutput.keptChanges("The worktree has uncommitted changes") == nil)
    }
}
