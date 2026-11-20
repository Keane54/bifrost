// The own request file of the user (docs/behaviour/reviews.md, "Your own requests"): the check is
// as strict as the check of a round result, and one failed rule refuses the whole file. The
// texts of the row say what went wrong and that the change is still in the copy of the PR.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

@Suite("the own request file", .testTimeLimit)
struct OwnRequestTests {
    private static let head = "f7698d38614ba22b41f996fab73124361d2fe389"

    private static func pr() throws -> PRKey { try #require(PRKey(text: "Owner-A/Repo-A#7")) }
    private static func commit() throws -> CommitID { try #require(CommitID(head)) }

    // The file with the fields, and each change to them. nil removes a field.
    private static func file(_ change: [String: JSONValue?] = [:]) -> Data {
        var fields: [String: JSONValue] = [
            "version": 1, "pr": "Owner-A/Repo-A#7", "headSha": .string(head),
            "commit": ["message": "refactor: rename the helper", "paths": ["src/a.swift"]],
        ]
        for (key, value) in change { fields[key] = value }
        let encoder = JSONEncoder()
        return (try? encoder.encode(JSONValue.object(fields))) ?? Data()
    }

    private static func check(_ data: Data, changed: Set<String> = ["src/a.swift"]) throws
        -> Result<CommitPlan, ResultRefusal>
    {
        OwnRequestFile.check(data, pr: try pr(), head: try commit(), changed: changed)
    }

    @Test func aGoodFileGivesTheCommit() throws {
        #expect(
            try Self.check(Self.file()).get()
                == CommitPlan(message: "refactor: rename the helper", paths: ["src/a.swift"]))
    }

    // Each case breaks one rule, and the refusal names only the field or the limit.
    @Test func eachBrokenRuleRefusesTheWholeFile() throws {
        let cases: [(Data, String)] = [
            (Data("{ not json".utf8), "the file is not valid JSON"),
            (Data("[]".utf8), "the file is not a JSON object"),
            (Self.file(["items": .array([])]), "an unknown field"),
            (Self.file(["reply": "Done."]), "an unknown field"),
            (Self.file(["commit": nil]), "the commit field is missing"),
            (Self.file(["commit": .null]), "the commit field is not a JSON object"),
            (Self.file(["version": 2]), "the version field is not 1"),
            (Self.file(["pr": "Owner-A/Repo-A#8"]), "the pr field is not this pull request"),
            (
                Self.file(["headSha": .string(String(repeating: "e", count: 40))]),
                "the headSha field is not the commit of the pull request's copy"
            ),
            (
                Self.file(["commit": ["message": "fix: it [skip ci]", "paths": ["src/a.swift"]]]),
                "the commit message asks to skip CI"
            ),
            (
                Self.file(["commit": ["message": "fix: it\u{1B}", "paths": ["src/a.swift"]]]),
                "the commit message has a control character"
            ),
            (
                Self.file(["commit": ["message": "fix: it", "paths": .array([])]]),
                "the commit has no paths"
            ),
            (
                Self.file(["commit": ["message": "fix: it", "paths": ["../a.swift"]]]),
                "path 1 of the commit is not a clean relative path"
            ),
            (
                Self.file(["commit": ["message": "fix: it", "paths": [".Git/config"]]]),
                "path 1 of the commit is in a .git folder"
            ),
            (
                Self.file(["commit": ["message": "fix: it", "paths": ["src/b.swift"]]]),
                "path 1 of the commit did not change"
            ),
            (
                Self.file([
                    "commit": ["message": "fix: it", "paths": ["src/a.swift", "src/a.swift"]]
                ]),
                "path 2 of the commit shows more than one time"
            ),
            (
                Self.file(["commit": ["message": "fix: it", "paths": ["src/a.swift"], "by": "x"]]),
                "an unknown field"
            ),
        ]
        for (data, refusal) in cases {
            #expect(throws: ResultRefusal(refusal), "\(refusal)") { try Self.check(data).get() }
        }
        let many = (1...201).map { JSONValue.string("src/\($0).swift") }
        let changed = Set((1...201).map { "src/\($0).swift" })
        let tooMany = Self.file(["commit": ["message": "fix: it", "paths": .array(many)]])
        #expect(throws: ResultRefusal("the commit has more than 200 paths")) {
            try Self.check(tooMany, changed: changed).get()
        }
        let large = Data(repeating: 0x20, count: RequestResult.maxBytes + 1)
        #expect(throws: ResultRefusal("the file is larger than 1,048,576 bytes")) {
            try Self.check(large).get()
        }
    }

    // The texts of the row are friendly, say why, and say where the change is.
    @Test func theTextsSayWhyAndWhereTheChangeIs() {
        let kept = "Your change is still in Bifrost's copy of this pull request."
        #expect(
            OwnRequestStop.badFile(ResultRefusal("an unknown field")).message
                == "Claude wrote a commit request Bifrost couldn't use (an unknown field), so "
                + "Bifrost didn't commit your change. \(kept) Ask Claude in its session to try "
                + "again.")
        #expect(
            OwnRequestStop.wrote(.pushFailed(.conflict)).message
                == "Someone pushed to this branch, and your change doesn't merge cleanly, so "
                + "Bifrost didn't push it. \(kept) Ask Claude in its session to undo it, choose "
                + "Handle now, then ask for it again.")
        #expect(
            OwnRequestStop.wrote(.commitRefused(.workflow)).message
                == "Bifrost didn't commit your change. Bifrost won't commit a GitHub workflow or "
                + "action. \(kept)")
        #expect(
            OwnRequestStop.wrote(.pushFailed(.git("fatal"))).message
                == "Bifrost couldn't push your change. The Event log has the details. Choose Try "
                + "again to push it.")
        #expect(
            OwnRequestStop.wrote(.fork).message
                == OwnRequestStop.wrote(.pushFailed(.fork)).message)
        // The worktree holds the merge of a conflict round, which is not on GitHub.
        #expect(
            OwnRequestStop.conflictMerge.message
                == "Claude was resolving merge conflicts in Bifrost's copy of this pull request, "
                + "so Bifrost didn't commit your change or push the merge. \(kept) Choose Discard "
                + "these changes, then ask Claude again.")
        // No text names a path or holds a text of the file.
        #expect(!OwnRequestStop.notSaved.message.contains("own-request"))
    }
}
