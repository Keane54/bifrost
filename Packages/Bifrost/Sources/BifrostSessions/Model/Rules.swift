// The small rules that the registry and the store file share.
import BifrostFoundation

// MARK: - Local names

package enum AliasRefusal: Error, Equatable, Sendable {
    case control
    case tooLong

    package var reason: String {
        switch self {
        case .control: "A name can't hold control or hidden characters."
        case .tooLong: "The name is too long. The maximum is \(maxAliasLength) characters."
        }
    }
}

package let maxAliasLength = 64

// The characters that a name cannot hold: C0 with tab and LF, DEL and C1, zero-width
// characters, and the bidi controls (with the Arabic letter mark, U+061C). A bidi control could
// reverse the text after the name. The local name and the name of a new session use this rule.
package func isHiddenInAName(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x00...0x1F, 0x7F...0x9F, 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069,
        0xFEFF:
        true
    default:
        false
    }
}

// The characters that a text from another program cannot hold: C0 (also the tab and the line
// breaks), DEL and C1, the line and paragraph separators (U+2028, U+2029), the bidi controls with
// the marks U+200E, U+200F and U+061C, and the default-ignorable characters that show nothing:
// the soft hyphen U+00AD, the combining grapheme joiner U+034F, the Khmer vowels U+17B4 and
// U+17B5, U+180E, U+200B, U+2060 to U+206F, U+FEFF, U+FFF9 to U+FFFB, the shorthand format
// controls U+1BCA0 to U+1BCA3, the musical format controls U+1D173 to U+1D17A, the tags (U+E0000
// to U+E007F) and the Hangul fillers (U+115F, U+1160, U+3164, U+FFA0). Such a character can make
// a text or a path look like another one. The joiners U+200C and U+200D and the variation
// selectors U+FE00 to U+FE0F stay, because emoji and some scripts need them.
package func isUnsafeInText(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x00...0x1F, 0x7F...0x9F, 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4...0x17B5,
        0x180E, 0x200B, 0x200E...0x200F, 0x2028...0x2029, 0x202A...0x202E, 0x2060...0x206F,
        0x3164, 0xFEFF, 0xFFA0, 0xFFF9...0xFFFB, 0x1BCA0...0x1BCA3, 0x1D173...0x1D17A,
        0xE0000...0xE007F:
        true
    default:
        false
    }
}

// The one clean of each text from the Live details mod (the tool, the reason, the answer, the
// model, the version, the effort and the permission mode) and from the session list (the name and
// waitingFor): the text with no unsafe character (isUnsafeInText). With lines, the tab and the LF
// stay, for the lines of an answer. A path is never cleaned, because a changed path names another
// file: a path with an unsafe character is no path (hasUnsafeCharacter).
package func cleanText(_ text: String, lines: Bool = false) -> String {
    guard hasUnsafeCharacter(text) else { return text }
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars
    where !isUnsafeInText(scalar) || (lines && (scalar == "\t" || scalar == "\n")) {
        scalars.append(scalar)
    }
    return String(scalars)
}

// True when the text holds an unsafe character (isUnsafeInText).
package func hasUnsafeCharacter(_ text: String) -> Bool {
    text.unicodeScalars.contains(where: isUnsafeInText)
}

// The text with no character that a name cannot hold (isHiddenInAName). A refusal text uses it
// for a path, so a path cannot change how the rest of the text reads.
package func withoutHiddenCharacters(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars where !isHiddenInAName(scalar) { scalars.append(scalar) }
    return String(scalars)
}

// Trim the name. Refuse a control or hidden character and a name of more than 64 Characters.
// An empty name is valid. It means "no local name".
package func cleanAlias(_ text: String) throws(AliasRefusal) -> String {
    let name = text.trimmed()
    if name.unicodeScalars.contains(where: isHiddenInAName) { throw .control }
    if name.count > maxAliasLength { throw .tooLong }
    return name
}

// MARK: - Worktrees

// The worktree root and the repo of a folder in <repo>/.claude/worktrees/<name>.
package struct WorktreeRoot: Equatable, Sendable {
    package var worktree: String
    package var repo: String
}

extension WorktreeRoot {
    private static let mark = "/.claude/worktrees/"

