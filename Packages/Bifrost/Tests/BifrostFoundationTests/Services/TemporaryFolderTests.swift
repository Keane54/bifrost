import BifrostTestSupport
import Foundation
import Testing

// The temporary folder of a test (TemporaryFolder in BifrostTestSupport). remove() frees the path
// at once with a rename, and removes the content in the background.
@Suite("the temporary folder of a test", .testTimeLimit)
struct TemporaryFolderTests {
    @Test func removeFreesThePathAtOnceAndThenRemovesTheContent() async throws {
        let folder = try TemporaryFolder()
        let manager = FileManager.default
        try manager.createDirectory(
            atPath: folder.appending("sub"), withIntermediateDirectories: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: folder.appending("sub/file")))
        let parent = (folder.path as NSString).deletingLastPathComponent
        let name = (folder.path as NSString).lastPathComponent
        folder.remove()
        #expect(!manager.fileExists(atPath: folder.path))
        // The renamed folder goes too.
        #expect(
            await waitUntil {
                let names = (try? manager.contentsOfDirectory(atPath: parent)) ?? []
                return !names.contains { $0.hasPrefix(name + TemporaryFolder.goneMark) }
            })
    }

    // A second remove, or a remove of a folder that is gone, does nothing.
    @Test func aRemoveOfAFolderThatIsGoneDoesNothing() throws {
        let folder = try TemporaryFolder(short: true)
        folder.remove()
        folder.remove()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
