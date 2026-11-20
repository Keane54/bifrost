// Why a review round or a request round ended with no result (docs/behaviour/reviews.md, "Review
// rounds" and "Request rounds"). The row shows the message with Try again, and no notification
// goes out. A message names no path and holds no text of the result file or of git: the log keeps
// the details. A message that comes after a write that GitHub may have saved does not say that
// nothing was posted, and does not ask for Try again, because Bifrost never sends such a write
// again by itself. message is the text of a review round; message(for:) gives the text of each
// kind of round.
import BifrostFoundation

package enum RoundFailure: Error, Sendable, Equatable {
    // The full diff or the diff since the baseline is over ReviewInput.maxDiffBytes.
    case tooLarge
    // The head of the PR moved between the read of GitHub and the fetch.
    case prChanged
    case prClosed
    // The session ended with no result file.
    case noResult
    // The user stopped the session of the round, or it went.
    case stopped
    // Request rounds: the user stopped the round while it sent the rest of the writes of an
    // earlier round. Those writes went, and Claude did not start.
    case stoppedAfterEarlierWrites
    // The session worked past the time limit of the round.
    case timeout
    // The pending review of the user is on another commit.
    case otherCommit
    // GitHub did not keep the review as a draft, or the draft of the user was submitted or
    // deleted before Bifrost wrote to it.
    case notPending
    // A round that was posting when Bifrost closed: GitHub may have its draft.
    case closedWhilePosting
    // The session showed a prompt and its result was missing or bad.
    case blocked
    // The draft review of Bifrost for this commit is still on GitHub.
    case ownDraft
    // A read of the PR on GitHub failed. Nothing was posted.
    case readFailed(GitHubError)
    // The files of the input folder could not be written.
    case inputFailed
    // A step of git or of the folders failed before the session.
    case prepareFailed
    // claude did not start the session.
    case startFailed
    // Claude Code does not trust the clone of the repository: the round waits for the trust step.
    case notTrusted
    // Bifrost could not save the state before a write to GitHub, so it wrote nothing.
    case notSaved
    // CI started to fail while the review waited in the queue.
    case ciFailing
    case draftTooLong
    case summaryTooLong
    // The result file broke a rule. The refusal names the field or the limit.
    case badResult(ResultRefusal)
    // GitHub refused the first write. Nothing was posted.
    case postRefused(String)
    // GitHub may have saved a write: Bifrost cannot tell.
    case postUnknown(GitHubError)
    // GitHub refused a thread after added of total threads went in.
    case partlyAdded(added: Int, total: Int, String)
    // Each comment went in, and GitHub refused the summary.
    case summaryRefused(String)
    // Request rounds: GitHub has more items of the PR than Bifrost reads, so a sent reply or a
    // deleted thread can hide in the rest.
    case tooManyComments
    // Request rounds: the PR is not a PR of the user.
    case notYours
    // Request rounds: the PR comes from a fork, where Bifrost can't push.
    case fork
    // A step after the session failed (git or the files), or the round stopped in a step that
    // can follow writes. GitHub can hold a part of the writes.
    case endFailed
    // Request rounds: a listed file of the fix breaks a rule of a fix commit. Nothing was posted.
    case commitRefused(CommitFileRefusal)
    // Request rounds: git did not make the fix commit. Nothing was posted.
    case commitFailed
    // Request rounds: the fix did not go to GitHub, or Bifrost can't tell.
    case pushFailed(PushRefusal)
    // Request rounds: a read or a write of GitHub stopped the writes after done of total
    // updates. The outbox keeps the rest for Try again, which first looks for a write that
    // GitHub may have made.
    case writesStopped(done: Int, total: Int, GitHubError)
    // Request rounds: GitHub refused a read or a write after done of total updates, and it would
    // refuse it again in each run (OutboxRules.lasts). The outbox went: its done items are
    // handled, and the others wait in held.
    case writesRefused(done: Int, total: Int, GitHubError)
    // Request rounds: the user has a draft review on the PR, and the replies would go into it.
    case ownPending
    // Request rounds: a reply went into a draft review of the user.
    case replyPending
    // Rounds on a PR of the user: the session of the PR was not ready for PRSessions.busyWait.
    // It worked, it showed a box that a person can answer, or a list still showed it as active.
    // The round did not start, and Bifrost did not stop the session.
    case sessionBusy
    // Request rounds: an own request file of the user waits in the input folder of the PR. The
    // round does not start: the own request goes first, then the round starts again.
    case ownRequestWaits
    // Request rounds: the worktree has changes that no round made, for example a change that the
    // user asked for in the session with no own request file. The changes stay, and the round
    // does not start. The row shows Needs you (waitsForYou).
    case changesNotOnGitHub

    // True when the row shows the failure as Needs you (PRState.waitsForYou), not as an error:
    // only the user can clear it.
    package var waitsForYou: Bool { self == .changesNotOnGitHub }

    // The text of the failure for a round of the kind. The request rounds have their own texts
    // for the failures that both kinds share.
    package func message(for kind: PRSessionKind) -> String {
        // A conflict round keeps its failures in its mark (ConflictFailure). Only the safety net
        // gives it a reason of the row (Needs you).
        if kind == .conflict, self == .changesNotOnGitHub {
            return "Bifrost's copy of this pull request has changes that aren't on GitHub yet, so "
                + "Bifrost didn't push a merge of the base branch. Ask Claude in its session to "
                + "commit or undo them, then choose Resolve now."
        }
        guard kind == .request else { return message }
        switch self {
        case .stopped:
            return "You stopped Claude, so Bifrost posted nothing. Choose Try again to start "
                + "over."
        case .timeout:
            return "Claude took more than 30 minutes, so Bifrost stopped it and posted nothing."
        case .noResult: return "Claude finished without a result, so Bifrost posted nothing."
        case .badResult(let refusal):
            return "Claude wrote a result Bifrost couldn't use (\(refusal.message)), so Bifrost "
                + "posted nothing."
        case .blocked:
            return "Claude stopped to ask for approval, for example to change a settings, git or "
                + "tool file, and a round can't give it. Bifrost stopped Claude and posted "
                + "nothing. Make that change yourself, or choose Try again."
        case .prepareFailed, .inputFailed:
            return "Bifrost couldn't get this pull request ready for Claude, so it posted "
                + "nothing. Choose Try again."
        case .startFailed:
            return "Bifrost couldn't start Claude's session, so it posted nothing. Choose Try "
                + "again."
        case .closedWhilePosting, .endFailed:
            return "Bifrost couldn't finish this round. Check the pull request on GitHub, then "
                + "choose Try again."
        case .prClosed: return "This pull request was closed, so Bifrost stopped posting."
        default: return message
        }
    }

    package var message: String {
        switch self {
        case .tooLarge:
            "This pull request is too big for a review session. Review it on GitHub."
        case .prChanged:
            "The pull request changed while Bifrost got it ready. Try again."
        case .prClosed:
            "This pull request is closed, so Bifrost didn't review it."
        case .noResult:
            "The review session ended without a result. Nothing was posted. Try again."
        case .stopped:
            "You stopped the review. Nothing was posted."
        case .stoppedAfterEarlierWrites:
            "You stopped the round after Bifrost sent the rest of the earlier updates, so Claude "
                + "didn't start. Choose Try again to start over."
        case .timeout:
            "The review took more than 30 minutes, so Bifrost stopped it. Nothing was posted."
        case .otherCommit:
            "You have a draft review on an older commit of this pull request. Submit or delete "
                + "it on GitHub, then try again."
        case .notPending:
            "GitHub didn't keep the review as a draft. Check the pull request on GitHub now."
        case .closedWhilePosting:
            "Bifrost closed while it saved the draft review. Check the pull request on GitHub."
        case .blocked:
            "The review session stopped to ask for something, so Bifrost stopped it. Nothing "
                + "was posted."
        case .ownDraft:
            "Your draft review from Bifrost is still on GitHub for this commit. Submit or "
                + "delete it there, then try again. Nothing was posted."
        case .readFailed(let error):
            "Bifrost couldn't load this pull request from GitHub, so nothing was posted. "
                + "\(error.message) Try again."
        case .inputFailed:
            "Bifrost couldn't write the files for the review session. Try again."
        case .prepareFailed:
            "Bifrost couldn't get this pull request ready for a review. Nothing was posted. "
                + "Try again."
        case .startFailed:
            "Bifrost couldn't start the review session. Nothing was posted. Try again."
        case .notTrusted:
            "Claude Code doesn't trust Bifrost's copy of this repository yet. Click Trust at "
                + "the top of the panel."
        case .notSaved:
            "Bifrost couldn't save its state, so it posted nothing. Try again."
        case .ciFailing:
            "CI started failing, so Bifrost didn't review this pull request."
        case .draftTooLong:
            "Your draft review text and Claude's summary together are longer than GitHub "
                + "allows (\(ReviewResult.count(ReviewResult.maxReviewBody)) characters). "
                + "Nothing was posted."
        case .summaryTooLong:
            "Claude's summary is longer than GitHub allows "
                + "(\(ReviewResult.count(ReviewResult.maxReviewBody)) characters). Nothing was "
                + "posted."
        case .badResult(let refusal):
            "The review session wrote a result Bifrost couldn't use (\(refusal.message)). "
                + "Nothing was posted. Try again."
        case .postRefused(let line):
            "GitHub didn't accept the draft review: \(Self.sentence(line)) Nothing was posted."
        case .postUnknown(.timedOut):
            "GitHub didn't answer in time, so Bifrost can't tell if your draft review was "
                + "saved. Check the pull request on GitHub."
        case .postUnknown(.badAnswer):
            "Bifrost couldn't read the answer from GitHub, so it can't tell if your draft "
                + "review was saved. Check the pull request on GitHub."
        case .postUnknown(let error):
            "Bifrost can't tell if your draft review was saved: \(error.message) Check the pull "
                + "request on GitHub."
        case .partlyAdded(let added, let total, let line):
            "GitHub stopped after \(added) of \(total) comments: \(Self.sentence(line)) Check "
                + "your draft review on GitHub."
        case .summaryRefused(let line):
            "Bifrost added the comments to your draft review, but GitHub didn't add the "
                + "summary: \(Self.sentence(line)) Check your draft review on GitHub."
        case .tooManyComments:
            "This pull request has too many comments for Bifrost to check, so nothing was "
                + "posted. Reply to them on GitHub."
        case .notYours: "This pull request isn't yours, so Bifrost stopped."
        case .fork: RowText.forkReason
        case .endFailed: "Bifrost couldn't finish the review. Check the pull request on GitHub."
        case .commitRefused(let refusal):
            "Bifrost didn't commit Claude's fix. \(refusal.message) Nothing was posted."
        case .commitFailed:
            "Bifrost couldn't commit Claude's fix, so it posted nothing. The Event log has the "
                + "details."
        case .pushFailed(let refusal): refusal.message
        case .writesStopped(let done, let total, let error):
            "GitHub stopped after \(done) of \(total) updates. \(error.message) Choose Try again "
                + "to send the rest."
        case .writesRefused(let done, let total, let error):
            "GitHub stopped after \(done) of \(total) updates. \(Self.sentence(error.message)) "
                + "Bifrost dropped the rest, so choose Try again to start over."
        case .ownPending:
            "You have a draft review on this pull request, and Bifrost's replies would go into "
                + "it. Submit or delete the draft on GitHub, then choose Try again."
        case .replyPending:
            "A reply went into your draft review on GitHub. Submit or delete the draft, then "
                + "choose Try again."
        case .sessionBusy:
            "Claude's session for this pull request was busy, so Bifrost didn't start the round. "
                + "Choose Try again when it's finished."
        case .ownRequestWaits:
            "Bifrost is sending the change you asked Claude for first, then it starts the round."
        case .changesNotOnGitHub:
            "Bifrost's copy of this pull request has changes that aren't on GitHub yet, so "
                + "Claude didn't start on the new comments. Ask Claude in its session to commit "
                + "or undo them, then choose Handle now."
        }
    }

    // The refusal of GitHub as a sentence, with a general text for an empty line.
    private static func sentence(_ line: String) -> String {
        let text = line.trimmed()
        if text.isEmpty { return "GitHub gave no reason." }
        return text.hasSuffix(".") ? text : text + "."
    }
}