    // The root of a cwd. A cwd in a subfolder gives the same root. A cwd outside
    // .claude/worktrees/<name>, a relative path, a "." or ".." segment and an empty repo part
    // give nil.
    package init?(cwd: String) {
        guard cwd.hasPrefix("/") else { return nil }
        let parts = cwd.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains(where: { $0 == "." || $0 == ".." }) { return nil }
        guard let mark = cwd.firstRange(of: Self.mark), mark.lowerBound > cwd.startIndex else {
            return nil
        }
        let name = cwd[mark.upperBound...].prefix { $0 != "/" }
        if name.isEmpty { return nil }
        self.init(
            worktree: String(cwd[..<mark.upperBound]) + name,
            repo: String(cwd[..<mark.lowerBound]))
    }

    // The root of a row: from its cwd, else from the worktree that Bifrost stored while the
    // session ran. A stored path that init(cwd:) refuses gives nil.
    package init?(cwd: String, stored: String?) {
        guard let root = WorktreeRoot(cwd: cwd) ?? stored.flatMap(WorktreeRoot.init(cwd:)) else {
            return nil
        }
        self = root
    }

    // True when the path is a worktree root itself, not a folder in a worktree.
    package static func isRoot(_ path: String) -> Bool {
        WorktreeRoot(cwd: path)?.worktree == path
    }
}

// The project folder of a working folder: the folder with no slash at the end, and for a path in
// a Claude worktree, its repository (the part before "/.claude/worktrees/<name>"). The part after
// the name must have no line break, else the path stays. The Overview shows and colours a row by
// this folder, and the New session dialog offers it. The rule reads Unicode scalars and takes the
// first worktree mark, so it is not WorktreeRoot(cwd:).
package func repoPath(_ cwd: String) -> String {
    var scalars = Array(cwd.unicodeScalars)
    while scalars.last == "/" { scalars.removeLast() }
    if let start = worktreeTailStart(scalars) { scalars.removeSubrange(start...) }
    var path = String.UnicodeScalarView()
    path.append(contentsOf: scalars)
    return String(path)
}

// The mark of a Claude worktree path, before the name of the worktree.
private let worktreeMark = Array("/.claude/worktrees/".unicodeScalars)

// The place where the first worktree tail starts: the mark, a name of one or more scalars that
// are not "/", then the end, or a "/" and a rest with no line break.
private func worktreeTailStart(_ scalars: [Unicode.Scalar]) -> Int? {
    var start = 0
    while start + worktreeMark.count < scalars.count {
        defer { start += 1 }
        guard scalars[start..<start + worktreeMark.count].elementsEqual(worktreeMark) else {
            continue
        }
        let nameStart = start + worktreeMark.count
        let nameEnd = scalars[nameStart...].firstIndex(of: "/") ?? scalars.count
        guard nameEnd > nameStart else { continue }
        if !scalars[nameEnd...].contains(where: isLineBreak) { return start }
    }
    return nil
}

// A line feed, a carriage return, or the line and paragraph separators.
private func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
    ["\n", "\r", "\u{2028}", "\u{2029}"].contains(scalar)
}

// The first other row in the worktree of the row, in the order of the rows, else nil. The state
// of each row does not matter: "claude rm" can remove a clean worktree while another session uses
// it, so a Delete of a row with a sharer keeps the folder and defers the "claude rm". A plain
// folder has no sharer. The row itself (the same row ID) never counts.
package func folderSharer(of row: SessionRow, in rows: [SessionRow]) -> SessionRow? {
    guard let root = WorktreeRoot(cwd: row.cwd, stored: row.worktree)?.worktree else { return nil }
    return rows.first {
        $0.sessionId != row.sessionId
            && WorktreeRoot(cwd: $0.cwd, stored: $0.worktree)?.worktree == root
    }
}

// MARK: - Model names

// The display name of a model ID, for example "Opus 5.5". An ID of an unknown form stays as it
// is. The digits are ASCII digits only.
package func modelName(_ id: String) -> String {
    let pattern = /claude-(opus|sonnet|haiku|fable)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?(\[1m\])?/
    guard let match = try? pattern.asciiOnlyDigits().wholeMatch(in: id) else { return id }
    let (_, family, major, minor, million) = match.output
    let name = family.prefix(1).uppercased() + family.dropFirst()
    let version = minor.map { "\(major).\($0)" } ?? String(major)
    return "\(name) \(version)\(million == nil ? "" : " (1M context)")"
}
