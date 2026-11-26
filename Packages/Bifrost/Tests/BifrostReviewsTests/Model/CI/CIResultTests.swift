// The strict check of the result file of a CI round (docs/behaviour/reviews.md, "My PRs", and
// skills/bifrost-fix-ci/bifrost-mode.md, "The result file"). The session that writes the file
// reads the CI logs and also holds review text from other people, so one failed rule refuses the
// whole file. A refusal names a field or a limit only.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private typealias D = ReviewData

// A good fix result of the round of CIData, with a change.
private func result(_ change: (inout [String: JSONValue]) -> Void = { _ in }) -> Data {
    var fields: [String: JSONValue] = [
        "version": 1, "pr": "Owner-A/Repo-A#7", "headSha": .string(D.headHex),
        "round": .string(CIData.token), "outcome": "fix",
        "reason": "The test expects the old limit of 10.",
        "commit": ["message": "fix: use the new limit in the test", "paths": ["src/limit.ts"]],
        "checks": "passed",
    ]
    change(&fields)
    return D.json(.object(fields))
}

// A retry result.
private func retry(_ change: (inout [String: JSONValue]) -> Void = { _ in }) -> Data {
    result {
        $0["outcome"] = "retry"
        $0["commit"] = nil
        $0["checks"] = nil
        change(&$0)
    }
}

// A needs-you result with the question.
private func needsYou(_ question: JSONValue?) -> Data {
    result {
        $0["outcome"] = "needs-you"
        $0["commit"] = nil
        $0["checks"] = nil
        $0["question"] = question
    }
}

private func check(
    _ data: Data, allowed: Set<CIAction> = [.fix, .retry], changed: Set<String>? = nil
) throws -> Result<CIOutcome, ResultRefusal> {
    CIResult.check(data, input: try CIData.input(allowed: allowed), changed: changed)
}

private func refusal(_ text: String) -> Result<CIOutcome, ResultRefusal> {
    .failure(ResultRefusal(text))
}

// The reason of the good result.
private let goodReason = "The test expects the old limit of 10."

private func outcome(_ decision: CIDecision, _ reason: String = goodReason)
    -> Result<CIOutcome, ResultRefusal>
{
    .success(CIOutcome(decision: decision, reason: reason))
}

