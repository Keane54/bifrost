// The check of a trust run (docs/behaviour/pty.md, "The trust run"): only a real folder strictly
// below the real path of the root gives a run. The tests make the folders, the files and the
// links in a temporary folder.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostSessions

@Suite("trust runs", .timeLimit(.minutes(1)))
struct TrustRunsTests {
    @Test func onlyAFolderBelowTheRootGivesARun() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fm = FileManager.default
        let real = folder.realPath
        let root = real + "/repos"
        try fm.createDirectory(atPath: root + "/owner/repo", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: real + "/repos-sibling", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: real + "/outside", withIntermediateDirectories: true)
        try "x".write(toFile: root + "/owner/file", atomically: false, encoding: .utf8)
        try fm.createSymbolicLink(
            atPath: root + "/owner/out", withDestinationPath: real + "/outside")
        try fm.createSymbolicLink(
            atPath: root + "/owner/in", withDestinationPath: root + "/owner/repo")
        let rootURL = URL(filePath: root, directoryHint: .isDirectory)

        func check(_ path: String) async -> CheckedTrustRun? {
            await TrustRuns.check(folder: URL(filePath: path), root: rootURL)
        }

        #expect(await check(root + "/owner/repo")?.folder == root + "/owner/repo")
        // The root of the temporary folder is behind a link (/var): the root may be given in
        // either form, and the run gets the real path.
        let linked = await TrustRuns.check(
            folder: URL(filePath: folder.path + "/repos/owner/repo"),
            root: URL(filePath: folder.path + "/repos", directoryHint: .isDirectory))
        #expect(linked?.folder == root + "/owner/repo")
        // A link that stays below the root gives the real folder.
        #expect(await check(root + "/owner/in")?.folder == root + "/owner/repo")
        #expect(await check(root) == nil)
        #expect(await check(root + "/") == nil)
        #expect(await check(real + "/repos-sibling") == nil)
        #expect(await check(root + "/owner/repo/../..") == nil)
        #expect(await check(root + "/owner/out") == nil)
        #expect(await check(root + "/owner/file") == nil)
        #expect(await check(root + "/owner/missing") == nil)
    }
}
