// The name of a GitHub repository: an owner and a name. The init refuses each text that could
// leave the folder of the clones when it is a part of a path.
package struct RepoName: Sendable, Hashable, Comparable, CustomStringConvertible {
    package let owner: String
    package let name: String

    // Each part has 1 to 100 of A-Z a-z 0-9 . _ - and is not "." or "..". It does not start with
    // "-".
    package init?(owner: String, name: String) {
        guard Self.isValid(owner), Self.isValid(name) else { return nil }
        self.owner = owner
        self.name = name
    }

    // The text "owner/name".
    package init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        self.init(owner: String(parts[0]), name: String(parts[1]))
    }

    // "owner/name" in lower case. GitHub names have no case, so the key names a path and a state
    // entry.
    package var key: String { "\(owner)/\(name)".lowercased() }

    package var description: String { "\(owner)/\(name)" }

    // The equality, the hash and the order use the key, so "Owner-A/Repo" and "owner-a/repo" are
    // one repository, as on GitHub. The description keeps the case that GitHub gave.
    package static func == (left: RepoName, right: RepoName) -> Bool {
        left.key == right.key
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }

    package static func < (left: RepoName, right: RepoName) -> Bool {
        left.key < right.key
    }

    private static func isValid(_ part: String) -> Bool {
        let bytes = part.utf8
        guard (1...100).contains(bytes.count), part != ".", part != ".." else { return false }
        guard bytes.first != UInt8(ascii: "-") else { return false }
        return bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "_"),
                UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }
}

// The stored form is the text "owner/name" in the case that GitHub gave, as the Electron state
// keys are. A text that is not a valid name does not decode.
extension RepoName: Codable {
    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let name = RepoName(text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a repository name.")
        }
        self = name
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
