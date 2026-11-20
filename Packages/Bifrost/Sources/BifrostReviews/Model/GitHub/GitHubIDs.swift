// The IDs that the GitHub writes and the git commands of Reviews take (docs/behaviour/reviews.md,
// "Safety"). Each init refuses each text that could change the target of a write: a PR key comes
// only from a GitHub PR address or a state key, a commit ID is full hex, and a branch name is a
// name that git accepts and that cannot read as a flag, a refspec or a range.
import Foundation

// One pull request: its repository and its number. The text keeps the case that GitHub gave, as
// the keys of state.json do. The equality, the hash and the order use the repository (with no
// case) and the number, so a state key in another case finds its PR. The stored form is the text.
package struct PRKey: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    package let repo: RepoName
    package let number: Int
    // https://github.com/<owner>/<repo>/pull/<number>
    package let webURL: URL

    // The number is 1 to 10 digits, with no sign and no zero first, as on GitHub.
    package init?(repo: RepoName, number: Int) {
        guard (1...9_999_999_999).contains(number),
            let url = URL(string: "https://github.com/\(repo.owner)/\(repo.name)/pull/\(number)")
        else { return nil }
        self.repo = repo
        self.number = number
        webURL = url
    }

    // Only https://github.com/<owner>/<repo>/pull/<n>: no other scheme, host, port, user, path,
    // query or fragment.
    package init?(url: String) {
        let prefix = "https://github.com/"
        guard url.hasPrefix(prefix) else { return nil }
        let parts = url.dropFirst(prefix.count).split(
            separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[2] == "pull",
            let repo = RepoName(owner: String(parts[0]), name: String(parts[1])),
            let number = Self.number(parts[3])
        else { return nil }
        self.init(repo: repo, number: number)
    }

    // "Owner/Repo#n": the key of state.json.
    package init?(text: String) {
        guard let hash = text.lastIndex(of: "#"), let repo = RepoName(String(text[..<hash])),
            let number = Self.number(text[text.index(after: hash)...])
        else { return nil }
        self.init(repo: repo, number: number)
    }

    package var text: String { "\(repo.description)#\(number)" }

    package var description: String { text }

    package static func == (left: PRKey, right: PRKey) -> Bool {
        left.repo == right.repo && left.number == right.number
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(repo)
        hasher.combine(number)
    }

    package static func < (left: PRKey, right: PRKey) -> Bool {
        left.repo == right.repo ? left.number < right.number : left.repo < right.repo
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let key = PRKey(text: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a PR key.")
        }
        self = key
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    // A number of 1 to 10 ASCII digits with no zero first.
    private static func number(_ text: Substring) -> Int? {
        guard (1...10).contains(text.utf8.count), text.utf8.first != UInt8(ascii: "0"),
            text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { return nil }
        return Int(text)
    }
}

// The ID of a git commit: 40 (SHA-1) or 64 (SHA-256) lower-case hex characters.
package struct CommitID: Sendable, Hashable, Codable, CustomStringConvertible {
    package let hex: String

    package init?(_ hex: String) {
        guard Self.isObjectID(hex) else { return nil }
        self.hex = hex
    }

    // The short form of the "Fixed by" replies: the first 7 characters.
    package var short: String { String(hex.prefix(7)) }

    package var description: String { hex }

    // True for the full ID of a git object: a commit, a tree or a blob.
    package static func isObjectID(_ text: String) -> Bool {
        let bytes = text.utf8
        return (bytes.count == 40 || bytes.count == 64)
            && bytes.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            }
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let commit = CommitID(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a commit ID.")
        }
        self = commit
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

// The name of a branch on GitHub, for the push target and the signed commit. The init refuses
// each text that `git check-ref-format --branch` refuses, a text that starts with "-", "+" or
// ":", and HEAD and "@". So the push refspec <commit>:refs/heads/<name> can never force, delete
// or name another ref.
package struct BranchName: Sendable, Hashable, Codable, CustomStringConvertible {
    package let text: String

    package init?(_ text: String) {
        guard Self.isValid(text) else { return nil }
        self.text = text
    }

    package var description: String { text }

    private static func isValid(_ text: String) -> Bool {
        guard !text.isEmpty, text != "HEAD", text != "@", let first = text.unicodeScalars.first,
            !"-+:/".unicodeScalars.contains(first), !text.hasSuffix("/"), !text.hasSuffix("."),
            !text.contains(".."), !text.contains("@{"), !text.contains("//")
        else { return false }
        // A control character, a space or a character that a refspec or a pattern uses.
        let refused = " ~^:?*[\\".unicodeScalars
        guard
            !text.unicodeScalars.contains(where: {
                $0.value < 0x20 || $0.value == 0x7F || refused.contains($0)
            })
        else { return false }
        return text.split(separator: "/").allSatisfy { part in
            !part.hasPrefix(".") && !part.hasSuffix(".lock")
        }
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let name = BranchName(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a branch name.")
        }
        self = name
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

// The ID of a GitHub node (a PR, a review, a thread, a comment or a user), for example
// PRRT_kwDOexample1. A legacy node ID is base64, so it can end with one or two "=".
package struct NodeID: Sendable, Hashable, Codable, CustomStringConvertible {
    package let text: String

    package init?(_ text: String) {
        let body = text.utf8.reversed().drop { $0 == UInt8(ascii: "=") }
        let padding = text.utf8.count - body.count
        guard (1...100).contains(body.count), padding <= 2,
            body.allSatisfy({ byte in
                switch byte {
                case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                    UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"):
                    true
                default:
                    false
                }
            })
        else { return nil }
        self.text = text
    }

    package var description: String { text }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let id = NodeID(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a node ID.")
        }
        self = id
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

// The ID of a job of GitHub Actions: the databaseId of its check run. The read of the logs of a
// job and the re-run of the failed jobs take it. Only a number above 0 is an ID.
package struct JobID: Hashable, Comparable, Sendable {
    package let value: Int

    package init?(_ value: Int) {
        guard value > 0 else { return nil }
        self.value = value
    }

    package static func < (left: JobID, right: JobID) -> Bool { left.value < right.value }
}

// The ID of a run of a workflow of GitHub Actions: the databaseId of the workflowRun of the check
// suite of a job. Only a number above 0 is an ID.
package struct RunID: Hashable, Comparable, Sendable {
    package let value: Int

    package init?(_ value: Int) {
        guard value > 0 else { return nil }
        self.value = value
    }

    package static func < (left: RunID, right: RunID) -> Bool { left.value < right.value }
}
