// The CI question of each way that a CI round stops (docs/behaviour/reviews.md, "My PRs"): the
// text of the Answer panel and the line for the Event log.
import BifrostFoundation
import BifrostTestSupport
import Testing

@testable import BifrostReviews

@Suite("the CI question of a stop", .testTimeLimit)
struct CIStopTests {
    private static let next = " Tell Claude what to try next, or fix it yourself."

    // Each case of the stop has the text that the user chose (2026-11-25), exactly.
    @Test func eachCaseHasItsText() {
        let s = Self.next
        let refusal = ResultRefusal("the reason field is empty")
        let pushed = ", so nothing was pushed." + s
        let unsigned = ", so turn off Sign commits through GitHub or make the change yourself."
        let unknownRerun =
            "Bifrost can't tell whether GitHub re-ran the failed jobs, so check the pull request "
            + "there."
        let expected: [(CIStop, String)] = [
            (
                .limits,
                "Claude has already made two fixes and Bifrost has re-run the failed jobs once for "
                    + "this commit, but CI is still failing." + s
            ),
            (.session(.stopped), "You stopped Claude" + pushed),
            (
                .session(.timeout),
                "Claude spent over 30 minutes on the failed checks, so Bifrost stopped it before "
                    + "anything was pushed." + s
            ),
            (.session(.noResult), "Claude finished without a result" + pushed),
            (
                .session(.badResult(refusal)),
                "Claude wrote a result Bifrost couldn't use (the reason field is empty)" + pushed
            ),
            (
                .session(.blocked),
                "Claude stopped to ask for approval, for example to change a settings, git or "
                    + "tool file, so Bifrost stopped it before anything was pushed." + s
            ),
            (
                .session(.sessionBusy),
                "Claude's session for this pull request was busy, so Bifrost didn't start on the "
                    + "failed checks." + s
            ),
            (
                .session(.readFailed(.timedOut)),
                "Bifrost couldn't read the failed checks from GitHub (GitHub didn't answer in "
                    + "time)." + s
            ),
            (
                .session(.readFailed(.unknownOutcome("connection reset"))),
                "Bifrost couldn't read the failed checks from GitHub (GitHub CLI (gh): connection "
                    + "reset)." + s
            ),
            (
                .session(.sessionEnded),
                "The session ended partway through, so Bifrost didn't push anything. Give Claude "
                    + "a hint and it'll try again, or handle it yourself."
            ),
            (
                .session(.prepareFailed),
                "Bifrost couldn't get Claude started on the failed checks." + s
            ),
            (
                .session(.notSaved),
                "Bifrost couldn't get Claude started on the failed checks." + s
            ),
            (
                .commit(.refused(.workflow)),
                "Bifrost didn't commit Claude's fix: Bifrost won't commit a GitHub workflow or "
                    + "action." + s
            ),
            (
                .commit(.git("fatal: no index")),
                "Bifrost couldn't commit Claude's fix, the Event log has the details." + s
            ),
            (
                .commit(.uncommitFailed),
                "Bifrost couldn't commit Claude's fix, the Event log has the details." + s
            ),
            (
                .push(.refused("hook declined")),
                "GitHub didn't accept Claude's fix, so the branch may be protected - the Event log "
                    + "has GitHub's reason." + s
            ),
            (
                .push(.workflowScope("refusing to allow an OAuth App without `workflow` scope")),
                "GitHub refused Claude's fix because it changes a workflow file and your GitHub "
                    + "login can't push workflow changes, so run gh auth refresh -h github.com -s "
                    + "workflow in a terminal." + s
            ),
            (
                .push(.git("fatal: unable to access")),
                "Bifrost couldn't push Claude's fix, the Event log has the details." + s
            ),
            (
                .push(.conflict),
                "Bifrost couldn't push Claude's fix, the Event log has the details." + s
            ),
            (
                .push(.unknown("")),
                "Bifrost can't tell whether Claude's fix reached GitHub, so check the pull request "
                    + "there." + s
            ),
            (.push(.target), "Bifrost won't push to this branch." + s),
            (.push(.fork), "Bifrost won't push to this branch." + s),
            (.push(.deleted(madeAgain: true)), "This branch has been deleted from GitHub." + s),
            (.push(.deleted(madeAgain: false)), "This branch has been deleted from GitHub." + s),
            (
                .push(.tooLarge),
                "Claude's fix is over 4 MB, which is too large for a commit that GitHub signs"
                    + unsigned
            ),
            (
                .push(.fileMode),
                "Claude's fix changes a link or an executable file, which a commit that GitHub "
                    + "signs can't keep" + unsigned
            ),
            (.push(.moved), ""),
            (.push(.rewritten), ""),
            (.rerun(.timedOut), unknownRerun),
            (.rerun(.unknownOutcome("Bad gateway")), unknownRerun),
            (.rerun(.badAnswer), unknownRerun),
            (CIStop.unknownRerun, unknownRerun),
            (
                .rerun(.refused("This workflow run is not done")),
                "GitHub didn't re-run the failed jobs: This workflow run is not done." + s
            ),
            (
                .rerun(.refused("The run is too old.")),
                "GitHub didn't re-run the failed jobs: The run is too old." + s
            ),
            (
                .rerun(.refused("  ")),
                "GitHub didn't re-run the failed jobs: GitHub gave no reason." + s
            ),
            (
                .rerun(.notLoggedIn),
                "GitHub didn't re-run the failed jobs: GitHub CLI (gh) isn't logged in. Run gh "
                    + "auth login -s workflow in a terminal, then click Refresh." + s
            ),
        ]
        for (stop, text) in expected {
            #expect(stop.question == text, "\(stop)")
        }
    }

