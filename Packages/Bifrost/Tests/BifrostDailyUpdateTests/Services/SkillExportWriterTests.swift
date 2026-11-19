import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostDailyUpdate

// The write of the skill export: settings.json in the Daily update folder of a test home.

@Suite("the write of the skill export", .timeLimit(.minutes(1)))
struct SkillExportWriterTests {
    @Test func theExportHasOnlyItsFieldsAndMode0600() async throws {
        let home = try TemporaryFolder()
        defer { home.remove() }
        let layout = DailyLayout(folder: home.url.appending(path: "daily-update"))
        // A folder from before with a mode that is too open.
        try FileManager.default.createDirectory(
            at: layout.folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let writer = SkillExportWriter(layout: layout)
        try await writer.write(boardSettings())
        let path = layout.exportFile.path(percentEncoded: false)
        #expect(mode(of: path) == 0o600)
        #expect(mode(of: layout.folder.path(percentEncoded: false)) == 0o700)
        let data = try Data(contentsOf: layout.exportFile)
        let fields = try #require(try JSONDecoder().decode(JSONValue.self, from: data).object)
        #expect(Set(fields.keys) == ["version", "areas", "format", "mergedPrs", "source", "you"])
        #expect(fields["source"]?.object?["server"] == "board")
        // A later write replaces the file.
        try await writer.write(.defaults)
        let again = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: layout.exportFile))
        #expect(again.object?["source"]?.object?["server"] == .null)
        #expect(again.object?["areas"] == [])
        #expect(mode(of: path) == 0o600)
    }

    // A file at the place of the folder: the write fails with the folder in the error.
    @Test func aFolderThatCannotBeMadeFails() async throws {
        let home = try TemporaryFolder()
        defer { home.remove() }
        let blocked = home.url.appending(path: "daily-update")
        try Data().write(to: blocked)
        let writer = SkillExportWriter(layout: DailyLayout(folder: blocked))
        await #expect(throws: FileError.self) { try await writer.write(.defaults) }
    }
}
