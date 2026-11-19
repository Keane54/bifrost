// The strict check of result.json (docs/behaviour/reviews.md, "Review rounds"): one good file
// and one bad file per rule. A refusal names a field or a limit only.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private typealias D = ReviewData

// One bad file and the field or limit that its refusal names.
struct BadResultFile: CustomTestStringConvertible, Sendable {
    let reason: String
    let data: Data
    var testDescription: String { reason }

    init(_ reason: String, _ change: (inout [String: JSONValue]) -> Void) {
        self.reason = reason
        data = D.result(change)
    }

    init(_ reason: String, raw: String) {
        self.reason = reason
        data = Data(raw.utf8)
    }

    init(_ reason: String, comment change: (inout [String: JSONValue]) -> Void) {
        self.reason = reason
        data = D.result { D.comment(&$0, change) }
    }
}

private func long(_ count: Int) -> String { String(repeating: "x", count: count) }

private let badFiles: [BadResultFile] = [
    BadResultFile("the result is not valid JSON", raw: "{\"version\": 1,"),
    BadResultFile("the result is not a JSON object", raw: "[1]"),
    BadResultFile("an unknown field") { $0["extra"] = 1 },
    BadResultFile("the summary field is missing") { $0["summary"] = nil },
    BadResultFile("the version field is not 1") { $0["version"] = 2 },
    BadResultFile("the pr field is not this pull request") { $0["pr"] = "Owner-A/Repo-A#8" },
    BadResultFile("the headSha field is not the reviewed commit") {
        $0["headSha"] = .string(D.oldHex)
    },
    BadResultFile("the recommendation field is not approve, comment or request-changes") {
        $0["recommendation"] = "merge"
    },
    BadResultFile("the why field is not text") { $0["why"] = 1 },
    BadResultFile("the why field is empty") { $0["why"] = " \n " },
    BadResultFile("the why field has a control character") { $0["why"] = "Bad\u{7}" },
    BadResultFile("the why field has a control character") { $0["why"] = "Bad \u{202E}txt" },
    BadResultFile("the why field is longer than 300 characters") { $0["why"] = .string(long(301)) },
    BadResultFile("the summary field is not text") { $0["summary"] = .null },
    BadResultFile("the summary field is longer than 20,000 characters") {
        $0["summary"] = .string(long(20_001))
    },
    BadResultFile("the comments field is not a list") { $0["comments"] = "none" },
    BadResultFile("the comments field has more than 50 comments") {
        let one: JSONValue = [
            "path": "src/a.swift", "line": 11, "side": "RIGHT", "body": "Nit.",
        ]
        $0["comments"] = .array(Array(repeating: one, count: 51))
    },
    BadResultFile("comment 1 is not a JSON object") { $0["comments"] = [1] },
    BadResultFile("an unknown field", comment: { $0["url"] = "https://example.invalid" }),
    BadResultFile("comment 1 has no side field", comment: { $0["side"] = nil }),
    BadResultFile(
        "comment 1 is on a file that is not in the diff", comment: { $0["path"] = "b.swift" }),
    BadResultFile("comment 1 is on a binary file", comment: { $0["path"] = "img/logo.png" }),
    BadResultFile(
        "the line of comment 1 is not a whole number of 1 or more", comment: { $0["line"] = 0 }),
    BadResultFile(
        "the line of comment 1 is not a whole number of 1 or more",
        comment: { $0["line"] = 1.5 }),
    BadResultFile("the side of comment 1 is not LEFT or RIGHT", comment: { $0["side"] = "right" }),
    BadResultFile(
        "the startLine of comment 1 is not a whole number of 1 or more",
        comment: { $0["startLine"] = .null }),
    BadResultFile(
        "the startLine of comment 1 is not below its line", comment: { $0["startLine"] = 11 }),
    BadResultFile(
        "the startSide of comment 1 is not its side",
        comment: {
            $0["startLine"] = 10
            $0["startSide"] = "LEFT"
        }),
    BadResultFile(
        "comment 1 has a startSide with no startLine", comment: { $0["startSide"] = "RIGHT" }),
    BadResultFile("the body of comment 1 is not text", comment: { $0["body"] = 1 }),
    BadResultFile("the body of comment 1 is empty", comment: { $0["body"] = " \t" }),
    BadResultFile(
        "the body of comment 1 is longer than 10,000 characters",
        comment: { $0["body"] = .string(long(10_001)) }),
    BadResultFile("an Approve recommendation has line comments") {
        $0["recommendation"] = "approve"
    },
    BadResultFile("a Comment recommendation has no text") {
        $0["recommendation"] = "comment"
        $0["summary"] = "  "
        $0["comments"] = []
    },
    BadResultFile("the summary with the moved comments is longer than 65,536 characters") {
        // 7 comments outside the diff, of 10,000 characters each, move into the summary.
        let moved: JSONValue = [
            "path": "src/a.swift", "line": 99, "side": "RIGHT", "body": .string(long(10_000)),
        ]
        $0["comments"] = .array(Array(repeating: moved, count: 7))
    },
]

