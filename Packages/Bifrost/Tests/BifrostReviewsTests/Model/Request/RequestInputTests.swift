// The input file of a request round (docs/behaviour/reviews.md, "Request rounds"): the PR, the
// items with their comments and the trust of each, the questions and the answers, and the files.
import BifrostFoundation
import Foundation
import Testing

@testable import BifrostReviews

@Suite("the input file of a request round")
struct RequestInputTests {
    static func input(fullDiff: Bool = true) throws -> RequestInput {
        let member = Rows.person("user-b")
        let thread = try Rows.thread(
            "PRRT_1", by: member, at: Rows.at(-120),
            replies: [
                try Rows.comment("c2", by: Rows.person("Viewer-A", .owner), at: Rows.at(-110)),
                try Rows.comment("c3", by: Rows.person("user-o", .none), at: Rows.at(-100)),
            ])
        let full = FullPR(
            key: try Rows.key("Owner-A/Repo-A#7"), url: "https://github.com/Owner-A/Repo-A/pull/7",
            title: "Add the cache", body: "The body.", author: Rows.viewer, headRef: "feat",
            headSHA: try Rows.commit("c"),
            threads: [
                FullThread(
                    thread: thread, isOutdated: true,
                    diffHunk: "@@ -1 +1 @@\n" + String(repeating: "h", count: 3_100),
                    viewerCanReply: true)
            ],
            comments: [
                try Rows.comment(
                    "IC_2", by: member, at: Rows.at(-60),
                    body: String(repeating: "x", count: 10_050))
            ],
            reviews: [
                try Rows.review(
                    "PRR_3", by: Rows.copilot, .commented, at: Rows.at(-90), body: "A summary.")
            ])
        let items = [
            WorkItem(id: try Rows.node("PRRT_1"), kind: .thread, since: Rows.at(-120)),
            WorkItem(id: try Rows.node("PRR_3"), kind: .reviewBody, since: Rows.at(-90)),
            WorkItem(id: try Rows.node("IC_2"), kind: .comment, since: Rows.at(-60)),
            WorkItem(id: try Rows.node("IC_gone"), kind: .comment, since: Rows.at(-50)),
        ]
        let questions = [
            try Rows.node("PRRT_1"): Question(
                text: "Keep the old name?", place: "src/a.swift line 4", at: Rows.at(-30),
                answer: "Yes, keep it.", seenUntil: Rows.at(-100))
        ]
        return RequestInput(
            full: full, items: items, questions: questions, round: "token-1",
            viewer: Rows.viewer, baseSHA: try Rows.commit("a"), headSHA: try Rows.commit("c"),
            mergeBase: try Rows.commit("b"),
            files: RequestInput.Files(
                folder: URL(filePath: "/tmp/io/7", directoryHint: .isDirectory),
                fullDiff: fullDiff))
    }

    // The file has the token of the round, the PR, and each item that the read has, in order.
    // Each comment says whether its author is trusted and whether it is the user's own (the case
    // of the login does not count); a question carries its answer.
    @Test func theFileHasTheItemsWithTheirTrustAndTheToken() throws {
        let input = try Self.input()
        let json = try #require(input.json.object)
        #expect(json["version"] == 1 && json["round"] == "token-1")
        #expect(json["viewer"] == .string(Rows.viewer))
        let pr = try #require(json["pr"]?.object)
        #expect(pr["key"] == "Owner-A/Repo-A#7" && pr["headRef"] == "feat")
        #expect(pr["headSha"] == .string(String(repeating: "c", count: 40)))
        #expect(pr["mergeBase"] == .string(String(repeating: "b", count: 40)))
        let items = try #require(json["items"]?.array?.compactMap { $0.object })
        #expect(items.map { $0["id"] } == ["PRRT_1", "PRR_3", "IC_2"])
        #expect(input.itemIDs.map(\.text) == ["PRRT_1", "PRR_3", "IC_2"])
        let thread = items[0]
        #expect(thread["kind"] == "thread" && thread["path"] == "src/a.swift")
        #expect(thread["line"] == 4 && thread["outdated"] == true)
        #expect(thread["question"] == "Keep the old name?" && thread["answer"] == "Yes, keep it.")
        let comments = try #require(thread["comments"]?.array?.compactMap { $0.object })
        #expect(comments.map { $0["trusted"] } == [true, false, false])
        #expect(comments.map { $0["you"] } == [false, true, false])
        #expect(comments.first?["association"] == "MEMBER")
        #expect(comments.first?["at"] == "2026-11-10T10:00:00.000Z")
        // The Copilot summary that a round still lists is trusted; a top-level comment has no
        // place.
        let review = items[1]
        #expect(review["kind"] == "review-body" && review["path"] == .null)
        #expect(review["comments"]?.array?.first?.object?["trusted"] == true)
        #expect(items[2]["kind"] == "comment" && items[2]["question"] == .null)
        let files = try #require(json["files"]?.object)
        #expect(files["result"] == "/tmp/io/7/result.json" && files["mode"] == "/tmp/io/7/mode.md")
        #expect(files["fullDiff"] == "/tmp/io/7/full.diff")
        #expect(input.files.input.path(percentEncoded: false) == "/tmp/io/7/input.json")
        #expect(try Self.input(fullDiff: false).json.object?["files"]?.object?["fullDiff"] == .null)
        #expect(input.fileData.last == UInt8(ascii: "\n"))
    }

    // The input of a round in the round folder of a PR names the files of that round: each name
    // has the round ID, also the name of the input file itself.
    @Test func theInputNamesTheFilesOfItsRound() throws {
        let token = "0f8a2c1e-5b7d-4c3a-9e21-6d4b8f0a1c2e"
        let round = RoundFiles(
            folder: URL(filePath: "/tmp/io/7", directoryHint: .isDirectory), token: token)
        let files = RequestInput.Files(round, fullDiff: true)
        #expect(files.input == round.input && files.result == round.result)
        let input = RequestInput(
            resumed: try Rows.key("Owner-A/Repo-A#7"), round: token,
            headSHA: try Rows.commit("c"), mergeBase: try Rows.commit("b"), itemIDs: [],
            files: files)
        let json = try #require(input.json.object?["files"]?.object)
        #expect(json["result"] == "/tmp/io/7/result-0f8a2c1e5b7d.json")
        #expect(json["mode"] == "/tmp/io/7/mode-0f8a2c1e5b7d.md")
        #expect(json["rules"] == "/tmp/io/7/rules-0f8a2c1e5b7d.md")
        #expect(json["fullDiff"] == "/tmp/io/7/full-0f8a2c1e5b7d.diff")
        #expect(files.input.path(percentEncoded: false) == "/tmp/io/7/input-0f8a2c1e5b7d.json")
        // The own request file has one path for each PR, with no round ID.
        #expect(json["ownRequest"] == "/tmp/io/7/own-request.json")
        #expect(RequestInput.Files(round, fullDiff: false).fullDiff == nil)
    }

    // A long comment and a long diff hunk are cut, with the marker after the kept text.
    @Test func aLongTextIsCut() throws {
        let input = try Self.input()
        let thread = try #require(input.items.first)
        #expect(thread.diffHunk?.hasSuffix(ReviewInput.cutMarker) == true)
        #expect(thread.diffHunk?.utf16.count == 3_000 + ReviewInput.cutMarker.utf16.count)
        let comment = try #require(input.items.last?.comments.first?.body)
        #expect(comment.utf16.count == 10_000 + ReviewInput.cutMarker.utf16.count)
    }
}
