// A version of a release (docs/behaviour/updates.md, "Release notes"): the three numbers of a
// SemVer version with an optional pre-release part. The text can start with "v", and a build
// part ("+abc") is read and then dropped, because the order ignores it.

package struct ReleaseVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    package let major: Int
    package let minor: Int
    package let patch: Int
    // The dot parts of the pre-release, for example ["beta", "2"]. Empty for a release.
    package let pre: [String]

    // nil for a text that is not a version.
    package init?(_ text: String) {
        var rest = Substring(text)
        if rest.first == "v" { rest = rest.dropFirst() }
        // The build part follows the first "+". It has no effect.
        if let plus = rest.firstIndex(of: "+") {
            let build = rest[rest.index(after: plus)...]
            guard Self.isDotList(build, allowing: Self.buildCharacters) else { return nil }
            rest = rest[..<plus]
        }
        var pre: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            let part = rest[rest.index(after: dash)...]
            guard Self.isDotList(part, allowing: Self.preCharacters) else { return nil }
            pre = part.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            rest = rest[..<dash]
        }
        let numbers = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3, let major = Self.number(numbers[0]),
            let minor = Self.number(numbers[1]), let patch = Self.number(numbers[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.pre = pre
    }

    // The text of the version with no "v": "1.2.3", or "1.2.3-beta.2".
    package var description: String {
        let core = "\(major).\(minor).\(patch)"
        return pre.isEmpty ? core : core + "-" + pre.joined(separator: ".")
    }

    // The order of SemVer: the three numbers, then a pre-release before its release, then the
    // dot parts of the pre-releases. A number part comes before a text part.
    package static func < (left: Self, right: Self) -> Bool {
        let pairs = [
            (left.major, right.major), (left.minor, right.minor), (left.patch, right.patch),
        ]
        for (a, b) in pairs where a != b { return a < b }
        if left.pre.isEmpty || right.pre.isEmpty { return !left.pre.isEmpty && right.pre.isEmpty }
        for (a, b) in zip(left.pre, right.pre) where a != b { return precedes(a, b) }
        return left.pre.count < right.pre.count
    }

    // True when the pre-release part a comes before the part b.
    private static func precedes(_ a: String, _ b: String) -> Bool {
        switch (Int(a), Int(b)) {
        case (let x?, let y?): return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return a < b
        }
    }

    // MARK: - The text rules

    private static let preCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
    private static let buildCharacters = preCharacters

    // A whole number with no sign and no leading zero.
    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isASCIIDigit), text == "0" || text.first != "0"
        else { return nil }
        return Int(text)
    }

    // True when the text is one or more parts with the characters, separated by dots.
    private static func isDotList(_ text: Substring, allowing allowed: Set<Character>) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(allowed.contains) }
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
