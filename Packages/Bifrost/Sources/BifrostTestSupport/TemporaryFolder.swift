import Dispatch
import Foundation

// A new empty folder for one test, with mode 0700. The test removes it with remove(), for
// example in a defer: the path is free at once, and the content goes in the background. Outside
// the test sandbox, the init records an issue and throws (TestSandbox), so no test writes a
// real file outside the sandbox.
//
// The default folder is in the temp folder of the user. A short folder is /tmp/bk-<8 hex
// characters>: a socket path in it stays below the limit of 103 bytes.
package struct TemporaryFolder: Sendable {
    package struct Failure: Error {
        package var code: Int32
    }

    package let path: String

    package init(short: Bool = false) throws {
        try TestSandbox.require()
        let parent =
            short ? "/tmp" : FileManager.default.temporaryDirectory.path(percentEncoded: false)
        let base = parent.hasSuffix("/") ? String(parent.dropLast()) : parent
        while true {
            let name =
                short
                ? String(format: "%@/bk-%08x", base, UInt32.random(in: .min ... .max))
                : "\(base)/bifrost-test-\(UUID().uuidString)"
            if mkdir(name, 0o700) == 0 {
                path = name
                return
            }
            let code = errno
            if code != EEXIST { throw Failure(code: code) }
        }
    }

    // The file URL of the folder.
    package var url: URL { URL(filePath: path, directoryHint: .isDirectory) }

    // The path with no link in it. The temp folders of macOS are behind links (/tmp and /var).
    package var realPath: String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // The path of a file or folder in the folder.
    package func appending(_ name: String) -> String { "\(path)/\(name)" }

    // The mark in the name of a folder that remove() renamed: <path>.gone-<UUID>. After the
    // tests, scripts/run-sandboxed.sh removes each such folder that is left.
    package static let goneMark = ".gone-"

    // Remove the folder and its content. One rename takes the folder off its path at once, on
    // the thread of the caller, so the path is free and no later write can make a file in it.
    // The removal of the content runs on a queue of its own, so it never holds the thread of
    // the caller (often the main actor). A folder that the rename cannot move is removed in
    // place, at once.
    package func remove() {
        let gone = "\(path)\(Self.goneMark)\(UUID().uuidString)"
        guard Darwin.rename(path, gone) == 0 else {
            if errno != ENOENT { Self.removeContent(path) }
            return
        }
        Self.removals.async { Self.removeContent(gone) }
    }

    // The queue of the removals of the renamed folders.
    private static let removals = DispatchQueue(label: "bifrost.test.removals", qos: .utility)

    // Remove the folder and its content. A write through a descriptor that was open before the
    // rename can end during the removal and leave a file, and then the removal fails because
    // the folder is not empty. Thus the removal tries again, at most 50 times, 20 ms apart.
    private static func removeContent(_ path: String) {
        for _ in 0..<50 {
            do {
                try FileManager.default.removeItem(atPath: path)
                return
            } catch {
                if !FileManager.default.fileExists(atPath: path) { return }
                usleep(20_000)
            }
        }
    }
}
