// The input file of a conflict round (docs/behaviour/reviews.md, "Merging the base branch", and
// skills/bifrost-resolve-conflicts/bifrost-mode.md, "The input file"): the token, the PR, the
// commits of the merge, the conflicted paths and the files of the round.
import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostReviews

private typealias D = ReviewData

enum ConflictData {
    static let token = "7c1e0f8a-2b5d-4c3a-9e21-6d4b8f0a1c2e"
    static let conflicts = ["README.md", "src/a b.swift"]

    // The input of a round of PR 7: the head (c), the tip of the base (a) and the merge base (b),
    // in a round folder whose path has a space.
    static func input(oursDiff: Bool = true, theirsDiff: Bool = true) throws -> ConflictInput {
        let folder = URL(filePath: "/r/my repos/.bifrost-io/7", directoryHint: .isDirectory)
        return try ConflictInput(
            pr: try D.pr(), round: token, url: "https://github.com/Owner-A/Repo-A/pull/7",
            title: "Add the cache", baseRef: "main", headRef: "feat/cache",
            headSHA: try D.commit(), baseSHA: try D.commit(D.baseHex),
            mergeBase: try D.commit(D.oldHex), viewer: "Viewer-A", conflicts: conflicts,
            files: ConflictInput.Files(
                RoundFiles(folder: folder, token: token), oursDiff: oursDiff,
                theirsDiff: theirsDiff))
    }
}

