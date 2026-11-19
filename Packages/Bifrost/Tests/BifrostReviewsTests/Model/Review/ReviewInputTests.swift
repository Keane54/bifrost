// The input file of a review round (docs/behaviour/reviews.md, "Review rounds", and
// skills/bifrost-review/bifrost-mode.md, "The input file").
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private typealias D = ReviewData

@Suite("the input file of a review round", .testTimeLimit)
struct ReviewInputTests {
    private func context(threads: [ViewerThread] = []) throws -> ReviewContext {
        var context = ReviewContext(
            pr: try D.pr(), url: "https://github.com/Owner-A/Repo-A/pull/7", title: "Retry",
            body: "This adds a retry.", author: "user-d", baseRef: "main", headRef: "feat/retry",
            headSHA: try D.commit())
        context.reviews = [
            ViewerReview(
                state: .changesRequested, body: "Please add a test.",
                submittedAt: Date(timeIntervalSince1970: 1_794_312_000),
                url: "https://github.com/Owner-A/Repo-A/pull/7#pullrequestreview-3",
                commit: try D.commit(D.oldHex)),
            ViewerReview(state: .commented, body: "  ", commit: try D.commit(D.oldHex)),
        ]
        context.threads = threads
        return context
    }

    // A re-review names the commit of the last review and the diff since it, and lists the
    // earlier threads and summaries of the user. A missing value is null.
    @Test func aReReviewHoldsTheBaselineAndTheEarlierPoints() throws {
        let thread = ViewerThread(
            path: "src/a.swift", line: nil, isResolved: true, isOutdated: false,
            url: "https://github.com/Owner-A/Repo-A/pull/7#discussion_r1",
            comments: [ViewerThread.Comment(author: "user-v", body: "Why?")])
        let folder = URL(filePath: "/io/7", directoryHint: .isDirectory)
        let input = ReviewInput(
            context: try context(threads: [thread]), round: "t-1", viewer: "user-v",
            baseSHA: try D.commit(D.baseHex), mergeBase: try D.commit(D.baseHex),
            baseline: Baseline(kind: .reReview, since: try D.commit(D.oldHex)),
            files: ReviewInput.Files(folder: folder, reReview: true), diff: D.diff)
        let json = input.json
        #expect(json.object?["version"] == 1)
        #expect(json.object?["round"] == "t-1")
        #expect(json.object?["viewer"] == "user-v")
        let pr = try #require(json.object?["pr"]?.object)
        #expect(pr["key"] == "Owner-A/Repo-A#7")
        #expect(pr["headSha"] == .string(D.headHex))
        #expect(pr["mergeBase"] == .string(D.baseHex))
        let review = try #require(json.object?["review"]?.object)
        #expect(review["kind"] == "re-review")
        #expect(review["since"] == .string(D.oldHex))
        #expect(review["note"] == .null)
        #expect(
            review["lastReview"]?.object?["submittedAt"] == "2026-11-10T12:00:00.000Z")
        #expect(json.object?["changedFiles"] == ["src/a.swift", "img/logo.png"])
        let earlier = try #require(json.object?["earlier"]?.object)
        #expect(earlier["threads"]?.array?.first?.object?["line"] == .null)
        // Only a real review with text is an earlier summary.
        #expect(earlier["summaries"]?.array?.count == 1)
        let files = try #require(json.object?["files"]?.object)
        #expect(files["sinceDiff"] == "/io/7/since.diff")
        #expect(files["result"] == "/io/7/result.json")
        #expect(input.files.input.path(percentEncoded: false) == "/io/7/input.json")
    }

    // A first review lists no earlier points and has no diff since a baseline.
    @Test func aFirstReviewHasNoEarlierPoints() throws {
        let input = ReviewInput(
            context: try context(), round: nil, viewer: "user-v",
            baseSHA: try D.commit(D.baseHex),
            mergeBase: try D.commit(D.baseHex), baseline: Baseline(kind: .first),
            files: ReviewInput.Files(
                folder: URL(filePath: "/io/7", directoryHint: .isDirectory), reReview: false),
            diff: D.diff)
        let earlier = try #require(input.json.object?["earlier"]?.object)
        #expect(earlier["threads"] == [])
        #expect(earlier["summaries"] == [])
        #expect(input.json.object?["files"]?.object?["sinceDiff"] == .null)
        #expect(input.json.object?["review"]?.object?["since"] == .null)
    }

    // A long text is cut at a whole character, with the marker of the mode file.
    @Test func aLongTextIsCutWithTheMarker() {
        #expect(ReviewInput.cut("short", 10) == "short")
        let cut = ReviewInput.cut("ab\u{1F600}cd", 3)
        #expect(cut == "ab" + ReviewInput.cutMarker)
    }
}
