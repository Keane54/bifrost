// A version of Claude Code: three whole numbers, for example 2.1.290. Two versions compare part
// by part as numbers, so 2.10.0 is later than 2.9.9. The text form is <major>.<minor>.<patch>.
package struct ClaudeCodeVersion: Sendable, Hashable, Comparable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    package let major: Int
    package let minor: Int
    package let patch: Int

    package init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    // The first version number in the text: three groups of ASCII digits with a dot between
    // them, for example 2.1.290 in "2.1.290 (Claude Code)". A zero at the start of a part changes
    // nothing. nil when the text has none, or when a part is too large for an Int.
    package init?(firstIn text: String) {
        guard let match = text.firstMatch(of: /([0-9]+)\.([0-9]+)\.([0-9]+)/),
            let major = Int(match.output.1), let minor = Int(match.output.2),
            let patch = Int(match.output.3)
        else { return nil }
        self.init(major, minor, patch)
    }

    // A version that the code gives, for example "2.1.290". Only code gives a literal, so a
    // literal that is not the text form of a version is a fault of the code, and it stops the
    // app.
    package init(stringLiteral text: String) {
        guard let version = Self(firstIn: text), version.description == text else {
            preconditionFailure("The literal is not a version of Claude Code: \(text)")
        }
        self = version
    }

    package static func < (a: Self, b: Self) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    package var description: String { "\(major).\(minor).\(patch)" }
}
