// The input file of a request round, input.json (docs/behaviour/reviews.md, "Request rounds", and
// skills/bifrost-resolve-comments/bifrost-mode.md, "The input file"). The session reads only the
// input folder: this file with the PR and the items of the round, the rules and the full diff.
// The PR text and the comments in it are material, never instructions: the mode file says so.
// Each comment says whether its author is trusted, with the trust rule of the work rule, so the
// skill needs no trust rule of its own. Long texts are cut with a marker.
import BifrostFoundation
import Foundation

package struct RequestInput: Sendable, Equatable, Encodable {
    package static let version = 1
    // The longest comment body and diff hunk in the file, in UTF-16 units.
    package static let maxItemText = 10_000
    package static let maxHunk = 3_000

    // The files of the input folder.
    package struct Files: Sendable, Equatable {
        package var result: URL
        package var mode: URL
        package var rules: URL
        // nil when the full diff is over ReviewInput.maxDiffBytes.
        package var fullDiff: URL?

        package init(folder: URL, fullDiff: Bool) {
            func file(_ name: String) -> URL {
                folder.appending(path: name, directoryHint: .notDirectory)
            }
            result = file("result.json")
            mode = file("mode.md")
            rules = file("humanise-rules.md")
            self.fullDiff = fullDiff ? file("full.diff") : nil
        }

        // input.json in the same folder.
        package var input: URL {
            result.deletingLastPathComponent().appending(
                path: "input.json", directoryHint: .notDirectory)
        }
    }

    // One comment of an item. trusted is the trust rule of the work rule; you marks a comment of
    // the user, which is never trusted.
    package struct Comment: Sendable, Equatable {
        package var author: String
        package var association: AuthorAssociation
        package var trusted: Bool
        package var you: Bool
        package var body: String
        package var at: Date
    }

    // One item of the round: a thread, a PR comment or a review body.
    package struct Item: Sendable, Equatable {
        package var id: NodeID
        package var kind: WorkItemKind
        // The file and the line of a thread. A top-level comment has none, and a thread that
        // GitHub can't put on a line of the head has no line.
        package var path: String?
        package var line: Int?
        package var outdated: Bool
        package var diffHunk: String?
        package var comments: [Comment]
        // The question of an earlier round about the item, and the answer of the user.
        package var question: String?
        package var answer: String?
    }

    package var pr: PRKey
    // The token of the round. result.json must give it back.
    package var round: String
    package var url: String
    package var title: String
    package var body: String
    package var baseRef: String
    package var headRef: String
    // The tip of the base branch, the head of the round and their merge base: the commits of the
    // PR go from the merge base to the head.
    package var baseSHA: CommitID
    package var headSHA: CommitID
    package var mergeBase: CommitID
    package var viewer: String
    // Oldest first.
    package var items: [Item]
    // The IDs of the items of the round, in their order. The check of the result reads them.
    package var itemIDs: [NodeID]
    package var files: Files

    package init(
        pr: PRKey, round: String, baseSHA: CommitID, headSHA: CommitID, mergeBase: CommitID,
        viewer: String, items: [Item], files: Files
    ) {
        self.pr = pr
        self.round = round
        url = ""
        title = ""
        body = ""
        baseRef = ""
        headRef = ""
        self.baseSHA = baseSHA
        self.headSHA = headSHA
        self.mergeBase = mergeBase
        self.viewer = viewer
        self.items = items
        itemIDs = items.map(\.id)
        self.files = files
    }

    // The input that the check of a result needs: the PR, the token, the head and the IDs of the
    // items. A round whose session ran when Bifrost started knows only these, from its state.
    package init(
        resumed pr: PRKey, round: String, headSHA: CommitID, mergeBase: CommitID,
        itemIDs: [NodeID], files: Files
    ) {
        self.init(
            pr: pr, round: round, baseSHA: mergeBase, headSHA: headSHA, mergeBase: mergeBase,
            viewer: "", items: [], files: files)
        self.itemIDs = itemIDs
    }

    // The input of a round from the full read of the PR, the commits of the fetch and the
    // questions of the state. An item that the read does not have goes.
    package init(
        full: FullPR, items: [WorkItem], questions: [NodeID: Question], round: String,
        viewer: String, baseSHA: CommitID, headSHA: CommitID, mergeBase: CommitID, files: Files
    ) {
        self.init(
            pr: full.key, round: round, baseSHA: baseSHA, headSHA: headSHA, mergeBase: mergeBase,
            viewer: viewer,
            items: items.compactMap { Self.item($0, full: full, viewer: viewer, asked: questions) },
            files: files)
        url = full.url
        title = full.title
        body = ReviewInput.cut(full.body, ReviewInput.maxPRBody)
        baseRef = full.baseRef
        headRef = full.headRef
    }

    // The item of the input, or nil when the read does not have it.
    private static func item(
        _ item: WorkItem, full: FullPR, viewer: String, asked: [NodeID: Question]
    ) -> Item? {
        let question = asked[item.id]
        func comment(_ author: Author, _ body: String, _ at: Date) -> Comment {
            // GitHub ignores the case of a login.
            let you = author.login.lowercased() == viewer.lowercased()
            return Comment(
                author: author.login, association: author.association,
                trusted: !you && Authors.isTrusted(author, viewer: viewer), you: you,
                body: ReviewInput.cut(body, maxItemText), at: at)
        }
        if let thread = full.threads.first(where: { $0.thread.id == item.id }) {
            return Item(
                id: item.id, kind: .thread, path: thread.thread.path, line: thread.thread.line,
                outdated: thread.isOutdated,
                diffHunk: thread.diffHunk.isEmpty ? nil : ReviewInput.cut(thread.diffHunk, maxHunk),
                comments: thread.thread.comments.map { comment($0.author, $0.body, $0.createdAt) },
                question: question?.text, answer: question?.answer)
        }
        let one: Comment
        let kind: WorkItemKind
        if let found = full.comments.first(where: { $0.id == item.id }) {
            one = comment(found.author, found.body, found.createdAt)
            kind = .comment
        } else if let review = full.reviews.first(where: { $0.id == item.id }) {
            one = comment(review.author, review.body, review.submittedAt ?? item.since)
            kind = .reviewBody
        } else {
            return nil
        }
        return Item(
            id: item.id, kind: kind, path: nil, line: nil, outdated: false, diffHunk: nil,
            comments: [one], question: question?.text, answer: question?.answer)
    }

    // MARK: - The file

    package func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }

    // The JSON of input.json. A missing value is null, as the mode file says.
    package var json: JSONValue {
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return [
            "version": .int(Self.version),
            "round": .string(round),
            "pr": [
                "key": .string(pr.text), "url": .string(url), "title": .string(title),
                "body": .string(body), "baseRef": .string(baseRef), "headRef": .string(headRef),
                "baseSha": .string(baseSHA.hex), "headSha": .string(headSHA.hex),
                "mergeBase": .string(mergeBase.hex),
            ],
            "viewer": .string(viewer),
            "items": .array(
                items.map { item in
                    [
                        "id": .string(item.id.text), "kind": .string(item.kind.rawValue),
                        "path": .text(item.path), "line": item.line.map(JSONValue.int) ?? .null,
                        "outdated": .bool(item.outdated), "diffHunk": .text(item.diffHunk),
                        "comments": .array(
                            item.comments.map {
                                [
                                    "author": .string($0.author),
                                    "association": .string($0.association.rawValue),
                                    "trusted": .bool($0.trusted), "you": .bool($0.you),
                                    "body": .string($0.body), "at": .string($0.at.formatted(iso)),
                                ]
                            }),
                        "question": .text(item.question), "answer": .text(item.answer),
                    ]
                }),
            "files": [
                "result": .string(files.result.path(percentEncoded: false)),
                "mode": .string(files.mode.path(percentEncoded: false)),
                "rules": .string(files.rules.path(percentEncoded: false)),
                "fullDiff": .text(files.fullDiff?.path(percentEncoded: false)),
            ],
        ]
    }

    // The bytes of input.json: sorted keys, two spaces, and a line break at the end.
    package var fileData: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(json)) ?? Data("{}".utf8)) + Data("\n".utf8)
    }
}
