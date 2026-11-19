// The ignore list of Reviews (docs/behaviour/reviews.md, "The rows"): the repositories that show
// no row. An entry is owner/repo or owner/*. The match ignores case, as GitHub names do.
import BifrostFoundation

// One entry of the ignore list, in its clean form: trimmed and in lower case.
package struct IgnoreEntry: Sendable, Hashable, CustomStringConvertible {
    // The owner, in lower case.
    package let owner: String
    // The repository, in lower case. nil for owner/*, which ignores each repository of the owner.
    package let name: String?

    // The rule of an entry: the owner has 1 to 39 ASCII letters, digits or "-", and starts with a
    // letter or a digit. The repository is "*", or 1 to 100 ASCII letters, digits, ".", "_" or
    // "-". The settings store each entry in this clean form.
    package init?(_ text: String) {
        let entry = text.trimmed().lowercased()
        guard let slash = entry.firstIndex(of: "/") else { return nil }
        let owner = entry[..<slash]
        let name = entry[entry.index(after: slash)...]
        guard let first = owner.utf8.first, Self.isLetterOrDigit(first), owner.utf8.count <= 39,
            owner.utf8.allSatisfy({ Self.isLetterOrDigit($0) || $0 == UInt8(ascii: "-") })
        else { return nil }
        self.owner = String(owner)
        if name == "*" {
            self.name = nil
            return
        }
        let marks: Set<UInt8> = [UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-")]
        guard (1...100).contains(name.utf8.count),
            name.utf8.allSatisfy({ Self.isLetterOrDigit($0) || marks.contains($0) })
        else { return nil }
        self.name = String(name)
    }

    // owner/repo or owner/*, in lower case.
    package var text: String { "\(owner)/\(name ?? "*")" }

    package var description: String { text }

    // True when the entry names the repository, or each repository of its owner.
    package func matches(_ repo: RepoName) -> Bool {
        repo.owner.lowercased() == owner && (name == nil || repo.name.lowercased() == name)
    }

    private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): true
        default: false
        }
    }
}

package enum IgnoreRule {
    // The most entries of the list.
    package static let maxEntries = 50

    package static let badEntry = "Use owner/repo or owner/*."
    package static let copy = "That repository is already in the list."
    package static let full = "You can keep up to \(maxEntries) entries."

    // True when an entry of the list names the repository.
    package static func matches(_ entries: [IgnoreEntry], _ repo: RepoName) -> Bool {
        entries.contains { $0.matches(repo) }
    }

    // The friendly reason why the list refuses the text as a new entry, or nil when the list
    // takes it: an entry of the wrong form, an entry that the list has, or a full list.
    package static func refusal(_ text: String, list: [IgnoreEntry] = []) -> String? {
        guard let entry = IgnoreEntry(text) else { return badEntry }
        if list.contains(entry) { return copy }
        return list.count >= maxEntries ? full : nil
    }
}
