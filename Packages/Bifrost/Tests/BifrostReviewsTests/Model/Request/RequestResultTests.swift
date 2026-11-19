// The strict check of the result file of a request round (docs/behaviour/reviews.md, "Request
// rounds"): one good file and one bad file per rule. A refusal names a field or a limit only.
import BifrostFoundation
import Foundation
import Testing

@testable import BifrostReviews

enum RequestData {
    static let token = "0f8a2c1e-5b7d-4c3a-9e21-6d4b8f0a1c2e"
    static let ids = ["PRRT_1", "IC_2", "PRR_3", "PRRT_4"]

    // The input of a round with four items at the head of ReviewData.
    static func input() throws -> RequestInput {
        RequestInput(
            resumed: try ReviewData.pr(), round: token, headSHA: try ReviewData.commit(),
            mergeBase: try ReviewData.commit(ReviewData.baseHex),
            itemIDs: try ids.map(ReviewData.node),
            files: RequestInput.Files(
                folder: URL(filePath: "/tmp/io/7", directoryHint: .isDirectory), fullDiff: true))
    }

    // A good result: a fix, a reply, no action and a question, with the commit of the fix.
    static func result(_ change: (inout [String: JSONValue]) -> Void = { _ in }) -> Data {
        var fields: [String: JSONValue] = [
            "version": 1, "pr": "Owner-A/Repo-A#7", "headSha": .string(ReviewData.headHex),
            "round": .string(token),
            "items": [
                ["id": "PRRT_1", "outcome": "fixed"],
                [
                    "id": "IC_2", "outcome": "no-fix",
                    "reply": "The README covers this.\n\tSee it.",
                ],
                ["id": "PRR_3", "outcome": "no-action"],
                ["id": "PRRT_4", "outcome": "needs-you", "question": "Keep the old name?"],
            ],
            "commit": [
                "message": "fix: check the upper limit\n\nThe body.", "paths": ["src/a.swift"],
            ],
            "checks": "passed",
        ]
        change(&fields)
        return ReviewData.json(.object(fields))
    }

    // A change of the item at the index.
    static func item(
        _ fields: inout [String: JSONValue], _ index: Int,
        _ change: (inout [String: JSONValue]) -> Void
    ) {
        var items = fields["items"]?.array ?? []
        var item = items[index].object ?? [:]
        change(&item)
        items[index] = .object(item)
        fields["items"] = .array(items)
    }

    // A change of the commit object.
    static func commit(
        _ fields: inout [String: JSONValue], _ change: (inout [String: JSONValue]) -> Void
    ) {
        var commit = fields["commit"]?.object ?? [:]
        change(&commit)
        fields["commit"] = .object(commit)
    }
}

// One bad file and the refusal that it gets.
struct BadResult: Sendable, CustomTestStringConvertible {
    let refusal: String
    let data: Data
    var changed: Set<String>? = nil
    var testDescription: String { refusal }

    init(
        _ refusal: String, changed: Set<String>? = nil,
        _ change: (inout [String: JSONValue]) -> Void
    ) {
        self.refusal = refusal
        self.changed = changed
        data = RequestData.result(change)
    }

    init(_ refusal: String, data: Data) {
        self.refusal = refusal
        self.data = data
    }

