// The check that a transcript has a user message (docs/behaviour/actions.md, "The transcript
// check"). Each test makes its own projects folder in a temporary folder, so no test reads the
// real ~/.claude.
import BifrostFoundation
import BifrostTestSupport
import Darwin
import Foundation
import Testing

@testable import BifrostSessions

private let session = "f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f"
private let user = #"{"type":"user","message":{"role":"user","content":"Reply with OK."}}"# + "\n"
private let other = #"{"type":"file-history-snapshot","messageId":"m1"}"# + "\n"

// A projects folder in a temporary folder.
private struct Projects {
    let folder: TemporaryFolder
    let url: URL

    init() throws {
        folder = try TemporaryFolder()
        url = URL(filePath: folder.appending("projects"), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var path: String { url.path(percentEncoded: false) }

    // Write the transcript of the session in a project folder.
    func transcript(_ project: String, _ text: String, id: String = session) throws {
        let dir = url.appending(path: project, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appending(path: "\(id).jsonl"))
    }

    func hasMessages(_ id: String = session) async -> Bool {
        await TranscriptReader.hasMessages(projects: url, sessionId: id)
    }

    func remove() {
        chmod(path, 0o700)
        folder.remove()
    }
}

@Suite("the transcript check")
struct TranscriptReaderTests {
    @Test func theCheckReadsAtMost256KB() {
        #expect(TranscriptReader.readBytes == 256 * 1024)
    }

    @Test func aTranscriptWithAUserMessageGivesTrue() async throws {
        let projects = try Projects()
        defer { projects.remove() }
        try FileManager.default.createDirectory(
            atPath: projects.path + "/-Users-x-other", withIntermediateDirectories: true)
        try projects.transcript("-Users-x-p", other + user)
        #expect(await projects.hasMessages())
    }

    @Test func noTranscriptGivesFalse() async throws {
        let projects = try Projects()
        defer { projects.remove() }
        #expect(await !projects.hasMessages())
    }

    @Test func aMissingProjectsFolderGivesFalse() async throws {
        let projects = try Projects()
        defer { projects.remove() }
        let missing = projects.url.appending(path: "missing")
        #expect(await !TranscriptReader.hasMessages(projects: missing, sessionId: session))
    }

    @Test func aTranscriptWithNoUserMessageGivesFalse() async throws {
        let projects = try Projects()
        defer { projects.remove() }
        try projects.transcript("-Users-x-p", other)
        #expect(await !projects.hasMessages())
    }

    @Test func aTranscriptOfAnotherSessionDoesNotCount() async throws {
        let projects = try Projects()
        defer { projects.remove() }
        try projects.transcript("-Users-x-p", user, id: "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d")
        #expect(await !projects.hasMessages())
    }

    @Test func aFileInTheProjectsFolderIsNotAProject() async throws {
        let projects = try Projects()
        defer { projects.remove() }
        try Data(user.utf8).write(to: projects.url.appending(path: "notes.txt"))
        #expect(await !projects.hasMessages())
    }

    // The user line starts at the first byte after the limit.
    @Test func aUserMessageAfterTheFirst256KBDoesNotCount() async throws {
        let projects = try Projects()
        defer { projects.remove() }
        let fill = String(repeating: "x", count: TranscriptReader.readBytes - 1)
        try projects.transcript("-Users-x-p", "\(fill)\n\(user)")
        #expect(await !projects.hasMessages())
    }

    // The text {"type":"user" ends at the last byte of the limit.
    @Test func aUserMessageMarkThatEndsAtTheLimitCounts() async throws {
        let projects = try Projects()
        defer { projects.remove() }
        let mark = #"{"type":"user""#
        let fill = String(repeating: "x", count: TranscriptReader.readBytes - mark.utf8.count)
        try projects.transcript("-Users-x-p", fill + user)
        #expect(await projects.hasMessages())
    }

    // The transcript name is a folder, so the read fails. A read error never blocks a session
    // that has messages.
    @Test func aReadErrorCountsAsASessionWithMessages() async throws {
        let projects = try Projects()
        defer { projects.remove() }
        try FileManager.default.createDirectory(
            atPath: projects.path + "/-Users-x-p/\(session).jsonl",
            withIntermediateDirectories: true)
        #expect(await projects.hasMessages())
    }

    @Test func aProjectsFolderThatCannotBeReadCountsAsASessionWithMessages() async throws {
        let projects = try Projects()
        defer { projects.remove() }
        try projects.transcript("-Users-x-p", other)
        #expect(chmod(projects.path, 0o000) == 0)
        #expect(await projects.hasMessages())
    }

    // No path is made from a session ID that is not a UUID.
    @Test(arguments: ["", "../x", "\(session)/../\(session)", "abc", "\(session)\0"])
    func aSessionIdThatIsNotAUUIDGivesFalse(id: String) async throws {
        let projects = try Projects()
        defer { projects.remove() }
        try projects.transcript("-Users-x-p", user)
        #expect(await !projects.hasMessages(id))
    }

    // A named pipe at the path of the transcript has no writer. The open does not wait for one.
    @Test func aPipeAtThePathOfTheTranscriptDoesNotHoldTheCheck() async throws {
        let projects = try Projects()
        defer { projects.remove() }
        let dir = projects.path + "/-Users-x-p"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        #expect(mkfifo("\(dir)/\(session).jsonl", 0o600) == 0)
        #expect(await !projects.hasMessages())
    }
}

// The transcript of a row, its size, its full lines after an offset with the end of the last
// one, and its change events, for Hand over (docs/behaviour/actions.md, "Hand over").
@Suite("the transcript reads of Hand over")
@MainActor
struct TranscriptTailTests {
    // The file of the current conversation of the row counts: currentId, else the row ID. A row
    // ID that is not a UUID gives no file.
    @Test func aRowFindsTheTranscriptOfItsCurrentConversation() async throws {
        let projects = try Projects()
        defer { projects.remove() }
        let current = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"
        try projects.transcript("-Users-x-p", user)
        try projects.transcript("-Users-x-q", user, id: current)
        var row = SessionRow.test(sessionId: session)
        let own = await TranscriptReader.transcript(of: row, projects: projects.url)
        #expect(own?.path(percentEncoded: false) == "\(projects.path)-Users-x-p/\(session).jsonl")
        row.currentId = current
        let cleared = await TranscriptReader.transcript(of: row, projects: projects.url)
        #expect(
            cleared?.path(percentEncoded: false) == "\(projects.path)-Users-x-q/\(current).jsonl")
        let notUUID = SessionRow.test(sessionId: "s1")
        #expect(await TranscriptReader.transcript(of: notUUID, projects: projects.url) == nil)
        #expect(await TranscriptReader.size(of: try #require(own)) == user.utf8.count)
    }

    // An offset inside a line skips to the next line, and a last line with no line break is not
    // complete yet, so neither is in the tail. A later read gets that line in full.
    @Test func theTailAfterAnOffsetHasOnlyFullLines() async throws {
        let projects = try Projects()
        defer { projects.remove() }
        try projects.transcript("-p", "line1\nline2\nlin")
        let file = projects.url.appending(path: "-p/\(session).jsonl")
        // The end is the offset after the last full line, or the offset of the read with no
        // full line.
        let cases: [(offset: Int, text: String, end: Int)] = [
            (0, "line1\nline2\n", 12), (2, "line2\n", 12), (5, "line2\n", 12),
            (6, "line2\n", 12), (7, "", 7), (12, "", 12), (15, "", 15),
        ]
        for (offset, text, end) in cases {
            let tail = try await TranscriptReader.tail(of: file, after: offset)
            #expect(tail == TranscriptTail(text: text, end: end))
        }
        await #expect(throws: TailFailure.shorter) {
            try await TranscriptReader.tail(of: file, after: 16)
        }
        await #expect(throws: TailFailure.tooLong) {
            try await TranscriptReader.tail(of: file, after: 0, limit: 14)
        }
        #expect(TranscriptReader.tailLimit == 4 * 1024 * 1024)
        let missing = projects.url.appending(path: "-p/none.jsonl")
        await #expect(throws: TailFailure.file(ENOENT)) {
            try await TranscriptReader.tail(of: missing, after: 0)
        }
        #expect(TailFailure.tooLong.reason == "The reply is too long to read.")
        #expect(TailFailure.shorter.reason == "The transcript got shorter while Bifrost read it.")
    }

    // The watch gives one event when it starts, so no write before the start is lost, and one
    // event after a write.
    @Test(.timeLimit(.minutes(1)))
    func aWriteGivesAChangeEvent() async throws {
        let projects = try Projects()
        defer { projects.remove() }
        try projects.transcript("-p", user)
        let file = projects.url.appending(path: "-p/\(session).jsonl")
        let events = Counter()
        let watch = Task {
            for await _ in TranscriptReader.changes(of: file) { events.add() }
        }
        defer { watch.cancel() }
        await waitUntil { events.count == 1 }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(other.utf8))
        try handle.close()
        await waitUntil { events.count >= 2 }
    }

    // A file that is not there gives one event and the end, so the reader finds the error.
    @Test func noFileGivesOneEventAndTheEnd() async throws {
        let projects = try Projects()
        defer { projects.remove() }
        var count = 0
        for await _ in TranscriptReader.changes(of: projects.url.appending(path: "none")) {
            count += 1
        }
        #expect(count == 1)
    }
}

// A count of events on the main actor.
@MainActor
private final class Counter {
    private(set) var count = 0
    func add() { count += 1 }
}
