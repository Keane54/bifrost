// The free disk and the size of the Reviews clones. Safety: each test reads a temporary folder.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostHealth

@Suite("performance disk state")
struct DiskStateTests {
    @Test func theClonesSizeAddsTheFilesOfAllFolders() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let repos = temp.url.appending(path: "repos", directoryHint: .isDirectory)
        let nested = repos.appending(path: "owner/name/.git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let block = Data(repeating: 7, count: 40_000)
        try block.write(to: repos.appending(path: "owner/name/file.txt"))
        try block.write(to: nested.appending(path: "pack"))
        let disk = DiskState(home: temp.url, clones: repos)
        let size = try #require(await disk.clonesSize())
        #expect(size >= 80_000)
        #expect(size < 1_000_000)
    }

    @Test func noClonesFolderGivesNoSize() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let missing = temp.url.appending(path: "repos", directoryHint: .isDirectory)
        #expect(await DiskState(home: temp.url, clones: missing).clonesSize() == nil)
        #expect(await DiskState(home: temp.url, clones: nil).clonesSize() == nil)
    }

    @Test func theFreeSpaceComesFromTheVolumeOfTheHome() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let free = try #require(await DiskState(home: temp.url, clones: nil).freeSpace())
        #expect(free > 0)
    }
}
