// The health log file: health.log in the logs folder of the app. Safety: each test writes in a
// temporary folder, never in the real logs folder.
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostHealth

private let time = Date(timeIntervalSince1970: 1_795_000_000.25)

private func text(_ url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

@Suite("performance health log")
struct HealthLogTests {
    @Test func eachLineStartsWithTheISOTime() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        // The logs folder does not exist yet: the first write makes it.
        let folder = temp.url.appending(path: "Library/Logs/Bifrost", directoryHint: .isDirectory)
        let log = HealthLog(folder: folder)
        await log.write("poll failed: sessions (3 in a row)", at: time)
        await log.write("live details did not start: line one\nline two", at: time)
        #expect(
            try text(folder.appending(path: "health.log")) == """
                2026-11-18T11:06:40.250Z poll failed: sessions (3 in a row)
                2026-11-18T11:06:40.250Z live details did not start: line one line two

                """)
    }

    @Test func theLogMovesAt1MB() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let log = HealthLog(folder: temp.url)
        let file = temp.url.appending(path: "health.log")
        let old = temp.url.appending(path: "health.old.log")
        try Data(repeating: UInt8(ascii: "a"), count: 999_999).write(to: file)
        await log.write("cleared by the user", at: time)
        // Below 1 MB, the line goes into the same file.
        #expect(!FileManager.default.fileExists(atPath: old.path))
        await log.write("cleared by the user", at: time)
        // At 1 MB, the file moves to health.old.log and a new file starts.
        #expect(try Data(contentsOf: old).count > 1_000_000)
        #expect(try text(file) == "2026-11-18T11:06:40.250Z cleared by the user\n")
    }

    @Test func aWriteErrorIsIgnored() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        // A file sits where the logs folder must be.
        let blocked = temp.url.appending(path: "Logs")
        try Data("x".utf8).write(to: blocked)
        let log = HealthLog(folder: blocked)
        await log.write("cleared by the user", at: time)
        #expect(try text(blocked) == "x")
    }
}
