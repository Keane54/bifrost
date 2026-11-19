// The release notes (docs/behaviour/updates.md, "Release notes"): the types of a release, the
// texts of the dialog, and the reading of the answer of the GitHub releases API. The release
// workflow writes each body: a summary, a "## <version>" heading, and a "### <Title>" heading
// for each section. Each item of a section is a line "* **scope:** text ([hash](url))", or the
// same line with no scope.
import Foundation

// One line of a section. The scope is the part in bold before the colon, or nil.
package struct ReleaseItem: Sendable, Equatable {
    package var scope: String?
    package var text: String

    package init(scope: String? = nil, text: String) {
        self.scope = scope
        self.text = text
    }
}

// A section that the dialog shows, with its friendly title, for example "New".
package struct ReleaseSection: Sendable, Equatable {
    package var title: String
    package var items: [ReleaseItem]

    package init(title: String, items: [ReleaseItem]) {
        self.title = title
        self.items = items
    }
}

// One release. The dialog gets the parsed body, never the raw text.
package struct Release: Sendable, Equatable {
    package var version: ReleaseVersion
    package var date: Date
    // The page of the release on GitHub.
    package var page: URL
    // The text before the first heading of the body. It can be empty.
    package var summary: String
    package var sections: [ReleaseSection]

    package init(
        version: ReleaseVersion, date: Date, page: URL, summary: String = "",
        sections: [ReleaseSection] = []
    ) {
        self.version = version
        self.date = date
        self.page = page
        self.summary = summary
        self.sections = sections
    }

    // True for a release with no summary and no shown section.
    package var isInternalOnly: Bool { summary.isEmpty && sections.isEmpty }
}

// The texts of the release notes dialog and of the Release notes button.
package enum ReleaseNotesText {
    package static let button = "Release notes"
    package static let close = "Close"
    package static let empty = "There are no release notes to show yet."
    package static let failed = "Couldn't load the release notes."
    package static let `internal` = "Small internal changes."
    package static let loading = "Loading the release notes…"
    package static let releasesPage = "Open the Releases page on GitHub"
    package static let title = "Release notes"
    package static let viewOnGitHub = "View on GitHub"
    package static let whatsNew = "What's new"

    // "10 Nov 2026". The time zone argument is for tests.
    package static func date(_ date: Date, zone: TimeZone = .current) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .abbreviated, time: .omitted, locale: Locale(identifier: "en_GB"),
                timeZone: zone))
    }
}

