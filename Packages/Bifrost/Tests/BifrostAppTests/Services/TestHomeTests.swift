import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostApp
@testable import BifrostFoundation

// The links of a test home: a link out of the home is refused. The test runs with the check of the
// app, PathCheck.system, in a new temporary folder.

private func config(_ value: String, realHome: String) -> String? {
    HomeLocator.testHome(
        environment: [HomeLocator.testHomeKey: value], realHome: realHome, check: .system)
}

@Suite("test home (links)", .testTimeLimit)
struct TestHomeLinkTests {
    @Test("a symbolic link to the real home or a parent of it is refused")
    func links() throws {
        let manager = FileManager.default
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let dir = temp.path
        let home = "\(dir)/home"
        let other = "\(dir)/other"
        try manager.createDirectory(atPath: home, withIntermediateDirectories: false)
        try manager.createDirectory(atPath: other, withIntermediateDirectories: false)
        try manager.createSymbolicLink(atPath: "\(dir)/link", withDestinationPath: home)
        try manager.createSymbolicLink(atPath: "\(dir)/up", withDestinationPath: dir)
        #expect(config("\(dir)/link", realHome: home) == nil)
        #expect(
            HomeLocator.refusedTestHome(
                environment: [HomeLocator.testHomeKey: "\(dir)/link"], realHome: home,
                check: .system) == "\(dir)/link")
        #expect(config("\(dir)/up", realHome: home) == nil)
        // A real home that is a link gives the same result.
        #expect(config(home, realHome: "\(dir)/link") == nil)
        // A real folder beside the home is accepted, with the path as given.
        #expect(config(other, realHome: home) == other)
    }

    // A link into a shared folder of the real home, and a shared folder that is a link to
    // another folder, are refused by their real paths.
    @Test func aLinkIntoASharedFolderIsRefused() throws {
        let manager = FileManager.default
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let dir = temp.path
        let home = "\(dir)/home"
        let elsewhere = "\(dir)/elsewhere"
        try manager.createDirectory(atPath: "\(home)/.claude/t", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: elsewhere, withIntermediateDirectories: false)
        try manager.createSymbolicLink(
            atPath: "\(dir)/into", withDestinationPath: "\(home)/.claude")
        try manager.createSymbolicLink(atPath: "\(home)/.bifrost", withDestinationPath: elsewhere)
        #expect(config("\(dir)/into", realHome: home) == nil)
        #expect(config("\(dir)/into/t", realHome: home) == nil)
        #expect(config("\(elsewhere)/x", realHome: home) == nil)
        // A folder beside the shared folders is accepted.
        #expect(config("\(home)/work", realHome: home) == "\(home)/work")
    }

    // The file systems of macOS ignore the case, so the check of the app ignores it too.
    @Test func theCheckOfTheAppIgnoresTheCase() {
        #expect(PathCheck.system.ignoresCase)
        #expect(config("/USERS/O", realHome: "/Users/o") == nil)
    }
}
