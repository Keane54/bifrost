// The check of a trust run (docs/behaviour/pty.md, "The trust run"). A trust run is the second
// checked form of a PTY spawn, as CheckedAttach is the first: it runs claude with no arguments in
// one folder, so that the user can answer the workspace trust prompt of Claude Code there. Only
// the check makes a CheckedTrustRun, and PTYManager.openTrust takes only this value, so each trust
// run goes through the check. The forbidden rule trust-run lets only BifrostReviews and the tests
// call the check, so no other part of the app can start claude in a folder of its choice.
import BifrostFoundation
import Darwin
import Foundation

// A trust run that TrustRuns.check allowed: the real path of its folder.
package struct CheckedTrustRun: Sendable, Equatable {
    package let folder: String

    fileprivate init(folder: String) {
        self.folder = folder
    }
}

package enum TrustRuns {
    // A run only for a real folder strictly below the real path of root (the folder of the
    // review clones). The check resolves each link of both paths first, so a link out of the
    // root, a ".." part and the root itself give nil. A file, a missing folder and a root that is
    // not there give nil too. The run gets the real path of the folder. The check reads the file
    // system on the blocking executor, because a slow disk can hold it.
    @concurrent package static func check(folder: URL, root: URL) async -> CheckedTrustRun? {
        await BlockingExecutor.run { () -> CheckedTrustRun? in
            guard let realRoot = RealPath.of(root.path(percentEncoded: false)),
                let realFolder = RealPath.of(folder.path(percentEncoded: false)),
                isFolder(realFolder)
            else { return nil }
            let prefix = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
            guard realFolder.hasPrefix(prefix), realFolder.count > prefix.count else { return nil }
            return CheckedTrustRun(folder: realFolder)
        }
    }

    // True when the path names a folder. The path has no link in it (RealPath).
    private static func isFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
