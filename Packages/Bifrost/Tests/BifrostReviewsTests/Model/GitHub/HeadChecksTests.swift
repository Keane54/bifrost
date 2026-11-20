// The checks of the head commit (docs/behaviour/reviews.md, "The GitHub data"): when they are
// settled, and which failures a CI round can act on.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private func job(_ name: String, _ id: Int, _ outcome: CheckOutcome) throws -> HeadCheck {
    HeadCheck(
        name: name, outcome: outcome,
        source: .actions(job: try #require(JobID(id)), run: try #require(RunID(9001))))
}

@Suite("the head checks", .testTimeLimit)
struct HeadChecksTests {
    @Test func settledNeedsEveryCheckDoneAFullPageAndTheHead() throws {
        let done = [
            try job("build", 1, .passed), try job("test", 2, .failed("FAILURE")),
            HeadCheck(name: "ci/legacy", outcome: .other, source: .status),
        ]
        #expect(HeadChecks(checks: done, cut: false, onHead: true).settled)
        // No checks on the head is settled too.
        #expect(HeadChecks(checks: [], cut: false, onHead: true).settled)

        let running = done + [HeadCheck(name: "lint", outcome: .running, source: .app("app-a"))]
        #expect(!HeadChecks(checks: running, cut: false, onHead: true).settled)
        #expect(!HeadChecks(checks: done, cut: true, onHead: true).settled)
        #expect(!HeadChecks(checks: done, cut: false, onHead: false).settled)
    }

    @Test func theFailedJobsAreTheActionsFailuresInTheOrderOfTheirIDs() throws {
        let checks = HeadChecks(
            checks: [
                try job("test", 30, .failed("TIMED_OUT")), try job("build", 10, .failed("FAILURE")),
                try job("deploy", 20, .failed("CANCELLED")), try job("lint", 5, .passed),
                try job("setup", 40, .failed("STARTUP_FAILURE")),
                try job("test again", 30, .failed("FAILURE")),
                HeadCheck(name: "preview", outcome: .failed("FAILURE"), source: .app("app-a")),
                HeadCheck(name: "ci/legacy", outcome: .failed("ERROR"), source: .status),
                HeadCheck(name: "docs", outcome: .running, source: .status),
            ],
            cut: false, onHead: true)
        #expect(checks.failedJobs.map(\.name) == ["build", "test", "setup"])
        #expect(checks.jobKey == [10, 30, 40].compactMap(JobID.init))
        // A failure of another app or of a status is shown only. A cancelled job is neither.
        #expect(checks.others.map(\.name) == ["preview", "ci/legacy"])
    }
}
