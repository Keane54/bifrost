// Why a CI round ended with no fix, no re-run and no question of Claude (docs/behaviour/
// reviews.md, "My PRs"). A CI round never writes lastError: each stop becomes the CI question of
// the PR for the Answer panel, so the user can tell Claude what to try next. The question names
// no path and holds no text of git: detail gives the line of git or of GitHub for the Event log.
// An empty question is a quiet end (a branch that moved or that someone rewrote: the new head is
// a new chain). A re-run that GitHub may have made has no text that asks for a new try, because
// Bifrost never sends it again.
import BifrostFoundation

package enum CIStop: Error, Sendable, Equatable {
    // The chain has no fix and no re-run left (CIRule.step).
    case limits
    // The session of the round failed, or a step before or after it.
    case session(RoundFailure)
    // The fix commit did not go.
    case commit(FixCommitFailure)
    // The push of the fix did not go, or Bifrost can't tell.
    case push(PushRefusal)
    // A re-run write of the failed jobs failed.
    case rerun(GitHubError)

    // The stop of a re-run that GitHub may have made, with no line (for example, Bifrost quit
    // during the writes).
    package static let unknownRerun = CIStop.rerun(.unknownOutcome(""))

    // The text of the CI question, or "" for a quiet end.
    package var question: String {
        let next = " Tell Claude what to try next, or fix it yourself."
        switch self {
        case .limits:
            return "Claude has already made two fixes and Bifrost has re-run the failed jobs once "
                + "for this commit, but CI is still failing." + next
        case .session(let failure): return Self.question(failure, next)
        case .commit(.refused(let refusal)):
            return "Bifrost didn't commit Claude's fix: \(refusal.message)" + next
        case .commit(.git), .commit(.uncommitFailed):
            return "Bifrost couldn't commit Claude's fix, the Event log has the details." + next
        case .push(let refusal): return Self.question(refusal, next)
        case .rerun(let error) where error.writeMayHaveHappened:
            return "Bifrost can't tell whether GitHub re-ran the failed jobs, so check the pull "
                + "request there."
        case .rerun(let error):
            let line: String
            if case .refused(let text) = error { line = text } else { line = error.message }
            return "GitHub didn't re-run the failed jobs: \(Self.sentence(line))" + next
        }
    }

    // The line for the Event log: the line of a push refusal, of a failed git of the commit, or
    // of a failed re-run write (the line of GitHub or of gh, else the text of the error). Else
    // nil.
    package var detail: String? {
        switch self {
        case .push(let refusal): refusal.detail
        case .commit(.git(let line)): line.isEmpty ? nil : line
        case .rerun(let error): Self.line(error)
        default: nil
        }
    }

    // The Event log line of the stop on the PR with its detail, or nil when the stop has no
    // detail.
    package func eventLine(for pr: PRKey) -> String? {
        guard let detail else { return nil }
        let start =
            switch self {
            case .commit: "Bifrost couldn't commit Claude's CI fix on \(pr.text)"
            case .rerun: "Bifrost couldn't re-run the failed jobs of \(pr.text)"
            case .push, .limits, .session: "Bifrost couldn't push Claude's CI fix to \(pr.text)"
            }
        return "Reviews: \(start): \(detail)"
    }

    // The Event log line of a stop whose question no row can show (the round has no head), or
    // nil for a quiet end.
    package func unshownLine(for pr: PRKey) -> String? {
        let text = question
        guard !text.isEmpty else { return nil }
        return "Reviews: Bifrost couldn't fix the failing CI of \(pr.text) - \(text)"
    }

    // The line of GitHub or of gh in the error, else the text of the error.
    private static func line(_ error: GitHubError) -> String {
        switch error {
        case .refused(let line) where !line.isEmpty: line
        case .unknownOutcome(let line) where !line.isEmpty: line
        default: error.message
        }
    }

    private static func question(_ failure: RoundFailure, _ next: String) -> String {
        switch failure {
        case .stopped: "You stopped Claude, so nothing was pushed." + next
        case .timeout:
            "Claude spent over 30 minutes on the failed checks, so Bifrost stopped it before "
                + "anything was pushed." + next
        case .noResult: "Claude finished without a result, so nothing was pushed." + next
        case .badResult(let refusal):
            "Claude wrote a result Bifrost couldn't use (\(refusal.message)), so nothing was "
                + "pushed." + next
        case .blocked:
            "Claude stopped to ask for approval, for example to change a settings, git or tool "
                + "file, so Bifrost stopped it before anything was pushed." + next
        case .sessionBusy:
            "Claude's session for this pull request was busy, so Bifrost didn't start on the "
                + "failed checks." + next
        case .readFailed(let error):
            "Bifrost couldn't read the failed checks from GitHub (\(Self.clause(error.message)))."
                + next
        case .sessionEnded:
            "The session ended partway through, so Bifrost didn't push anything. Give Claude a "
                + "hint and it'll try again, or handle it yourself."
        default: "Bifrost couldn't get Claude started on the failed checks." + next
        }
    }

    private static func question(_ refusal: PushRefusal, _ next: String) -> String {
        let unsigned = ", so turn off Sign commits through GitHub or make the change yourself."
        return switch refusal {
        case .moved, .rewritten: ""
        case .refused:
            "GitHub didn't accept Claude's fix, so the branch may be protected - the Event log has "
                + "GitHub's reason." + next
        case .workflowScope:
            "GitHub refused Claude's fix because it changes a workflow file and your GitHub login "
                + "can't push workflow changes, so run \(PushRefusal.refreshCommand) in a terminal."
                + next
        case .git, .conflict:
            "Bifrost couldn't push Claude's fix, the Event log has the details." + next
        case .unknown:
            "Bifrost can't tell whether Claude's fix reached GitHub, so check the pull request "
                + "there." + next
        case .target, .fork: "Bifrost won't push to this branch." + next
        case .deleted: "This branch has been deleted from GitHub." + next
        case .tooLarge:
            "Claude's fix is over 4 MB, which is too large for a commit that GitHub signs"
                + unsigned
        case .fileMode:
            "Claude's fix changes a link or an executable file, which a commit that GitHub signs "
                + "can't keep" + unsigned
        }
    }

    // The line of GitHub as a sentence that ends in a full stop, with a general text for an empty
    // line.
    private static func sentence(_ line: String) -> String {
        let text = line.trimmed()
        if text.isEmpty { return "GitHub gave no reason." }
        return text.hasSuffix(".") ? text : text + "."
    }

    // The text with no full stop at its end, for a text in parentheses in a sentence.
    private static func clause(_ text: String) -> String {
        text.hasSuffix(".") ? String(text.dropLast()) : text
    }
}
