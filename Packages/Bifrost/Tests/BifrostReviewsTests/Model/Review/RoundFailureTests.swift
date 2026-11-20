// The texts of a failed review round or request round (docs/behaviour/reviews.md, "Review
// rounds" and "Request rounds").
import BifrostTestSupport
import Testing

@testable import BifrostReviews

@Suite("the texts of a failed round", .testTimeLimit)
struct RoundFailureTests {
    // A write that GitHub may have saved never asks for Try again and never says that nothing
    // was posted: Bifrost never sends it again by itself.
    @Test func aWriteThatMayHaveHappenedSendsTheUserToGitHub() {
        let unknown: [RoundFailure] = [
            .postUnknown(.timedOut), .postUnknown(.badAnswer), .postUnknown(.unknownOutcome("")),
            .closedWhilePosting, .notPending, .partlyAdded(added: 1, total: 3, "Bad."),
            .summaryRefused("Bad."),
        ]
        for failure in unknown {
            #expect(!failure.message.contains("Try again"), "\(failure)")
            #expect(!failure.message.contains("Nothing was posted"), "\(failure)")
            #expect(failure.message.contains("GitHub"), "\(failure)")
        }
    }

    // A refusal of the first write says that nothing was posted, with the reason of GitHub.
    @Test func aRefusedWriteSaysNothingWasPosted() {
        #expect(
            RoundFailure.postRefused("Validation Failed").message
                == "GitHub didn't accept the draft review: Validation Failed. Nothing was posted.")
        #expect(RoundFailure.badResult(ResultRefusal("the why field is empty")).message.contains(
            "(the why field is empty)"))
    }

    // A request round has its own texts for the failures that both kinds share: each one says
    // that Bifrost posted nothing, and names Claude rather than a review. The texts of a review
    // round stay.
    @Test func aRequestRoundHasItsOwnTexts() {
        let shared: [RoundFailure] = [
            .stopped, .timeout, .noResult, .badResult(ResultRefusal("a missing item")), .blocked,
            .prepareFailed, .inputFailed, .startFailed,
        ]
        for failure in shared {
            let text = failure.message(for: .request)
            #expect(text != failure.message, "\(failure)")
            #expect(text.contains("posted nothing"), "\(failure)")
            #expect(!text.contains("review"), "\(failure)")
            #expect(failure.message(for: .review) == failure.message)
        }
        #expect(
            RoundFailure.badResult(ResultRefusal("a missing item")).message(for: .request)
                == "Claude wrote a result Bifrost couldn't use (a missing item), so Bifrost "
                + "posted nothing.")
        // A request session that asks for approval (a write to a settings, git or tool file
        // under --restricted) gets a reason that says so.
        #expect(RoundFailure.blocked.message(for: .request).contains("approval"))
        #expect(RoundFailure.fork.message == RowText.forkReason)
        // The session of the PR was busy for busyWait: the round did not start.
        #expect(
            RoundFailure.sessionBusy.message(for: .request)
                == "Claude's session for this pull request was busy, so Bifrost didn't start the "
                + "round. Choose Try again when it's finished.")
        #expect(!RoundFailure.endFailed.message(for: .request).contains("Nothing was posted"))
    }

    // A conflict round keeps its failures in its mark (ConflictFailure). Only the safety net gives
    // it a reason of the row, which sends the user to Resolve now, not to Handle now.
    @Test func aConflictRoundHasTheTextOfTheSafetyNet() {
        #expect(
            RoundFailure.changesNotOnGitHub.message(for: .conflict)
                == "Bifrost's copy of this pull request has changes that aren't on GitHub yet, "
                + "so Bifrost didn't push a merge of the base branch. Ask Claude in its session "
                + "to commit or undo them, then choose Resolve now.")
        #expect(RoundFailure.stopped.message(for: .conflict) == RoundFailure.stopped.message)
    }

    // The writes of a request round: a refusal before any write says that nothing was posted,
    // writes that stopped give the count and send the user to Try again, and a push that may
    // have landed never says that nothing was posted.
    @Test func theWritesOfARequestRoundSayWhatWent() {
        #expect(
            RoundFailure.commitRefused(.workflow).message(for: .request)
                == "Bifrost didn't commit Claude's fix. Bifrost won't commit a GitHub workflow or "
                + "action. Nothing was posted.")
        #expect(
            RoundFailure.writesStopped(done: 2, total: 5, .timedOut).message(for: .request)
                == "GitHub stopped after 2 of 5 updates. GitHub didn't answer in time. Choose Try "
                + "again to send the rest.")
        // A refusal that comes again in each run drops the rest, so Try again starts over.
        #expect(
            RoundFailure.writesRefused(done: 1, total: 3, .refused("Not allowed"))
                .message(for: .request)
                == "GitHub stopped after 1 of 3 updates. GitHub refused the request: Not allowed. "
                + "Bifrost dropped the rest, so choose Try again to start over.")
        #expect(PushRefusal.refused("").message.contains("protected"))
        // A stop of the user after the earlier writes says that they went.
        let stopped = RoundFailure.stoppedAfterEarlierWrites.message(for: .request)
        #expect(stopped.contains("sent the rest of the earlier updates"))
        #expect(!stopped.contains("posted nothing") && !stopped.contains("Nothing was posted"))
        for refusal in [PushRefusal.target, .fork, .tooLarge, .fileMode, .refused(""), .git("")] {
            #expect(RoundFailure.pushFailed(refusal).message.lowercased().contains("nothing"))
        }
        for refusal in [PushRefusal.conflict, .rewritten, .moved] {
            #expect(refusal.message.contains("posted the other replies"), "\(refusal)")
        }
        #expect(!PushRefusal.unknown("").message.lowercased().contains("nothing"))
        #expect(PushRefusal.unknown("line").detail == "line" && PushRefusal.target.detail == nil)
    }
}