@Suite("the check of the result file", .testTimeLimit)
struct ReviewResultTests {
    // A good file gives only the known fields: the reason on one line, a summary with only white
    // space as no summary, and the range of a comment.
    @Test func aGoodFileGivesTheOutcome() throws {
        let data = D.result {
            $0["why"] = "  The check\n is   off by one. "
            D.comment(&$0) {
                $0["startLine"] = 10
                $0["startSide"] = "RIGHT"
            }
        }
        let outcome = try ReviewResult.check(data, input: try D.input()).get()
        #expect(outcome.recommendation == .requestChanges)
        #expect(outcome.reason == "The check is off by one.")
        #expect(outcome.summary == "One bug blocks this.")
        #expect(
            outcome.comments == [
                DraftComment(
                    path: "src/a.swift", line: 11, side: .right, startLine: 10,
                    body: "Use `<` here.")
            ])
        let approve = D.result {
            $0["recommendation"] = "approve"
            $0["summary"] = "  "
            $0["comments"] = []
        }
        let nothing = try ReviewResult.check(approve, input: try D.input()).get()
        #expect(nothing.summary == "" && nothing.comments.isEmpty)
    }

    // One failed rule refuses the whole file, with the field or the limit of the rule.
    @Test(arguments: badFiles)
    func eachRuleRefusesItsBadFile(_ bad: BadResultFile) throws {
        let result = ReviewResult.check(bad.data, input: try D.input())
        #expect(result == .failure(ResultRefusal(bad.reason)))
    }

    // A round with a token needs the token back in the round field, so a result of another
    // session never counts. A round with no token (an Electron round) allows no round field.
    @Test func theTokenOfTheRoundMustComeBack() throws {
        var input = try D.input()
        input.round = "t-1"
        let good = D.result { $0["round"] = "t-1" }
        #expect((try? ReviewResult.check(good, input: input).get()) != nil)
        #expect(
            ReviewResult.check(D.result(), input: input)
                == .failure(ResultRefusal("the round field is missing")))
        #expect(
            ReviewResult.check(D.result { $0["round"] = "t-2" }, input: input)
                == .failure(ResultRefusal("the round field is not this review round")))
        #expect(
            ReviewResult.check(good, input: try D.input())
                == .failure(ResultRefusal("an unknown field")))
    }

    // A file over 1 MiB is refused before the decode.
    @Test func aFileOverTheLimitIsRefused() throws {
        let data = Data(repeating: UInt8(ascii: " "), count: ReviewResult.maxBytes + 1)
        #expect(
            ReviewResult.check(data, input: try D.input())
                == .failure(ResultRefusal("the result is larger than 1,048,576 bytes")))
    }

    // The reason of a refusal never holds text from the file: a secret in a bad field, a bad
    // path and a bad key name never show.
    @Test func theReasonNeverHoldsTextFromTheFile() throws {
        let secret = "SECRET-TEXT-FROM-THE-FILE"
        let files = [
            D.result { $0["why"] = .string(secret + "\u{1}") },
            D.result { $0["pr"] = .string(secret) },
            D.result { $0[secret] = 1 },
            D.result { D.comment(&$0) { $0["path"] = .string(secret) } },
            D.result { D.comment(&$0) { $0["side"] = .string(secret) } },
            Data("{\"\(secret)\": ".utf8),
        ]
        for data in files {
            let refusal = try #require(ReviewResult.check(data, input: try D.input()).failure)
            #expect(!refusal.message.contains(secret))
            #expect(!RoundFailure.badResult(refusal).message.contains(secret))
        }
    }
}

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}
