// The values of the tests of the review rounds: a PR, its commits, a small diff and the input of
// a round.
import BifrostFoundation
import Foundation
import Testing

@testable import BifrostReviews

enum ReviewData {
    static let headHex = String(repeating: "c", count: 40)
    static let baseHex = String(repeating: "a", count: 40)
    static let oldHex = String(repeating: "b", count: 40)

    static func pr(_ text: String = "Owner-A/Repo-A#7") throws -> PRKey {
        try #require(PRKey(text: text))
    }

    static func commit(_ hex: String = headHex) throws -> CommitID {
        try #require(CommitID(hex))
    }

    static func node(_ text: String) throws -> NodeID {
        try #require(NodeID(text))
    }

    // src/a.swift: a hunk of lines 10 to 13 on the left and 10 to 14 on the right, and a binary
    // file.
    static let diffText = """
        diff --git a/src/a.swift b/src/a.swift
        index 1111111..2222222 100644
        --- a/src/a.swift
        +++ b/src/a.swift
        @@ -10,4 +10,5 @@ struct A {
             let one = 1
        -    let two = 2
        +    let two = 3
        +    let three = 3
             let four = 4
             let five = 5
        diff --git a/img/logo.png b/img/logo.png
        index 3333333..4444444 100644
        Binary files a/img/logo.png and b/img/logo.png differ

        """

    static var diff: [DiffFile] { DiffLines.parse(diffText) }

    // The input of a first review of the PR at the head.
    static func input(diff: [DiffFile] = ReviewData.diff) throws -> ReviewInput {
        ReviewInput(
            pr: try pr(), baseSHA: try commit(baseHex), headSHA: try commit(),
            mergeBase: try commit(baseHex), viewer: "user-v", baseline: Baseline(kind: .first),
            files: ReviewInput.Files(
                folder: URL(filePath: "/tmp/io/7", directoryHint: .isDirectory),
                reReview: false),
            diff: diff)
    }

    // The bytes of a JSON object.
    static func json(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    // A good result file of a Request changes review with one comment, with a change.
    static func result(_ change: (inout [String: JSONValue]) -> Void = { _ in }) -> Data {
        var fields: [String: JSONValue] = [
            "version": 1, "pr": "Owner-A/Repo-A#7", "headSha": .string(headHex),
            "recommendation": "request-changes", "why": "The new limit check is off by one.",
            "summary": "One bug blocks this.",
            "comments": [
                ["path": "src/a.swift", "line": 11, "side": "RIGHT", "body": "Use `<` here."]
            ],
        ]
        change(&fields)
        return json(.object(fields))
    }

    // A change of the first comment of a result.
    static func comment(
        _ fields: inout [String: JSONValue], _ change: (inout [String: JSONValue]) -> Void
    ) {
        var items = fields["comments"]?.array ?? []
        var first = items.first?.object ?? [:]
        change(&first)
        items[0] = .object(first)
        fields["comments"] = .array(items)
    }
}