    static let all: [BadResult] = [
        BadResult(
            "the result is larger than 1,048,576 bytes",
            data: Data(repeating: 0x20, count: 1_048_577)),
        BadResult("the result is not valid JSON", data: Data("{\"version\": 1".utf8)),
        BadResult("the result is not a JSON object", data: Data("[1]".utf8)),
        BadResult("an unknown field") { $0["note"] = "hi" },
        BadResult("the checks field is missing") { $0["checks"] = nil },
        BadResult("the round field is missing") { $0["round"] = nil },
        BadResult("the version field is not 1") { $0["version"] = 2 },
        BadResult("the pr field is not this pull request") { $0["pr"] = "Owner-A/Repo-A#8" },
        BadResult("the headSha field is not the head commit of the round") {
            $0["headSha"] = .string(ReviewData.oldHex)
        },
        BadResult("the round field is not this request round") { $0["round"] = "other" },
        BadResult("the items field is not a list") { $0["items"] = "all" },
        BadResult("item 1 is not a JSON object") { $0["items"] = ["x"] },
        BadResult("an unknown field") { RequestData.item(&$0, 0) { $0["note"] = "x" } },
        BadResult("item 1 has no id field") { RequestData.item(&$0, 0) { $0["id"] = nil } },
        BadResult("item 1 has no outcome field") {
            RequestData.item(&$0, 0) { $0["outcome"] = nil }
        },
        BadResult("an item that is not in the input") {
            RequestData.item(&$0, 0) { $0["id"] = "PRRT_9" }
        },
        BadResult("a second result for one item") {
            RequestData.item(&$0, 2) { $0["id"] = "PRRT_1" }
        },
        BadResult("the outcome of item 1 is not fixed, no-fix, no-action or needs-you") {
            RequestData.item(&$0, 0) { $0["outcome"] = "done" }
        },
        BadResult("item 1 has a reply field, which a fixed item does not have") {
            RequestData.item(&$0, 0) { $0["reply"] = "Done." }
        },
        BadResult("item 3 has a by field, which a no-action item does not have") {
            RequestData.item(&$0, 2) { $0["by"] = .string(ReviewData.oldHex) }
        },
        BadResult("the by field of item 1 is not a full commit ID") {
            RequestData.item(&$0, 0) { $0["by"] = "abc1234" }
        },
        BadResult("item 2 has no reply field") { RequestData.item(&$0, 1) { $0["reply"] = nil } },
        BadResult("the reply of item 2 is not text") {
            RequestData.item(&$0, 1) { $0["reply"] = 5 }
        },
        BadResult("the reply of item 2 is empty") {
            RequestData.item(&$0, 1) { $0["reply"] = " \n " }
        },
        BadResult("the reply of item 2 is longer than 4,000 characters") {
            RequestData.item(&$0, 1) {
                $0["reply"] = .string(String(repeating: "a", count: 4_001))
            }
        },
        BadResult("the reply of item 2 has a control character") {
            RequestData.item(&$0, 1) { $0["reply"] = "A bell \u{7} here." }
        },
        BadResult("the reply of item 2 has a control character") {
            RequestData.item(&$0, 1) { $0["reply"] = "Turn \u{202E}this." }
        },
        BadResult("item 4 has no question field") {
            RequestData.item(&$0, 3) { $0["question"] = nil }
        },
        BadResult("the question of item 4 is longer than 500 characters") {
            RequestData.item(&$0, 3) {
                $0["question"] = .string(String(repeating: "q", count: 501))
            }
        },
        BadResult("a missing item") {
            $0["items"] = .array(Array(($0["items"]?.array ?? []).prefix(3)))
        },
        BadResult("the commit field is not null or a JSON object") { $0["commit"] = "fix" },
        BadResult("an unknown field") { RequestData.commit(&$0) { $0["author"] = "me" } },
        BadResult("the commit has no paths field") {
            RequestData.commit(&$0) { $0["paths"] = nil }
        },
        BadResult("the commit message is not text") {
            RequestData.commit(&$0) { $0["message"] = 1 }
        },
        BadResult("the first line of the commit message is empty") {
            RequestData.commit(&$0) { $0["message"] = "  \nThe body." }
        },
        BadResult("the first line of the commit message is longer than 100 characters") {
            RequestData.commit(&$0) {
                $0["message"] = .string(String(repeating: "s", count: 101))
            }
        },
        BadResult("the commit message is longer than 4,000 characters") {
            RequestData.commit(&$0) {
                $0["message"] = .string("fix: it\n\n" + String(repeating: "b", count: 4_000))
            }
        },
        BadResult("the commit message has a control character") {
            RequestData.commit(&$0) { $0["message"] = "fix: it\n\n\tIndented." }
        },
        BadResult("the paths field of the commit is not a list") {
            RequestData.commit(&$0) { $0["paths"] = "src/a.swift" }
        },
        BadResult("the commit has no paths") { RequestData.commit(&$0) { $0["paths"] = [] } },
        BadResult("the commit has more than 200 paths") {
            RequestData.commit(&$0) {
                $0["paths"] = .array((0...200).map { .string("f\($0)") })
            }
        },
        BadResult("path 1 of the commit is not text") {
            RequestData.commit(&$0) { $0["paths"] = [3] }
        },
        BadResult("path 1 of the commit is not a clean relative path") {
            RequestData.commit(&$0) { $0["paths"] = ["../outside.txt"] }
        },
        BadResult("path 1 of the commit is not a clean relative path") {
            RequestData.commit(&$0) { $0["paths"] = ["/etc/hosts"] }
        },
        BadResult("path 1 of the commit is not a clean relative path") {
            RequestData.commit(&$0) { $0["paths"] = ["src\\a.swift"] }
        },
        BadResult("path 2 of the commit is in a .git folder") {
            RequestData.commit(&$0) { $0["paths"] = ["src/a.swift", "sub/.GIT/config"] }
        },
        BadResult("path 1 of the commit did not change", changed: ["src/b.swift"]) { _ in },
        BadResult("path 2 of the commit shows more than one time") {
            RequestData.commit(&$0) { $0["paths"] = ["src/a.swift", "src/a.swift"] }
        },
        BadResult("the checks field is not passed, failed, blocked or none") {
            $0["checks"] = "green"
        },
        BadResult("a Fixed item has no commit") { $0["commit"] = .null },
        BadResult("a commit with no Fixed item") {
            RequestData.item(&$0, 0) { $0["by"] = .string(ReviewData.oldHex) }
        },
    ]
}