package enum ReleaseNotes {
    // The most releases that the app keeps from one answer.
    package static let maxReleases = 10

    // The sections that the dialog shows, in their order, each with the titles that the release
    // workflow gives it. The dialog hides each other section, for example Documentation, Code
    // Refactoring and Tests. The breaking changes show as "Changed" (user decision, 2026-11-10).
    // The conventional commits preset puts a warning sign before that title.
    private static let shown: [(friendly: String, titles: [String])] = [
        ("Changed", ["BREAKING CHANGES", "⚠ BREAKING CHANGES"]),
        ("New", ["Features"]),
        ("Fixed", ["Bug Fixes"]),
        ("Faster", ["Performance Improvements"]),
        ("Reverted", ["Reverts"]),
    ]

    // The releases of the answer of GitHub, newest version first, at most maxReleases. nil when
    // the answer is not a list. A draft, a pre-release and an entry that cannot be read are
    // dropped. With pagesUnder, a release whose page is not below that address is dropped too, so
    // the dialog never opens another address.
    package static func parse(_ data: Data, pagesUnder prefix: URL? = nil) -> [Release]? {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        let releases = entries.compactMap { $0.raw?.release(pagesUnder: prefix) }
        let sorted = releases.sorted { $0.version > $1.version }
        // A version comes once: the first entry of a version counts (the same tag with and
        // without "v", or two build parts).
        var seen: Set<ReleaseVersion> = []
        let unique = sorted.filter { seen.insert($0.version).inserted }
        return Array(unique.prefix(maxReleases))
    }

    // The summary and the shown sections of a release body.
    package static func parseBody(_ body: String) -> (summary: String, sections: [ReleaseSection]) {
        let (summary, sections) = split(body)
        return (summary, shownSections(sections))
    }

    // Split a body into the summary and the sections with their original titles. A line that is
    // not an item is dropped.
    static func split(_ body: String) -> (summary: String, sections: [ReleaseSection]) {
        var summary: [Substring] = []
        var sections: [ReleaseSection] = []
        var inSummary = true
        var inSection = false
        for line in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix("### ") {
                inSummary = false
                inSection = true
                let title = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                sections.append(ReleaseSection(title: title, items: []))
            } else if line.hasPrefix("## ") {
                inSummary = false
                inSection = false
            } else if inSummary {
                summary.append(line)
            } else if inSection, let item = item(of: line) {
                sections[sections.count - 1].items.append(item)
            }
        }
        let text = summary.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, sections)
    }

    // The sections that the dialog shows, with their friendly titles, in the order of `shown`.
    // Two sections with the same friendly title become one. A section with no item is dropped.
    static func shownSections(_ sections: [ReleaseSection]) -> [ReleaseSection] {
        shown.compactMap { entry in
            let items = sections.filter { entry.titles.contains($0.title) }.flatMap(\.items)
            return items.isEmpty ? nil : ReleaseSection(title: entry.friendly, items: items)
        }
    }

    // The item of a line "* text" or "- text" with no indent, or nil. The commit link at the end
    // of the line, and all text after it, are dropped.
    private static func item(of line: Substring) -> ReleaseItem? {
        guard line.hasPrefix("* ") || line.hasPrefix("- ") else { return nil }
        let text = withoutCommitLink(String(line.dropFirst(2))).trimmingCharacters(in: .whitespaces)
        if let (scope, rest) = scoped(text) {
            return rest.isEmpty ? nil : ReleaseItem(scope: scope, text: rest)
        }
        return text.isEmpty ? nil : ReleaseItem(text: text)
    }

    // "**scope:** text" gives the scope and the text.
    private static func scoped(_ text: String) -> (scope: String, rest: String)? {
        guard text.hasPrefix("**") else { return nil }
        let start = text.index(text.startIndex, offsetBy: 2)
        guard let close = text.range(of: ":**", range: start..<text.endIndex) else { return nil }
        let scope = text[start..<close.lowerBound].trimmingCharacters(in: .whitespaces)
        let rest = text[close.upperBound...]
        // The text after the marker starts with white space.
        guard !scope.isEmpty, rest.first?.isWhitespace == true else { return nil }
        return (scope, rest.trimmingCharacters(in: .whitespaces))
    }

    // The text before " ([hash](url))" and what follows it. A hash has 7 to 40 hex digits.
    private static func withoutCommitLink(_ text: String) -> String {
        var from = text.startIndex
        while let open = text.range(of: "([", range: from..<text.endIndex) {
            let after = open.upperBound
            if let end = text.range(of: "](", range: after..<text.endIndex),
                isHash(text[after..<end.lowerBound]),
                let close = text.range(of: "))", range: end.upperBound..<text.endIndex),
                !text[end.upperBound..<close.lowerBound].contains(where: \.isWhitespace),
                !text[end.upperBound..<close.lowerBound].contains(")")
            {
                return String(text[..<open.lowerBound])
            }
            from = after
        }
        return text
    }

    private static func isHash(_ text: Substring) -> Bool {
        (7...40).contains(text.count) && text.allSatisfy(\.isHexDigit)
    }

    // MARK: - The answer of GitHub

    // One entry of the list. An entry that does not decode has no raw value.
    private struct Entry: Decodable {
        let raw: Raw?

        init(from decoder: any Decoder) {
            raw = try? Raw(from: decoder)
        }
    }

    private struct Raw: Decodable {
        var draft: Bool?
        var prerelease: Bool?
        var body: String?
        var htmlUrl: String?
        var publishedAt: String?
        var tagName: String?

        enum CodingKeys: String, CodingKey {
            case draft, prerelease, body
            case htmlUrl = "html_url"
            case publishedAt = "published_at"
            case tagName = "tag_name"
        }

        // The release of the entry, or nil for a draft, a pre-release or an entry that the app
        // cannot read.
        func release(pagesUnder prefix: URL?) -> Release? {
            guard draft != true, prerelease != true, let tagName, let htmlUrl, let publishedAt,
                let version = ReleaseVersion(tagName), version.pre.isEmpty,
                let page = URL(string: htmlUrl), page.scheme == "https",
                let date = try? Date(publishedAt, strategy: .iso8601)
            else { return nil }
            if let prefix, !page.absoluteString.hasPrefix(prefix.absoluteString + "/") {
                return nil
            }
            let parts = ReleaseNotes.parseBody(body ?? "")
            return Release(
                version: version, date: date, page: page, summary: parts.summary,
                sections: parts.sections)
        }
    }
}
