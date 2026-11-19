// The note file of Hand over (docs/behaviour/actions.md, "Hand over"): Bifrost writes each note
// to a new file and never writes over a file. Only the user can read the folder and the file.
// Each test writes only in its own temporary folder.
import BifrostFoundation
import BifrostTestSupport
import Darwin
import Foundation
import Testing

@testable import BifrostSessions

private func contents(_ path: String) -> String? {
    FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
}

// The permission bits of the file or folder at the path. The read does not follow a link.
private func mode(_ path: String) -> mode_t? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return info.st_mode & 0o7777
}

private func write(_ text: String, _ name: String, in folder: String) async throws(NoteFileError)
    -> String
{
    let url = URL(filePath: folder, directoryHint: .isDirectory)
    return try await NoteFile.write(text, named: name, in: url).path(percentEncoded: false)
}

@Suite("the note file of Hand over")
struct NoteFileTests {
    // A used name gets -2 before the extension, then -3, and so on. The file that was there
    // keeps its text.
    @Test func aNoteNeverWritesOverAFile() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let folder = temp.appending("notes")
        #expect(try await write("one", "x-1.md", in: folder) == "\(folder)/x-1.md")
        #expect(try await write("two", "x-1.md", in: folder) == "\(folder)/x-1-2.md")
        #expect(try await write("three", "x-1.md", in: folder) == "\(folder)/x-1-3.md")
        #expect(contents("\(folder)/x-1.md") == "one")
        #expect(contents("\(folder)/x-1-2.md") == "two")
        #expect(contents("\(folder)/x-1-3.md") == "three")
        // A folder at the path counts as a used name too.
        try FileManager.default.createDirectory(
            atPath: "\(folder)/y.md", withIntermediateDirectories: false)
        #expect(try await write("y", "y.md", in: folder) == "\(folder)/y-2.md")
    }

    // A link at the path is a used name, so the write never goes through it: the target of the
    // link stays as it was, also a link to no file.
    @Test func aLinkAtThePathIsNotFollowed() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let folder = temp.appending("notes")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        let target = temp.appending("target.md")
        try Data("target".utf8).write(to: URL(filePath: target))
        #expect(symlink(target, "\(folder)/n.md") == 0)
        #expect(symlink(temp.appending("none.md"), "\(folder)/n-2.md") == 0)
        #expect(try await write("note", "n.md", in: folder) == "\(folder)/n-3.md")
        #expect(contents(target) == "target")
        #expect(!FileManager.default.fileExists(atPath: temp.appending("none.md")))
        #expect(contents("\(folder)/n-3.md") == "note")
    }

    // The folder is made with mode 0700 and the file with mode 0600. A folder that exists keeps
    // its mode.
    @Test func theModesAre0700And0600() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let folder = temp.appending("a/notes")
        let path = try await write("note", "n.md", in: folder)
        #expect(mode(folder) == 0o700)
        #expect(mode(temp.appending("a")) == 0o700)
        #expect(mode(path) == 0o600)
        let open = temp.appending("open")
        try FileManager.default.createDirectory(
            atPath: open, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755])
        #expect(mode(try await write("note", "n.md", in: open)) == 0o600)
        #expect(mode(open) == 0o755)
    }

    // The name must be a plain file name, so the file is always in the folder. After 100 names,
    // the write stops.
    @Test func onlyAPlainNameAndAHundredTriesWork() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        let folder = temp.appending("notes")
        for name in ["", ".", "..", "a/b.md", "../b.md", "a\0.md"] {
            await #expect(throws: NoteFileError.badName) { try await write("n", name, in: folder) }
        }
        for _ in 1...100 { _ = try await write("n", "z.md", in: folder) }
        await #expect(throws: NoteFileError.tooMany) { try await write("n", "z.md", in: folder) }
        #expect(NoteFileError.badName.message == "The note file name isn't valid.")
        #expect(NoteFileError.tooMany.message == "Too many hand-over notes have this name.")
    }

    @Test func aFolderThatCannotBeMadeGivesTheReason() async throws {
        let temp = try TemporaryFolder()
        defer { temp.remove() }
        try Data().write(to: URL(filePath: temp.appending("file")))
        let folder = temp.appending("file/notes")
        await #expect(
            throws: NoteFileError.file(.system(.createFolder, path: folder, code: ENOTDIR))
        ) { try await write("n", "n.md", in: folder) }
    }
}
