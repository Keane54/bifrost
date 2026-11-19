import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostFoundation

// The one program lookup (docs/behaviour/process.md): the process runner and the claude locator
// use it. Only an absolute folder of the PATH counts, and only a regular file that the user can
// run.

// A new temporary folder with a runnable program and a plain file in it. The caller removes it.
private func programFolder() throws -> TemporaryFolder {
    let temp = try TemporaryFolder()
    let folder = temp.url
    let program = folder.appendingPathComponent("bifrost-probe")
    try Data("#!/bin/sh\necho found\n".utf8).write(to: program)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    let plain = folder.appendingPathComponent("bifrost-plain")
    try Data("text\n".utf8).write(to: plain)
    return temp
}

// The folder as a path relative to the current folder of the process, for example
// "../../../private/var/folders/...". It names the same folder, but it does not start with "/".
private func relativePath(_ folder: URL) -> String {
    let depth = FileManager.default.currentDirectoryPath.split(separator: "/").count
    let up = Array(repeating: "..", count: depth).joined(separator: "/")
    return up + folder.resolvingSymlinksInPath().path
}

@Suite("the program lookup", .timeLimit(.minutes(2)), .tags(.realProcess))
struct ProgramLookupTests {
    // Some tests write programs to the temp folder and start them.
    init() throws { try TestSandbox.require() }

    @Test func theFirstAbsoluteFolderWithTheProgramWins() {
        let runnable: Set<String> = ["/b/claude", "/c/claude", "rel/claude", "/d/claude"]
        func find(_ path: String) -> String? {
            ProgramLookup.find("claude", path: path, isRunnable: runnable.contains)
        }
        #expect(find("/a:/b") == "/b/claude")
        #expect(find("/a:/c:/b") == "/c/claude")
        #expect(find("/d/") == "/d/claude")
        // A relative folder and an empty part are skipped.
        #expect(find("rel::/b") == "/b/claude")
        #expect(find("rel") == nil)
        #expect(find("/a:/e") == nil)
        #expect(find("") == nil)
    }

    @Test func onlyARegularFileThatTheUserCanRunCounts() throws {
        let temp = try programFolder()
        defer { temp.remove() }
        let folder = temp.url
        // A folder with the name of the program comes first in the PATH.
        let decoy = folder.appendingPathComponent("decoy")
        try FileManager.default.createDirectory(
            at: decoy.appendingPathComponent("bifrost-probe"), withIntermediateDirectories: true)
        let path = "\(decoy.path):\(folder.path)"
        #expect(
            ProgramLookup.find("bifrost-probe", path: path)
                == folder.appendingPathComponent("bifrost-probe").path)
        #expect(ProgramLookup.find("bifrost-plain", path: path) == nil)
        #expect(!ProgramLookup.isRunnable(decoy.appendingPathComponent("bifrost-probe").path))
    }

    // A link counts only when it leads to a regular file that the user can run. The result is
    // the path of the link.
    @Test func aLinkCountsOnlyWhenItLeadsToARunnableFile() throws {
        let temp = try programFolder()
        defer { temp.remove() }
        let folder = temp.url
        let links = folder.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: false)
        func link(_ name: String, to target: String) {
            symlink(target, links.appendingPathComponent(name).path)
        }
        link("to-plain", to: folder.appendingPathComponent("bifrost-plain").path)
        link("to-folder", to: folder.path)
        link("dangling", to: folder.appendingPathComponent("nowhere").path)
        link("to-program", to: folder.appendingPathComponent("bifrost-probe").path)
        for name in ["to-plain", "to-folder", "dangling"] {
            #expect(ProgramLookup.find(name, path: links.path) == nil, "\(name)")
        }
        #expect(
            ProgramLookup.find("to-program", path: links.path)
                == links.appendingPathComponent("to-program").path)
    }

    // The relative folder names a folder that holds the program, but the lookup and the runner
    // never use it.
    @Test func aRelativeFolderOfThePathIsSkippedAlsoWhenItHoldsTheProgram() async throws {
        let temp = try programFolder()
        defer { temp.remove() }
        let folder = temp.url
        let relative = relativePath(folder)
        #expect(ProgramLookup.isRunnable("\(relative)/bifrost-probe"))
        #expect(ProgramLookup.find("bifrost-probe", path: relative) == nil)
        let result = await ProcessRunner().run(
            Command("bifrost-probe", environment: ["PATH": "\(relative):/nowhere"]))
        #expect(result.end == .notStarted)
        let found = await ProcessRunner().run(
            Command("bifrost-probe", environment: ["PATH": "\(relative):\(folder.path)"]))
        #expect(found == ExecResult(.exited(0), stdout: "found\n"))
    }
}
