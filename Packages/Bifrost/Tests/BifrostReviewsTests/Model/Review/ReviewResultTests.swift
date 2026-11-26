// The strict check of result.json (docs/behaviour/reviews.md, "Review rounds"): one good file
// and one bad file per rule, for version 2 and for version 1. A refusal names a field or a limit
// only.
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

    init(_ reason: String, v2 change: (inout [String: JSONValue]) -> Void) {
        self.reason = reason
        data = D.resultV2(change)
    }

    init(_ reason: String, finding change: (inout [String: JSONValue]) -> Void) {
        self.reason = reason
        data = D.resultV2 { D.finding(&$0, change) }
    }
}

private func long(_ count: Int) -> String { String(repeating: "x", count: count) }

// The version 1 files: the rules of the old form, which a round that started before an update
// still gives.
private let badFiles: [BadResultFile] = [
    BadResultFile("the result is not valid JSON", raw: "{\"version\": 1,"),
    BadResultFile("the result is not a JSON object", raw: "[1]"),
    BadResultFile("an unknown field") { $0["extra"] = 1 },
    BadResultFile("the summary field is missing") { $0["summary"] = nil },
    BadResultFile("the version field is not 1 or 2") { $0["version"] = 3 },
    BadResultFile("the version field is missing") { $0["version"] = nil },
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
    BadResultFile(
        "the body of comment 1 has a control character", comment: { $0["body"] = "Bad\u{7}" }),
    BadResultFile("the summary field has a control character") {
        $0["recommendation"] = "approve"
        $0["summary"] = "Two \u{202E}small points."
        $0["comments"] = []
    },
    BadResultFile("the summary field has a control character") {
        $0["summary"] = "One bug \u{202E}blocks this."
    },
    BadResultFile("the summary field has a control character") {
        $0["recommendation"] = "comment"
        $0["summary"] = "One point.\u{7}"
    },
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

// The version 2 files.
private let badV2Files: [BadResultFile] = [
    BadResultFile("the version field is missing", v2: { $0["version"] = nil }),
    BadResultFile("the version field is not 1 or 2", v2: { $0["version"] = "2" }),
    BadResultFile("an unknown field", v2: { $0["comments"] = [] }),
    BadResultFile("the note field is missing", v2: { $0["note"] = nil }),
    BadResultFile("the summary field is missing", v2: { $0["summary"] = nil }),
    BadResultFile("the findings field is missing", v2: { $0["findings"] = nil }),
    BadResultFile("the pr field is not this pull request", v2: { $0["pr"] = "Owner-A/Repo-A#8" }),
    BadResultFile("the why field has a control character", v2: { $0["why"] = "bad\u{7}" }),
    BadResultFile("the note field is not text", v2: { $0["note"] = 1 }),
    BadResultFile("the note field is empty", v2: { $0["note"] = " \n\t " }),
    BadResultFile(
        "the note field is longer than 2,000 characters",
        v2: { $0["note"] = .string(long(2_001)) }),
    BadResultFile(
        "the note field has a control character", v2: { $0["note"] = "One.\u{202E}Two." }),
    BadResultFile("the note field has a control character", v2: { $0["note"] = "One.\r\nTwo." }),
    BadResultFile("the note field has a control character", v2: { $0["note"] = "One.\u{7}" }),
    BadResultFile("the summary field is not text", v2: { $0["summary"] = .null }),
    BadResultFile(
        "the summary field is longer than 20,000 characters",
        v2: { $0["summary"] = .string(long(20_001)) }),
    BadResultFile(
        "the summary field has a control character",
        v2: { $0["summary"] = "One bug \u{202E}blocks this." }),
    BadResultFile(
        "the summary field has a control character",
        v2: {
            $0["recommendation"] = "comment"
            $0["summary"] = "One point.\r\nAnother point."
        }),
    BadResultFile(
        "an Approve recommendation has a summary",
        v2: {
            $0["recommendation"] = "approve"
            $0["summary"] = "x"
        }),
    BadResultFile("the findings field is not a list", v2: { $0["findings"] = "none" }),
    BadResultFile(
        "the findings field has more than 50 findings",
        v2: {
            $0["findings"] = .array(Array(repeating: D.item("nit", body: "Nit."), count: 51))
        }),
    BadResultFile("finding 1 is not a JSON object", v2: { $0["findings"] = [1] }),
    BadResultFile("an unknown field", finding: { $0["url"] = "https://example.invalid" }),
    BadResultFile("finding 1 has no kind field", finding: { $0["kind"] = nil }),
    BadResultFile("finding 1 has no body field", finding: { $0["body"] = nil }),
    BadResultFile(
        "the kind of finding 1 is not bug, minor or nit", finding: { $0["kind"] = "style" }),
    BadResultFile(
        "finding 1 has only a part of its place",
        finding: {
            $0["line"] = nil
            $0["side"] = nil
        }),
    BadResultFile("finding 1 has only a part of its place", finding: { $0["path"] = nil }),
    BadResultFile(
        "finding 1 has only a part of its place",
        v2: { $0["findings"] = [["kind": "minor", "startLine": 3, "body": "A range."]] }),
    BadResultFile(
        "finding 1 is on a file that is not in the diff", finding: { $0["path"] = "b.swift" }),
    BadResultFile("finding 1 is on a binary file", finding: { $0["path"] = "img/logo.png" }),
    BadResultFile(
        "the line of finding 1 is not a whole number of 1 or more", finding: { $0["line"] = 0 }),
    BadResultFile(
        "the side of finding 1 is not LEFT or RIGHT", finding: { $0["side"] = "right" }),
    BadResultFile(
        "the startLine of finding 1 is not a whole number of 1 or more",
        finding: { $0["startLine"] = 0 }),
    BadResultFile(
        "the startLine of finding 1 is not below its line", finding: { $0["startLine"] = 11 }),
    BadResultFile(
        "the startSide of finding 1 is not its side",
        finding: {
            $0["startLine"] = 10
            $0["startSide"] = "LEFT"
        }),
    BadResultFile(
        "finding 1 has a startSide with no startLine", finding: { $0["startSide"] = "RIGHT" }),
    BadResultFile("the body of finding 1 is not text", finding: { $0["body"] = 1 }),
    BadResultFile("the body of finding 1 is empty", finding: { $0["body"] = " \n" }),
    BadResultFile(
        "the body of finding 1 is longer than 10,000 characters",
        finding: { $0["body"] = .string(long(10_001)) }),
    BadResultFile(
        "the body of finding 1 has a control character", finding: { $0["body"] = "Bad\u{7}" }),
    BadResultFile(
        "the body of finding 1 has a control character",
        finding: { $0["body"] = "Bad \u{202E}txt" }),
    BadResultFile(
        "the body of finding 2 has a control character",
        v2: {
            $0["findings"] = [
                D.item("bug", line: 11, body: "Line one.\n\tLine two."),
                D.item("nit", body: "Bad\u{1B}[31m"),
            ]
        }),
    BadResultFile(
        "a Request changes recommendation has no text",
        v2: {
            $0["summary"] = " "
            $0["findings"] = [D.item("nit", line: 12, body: "`three` says it better.")]
        }),
    BadResultFile(
        "a Comment recommendation has no text",
        v2: {
            $0["recommendation"] = "comment"
            $0["summary"] = ""
            $0["findings"] = []
        }),
    BadResultFile(
        "the summary with the moved comments is longer than 65,536 characters",
        v2: {
            // 7 findings outside the diff, of 10,000 characters each, move into the summary.
            let moved = D.item("minor", line: 99, body: long(10_000))
            $0["findings"] = .array(Array(repeating: moved, count: 7))
        }),
]

// A diff of src/upload.ts with hunks that show lines 10 to 13 and 39 to 42 of the head version:
// the diff of the example of the mode file.
private let uploadDiff = """
    diff --git a/src/upload.ts b/src/upload.ts
    index 1111111..2222222 100644
    --- a/src/upload.ts
    +++ b/src/upload.ts
    @@ -10,3 +10,4 @@ export class Upload {
       const a = 1;
    -  let n = 0;
    +  let n = 3;
    +  let wait = 100;
       const b = 2;
    @@ -38,3 +39,4 @@ export class Upload {
       try {
    +    log(`retry ${n} of 3`);
         await send();
       }

    """

// The text of the Bifrost mode file of the review skill in the repo.
private func reviewModeFile() throws -> String {
    try String(
        contentsOf: try Repo.root().appending(
            path: "App/Bifrost/Resources/bifrost-skills/skills/bifrost-review/bifrost-mode.md"),
        encoding: .utf8)
}

// The words of the mode file with each run of white space as one space, so a phrase that wraps
// to the next line still matches.
private func reviewModeWords() throws -> String {
    try reviewModeFile().split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

@Suite("the check of the result file", .testTimeLimit)
struct ReviewResultTests {
    // A good version 1 file gives only the known fields: the reason on one line, a summary with
    // only white space as no summary, and the range of a comment as the place of a bug.
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
            outcome.findings == [
                D.finding(.bug, line: 11, startLine: 10, body: "Use `<` here.", onDiff: true)
            ])
        let approve = D.result {
            $0["recommendation"] = "approve"
            $0["summary"] = "  "
            $0["comments"] = []
        }
        let nothing = try ReviewResult.check(approve, input: try D.input()).get()
        #expect(nothing.summary == "" && nothing.findings.isEmpty)
    }

    // A version 2 file gives the note as written, with its line break and its tab, and each
    // finding with its kind, its place and its body.
    @Test func aVersion2FileGivesTheNoteAndTheFindings() throws {
        let data = D.resultV2 {
            $0["why"] = " the new limit\n check is off by one "
            $0["note"] = "Line one.\n\tLine two."
            $0["findings"] = [
                D.item("bug", line: 11, body: "Use `<` here."),
                [
                    "kind": "minor", "path": "src/a.swift", "line": 11, "side": "RIGHT",
                    "startLine": 10, "startSide": "RIGHT", "body": "The two lines repeat it.",
                ],
                D.item("nit", line: 12, body: "`three` says it better."),
                D.item("minor", body: "The PR does not update the limit docs."),
            ]
        }
        let outcome = try ReviewResult.check(data, input: try D.input()).get()
        #expect(
            outcome
                == ReviewOutcome(
                    recommendation: .requestChanges, reason: "the new limit check is off by one",
                    note: "Line one.\n\tLine two.", summary: "One bug blocks this.",
                    findings: [
                        D.finding(.bug, line: 11, body: "Use `<` here.", onDiff: true),
                        D.finding(
                            .minor, line: 11, startLine: 10, body: "The two lines repeat it.",
                            onDiff: true),
                        D.finding(.nit, line: 12, body: "`three` says it better.", onDiff: true),
                        D.finding(.minor, body: "The PR does not update the limit docs."),
                    ]))
        #expect(outcome.draftFindings.map(\.kind) == [.bug, .minor, .minor])
        // An Approve has no summary, and its findings can be only nits.
        let approve = D.resultV2 {
            $0["recommendation"] = "approve"
            $0["summary"] = " "
            $0["findings"] = [D.item("nit", line: 12, body: "`three` says it better.")]
        }
        let nits = try ReviewResult.check(approve, input: try D.input()).get()
        #expect(nits.summary == "" && nits.findings.map(\.kind) == [.nit])
    }

    // onDiff is true only when a hunk of the diff of the round shows the place of the finding, on
    // its side: a line of the head version, or a deleted line with its number in the base.
    @Test func eachFindingKnowsIfTheDiffShowsIt() throws {
        let data = D.resultV2 {
            $0["findings"] = [
                D.item("bug", line: 12, body: "In the hunk."),
                D.item("bug", line: 11, side: "LEFT", body: "A deleted line."),
                D.item("bug", line: 14, side: "LEFT", body: "Past the base lines of the hunk."),
                D.item("bug", line: 99, body: "Out of the hunk."),
                D.item("minor", body: "On the whole PR."),
            ]
        }
        let outcome = try ReviewResult.check(data, input: try D.input()).get()
        #expect(outcome.findings.map(\.onDiff) == [true, true, false, false, false])
        #expect(outcome.findings.map { $0.comment != nil } == [true, true, false, false, false])
    }

    // An old Approve held its minor points in the summary. That summary is now one minor finding
    // on the whole PR, so it shows in the Review panel and is never posted unseen.
    @Test func aVersion1ApproveSummaryReadsAsOneMinorFinding() throws {
        let approve = D.result {
            $0["recommendation"] = "approve"
            $0["summary"] = "Two small points."
            $0["comments"] = []
        }
        let outcome = try ReviewResult.check(approve, input: try D.input()).get()
        #expect(outcome.note == "" && outcome.summary == "")
        #expect(
            outcome.findings == [
                Finding(kind: .minor, place: nil, body: "Two small points.", onDiff: false)
            ])
        let blank = D.result {
            $0["recommendation"] = "approve"
            $0["summary"] = " \n"
            $0["comments"] = []
        }
        #expect(try ReviewResult.check(blank, input: try D.input()).get().findings == [])
    }

    // A version 1 Request changes file reads as before: its summary, and each comment as a bug
    // with the place and the body of the comment. It has no note.
    @Test func aVersion1RequestChangesFileStillReads() throws {
        let outcome = try ReviewResult.check(D.result(), input: try D.input()).get()
        #expect(
            outcome
                == ReviewOutcome(
                    recommendation: .requestChanges, reason: "The new limit check is off by one.",
                    note: "", summary: "One bug blocks this.",
                    findings: [D.finding(.bug, line: 11, body: "Use `<` here.", onDiff: true)]))
        let outside = D.result { D.comment(&$0) { $0["line"] = 99 } }
        let moved = try ReviewResult.check(outside, input: try D.input()).get()
        #expect(moved.findings == [D.finding(.bug, line: 99, body: "Use `<` here.")])
    }

    // One failed rule refuses the whole file, with the field or the limit of the rule.
    @Test(arguments: badFiles + badV2Files)
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
        let goodV2 = D.resultV2 { $0["round"] = "t-1" }
        #expect((try? ReviewResult.check(goodV2, input: input).get()) != nil)
        #expect(
            ReviewResult.check(D.resultV2(), input: input)
                == .failure(ResultRefusal("the round field is missing")))
        #expect(
            ReviewResult.check(D.resultV2 { $0["round"] = "t-2" }, input: input)
                == .failure(ResultRefusal("the round field is not this review round")))
        #expect(
            ReviewResult.check(goodV2, input: try D.input())
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
            D.resultV2 { $0["version"] = .string(secret) },
            D.resultV2 { $0["note"] = .string(secret + "\u{7}") },
            D.resultV2 { D.finding(&$0) { $0["kind"] = .string(secret) } },
            D.resultV2 { D.finding(&$0) { $0["path"] = .string(secret) } },
            D.resultV2 { D.finding(&$0) { $0[secret] = 1 } },
            D.resultV2 { D.finding(&$0) { $0["body"] = .string(secret + "\u{202E}") } },
        ]
        for data in files {
            let refusal = try #require(ReviewResult.check(data, input: try D.input()).failure)
            #expect(!refusal.message.contains(secret))
            #expect(!RoundFailure.badResult(refusal).message.contains(secret))
        }
        let note = D.resultV2 { $0["note"] = .string(secret + "\u{7}") }
        #expect(
            ReviewResult.check(note, input: try D.input())
                == .failure(ResultRefusal("the note field has a control character")))
    }

    // The example of the mode file is a good version 2 result, so Claude copies a form that
    // passes the check. The mode file names each field of the result.
    @Test func theModeFileExampleIsAGoodVersion2Result() throws {
        let mode = try reviewModeFile()
        let start = try #require(mode.range(of: "```json\n"))
        let end = try #require(mode.range(of: "\n```", range: start.upperBound..<mode.endIndex))
        let example = Data(mode[start.upperBound..<end.lowerBound].utf8)
        var input = try D.input(diff: DiffLines.parse(uploadDiff))
        input.pr = try D.pr("example-org/api#7")
        input.headSHA = try D.commit(String(repeating: "a", count: 40))
        input.round = "0f8a2c1e-5b7d-4c3a-9e21-6d4b8f0a1c2e"
        let outcome = try ReviewResult.check(example, input: input).get()
        #expect(outcome.recommendation == .approve && outcome.summary == "")
        #expect(!outcome.note.isEmpty)
        #expect(outcome.findings.map(\.kind) == [.minor, .nit])
        #expect(outcome.findings.map(\.onDiff) == [true, true])
        #expect(outcome.reason.first?.isLowercase == true && outcome.reason.last != ".")
        let names = [
            "version", "pr", "headSha", "round", "recommendation", "why", "note", "summary",
            "findings", "kind", "path", "line", "side", "startLine", "startSide", "body", "bug",
            "minor", "nit",
        ]
        for name in names {
            #expect(mode.contains("`\(name)`"), "\(name)")
        }
    }

    // Bifrost shows the reason after "Claude suggests: <recommendation> - " and adds the
    // punctuation, so the mode file asks for one short clause in lower case with no full stop.
    // The Review panel shows the note, so the note follows the humanise rules in a natural voice,
    // never as a row of short sentences.
    @Test func theModeFileAsksForAShortLowerCaseWhy() throws {
        let mode = try reviewModeWords()
        #expect(mode.contains("as one short clause on one line"))
        #expect(
            mode.contains("Start it with a lower-case letter, and put no full stop at the end."))
        #expect(mode.contains("before you write the note, the summary and the findings"))
        #expect(mode.contains("Write it in a natural voice"))
        #expect(mode.contains("do not write a row of short sentences"))
        #expect(!mode.contains("short sentences of plain text"))
    }

    // Section 7 of the skill gives the voice of a review. The mode file overrides the skill, so
    // it must not bring back one fixed shape for each comment, and it must not pass its own
    // controlled style on to the review.
    @Test func theModeFileKeepsTheVoiceOfSection7() throws {
        let mode = try reviewModeWords()
        #expect(!mode.contains("what goes wrong and the fix"))
        #expect(mode.contains("in the voice that section 7 of `SKILL.md` gives"))
        #expect(mode.contains("Do not copy that style into the review."))
    }
}

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let failure) = self { failure } else { nil }
    }
}
