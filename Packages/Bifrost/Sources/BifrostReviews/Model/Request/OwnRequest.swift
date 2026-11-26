// The own request file of a PR of the user (docs/behaviour/reviews.md, "Your own requests", and
// skills/bifrost-resolve-comments/bifrost-mode.md, "A request from the user between rounds").
// Between rounds, the user can type a request into the request session of the PR. Claude makes
// the change, then lists the files and writes a commit message in this file. Claude never commits
// or pushes: Bifrost does, through the path of the fix of a round. The context of the session
// holds review text from other people, so Bifrost trusts none of the file. The check is as strict
// as the check of a round result: one failed rule refuses the whole file, and Bifrost then commits
// nothing and pushes nothing. A refusal names a field or a limit only, never text from the file.
import BifrostFoundation
import Foundation

package enum OwnRequestFile {
    // The name of the file in the input folder of the PR. No round asks for the file, so its name
    // has no round ID: the path is the same in each round (RequestInput.Files.ownRequest).
    package static let name = "own-request.json"
    package static let version = 1

    private static let keys = ["version", "pr", "headSha", "commit"]

    // Check the bytes of the file against the PR, the commit that the worktree is at (head) and
    // the paths that changed in the worktree. The commit has the rules of the commit of a round
    // result (RequestResult.commitPlan): the message rules, and 1 to 200 clean relative paths
    // outside any .git folder, each changed in the worktree and each one time.
    package static func check(
        _ data: Data, pr: PRKey, head: CommitID, changed: Set<String>
    ) -> Result<CommitPlan, ResultRefusal> {
        Result { () throws(ResultRefusal) in try plan(data, pr, head, changed) }
    }

    private static func plan(_ data: Data, _ pr: PRKey, _ head: CommitID, _ changed: Set<String>)
        throws(ResultRefusal) -> CommitPlan
    {
        guard data.count <= RequestResult.maxBytes else {
            throw ResultRefusal(
                "the file is larger than \(ReviewResult.count(RequestResult.maxBytes)) bytes")
        }
        // The error of the decoder can hold a part of the file, so it never shows.
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ResultRefusal("the file is not valid JSON")
        }
        guard let fields = value.object else {
            throw ResultRefusal("the file is not a JSON object")
        }
        if fields.keys.contains(where: { !keys.contains($0) }) {
            throw ResultRefusal("an unknown field")
        }
        if let missing = keys.first(where: { fields[$0] == nil }) {
            throw ResultRefusal("the \(missing) field is missing")
        }
        guard fields["version"]?.wholeNumber == version else {
            throw ResultRefusal("the version field is not 1")
        }
        guard fields["pr"]?.string == pr.text else {
            throw ResultRefusal("the pr field is not this pull request")
        }
        guard fields["headSha"]?.string == head.hex else {
            throw ResultRefusal("the headSha field is not the commit of the pull request's copy")
        }
        // A request that changes no file writes no file, so a file always has a commit.
        guard let commit = fields["commit"], commit.object != nil else {
            throw ResultRefusal("the commit field is not a JSON object")
        }
        guard let plan = try RequestResult.commitPlan(commit, changed: changed) else {
            throw ResultRefusal("the commit field is not a JSON object")
        }
        return plan
    }
}

// How a check or a run of Discard these changes ended (ReviewRounds.discardChanges). message is
// the friendly text of the panel's error line when nothing was discarded.
package enum DiscardOutcome: Sendable, Equatable {
    // The check: these files of the copy of the PR go with the discard.
    case files([String])
    case discarded
    // The copy has no change now. The reason of the row clears: there is nothing to discard.
    case nothing
    // A round, an own request, a discard or the session uses the copy now.
    case notNow
    // git could not read or reset the copy. The changes and the reason stay.
    case failed

    package var message: String? {
        switch self {
        case .files, .discarded: nil
        case .nothing:
            "There's nothing to discard: Bifrost's copy of this pull request has no changes now."
        case .notNow:
            "Bifrost can't discard the changes now, because Claude or a round is using this pull "
                + "request's copy. Try again when it's finished."
        case .failed:
            "Bifrost couldn't discard the changes, so they're still there. The Event log has "
                + "the details."
        }
    }
}

