// The strict check of the result file of a conflict round (docs/behaviour/reviews.md, "Merging
// the base branch", and skills/bifrost-resolve-conflicts/bifrost-mode.md, "The result file"). The
// session that writes the file also holds review text from other people, so one failed rule
// refuses the whole file. A refusal names a field or a limit only.
import BifrostFoundation
import Foundation
import Testing

@testable import BifrostReviews

private typealias D = ReviewData

// A good resolved result of the round of ConflictData, with a change.
private func result(_ change: (inout [String: JSONValue]) -> Void = { _ in }) -> Data {
    var fields: [String: JSONValue] = [
        "version": 1, "pr": "Owner-A/Repo-A#7", "headSha": .string(D.headHex),
        "baseSha": .string(D.baseHex), "round": .string(ConflictData.token),
        "outcome": "resolved", "files": ["src/a b.swift", "README.md"],
    ]
    change(&fields)
    return D.json(.object(fields))
}

// A needs-you result with the reason.
private func needsYou(_ reason: JSONValue) -> Data {
    result {
        $0["outcome"] = "needs-you"
        $0["files"] = nil
        $0["reason"] = reason
    }
}

private func check(_ data: Data) throws -> Result<ConflictAnswer, ResultRefusal> {
    ConflictResult.check(data, input: try ConflictData.input())
}

private func refusal(_ text: String) -> Result<ConflictAnswer, ResultRefusal> {
    .failure(ResultRefusal(text))
}

// One bad file of the table and the refusal that it gets.
struct BadConflictResult: Sendable, CustomTestStringConvertible {
    let refusal: String
    let data: Data
    var testDescription: String { refusal }

    init(_ refusal: String, _ change: (inout [String: JSONValue]) -> Void) {
        self.refusal = refusal
        data = result(change)
    }

    init(_ refusal: String, data: Data) {
        self.refusal = refusal
        self.data = data
    }

    static let all: [BadConflictResult] = [
        BadConflictResult("the result is not valid JSON", data: Data("{\"version\": 1".utf8)),
        BadConflictResult("the result is not a JSON object", data: Data("[1]".utf8)),
        BadConflictResult("the version field is missing") { $0["version"] = nil },
        BadConflictResult("the baseSha field is missing") { $0["baseSha"] = nil },
        BadConflictResult("the outcome field is missing") { $0["outcome"] = nil },
        BadConflictResult("the version field is not 1") { $0["version"] = 2 },
        BadConflictResult("the pr field is not this pull request") {
            $0["pr"] = "Owner-A/Repo-A#8"
        },
        BadConflictResult("the headSha field is not the head commit of the round") {
            $0["headSha"] = .string(D.oldHex)
        },
        BadConflictResult("the baseSha field is not the base commit of the round") {
            $0["baseSha"] = .string(D.headHex)
        },
        BadConflictResult("the outcome field is not resolved or needs-you") {
            $0["outcome"] = "fixed"
        },
        BadConflictResult("a resolved result has a reason field") { $0["reason"] = "Done." },
        BadConflictResult("a resolved result has a reason field") { $0["reason"] = .null },
        BadConflictResult("a needs-you result has a files field") {
            $0["outcome"] = "needs-you"
            $0["reason"] = "Unclear."
        },
    ]
}