    // The line of git or of GitHub goes to the Event log, never to the question.
    @Test func theDetailIsTheLineOfGitOrOfGitHub() {
        #expect(CIStop.push(.refused("hook declined")).detail == "hook declined")
        #expect(CIStop.push(.git("fatal: unable to access")).detail == "fatal: unable to access")
        #expect(CIStop.push(.workflowScope("no workflow scope")).detail == "no workflow scope")
        #expect(CIStop.push(.unknown("")).detail == nil)
        #expect(CIStop.push(.moved).detail == nil)
        #expect(CIStop.commit(.git("fatal: no index")).detail == "fatal: no index")
        #expect(CIStop.commit(.git("")).detail == nil)
        #expect(CIStop.commit(.refused(.workflow)).detail == nil)
        #expect(CIStop.rerun(.refused("The run is too old.")).detail == "The run is too old.")
        #expect(CIStop.rerun(.timedOut).detail == GitHubError.timedOut.message)
        #expect(CIStop.rerun(.refused("")).detail == GitHubError.refused("").message)
        #expect(CIStop.rerun(.unknownOutcome("Bad gateway")).detail == "Bad gateway")
        #expect(CIStop.limits.detail == nil && CIStop.session(.stopped).detail == nil)
        for stop in [CIStop.push(.refused("hook declined")), .commit(.git("fatal: no index"))] {
            #expect(!stop.question.contains("hook") && !stop.question.contains("fatal"))
        }
    }

    // The Event log lines: a stop with a line of git or of GitHub gives its line, and a stop
    // whose question no row can show gives the question. A quiet end gives none.
    @Test func theEventLinesHaveTheirTexts() throws {
        let pr = try #require(PRKey(text: "Owner-A/Repo-A#7"))
        #expect(
            CIStop.commit(.git("fatal: no index")).eventLine(for: pr)
                == "Reviews: Bifrost couldn't commit Claude's CI fix on Owner-A/Repo-A#7: fatal: "
                + "no index")
        #expect(
            CIStop.rerun(.refused("The run is too old.")).eventLine(for: pr)
                == "Reviews: Bifrost couldn't re-run the failed jobs of Owner-A/Repo-A#7: The run "
                + "is too old.")
        #expect(
            CIStop.push(.refused("hook declined")).eventLine(for: pr)
                == "Reviews: Bifrost couldn't push Claude's CI fix to Owner-A/Repo-A#7: hook "
                + "declined")
        #expect(CIStop.push(.moved).eventLine(for: pr) == nil)
        #expect(CIStop.limits.eventLine(for: pr) == nil)
        #expect(
            CIStop.session(.noResult).unshownLine(for: pr)
                == "Reviews: Bifrost couldn't fix the failing CI of Owner-A/Repo-A#7 - Claude "
                + "finished without a result, so nothing was pushed." + Self.next)
        #expect(CIStop.push(.moved).unshownLine(for: pr) == nil)
    }
}
