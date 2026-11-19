// The rule of the paths of a fix commit (docs/behaviour/reviews.md, "What a fix commit can hold").
// Bifrost never commits a path outside the worktree, a path in a .git folder, a workflow or an
// action of GitHub, a path in a .claude folder at any depth, or the .gitmodules file.
// CommitFileCheck adds the checks of the files and of the index.
import Foundation

// Why Bifrost does not commit a file.
package enum CommitFileRefusal: Error, Sendable, Equatable {
    // The path is empty or absolute, or it has a part that is "..", ".", empty or starts with "-".
    case outside
    // The path has a .git part.
    case gitFolder
    // The path is in .github/workflows or .github/actions at the root: GitHub runs these files.
    case workflow
    // The path has a .claude part: Claude Code reads its settings from these folders.
    case claudeFolder
    // The path is a symbolic link, is reached through one, is not a regular file, is a link in
    // the index, or names a folder of the index.
    case link
    // The file has more than one hard link.
    case hardLink
    // The path is a submodule in the index, or the .gitmodules file at the root, which gives the
    // addresses of the submodules.
    case submodule
    // The file is over CommitFileRule.maxFileBytes.
    case tooLarge
    // The file has a filter attribute, so git add would run a program of the config.
    case filter
    // The path is not there and is not an entry of the index, so the commit would not change it.
    case unchanged
    // The index or the head of the worktree holds a submodule. git can run a program of the
    // submodule folder, which a session can write, so Bifrost never commits there.
    case repositoryWithSubmodule
    // git or the file system gave no answer, so Bifrost could not check the files.
    case unchecked

    package var message: String {
        switch self {
        case .outside: "Bifrost won't commit a file outside the PR's folder."
        case .gitFolder: "Bifrost won't commit a file in a .git folder."
        case .workflow: "Bifrost won't commit a GitHub workflow or action."
        case .claudeFolder: "Bifrost won't commit a file in a .claude folder."
        case .link: "Bifrost won't commit a link or anything that isn't a plain file."
        case .hardLink: "Bifrost won't commit a file that has more than one link."
        case .submodule: "Bifrost won't commit a submodule or the .gitmodules file."
        case .unchanged: "Bifrost found no change to commit in a file of the fix."
        case .repositoryWithSubmodule: "Bifrost won't commit in a repository that has a submodule."
        case .tooLarge: "Bifrost won't commit a file over 1 MB."
        case .filter: "Bifrost won't commit a file that a git filter changes."
        case .unchecked: "Bifrost couldn't check the files of the fix."
        }
    }
}

package enum CommitFileRule {
    // The largest file of a fix commit, and the largest sum of the files of a signed commit.
    package static let maxFileBytes = 1_048_576, maxSignedBytes = 4 * 1_048_576

    // The refusal of a path of the worktree, or nil. Each compare ignores case, because the
    // default APFS volume ignores it, and ignores the characters that show nothing (such as
    // U+200B), because git and the file system can drop them. A path is relative to the root of
    // the worktree, with "/" between its parts.
    package static func pathRefusal(_ path: String) -> CommitFileRefusal? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if path.isEmpty
            || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasPrefix("-") })
        {
            return .outside
        }
        let keys = parts.map(key)
        if keys.contains(".git") { return .gitFolder }
        if keys == [".gitmodules"] { return .submodule }
        if keys.count >= 2, keys[0] == ".github", keys[1] == "workflows" || keys[1] == "actions" {
            return .workflow
        }
        if keys.contains(".claude") { return .claudeFolder }
        return nil
    }

    // The form of a part for a compare: no character that shows nothing, and no case.
    private static func key(_ part: Substring) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in part.unicodeScalars where !scalar.properties.isDefaultIgnorableCodePoint {
            scalars.append(scalar)
        }
        return String(scalars).folding(options: .caseInsensitive, locale: nil)
    }
}