@Suite("the result file of a conflict round")
struct ConflictResultTests {
    // A resolved file lists each conflicted file once, in any order. A needs-you file gives its
    // reason on one line, with the white space at its ends trimmed.
    @Test func aGoodFileGivesTheAnswer() throws {
        #expect(try check(result()) == .success(.resolved))
        #expect(
            try check(needsYou("  Both sides changed the retry limit.\n"))
                == .success(.needsYou("Both sides changed the retry limit.")))
    }

    // A resolved result lists each conflicted file exactly one time, and no other file.
    @Test func aResolvedResultMustListEachConflictOnce() throws {
        #expect(
            try check(result { $0["files"] = nil })
                == refusal("a resolved result has no files field"))
        #expect(
            try check(result { $0["files"] = "README.md" })
                == refusal("the files field is not a list"))
        #expect(try check(result { $0["files"] = [3] }) == refusal("file 1 is not text"))
        #expect(
            try check(result { $0["files"] = ["README.md"] })
                == refusal("the files field lacks a conflicted file"))
        #expect(
            try check(result { $0["files"] = [] })
                == refusal("the files field lacks a conflicted file"))
        #expect(
            try check(result { $0["files"] = ["README.md", "src/a b.swift", "README.md"] })
                == refusal("file 3 shows more than one time"))
        #expect(
            try check(result { $0["files"] = ["README.md", "src/a b.swift", "src/c.swift"] })
                == refusal("file 3 is not a conflicted file"))
        // A path must be the conflicted path exactly: no other form of it counts.
        #expect(
            try check(result { $0["files"] = ["./README.md", "src/a b.swift"] })
                == refusal("file 1 is not a conflicted file"))
        #expect(
            try check(result { $0["files"] = ["readme.md", "src/a b.swift"] })
                == refusal("file 1 is not a conflicted file"))
    }

    // The round field must be the token of this round: a result of an earlier round of the
    // session, or of another session, never counts.
    @Test func aWrongTokenIsRefused() throws {
        #expect(
            try check(result { $0["round"] = "0f8a2c1e-5b7d-4c3a-9e21-6d4b8f0a1c2e" })
                == refusal("the round field is not this conflict round"))
        #expect(
            try check(result { $0["round"] = 7 })
                == refusal("the round field is not this conflict round"))
        #expect(
            try check(result { $0["round"] = nil }) == refusal("the round field is missing"))
    }

    // A needs-you result needs a reason of 1 to 300 characters on one line, with no control
    // character and no character that changes the direction of the text.
    @Test func needsYouNeedsAOneLineReason() throws {
        let noReason = result {
            $0["outcome"] = "needs-you"
            $0["files"] = nil
        }
        #expect(try check(noReason) == refusal("a needs-you result has no reason field"))
        #expect(try check(needsYou(5)) == refusal("the reason field is not text"))
        #expect(try check(needsYou(.null)) == refusal("the reason field is not text"))
        #expect(try check(needsYou(" \n\t ")) == refusal("the reason field is empty"))
        for broken in ["First line.\nSecond line.", "One.\r\nTwo.", "One.\u{2028}Two."] {
            #expect(
                try check(needsYou(.string(broken)))
                    == refusal("the reason field has more than one line"), "\(broken)")
        }
        for control in ["A tab\there.", "A bell \u{7} here.", "Turn \u{202E}this."] {
            #expect(
                try check(needsYou(.string(control)))
                    == refusal("the reason field has a control character"), "\(control)")
        }
        let longest = String(repeating: "r", count: 300)
        #expect(try check(needsYou(.string(longest))) == .success(.needsYou(longest)))
        #expect(
            try check(needsYou(.string(longest + "r")))
                == refusal("the reason field is longer than 300 characters"))
    }

    // Only the known fields: an unknown field at the top refuses the whole file.
    @Test func anUnknownFieldIsRefused() throws {
        #expect(try check(result { $0["note"] = "hi" }) == refusal("an unknown field"))
        #expect(try check(result { $0["commit"] = .null }) == refusal("an unknown field"))
        #expect(try check(result { $0["items"] = [] }) == refusal("an unknown field"))
    }

    // A file over 1 MiB is refused before Bifrost reads it.
    @Test func aResultOver1MiBIsRefused() throws {
        let large = Data(repeating: 0x20, count: 1_048_577)
        #expect(try check(large) == refusal("the result is larger than 1,048,576 bytes"))
        let padded = result() + Data(repeating: 0x20, count: 1_048_576 - result().count)
        #expect(try check(padded) == .success(.resolved))
    }

    // Each bad file of the table is refused with its reason.
    @Test(arguments: BadConflictResult.all)
    func aBadFileIsRefused(_ bad: BadConflictResult) throws {
        #expect(try check(bad.data) == refusal(bad.refusal))
    }
}
