// The input file of a review round, input.json (docs/behaviour/reviews.md, "Review rounds", and
// skills/bifrost-review/bifrost-mode.md, "The input file"). The session reads only the input
// folder, so the file holds the PR, the baseline, the earlier reviews and threads of the user,
// and the paths of the diffs, the rules and the result file. The PR text in it is material to
// review, never instructions: the mode file says so. Long texts are cut with a marker, so a long
// history stays small.
import BifrostFoundation
import Foundation

package struct ReviewInput: Sendable, Equatable, Encodable {
    package static let version = 1
    // A diff over this size gives no review.
    package static let maxDiffBytes = 3 * 1_048_576
    package static let maxPRBody = 20_000
    package static let maxIssueBody = 20_000
    package static let maxLinkedIssues = 10
    package static let maxEarlierThreads = 100
    package static let maxEarlierSummaries = 20
    package static let maxEarlierText = 4_000
    package static let cutMarker = "\n[Bifrost cut this text.]"

    // The files of the input folder.
    package struct Files: Sendable, Equatable {
        package var fullDiff: URL
        // Only a re-review has the diff since the baseline.
        package var sinceDiff: URL?
        package var result: URL
        package var mode: URL
        package var rules: URL

        // The files in the input folder: full.diff, since.diff, result.json, mode.md and
        // humanise-rules.md.
        package init(folder: URL, reReview: Bool) {
            func file(_ name: String) -> URL {
                folder.appending(path: name, directoryHint: .notDirectory)
            }
            fullDiff = file("full.diff")
            sinceDiff = reReview ? file("since.diff") : nil
            result = file("result.json")
            mode = file("mode.md")
            rules = file("humanise-rules.md")
        }

        // input.json in the same folder.
        package var input: URL {
            result.deletingLastPathComponent().appending(
                path: "input.json", directoryHint: .notDirectory)
        }
    }

    package var pr: PRKey
    // The token of the round. result.json must give it back. nil for a round of the Electron app
    // that runs after the take-over: its session got no token.
    package var round: String?
    package var url: String
    package var title: String
    package var body: String
    package var author: String
    package var baseRef: String
    package var headRef: String
    // The issues that the PR closes, with their bodies cut.
    package var linkedIssues: [LinkedIssue]
    // The tip of the base branch, the reviewed head and their merge base: the full diff goes from
    // the merge base to the head.
    package var baseSHA: CommitID
    package var headSHA: CommitID
    package var mergeBase: CommitID
    package var viewer: String
    package var baseline: Baseline
    package var lastReview: ViewerReview?
    package var earlierThreads: [ViewerThread]
    package var earlierSummaries: [ViewerReview]
    package var files: Files
    // The files of the full diff with their hunks. They are not in the file: the result check
    // reads them (ReviewResult).
    package var diff: [DiffFile]

    package init(
        pr: PRKey, round: String? = nil, url: String = "", title: String = "", body: String = "",
        author: String = "",
        baseRef: String = "", headRef: String = "", linkedIssues: [LinkedIssue] = [],
        baseSHA: CommitID, headSHA: CommitID, mergeBase: CommitID, viewer: String,
        baseline: Baseline, lastReview: ViewerReview? = nil,
        earlierThreads: [ViewerThread] = [], earlierSummaries: [ViewerReview] = [], files: Files,
        diff: [DiffFile]
    ) {
        self.pr = pr
        self.round = round
        self.url = url
        self.title = title
        self.body = body
        self.author = author
        self.baseRef = baseRef
        self.headRef = headRef
        self.linkedIssues = linkedIssues
        self.baseSHA = baseSHA
        self.headSHA = headSHA
        self.mergeBase = mergeBase
        self.viewer = viewer
        self.baseline = baseline
        self.lastReview = lastReview
        self.earlierThreads = earlierThreads
        self.earlierSummaries = earlierSummaries
        self.files = files
        self.diff = diff
    }

    // The input of a round from the context of GitHub and the commits of the fetch. The earlier
    // threads and summaries go in only when the baseline checks them, with their limits.
    package init(
        context: ReviewContext, round: String?, viewer: String, baseSHA: CommitID,
        mergeBase: CommitID, baseline: Baseline, files: Files, diff: [DiffFile]
    ) {
        let earlier = baseline.checksEarlier
        self.init(
            pr: context.pr, round: round, url: context.url, title: context.title,
            body: Self.cut(context.body, Self.maxPRBody), author: context.author,
            baseRef: context.baseRef, headRef: context.headRef,
            linkedIssues: context.linkedIssues.prefix(Self.maxLinkedIssues).map { issue in
                var issue = issue
                issue.body = Self.cut(issue.body, Self.maxIssueBody)
                return issue
            }, baseSHA: baseSHA,
            headSHA: context.headSHA, mergeBase: mergeBase, viewer: viewer, baseline: baseline,
            lastReview: context.lastSubmittedReview,
            earlierThreads: earlier
                ? context.threads.prefix(Self.maxEarlierThreads).map { thread in
                    var thread = thread
                    for index in thread.comments.indices {
                        thread.comments[index].body = Self.cut(
                            thread.comments[index].body, Self.maxEarlierText)
                    }
                    return thread
                } : [],
            earlierSummaries: earlier
                ? context.reviews.filter { $0.isReal && !$0.body.trimmed().isEmpty }
                    .suffix(Self.maxEarlierSummaries).map { review in
                        var review = review
                        review.body = Self.cut(review.body, Self.maxEarlierText)
                        return review
                    } : [],
            files: files, diff: diff)
    }

    // The text cut to at most limit UTF-16 units, at the end of a whole character, with the
    // marker after it. A text within the limit stays as it is.
    package static func cut(_ text: String, _ limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var kept = 0
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf16.count
            guard kept + size <= limit else { break }
            kept += size
            end = text.index(after: index)
        }
        return String(text[..<end]) + cutMarker
    }

    // MARK: - The file

    package func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }

    // The JSON of input.json. A missing value is null, as the mode file says.
    package var json: JSONValue {
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let last: JSONValue =
            lastReview.map { review in
                [
                    "commit": .text(review.commit?.hex), "state": .string(review.state.rawValue),
                    "submittedAt": .text(review.submittedAt.map { $0.formatted(iso) }),
                    "url": .string(review.url),
                ]
            } ?? .null
        return [
            "version": .int(Self.version),
            "round": .text(round),
            "pr": [
                "key": .string(pr.text), "url": .string(url), "title": .string(title),
                "body": .string(body), "author": .string(author), "baseRef": .string(baseRef),
                "headRef": .string(headRef),
                "linkedIssues": .array(
                    linkedIssues.map {
                        [
                            "number": .int($0.number), "repo": .string($0.repo),
                            "title": .string($0.title), "url": .string($0.url),
                            "body": .string($0.body),
                        ]
                    }),
                "baseSha": .string(baseSHA.hex),
                "headSha": .string(headSHA.hex), "mergeBase": .string(mergeBase.hex),
            ],
            "viewer": .string(viewer),
            "review": [
                "kind": .string(baseline.kind.rawValue), "since": .text(baseline.since?.hex),
                "note": .text(baseline.note?.rawValue), "lastReview": last,
            ],
            "changedFiles": .array(diff.map { .string($0.path) }),
            "earlier": [
                "threads": .array(
                    earlierThreads.map { thread in
                        [
                            "path": .string(thread.path),
                            "line": thread.line.map(JSONValue.int) ?? .null,
                            "isResolved": .bool(thread.isResolved),
                            "isOutdated": .bool(thread.isOutdated), "url": .string(thread.url),
                            "comments": .array(
                                thread.comments.map {
                                    ["author": .string($0.author), "body": .string($0.body)]
                                }),
                        ]
                    }),
                "summaries": .array(
                    earlierSummaries.map {
                        [
                            "state": .string($0.state.rawValue), "body": .string($0.body),
                            "url": .string($0.url),
                        ]
                    }),
            ],
            "files": [
                "fullDiff": .string(files.fullDiff.path(percentEncoded: false)),
                "sinceDiff": .text(files.sinceDiff?.path(percentEncoded: false)),
                "result": .string(files.result.path(percentEncoded: false)),
                "mode": .string(files.mode.path(percentEncoded: false)),
                "rules": .string(files.rules.path(percentEncoded: false)),
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