@Suite("the result file of a CI round", .testTimeLimit)
struct CIResultTests {
    // A fix needs its commit and the checks of the session, and the checks did not fail. The
    // paths of the commit must be changed paths of the worktree.
    @Test func aFixNeedsACommitAndChecks() throws {
        let plan = CommitPlan(
            message: "fix: use the new limit in the test", paths: ["src/limit.ts"])
        #expect(try check(result()) == outcome(.fix(plan, .passed)))
        #expect(
            try check(result { $0["checks"] = "blocked" }, changed: ["src/limit.ts"])
                == outcome(.fix(plan, .blocked)))
        #expect(try check(result { $0["checks"] = "none" }) == outcome(.fix(plan, .none)))
        #expect(try check(result { $0["question"] = .null }) == outcome(.fix(plan, .passed)))
        #expect(try check(result { $0["commit"] = nil }) == refusal("a fix result has no commit"))
        #expect(
            try check(result { $0["commit"] = .null }) == refusal("a fix result has no commit"))
        for checks: JSONValue? in ["failed", nil, .null, "ok", 1] {
            #expect(
                try check(result { $0["checks"] = checks })
                    == refusal("the checks field of a fix is not passed, blocked or none"),
                "\(String(describing: checks))")
        }
        #expect(
            try check(result { $0["question"] = "Why?" })
                == refusal("a fix result has a question field"))
        // The commit check of the request rounds applies.
        #expect(
            try check(result(), changed: ["src/other.ts"])
                == refusal("path 1 of the commit did not change"))
        #expect(
            try check(result { $0["commit"] = ["message": "fix", "paths": [".git/config"]] })
                == refusal("path 1 of the commit is in a .git folder"))
    }

    // A retry re-runs the failed jobs: it has no commit, no checks and no question. Each one can
    // be null.
    @Test func aRetryHasNoCommit() throws {
        #expect(try check(retry()) == outcome(.retry))
        #expect(
            try check(retry {
                $0["commit"] = .null
                $0["checks"] = .null
                $0["question"] = .null
            }) == outcome(.retry))
        #expect(
            try check(retry { $0["commit"] = ["message": "fix: a", "paths": ["src/limit.ts"]] })
                == refusal("a retry result has a commit field"))
        #expect(
            try check(retry { $0["checks"] = "passed" })
                == refusal("a retry result has a checks field"))
        #expect(
            try check(retry { $0["question"] = "Why?" })
                == refusal("a retry result has a question field"))
    }

    // Only the outcomes of the input go: a spent budget refuses its outcome. needs-you is always
    // allowed.
    @Test func anOutcomeOutsideAllowedIsRefused() throws {
        #expect(
            try check(result(), allowed: [.retry])
                == refusal("the outcome field is not allowed in this round"))
        #expect(
            try check(retry(), allowed: [.fix])
                == refusal("the outcome field is not allowed in this round"))
        #expect(
            try check(needsYou("Should I raise the timeout?"), allowed: [])
                == outcome(.needsYou("Should I raise the timeout?")))
        #expect(
            try check(result { $0["outcome"] = "fixed" })
                == refusal("the outcome field is not fix, retry or needs-you"))
    }

    // CI must run on the pushed fix, so a message that tells GitHub to skip it is refused.
    @Test func aSkipCIMessageIsRefused() throws {
        for message in ["fix: a [skip ci]", "fix: b\n\n[CI SKIP]", "fix: c\n\nskip-checks: true"] {
            #expect(
                try check(result { $0["commit"] = ["message": .string(message), "paths": ["a"]] })
                    == refusal("the commit message asks to skip CI"), "\(message)")
        }
    }

    // The PR, the head and the token must be the ones of this round: a result of an earlier
    // round of the session, or of another PR, never counts.
    @Test func aWrongTokenOrHeadIsRefused() throws {
        #expect(
            try check(result { $0["round"] = "0f8a2c1e-5b7d-4c3a-9e21-6d4b8f0a1c2e" })
                == refusal("the round field is not this CI round"))
        #expect(
            try check(result { $0["round"] = 7 })
                == refusal("the round field is not this CI round"))
        #expect(
            try check(result { $0["headSha"] = .string(D.oldHex) })
                == refusal("the headSha field is not the head commit of the round"))
        #expect(
            try check(result { $0["pr"] = "Owner-A/Repo-A#8" })
                == refusal("the pr field is not this pull request"))
        #expect(try check(result { $0["version"] = 2 }) == refusal("the version field is not 1"))
        for key in ["version", "pr", "headSha", "round", "outcome", "reason"] {
            #expect(
                try check(result { $0[key] = nil }) == refusal("the \(key) field is missing"),
                "\(key)")
        }
    }

    // A needs-you result needs a question of 1 to 500 characters for the Answer panel, with no
    // control character other than a line break. It has no commit and no checks.
    @Test func needsYouNeedsAQuestion() throws {
        let asked = "The deploy job needs a secret.\nShould I skip it in forks?"
        #expect(try check(needsYou(.string(asked))) == outcome(.needsYou(asked)))
        #expect(try check(needsYou(nil)) == refusal("a needs-you result has no question"))
        #expect(try check(needsYou(.null)) == refusal("a needs-you result has no question"))
        #expect(try check(needsYou(5)) == refusal("the question field is not text"))
        #expect(try check(needsYou(" \n ")) == refusal("the question field is empty"))
        for control in ["A tab\there.", "A bell \u{7} here.", "Turn \u{202E}this.", "a\r\nb"] {
            #expect(
                try check(needsYou(.string(control)))
                    == refusal("the question field has a control character"), "\(control)")
        }
        let longest = String(repeating: "q", count: 500)
        #expect(try check(needsYou(.string(longest))) == outcome(.needsYou(longest)))
        #expect(
            try check(needsYou(.string(longest + "q")))
                == refusal("the question field is longer than 500 characters"))
        // The limit counts UTF-16 units: a character outside the BMP counts two.
        let faces = String(repeating: "\u{1F600}", count: 250)
        #expect(try check(needsYou(.string(faces))) == outcome(.needsYou(faces)))
        #expect(
            try check(needsYou(.string(faces + "\u{1F600}")))
                == refusal("the question field is longer than 500 characters"))
        let withCommit = result {
            $0["outcome"] = "needs-you"
            $0["checks"] = nil
            $0["question"] = "Why?"
        }
        #expect(try check(withCommit) == refusal("a needs-you result has a commit field"))
        let withChecks = result {
            $0["outcome"] = "needs-you"
            $0["commit"] = .null
            $0["question"] = "Why?"
        }
        #expect(try check(withChecks) == refusal("a needs-you result has a checks field"))
    }

    // The reason is one line of 1 to 300 characters, with the white space at its ends trimmed,
    // and with no control character and no character that changes the direction of the text.
    @Test func aReasonMustBeOneLine() throws {
        #expect(
            try check(result { $0["reason"] = "  The test expects the old limit of 10.\n" })
                == outcome(.fix(
                    CommitPlan(
                        message: "fix: use the new limit in the test", paths: ["src/limit.ts"]),
                    .passed)))
        #expect(try check(result { $0["reason"] = 5 }) == refusal("the reason field is not text"))
        #expect(
            try check(result { $0["reason"] = .null }) == refusal("the reason field is not text"))
        #expect(try check(result { $0["reason"] = " \t " }) == refusal("the reason field is empty"))
        for broken in ["First line.\nSecond line.", "One.\r\nTwo.", "One.\u{2028}Two."] {
            #expect(
                try check(result { $0["reason"] = .string(broken) })
                    == refusal("the reason field has more than one line"), "\(broken)")
        }
        for control in ["A tab\there.", "A bell \u{7} here.", "Turn \u{202E}this."] {
            #expect(
                try check(result { $0["reason"] = .string(control) })
                    == refusal("the reason field has a control character"), "\(control)")
        }
        let longest = String(repeating: "r", count: 300)
        #expect(try check(retry { $0["reason"] = .string(longest) }) == outcome(.retry, longest))
        #expect(
            try check(retry { $0["reason"] = .string(longest + "r") })
                == refusal("the reason field is longer than 300 characters"))
        // The limit counts UTF-16 units: a character outside the BMP counts two.
        let faces = String(repeating: "\u{1F600}", count: 150)
        #expect(try check(retry { $0["reason"] = .string(faces) }) == outcome(.retry, faces))
        #expect(
            try check(retry { $0["reason"] = .string(faces + "\u{1F600}") })
                == refusal("the reason field is longer than 300 characters"))
    }

    // Only the known fields: an unknown field at the top refuses the whole file.
    @Test func anUnknownFieldIsRefused() throws {
        for key in ["note", "items", "baseSha", "files"] {
            #expect(try check(result { $0[key] = "x" }) == refusal("an unknown field"), "\(key)")
        }
        #expect(try check(Data("{\"version\": 1".utf8)) == refusal("the result is not valid JSON"))
        #expect(try check(Data("[1]".utf8)) == refusal("the result is not a JSON object"))
    }

    // A file over 1 MiB is refused before Bifrost reads it.
    @Test func aResultOver1MiBIsRefused() throws {
        let large = Data(repeating: 0x20, count: 1_048_577)
        #expect(try check(large) == refusal("the result is larger than 1,048,576 bytes"))
        let padded = result() + Data(repeating: 0x20, count: 1_048_576 - result().count)
        #expect(try check(padded).map(\.reason) == .success(goodReason))
    }
}
