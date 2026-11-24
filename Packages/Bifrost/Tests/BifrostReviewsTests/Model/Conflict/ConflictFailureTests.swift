// The texts of a conflict round that put no merge on GitHub (docs/behaviour/reviews.md, "Merging
// the base branch"). The details of git and of the push go only to the Event log.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private let again = " Choose Resolve now to try again."

@Suite("the texts of a conflict failure", .testTimeLimit)
struct ConflictFailureTests {
    @Test func eachFailureHasItsText() {
        let texts: [(ConflictFailure, String)] = [
            (
                .noConflict,
                "Bifrost merged the base branch without any conflicts, so GitHub may not have "
                    + "caught up yet. Click Refresh, or choose Resolve now to try again."
            ),
            (
                .tooMany,
                "This merge has conflicts in more than \(ConflictMerge.maxFiles) files, which is "
                    + "too many for Claude. Resolve them yourself."
            ),
            (
                .notText,
                "Some of these conflicts aren't plain text changes (a file was deleted, renamed or "
                    + "is binary), so Claude didn't try. Resolve them yourself."
            ),
            (
                .forbidden(.workflow),
                "A conflict is in a file Bifrost won't change. Bifrost won't commit a GitHub "
                    + "workflow or action. Resolve it yourself."
            ),
            (
                .forbidden(.repositoryWithSubmodule),
                "This repository has a submodule, and Bifrost won't commit in a repository with "
                    + "one, so Claude didn't try. Resolve the conflicts yourself."
            ),
            (
                .claude("The two changes mean different things"),
                "Claude couldn't resolve these conflicts: The two changes mean different things. "
                    + "Resolve them yourself, or choose Resolve now to try again."
            ),
            (
                .claude("  Which name is right?\n"),
                "Claude couldn't resolve these conflicts: Which name is right? Resolve them "
                    + "yourself, or choose Resolve now to try again."
            ),
            (
                .claude(" "),
                "Claude couldn't resolve these conflicts: Claude gave no reason. Resolve them "
                    + "yourself, or choose Resolve now to try again."
            ),
            (
                .markersLeft,
                "Claude left conflict markers in a file, so Bifrost didn't push the merge." + again
            ),
            (
                .otherFiles,
                "Claude changed files that weren't in conflict, so Bifrost didn't push the merge."
                    + again
            ),
            (
                .commitRefused(.tooLarge),
                "Bifrost didn't commit Claude's merge. Bifrost won't commit a file over 1 MB."
                    + again
            ),
            (
                .git("fatal: bad object"),
                "Bifrost couldn't make the merge. The Event log has the details." + again
            ),
        ]
        for (failure, text) in texts {
            #expect(failure.message == text, "\(failure)")
        }
    }

    // The reason of Claude goes in the tip of the row as one line of at most 300 UTF-16 units.
    @Test func aLongOrMultiLineReasonIsOneShortLine() {
        let start = "Claude couldn't resolve these conflicts: "
        let end = " Resolve them yourself, or choose Resolve now to try again."
        let lines = ConflictFailure.claude("The names differ.\nOne side renamed it.\r\n\n  The end")
        #expect(lines.message == start + "The names differ. One side renamed it. The end." + end)
        let long = ConflictFailure.claude(String(repeating: "word ", count: 100)).message
        #expect(long.hasPrefix(start) && long.hasSuffix(end))
        let reason = String(long.dropFirst(start.count).dropLast(end.count))
        #expect(reason.utf16.count <= ConflictFailure.maxReason && reason.hasSuffix("d\u{2026}"))
    }

    @Test func eachSessionFailureHasItsText() {
        let texts: [(RoundFailure, String)] = [
            (.stopped, "You stopped Claude, so Bifrost pushed nothing." + again),
            (
                .sessionEnded,
                "Claude's session ended before the round finished, so Bifrost pushed nothing."
                    + again
            ),
            (
                .timeout,
                "Claude took more than 30 minutes, so Bifrost stopped it and pushed nothing."
                    + again
            ),
            (.noResult, "Claude finished without a result, so Bifrost pushed nothing." + again),
            (
                .badResult(ResultRefusal("files")),
                "Claude wrote a result Bifrost couldn't use (files), so Bifrost pushed nothing."
                    + again
            ),
            (
                .blocked,
                "Claude stopped to ask for approval, for example to change a settings, git or "
                    + "tool file, and a round can't give it. Bifrost stopped Claude and pushed "
                    + "nothing."
            ),
            (
                .sessionBusy,
                "Claude's session for this pull request was busy, so Bifrost didn't start. Choose "
                    + "Resolve now when it's finished."
            ),
            (
                .readFailed(.timedOut),
                "Bifrost couldn't load this pull request from GitHub. GitHub didn't answer in "
                    + "time." + again
            ),
            (.startFailed, "Bifrost couldn't get Claude started on these conflicts." + again),
            (.prepareFailed, "Bifrost couldn't get Claude started on these conflicts." + again),
        ]
        for (failure, text) in texts {
            #expect(ConflictFailure.session(failure).message == text, "\(failure)")
        }
    }

    // A push that found new commits or a rewritten branch ends with no text: the new head makes
    // a new pair. The line of git or of GitHub goes only to the Event log.
    @Test func eachPushFailureHasItsText() {
        let texts: [(PushRefusal, String)] = [
            (.target, "Bifrost won't push to this branch, so it didn't push the merge."),
            (
                .refused("[remote rejected] protected"),
                "GitHub didn't accept the merge, so the branch may be protected. The Event log "
                    + "has GitHub's reason."
            ),
            (
                .git("fatal: unable to access"),
                "Bifrost couldn't push the merge. The Event log has the details." + again
            ),
            (
                .unknown("timeout"),
                "Bifrost can't tell if the merge reached GitHub. Check the pull request on GitHub."
            ),
            (
                .deleted(madeAgain: false),
                "The branch is gone from GitHub, so Bifrost didn't push the merge."
            ),
            (.moved, ""), (.rewritten, ""),
        ]
        for (refusal, text) in texts {
            #expect(ConflictFailure.push(refusal).message == text, "\(refusal)")
        }
        #expect(ConflictFailure.git("fatal: bad object").detail == "fatal: bad object")
        #expect(ConflictFailure.push(.git("fatal: x")).detail == "fatal: x")
        #expect(ConflictFailure.git("").detail == nil && ConflictFailure.markersLeft.detail == nil)
        let line = "fatal: secret/path"
        for failure in [ConflictFailure.git(line), .push(.git(line)), .push(.refused(line))] {
            #expect(!failure.message.contains("secret"))
        }
    }
}