@Suite("the input file of a conflict round")
struct ConflictInputTests {
    // The file has the token of the round, the PR with the head, the fetched tip of the base and
    // their merge base, the conflicted paths, and the files of the round, each named with the
    // round ID. It has no PR body and no comment.
    @Test func theInputCarriesTheTokenTheCommitsAndTheConflicts() throws {
        let input = try ConflictData.input()
        let json = try #require(input.json.object)
        #expect(Set(json.keys) == ["version", "round", "pr", "viewer", "conflicts", "files"])
        #expect(json["version"] == 1 && json["round"] == .string(ConflictData.token))
        #expect(json["viewer"] == "Viewer-A")
        #expect(json["conflicts"] == ["README.md", "src/a b.swift"])
        let pr = try #require(json["pr"]?.object)
        #expect(
            pr == [
                "key": "Owner-A/Repo-A#7", "url": "https://github.com/Owner-A/Repo-A/pull/7",
                "title": "Add the cache", "baseRef": "main", "headRef": "feat/cache",
                "headSha": .string(D.headHex), "baseSha": .string(D.baseHex),
                "mergeBase": .string(D.oldHex),
            ])
        let folder = "/r/my repos/.bifrost-io/7/"
        #expect(
            json["files"]
                == [
                    "result": .string(folder + "result-7c1e0f8a2b5d.json"),
                    "mode": .string(folder + "mode-7c1e0f8a2b5d.md"),
                    "oursDiff": .string(folder + "ours-7c1e0f8a2b5d.diff"),
                    "theirsDiff": .string(folder + "theirs-7c1e0f8a2b5d.diff"),
                    "ownRequest": .string(folder + "own-request.json"),
                ])
        #expect(
            input.files.input.path(percentEncoded: false) == folder + "input-7c1e0f8a2b5d.json")
        // The bytes of the file are the same JSON, with a line break at the end.
        let data = input.fileData
        #expect(data.last == UInt8(ascii: "\n"))
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == input.json)
        #expect(String(decoding: data, as: UTF8.self).contains("\"/r/my repos/"))
    }

    // A diff over ReviewInput.maxDiffBytes is not in the folder: its path is null, so the session
    // reads the changes with git.
    @Test func aDiffOverTheLimitIsNull() throws {
        let input = try ConflictData.input(oursDiff: false)
        #expect(input.files.oursDiff == nil && input.files.theirsDiff != nil)
        let files = try #require(input.json.object?["files"]?.object)
        #expect(files["oursDiff"] == .null)
        #expect(files["theirsDiff"]?.string?.hasSuffix("theirs-7c1e0f8a2b5d.diff") == true)
    }

    // A list of more than MergeStart.maxFiles (50) conflicts never reaches Claude, and an
    // empty list gives Claude nothing to do.
    @Test func aListOverTheLimitNeverReachesClaude() throws {
        let good = try ConflictData.input()
        func input(_ count: Int) throws(ConflictFailure) -> ConflictInput {
            try ConflictInput(
                pr: good.pr, round: good.round, url: good.url, title: good.title,
                baseRef: good.baseRef, headRef: good.headRef, headSHA: good.headSHA,
                baseSHA: good.baseSHA, mergeBase: good.mergeBase, viewer: good.viewer,
                conflicts: (0..<count).map { "src/f\($0).swift" }, files: good.files)
        }
        #expect(try input(50).conflicts.count == 50)
        #expect(throws: ConflictFailure.tooMany) { try input(51) }
        #expect(throws: ConflictFailure.noConflict) { try input(0) }
    }

    // The own request file of the user between rounds has the path of the request rounds of
    // the PR: the same file in each round, whatever the kind of the last round.
    @Test func theOwnRequestFileIsTheOneOfTheRequestRounds() throws {
        let rounds = RoundFiles(
            folder: URL(filePath: "/r/my repos/.bifrost-io/7", directoryHint: .isDirectory),
            token: ConflictData.token)
        let conflict = ConflictInput.Files(rounds, oursDiff: true, theirsDiff: true)
        let request = RequestInput.Files(rounds, fullDiff: true)
        #expect(conflict.ownRequest == request.ownRequest)
        let other = ConflictInput.Files(
            RoundFiles(folder: rounds.folder, token: "0f8a2c1e-5b7d-4c3a-9e21-6d4b8f0a1c2e"),
            oursDiff: false, theirsDiff: false)
        #expect(other.ownRequest == conflict.ownRequest)
        #expect(other.result != conflict.result)
    }

    // Each JSON example of the mode file passes the check that Bifrost runs on the file: the two
    // result files and the own request file.
    @Test func theExamplesOfTheModeFilePassTheChecks() throws {
        let mode = try modeFile()
        let examples = mode.components(separatedBy: "```json\n").dropFirst().map {
            Data(($0.components(separatedBy: "```").first ?? "").utf8)
        }
        try #require(examples.count == 3)
        let pr = try D.pr("example-org/api#9")
        let head = try D.commit(String(repeating: "a", count: 40))
        var input = try ConflictData.input()
        input.pr = pr
        input.headSHA = head
        input.baseSHA = try D.commit(String(repeating: "b", count: 40))
        input.conflicts = ["README.md", "src/limit.ts"]
        #expect(ConflictResult.check(examples[0], input: input) == .success(.resolved))
        guard case .success(.needsYou(let reason)) = ConflictResult.check(examples[1], input: input)
        else {
            Issue.record("the needs-you example is not a good result")
            return
        }
        #expect(reason.hasPrefix("Both sides"))
        let own = OwnRequestFile.check(
            examples[2], pr: pr, head: head, changed: ["src/cache.ts", "src/cache.test.ts"])
        #expect(own.map(\.paths) == .success(["src/cache.ts", "src/cache.test.ts"]))
        // The section of the own request is the one that the request mode has.
        #expect(mode.contains("## A request from the user between rounds"))
    }

    // A conflict round keeps to the conflict. The mode file finds the merge of a round by the
    // message of the auto commit, and then makes no change for a request of the user. It gives no
    // way to delete a file.
    @Test func theModeFileKeepsARoundToTheConflict() throws {
        let mode = try modeFile()
        #expect(mode.contains("`\(ConflictMerge.autoMessage)`"))
        #expect(mode.contains("git log -1 --format=%s"))
        #expect(!mode.contains("`rm`"))
        #expect(mode.contains("Never delete a file in a round."))
    }

    // The mode file of the skill names each field of the input file and of the result file, so a
    // new field never goes unexplained to Claude.
    @Test func theModeFileNamesEachFieldOfTheInputAndTheResult() throws {
        let mode = try modeFile()
        let json = try #require(try ConflictData.input().json.object)
        var names: [String] = []
        for (key, value) in json {
            names.append(key)
            for inner in value.object.map({ Array($0.keys) }) ?? [] {
                names.append("\(key).\(inner)")
            }
        }
        names += ["headSha", "baseSha", "outcome", "reason", "resolved", "needs-you"]
        for name in names {
            #expect(mode.contains("`\(name)`"), "\(name)")
        }
    }
}

// The text of the Bifrost mode file of the conflict skill in the repo.
private func modeFile() throws -> String {
    try String(
        contentsOf: try Repo.root().appending(
            path: "App/Bifrost/Resources/bifrost-skills/skills/bifrost-resolve-conflicts/"
                + "bifrost-mode.md"),
        encoding: .utf8)
}
