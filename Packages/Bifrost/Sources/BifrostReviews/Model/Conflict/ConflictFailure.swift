// Why a conflict round put no merge on GitHub (docs/behaviour/reviews.md, "Merging the base
// branch"). The row shows the message. A message holds no path and no text of git: detail gives the
// line of git or of the push for the Event log. R is the end " Choose Resolve now to try again.".
import BifrostFoundation

package enum ConflictFailure: Error, Sendable, Equatable {
    // git merged the base branch with no conflict: GitHub may not have the new state yet.
    case noConflict
    // The merge has conflicts in more than MergeStart.maxFiles (50) files.
    case tooMany
    // A conflict is not a change of plain text: a file was deleted or renamed, or it is binary,
    // a link, a submodule or over 1 MiB, or it has no conflict markers.
    case notText
    // A file that has a conflict is a file that Bifrost does not commit (CommitFileRule, or
    // CommitFileCheck before the session: a filter attribute or a submodule in the repository).
    case forbidden(CommitFileRefusal)
    // Claude could not resolve the conflicts. The text is the reason of Claude.
    case claude(String)
    // A file of the merge still holds conflict markers.
    case markersLeft
    // The worktree or the merge changes a file that has no conflict.
    case otherFiles
    // A file of the merge breaks a rule of a commit.
    case commitRefused(CommitFileRefusal)
    // A git command failed. The text is the line of git, for the Event log.
    case git(String)
    // The session of the round failed.
    case session(RoundFailure)
    // The merge did not go to GitHub, or Bifrost can't tell.
    case push(PushRefusal)

    // The text for the Event log, or nil.
    package var detail: String? {
        switch self {
        case .git(let line): line.isEmpty ? nil : line
        case .push(let refusal): refusal.detail
        default: nil
        }
    }

    // The text of the row. A push that found new commits on the branch, or a rewritten branch,
    // has no text: the round ends with no text, because the new head makes a new pair of the head
    // and the base.
    package var message: String {
        let again = " Choose Resolve now to try again."
        switch self {
        case .noConflict:
            return "Bifrost merged the base branch without any conflicts, so GitHub may not have "
                + "caught up yet. Click Refresh, or choose Resolve now to try again."
        case .tooMany:
            return "This merge has conflicts in more than 50 files, which is too many for Claude. "
                + "Resolve them yourself."
        case .notText:
            return "Some of these conflicts aren't plain text changes (a file was deleted, "
                + "renamed or is binary), so Claude didn't try. Resolve them yourself."
        // A submodule refuses each commit in the repository, not a commit of one file.
        case .forbidden(.repositoryWithSubmodule):
            return "This repository has a submodule, and Bifrost won't commit in a repository "
                + "with one, so Claude didn't try. Resolve the conflicts yourself."
        case .forbidden(let refusal):
            return "A conflict is in a file Bifrost won't change. \(refusal.message) Resolve it "
                + "yourself."
        case .claude(let reason):
            return "Claude couldn't resolve these conflicts: \(Self.sentence(reason)) Resolve "
                + "them yourself, or choose Resolve now to try again."
        case .markersLeft:
            return "Claude left conflict markers in a file, so Bifrost didn't push the merge."
                + again
        case .otherFiles:
            return "Claude changed files that weren't in conflict, so Bifrost didn't push the "
                + "merge." + again
        case .commitRefused(let refusal):
            return "Bifrost didn't commit Claude's merge. \(refusal.message)" + again
        case .git:
            return "Bifrost couldn't make the merge. The Event log has the details." + again
        case .session(let failure): return Self.message(failure, again)
        case .push(let refusal): return Self.message(refusal, again)
        }
    }

    private static func message(_ failure: RoundFailure, _ again: String) -> String {
        switch failure {
        case .stopped: "You stopped Claude, so Bifrost pushed nothing." + again
        case .sessionEnded:
            "Claude's session ended before the round finished, so Bifrost pushed nothing." + again
        case .timeout:
            "Claude took more than 30 minutes, so Bifrost stopped it and pushed nothing." + again
        case .noResult: "Claude finished without a result, so Bifrost pushed nothing." + again
        case .badResult(let refusal):
            "Claude wrote a result Bifrost couldn't use (\(refusal.message)), so Bifrost pushed "
                + "nothing." + again
        case .blocked:
            "Claude stopped to ask for approval, for example to change a settings, git or tool "
                + "file, and a round can't give it. Bifrost stopped Claude and pushed nothing."
        case .sessionBusy:
            "Claude's session for this pull request was busy, so Bifrost didn't start. Choose "
                + "Resolve now when it's finished."
        case .readFailed(let error):
            "Bifrost couldn't load this pull request from GitHub. \(error.message)" + again
        default: "Bifrost couldn't get Claude started on these conflicts." + again
        }
    }

    // A fork, a conflict and the refusals of a signed commit never come from the push of a
    // merge, so they get the text of the nearest case.
    private static func message(_ refusal: PushRefusal, _ again: String) -> String {
        switch refusal {
        case .moved, .rewritten: ""
        case .target, .fork: "Bifrost won't push to this branch, so it didn't push the merge."
        case .refused:
            "GitHub didn't accept the merge, so the branch may be protected. The Event log has "
                + "GitHub's reason."
        case .workflowScope:
            "GitHub refused the merge because it changes a workflow file and your GitHub login "
                + "can't push workflow changes, so run \(PushRefusal.refreshCommand) in a "
                + "terminal and then click Resolve now."
        case .git, .conflict, .tooLarge, .fileMode:
            "Bifrost couldn't push the merge. The Event log has the details." + again
        case .unknown:
            "Bifrost can't tell if the merge reached GitHub. Check the pull request on GitHub."
        case .deleted: "The branch is gone from GitHub, so Bifrost didn't push the merge."
        }
    }

    // The reason of Claude as one line of at most maxReason UTF-16 units: each line break becomes
    // a space, and a longer reason is cut at a whole character with an ellipsis at its end. Then
    // it ends in a full stop, an exclamation mark, a question mark or the ellipsis. An empty
    // reason gets a general text.
    private static func sentence(_ reason: String) -> String {
        let text = reason.split(whereSeparator: \.isNewline).map { $0.trimmed() }
            .filter { !$0.isEmpty }.joined(separator: " ")
        if text.isEmpty { return "Claude gave no reason." }
        if text.utf16.count > maxReason {
            return text.cut(utf16: maxReason - 1).trimmed() + "\u{2026}"
        }
        return [".", "!", "?"].contains { text.hasSuffix($0) } ? text : text + "."
    }

    // The most UTF-16 units of the reason of Claude in a message.
    package static let maxReason = 300
}
