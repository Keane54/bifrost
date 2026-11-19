// The folders in which Bifrost reads no git file and runs no git: the reviews folders of the
// development app and of the Electron app. A PR session can write the .git file, the HEAD file
// and the git config of its folder, and git reads each of them. The branch reader and the folder
// check of the session actions use the same check.
package struct SkipRoots: Sendable {
    package let roots: [String]

    package init(_ roots: [String]) { self.roots = roots }

    // True when the absolute path is a root or a folder below one, by the paths as they are or by
    // their real paths. realPath gives nil for a path that does not exist. A session can report the
    // real path of a folder that a root names through a link, and a link outside a root can point
    // into it.
    package func contains(_ path: String, realPath: (String) async -> String?) async -> Bool {
        if roots.contains(where: { Self.isRootOrBelow($0, path) }) { return true }
        guard !roots.isEmpty, let real = await realPath(path) else { return false }
        for root in roots {
            if let realRoot = await realPath(root), Self.isRootOrBelow(realRoot, real) {
                return true
            }
        }
        return false
    }

    // The compare uses the normal form of each path, so "/r/x/" is the root "/r/x", and
    // "/r/x-old" is not below it.
    private static func isRootOrBelow(_ root: String, _ path: String) -> Bool {
        resolvePath(path, from: "/") == resolvePath(root, from: "/")
            || isInside(root: root, path: path, base: "/")
    }
}
