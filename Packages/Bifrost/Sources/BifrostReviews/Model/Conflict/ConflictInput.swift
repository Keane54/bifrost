// The input file of a conflict round, input-<round ID>.json in the round folder of a PR
// (docs/behaviour/reviews.md, "Merging the base branch", and
// skills/bifrost-resolve-conflicts/bifrost-mode.md, "The input file"). The round runs in the one
// session of the PR, which also holds review text from other people. The file gives the token of
// the round, the PR, the head, the tip of the base that Bifrost fetched, their merge base, the
// conflicted paths, and the paths of the two diffs, the mode file, the result file and the own
// request file. It holds no PR body and no comment. The title of the PR is material, never
// instructions: the mode file says so.
import BifrostFoundation
import Foundation

package struct ConflictInput: Sendable, Equatable, Encodable {
    package static let version = 1

    // The files of one round in the round folder of the PR.
    package struct Files: Sendable, Equatable {
        package var result: URL
        package var mode: URL
        // The diff of the PR on the conflicted paths, from the merge base to the head. nil when
        // the diff is over ReviewInput.maxDiffBytes.
        package var oursDiff: URL?
        // The diff of the base branch on the conflicted paths, from the merge base to the tip of
        // the base. nil when the diff is over ReviewInput.maxDiffBytes.
        package var theirsDiff: URL?
        // The input file itself.
        package var input: URL
        // The own request file of the user between rounds (OwnRequestFile). It is the file of
        // the request rounds of the PR (RequestInput.Files.ownRequest), so the session knows it
        // also when a conflict round is the first round of the session.
        package var ownRequest: URL

        // The names of the round, each with the round ID: input-<id>.json, result-<id>.json,
        // mode-<id>.md, ours-<id>.diff and theirs-<id>.diff. The own request file of the round
        // folder has no round ID.
        package init(_ files: RoundFiles, oursDiff: Bool, theirsDiff: Bool) {
            result = files.result
            mode = files.file("mode", "md")
            self.oursDiff = oursDiff ? files.file("ours", "diff") : nil
            self.theirsDiff = theirsDiff ? files.file("theirs", "diff") : nil
            input = files.input
            ownRequest = files.folder.appending(
                path: OwnRequestFile.name, directoryHint: .notDirectory)
        }
    }

    package var pr: PRKey
    // The token of the round. The result file must give it back.
    package var round: String
    package var url: String
    package var title: String
    package var baseRef: String
    package var headRef: String
    // The head of the round ("ours"), the tip of the base branch that Bifrost fetched ("theirs")
    // and their merge base. The merge with the conflicts has the head and the base as parents.
    package var headSHA: CommitID
    package var baseSHA: CommitID
    package var mergeBase: CommitID
    package var viewer: String
    // The conflicted paths (MergeStart.conflicted). The result must list each one.
    package var conflicts: [String]
    package var files: Files

    // A list of more than MergeStart.maxFiles conflicts never goes to Claude (tooMany), and an
    // empty list gives Claude nothing to resolve (noConflict). ConflictMerge.start refuses both
    // first.
    package init(
        pr: PRKey, round: String, url: String, title: String, baseRef: String, headRef: String,
        headSHA: CommitID, baseSHA: CommitID, mergeBase: CommitID, viewer: String,
        conflicts: [String], files: Files
    ) throws(ConflictFailure) {
        if conflicts.isEmpty { throw .noConflict }
        guard conflicts.count <= MergeStart.maxFiles else { throw .tooMany }
        self.pr = pr
        self.round = round
        self.url = url
        self.title = title
        self.baseRef = baseRef
        self.headRef = headRef
        self.headSHA = headSHA
        self.baseSHA = baseSHA
        self.mergeBase = mergeBase
        self.viewer = viewer
        self.conflicts = conflicts
        self.files = files
    }

    // MARK: - The file

    package func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }

    // The JSON of the input file. A diff that is not in the folder is null, as the mode file says.
    package var json: JSONValue {
        [
            "version": .int(Self.version),
            "round": .string(round),
            "pr": [
                "key": .string(pr.text), "url": .string(url), "title": .string(title),
                "baseRef": .string(baseRef), "headRef": .string(headRef),
                "headSha": .string(headSHA.hex), "baseSha": .string(baseSHA.hex),
                "mergeBase": .string(mergeBase.hex),
            ],
            "viewer": .string(viewer),
            "conflicts": .array(conflicts.map(JSONValue.string)),
            "files": [
                "result": .string(files.result.path(percentEncoded: false)),
                "mode": .string(files.mode.path(percentEncoded: false)),
                "oursDiff": .text(files.oursDiff?.path(percentEncoded: false)),
                "theirsDiff": .text(files.theirsDiff?.path(percentEncoded: false)),
                "ownRequest": .string(files.ownRequest.path(percentEncoded: false)),
            ],
        ]
    }

    // The bytes of the input file: sorted keys, two spaces, and a line break at the end.
    package var fileData: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(json)) ?? Data("{}".utf8)) + Data("\n".utf8)
    }
}