@Suite("the result file of a request round")
struct RequestResultTests {
    // A good file gives each outcome in the order of the file, the commit and the checks. A
    // reply can hold a line break and a tab.
    @Test func aGoodFileGivesTheOutcome() throws {
        let input = try RequestData.input()
        let outcome = try RequestResult.check(
            RequestData.result(), input: input, changed: ["src/a.swift", "notes.txt"]
        ).get()
        #expect(
            outcome.items == [
                ItemResult(id: try ReviewData.node("PRRT_1"), outcome: .fixed(by: nil)),
                ItemResult(
                    id: try ReviewData.node("IC_2"),
                    outcome: .noFix(reply: "The README covers this.\n\tSee it.")),
                ItemResult(id: try ReviewData.node("PRR_3"), outcome: .noAction),
                ItemResult(
                    id: try ReviewData.node("PRRT_4"),
                    outcome: .needsYou(question: "Keep the old name?")),
            ])
        #expect(
            outcome.commit
                == CommitPlan(
                    message: "fix: check the upper limit\n\nThe body.", paths: ["src/a.swift"]))
        #expect(outcome.checks == .passed)
        #expect(outcome.fixedByRound == [try ReviewData.node("PRRT_1")])
    }

    // An item that an earlier commit of the PR fixed names it, and needs no commit of the round.
    @Test func aFixByAnEarlierCommitNeedsNoCommit() throws {
        let data = RequestData.result {
            RequestData.item(&$0, 0) { $0["by"] = .string(ReviewData.oldHex) }
            $0["commit"] = .null
            $0["checks"] = "none"
        }
        let outcome = try RequestResult.check(data, input: try RequestData.input()).get()
        let earlier = try ReviewData.commit(ReviewData.oldHex)
        #expect(outcome.items.first?.outcome == .fixed(by: earlier))
        #expect(outcome.commit == nil && outcome.fixedByRound.isEmpty)
    }

    // Each bad file is refused with its reason, which names a field or a limit only.
    @Test(arguments: BadResult.all) func aBadFileIsRefused(_ bad: BadResult) throws {
        let result = RequestResult.check(
            bad.data, input: try RequestData.input(), changed: bad.changed)
        #expect(result.failure == ResultRefusal(bad.refusal))
    }

    // A commit message that asks GitHub to skip CI is refused, in each form and case.
    @Test func aSkipCIMessageIsRefused() throws {
        let input = try RequestData.input()
        for message in [
            "fix: it [skip ci]", "fix: it\n\n[CI SKIP]", "fix: [ no  ci ]", "[skip actions] fix",
            "fix: it [Actions   Skip]", "fix: it\n\nskip-checks: true",
            "fix: it\n\nSKIP-CHECKS:TRUE",
        ] {
            let data = RequestData.result {
                RequestData.commit(&$0) { $0["message"] = .string(message) }
            }
            #expect(
                RequestResult.check(data, input: input).failure
                    == ResultRefusal("the commit message asks to skip CI"), "\(message)")
        }
        let plain = RequestData.result {
            RequestData.commit(&$0) { $0["message"] = "fix: skip the CI cache [ci]" }
        }
        #expect(RequestResult.check(plain, input: input).failure == nil)
    }

    // Failed checks can't have a commit; blocked checks can, because CI runs on GitHub after the
    // push.
    @Test func failedChecksCannotHaveACommit() throws {
        let input = try RequestData.input()
        let failed = RequestData.result { $0["checks"] = "failed" }
        #expect(
            RequestResult.check(failed, input: input).failure
                == ResultRefusal("a commit with failed checks"))
        let blocked = RequestData.result { $0["checks"] = "blocked" }
        #expect(try RequestResult.check(blocked, input: input).get().checks == .blocked)
    }
}

extension Result {
    // The error of a failure, or nil.
    fileprivate var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
