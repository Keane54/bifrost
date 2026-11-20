// The files of one round in the round folder of a PR (docs/behaviour/reviews.md, "Request
// rounds"). The round folder stays from round to round, because the one session of the PR has it
// as a working folder. So each file name has the round ID: a file of an earlier round, or a late
// write of its session, never counts as a file of this round.
import Foundation

package struct RoundFiles: Sendable, Equatable {
    // The round folder of the PR.
    package let folder: URL
    // The first 12 hex digits of the token of the round. The token is a UUID in lower case. Only
    // its hex digits count, so a name never holds a path character.
    package let id: String

    package init(folder: URL, token: String) {
        self.folder = folder
        id = String(token.filter { $0.isASCII && $0.isHexDigit }.prefix(12))
    }

    // input-<id>.json
    package var input: URL { file("input", "json") }
    // result-<id>.json
    package var result: URL { file("result", "json") }

    // <stem>-<id>.<ext> in the round folder, for example mode-<id>.md or log-<job>-<id>.txt.
    package func file(_ stem: String, _ ext: String) -> URL {
        folder.appending(path: "\(stem)-\(id).\(ext)", directoryHint: .notDirectory)
    }
}
