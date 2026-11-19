import BifrostFoundation
import System

// MARK: - Paths

// The absolute, lexically normal form of a path. A relative path starts at the folder base.
// The services give the current folder of the process as base.
package func resolvePath(_ path: String, from base: String) -> String {
    FilePath(base).pushing(FilePath(path)).lexicallyNormalized().string
}

// True when path is a folder below root (not root itself), after both are resolved from base.
package func isInside(root: String, path: String, base: String) -> Bool {
    let r = FilePath(resolvePath(root, from: base))
    let p = FilePath(resolvePath(path, from: base))
    return p != r && p.starts(with: r)
}

// MARK: - Branches

// The branch name in the text of a HEAD file. "ref: refs/heads/<name>" gives the name. A full
// hash (a detached head) gives "HEAD", as git does. Other text gives nil: ask git. A branch name
// cannot hold a line break.
package func branchOfHead(_ text: String) -> String? {
    let body = text.trimmed()
    let prefix = "ref: refs/heads/"
    if body.hasPrefix(prefix) {
        let name = body.dropFirst(prefix.count)
        return name.isEmpty || name.contains(where: \.isNewline) ? nil : String(name)
    }
    let isHash =
        (body.count == 40 || body.count == 64) && body.allSatisfy { $0.isASCII && $0.isHexDigit }
    return isHash ? "HEAD" : nil
}

// The gitdir path of a .git file: the rest of the first line that starts with "gitdir:",
// trimmed. nil when no line has a path (D7).
package func gitdirOf(_ text: String) -> String? {
    for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("gitdir:") {
        let path = line.dropFirst("gitdir:".count).trimmed()
        return path.isEmpty ? nil : path
    }
    return nil
}
