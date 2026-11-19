import Foundation

// The repo of this package. A test reads a file outside the packages through it, for example the
// fake claude of scripts/fake-claude, the fake gh of scripts/fake-gh or a file of the app target.
// The fixtures of a test target are its resources (Bundle.module), not files of the repo.
package enum Repo {
    package struct NotFound: Error, CustomStringConvertible {
        let start: String

        package var description: String { "No folder above \(start) holds Bifrost.xcodeproj." }
    }

    // The first folder above the source file of this type that holds Bifrost.xcodeproj. A move
    // of a test file or of this file does not change it.
    package static func root() throws(NotFound) -> URL {
        let start = URL(fileURLWithPath: #filePath)
        var folder = start.deletingLastPathComponent()
        while folder.pathComponents.count > 1 {
            let project = folder.appending(path: "Bifrost.xcodeproj").path
            if FileManager.default.fileExists(atPath: project) { return folder }
            folder = folder.deletingLastPathComponent()
        }
        throw NotFound(start: start.path)
    }

    // The fake claude of the chat and attach tests.
    package static func fakeClaude() throws(NotFound) -> String {
        try root().appending(path: "scripts/fake-claude/claude").path
    }

    // The fake gh of the PR lookup tests.
    package static func fakeGh() throws(NotFound) -> String {
        try root().appending(path: "scripts/fake-gh/gh").path
    }
}