// Why Bifrost did not commit or push an own request of the user. message is the reason of the
// row (Needs you), in friendly text; the Event log keeps the details of git and GitHub.
package enum OwnRequestStop: Error, Sendable, Equatable {
    // The own request file broke a rule.
    case badFile(ResultRefusal)
    // git could not read the worktree of the PR.
    case noWorktree
    // Bifrost could not save its state before the commit.
    case notSaved
    // The commit or the push stopped (RoundWrites).
    case wrote(RoundFailure)
    // The worktree holds the merge of a conflict round, which is not on GitHub (the request came
    // in the turn of a conflict round, or after it with no reset). A commit on it would push the
    // merge with its markers.
    case conflictMerge

    // The end of a text whose change is still in the worktree, as changes.
    private static let kept = "Your change is still in Bifrost's copy of this pull request."
    private static let askAgain = "Ask Claude in its session to try again."
    private static let unsigned =
        "Turn off Sign commits through GitHub, then ask Claude in its session to try again."
    // The way out when the branch on GitHub moved: the worktree can move to the new head only
    // when the change is out of it.
    private static let startAgain =
        "Ask Claude in its session to undo it, choose Handle now, then ask for it again."

    package var message: String {
        switch self {
        case .badFile(let refusal):
            "Claude wrote a commit request Bifrost couldn't use (\(refusal.message)), so Bifrost "
                + "didn't commit your change. \(Self.kept) \(Self.askAgain)"
        case .noWorktree:
            "Bifrost couldn't read its copy of this pull request, so it didn't commit your "
                + "change. \(Self.askAgain)"
        case .notSaved:
            "Bifrost couldn't save its state, so it didn't commit your change. \(Self.kept) "
                + Self.askAgain
        case .wrote(let failure): Self.message(failure)
        case .conflictMerge:
            "Claude was resolving merge conflicts in Bifrost's copy of this pull request, so "
                + "Bifrost didn't commit your change or push the merge. \(Self.kept) Choose "
                + "Discard these changes, then ask Claude again."
        }
    }

    private static func message(_ failure: RoundFailure) -> String {
        switch failure {
        case .commitRefused(let refusal):
            "Bifrost didn't commit your change. \(refusal.message) \(kept)"
        case .commitFailed:
            "Bifrost couldn't commit your change. The Event log has the details. \(kept)"
        case .pushFailed(let refusal): message(refusal)
        case .readFailed(let error), .writesStopped(_, _, let error):
            "Bifrost couldn't push your change. \(error.message) Choose Try again to push it."
        case .writesRefused(_, _, let error):
            "GitHub stopped Bifrost before it pushed your change. \(error.message) \(kept)"
        case .prClosed: "This pull request was closed, so Bifrost didn't push your change."
        case .notYours: "This pull request isn't yours, so Bifrost didn't push your change."
        case .fork: message(PushRefusal.fork)
        default:
            "Bifrost couldn't finish your change. Check the pull request on GitHub, then choose "
                + "Try again."
        }
    }

    private static func message(_ refusal: PushRefusal) -> String {
        switch refusal {
        case .conflict:
            "Someone pushed to this branch, and your change doesn't merge cleanly, so Bifrost "
                + "didn't push it. \(kept) \(startAgain)"
        case .rewritten:
            "Someone rewrote this branch, so Bifrost didn't push your change. \(kept) \(startAgain)"
        case .moved:
            "The branch kept changing while Bifrost pushed, so your change didn't go. \(kept) "
                + askAgain
        case .deleted(madeAgain: false):
            "The branch is gone from GitHub, so Bifrost didn't push your change. \(kept)"
        case .deleted(madeAgain: true): refusal.message
        case .target: "Bifrost won't push to this branch, so it didn't push your change. \(kept)"
        case .fork:
            "This pull request comes from a fork, where Bifrost can't push, so it didn't push "
                + "your change. \(kept)"
        case .tooLarge:
            "Your change is over 4 MB, which is too large for a commit that GitHub signs. "
                + "\(unsigned) \(kept)"
        case .fileMode:
            "Your change touches a link or a file that must stay executable, and GitHub can't "
                + "keep that in a commit it signs. \(unsigned) \(kept)"
        case .refused:
            "GitHub didn't accept your change, so the branch may be protected. The Event log has "
                + "GitHub's reason. \(kept)"
        case .workflowScope:
            "GitHub refused your change because it touches a workflow file and your GitHub login "
                + "can't push workflow changes, so run \(PushRefusal.refreshCommand) in a "
                + "terminal and then try again. \(kept)"
        case .git:
            "Bifrost couldn't push your change. The Event log has the details. Choose Try again "
                + "to push it."
        case .unknown:
            "Bifrost can't tell if your change reached GitHub. Check the pull request on GitHub, "
                + "then choose Try again."
        }
    }
}
