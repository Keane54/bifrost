// The reads of a transcript (docs/behaviour/actions.md, "The transcript check" and "Hand
// over"). Claude Code cannot resume a session with no user message, so Take control checks the
// start of the transcript first. Hand over finds the transcript of a row, reads its size before
// the send, then reads the full lines after that size on each change of the file. Claude Code
// writes the transcript to <home>/.claude/projects/<project>/<session id>.jsonl. These reads only
// read.
import BifrostFoundation
import Darwin
import Foundation

package enum TranscriptReader {
    // The check reads at most this part of a transcript.
    package static let readBytes = 262_144

    // The text of a user line in a transcript.
    private static let userMessage = Array(#""type":"user""#.utf8)

    // True when a transcript of the session in a folder of projects has a user message in its
    // first readBytes. No transcript gives false. A read error gives true, so the check never
    // blocks a session that has messages. A session ID that is not a UUID gives false, and no
    // path is made from it. The reads run off the actor of the caller.
    @concurrent package static func hasMessages(projects: URL, sessionId: String) async -> Bool {
        guard SessionID(sessionId) != nil else { return false }
        let folder = projects.path(percentEncoded: false)
        let names: [String]
        switch entries(of: folder) {
        case .success(let list): names = list
        case .failure(.missing): return false
        case .failure(.failed): return true
        }
        let fileName = "\(sessionId).jsonl"
        for name in names {
            let file = URL(filePath: folder, directoryHint: .isDirectory)
                .appending(components: name, fileName, directoryHint: .notDirectory)
                .path(percentEncoded: false)
            switch start(of: file) {
            case .success(let bytes):
                if contains(bytes, userMessage) { return true }
            // No transcript in this project, or the name is a file and not a folder.
            case .failure(let error) where error.code == ENOENT || error.code == ENOTDIR:
                continue
            case .failure:
                return true
            }
        }
        return false
    }

    // Why the list of a folder failed: the folder is not there, or another error.
    private enum ListFailure: Error {
        case missing, failed
    }

    // The names in the folder, with no "." and "..". readdir gives nil at the end and at an
    // error, and only an error sets errno, so errno is 0 before each call.
    private static func entries(of folder: String) -> Result<[String], ListFailure> {
        guard let dir = opendir(folder) else {
            return .failure(errno == ENOENT ? .missing : .failed)
        }
        defer { closedir(dir) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(dir) else {
                return errno == 0 ? .success(names) : .failure(.failed)
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
    }

    // The first readBytes of the file, or the error number of the open or the read. The open
    // does not wait for a writer of a named pipe.
    private static func start(of file: String) -> Result<[UInt8], CallError> {
        let fd = open(file, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(CallError(code: errno)) }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: readBytes)
        var filled = 0
        while filled < readBytes {
            let count = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                return read(fd, base + filled, readBytes - filled)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(CallError(code: errno))
            }
            if count == 0 { break }
            filled += count
        }
        return .success(Array(buffer.prefix(filled)))
    }

    // True when the bytes hold the needle.
    private static func contains(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
        guard let first = needle.first, bytes.count >= needle.count else { return false }
        var index = 0
        while index <= bytes.count - needle.count {
            if bytes[index] == first && bytes[index..<index + needle.count].elementsEqual(needle) {
                return true
            }
            index += 1
        }
        return false
    }
}

// MARK: - The reads of Hand over

// The full lines of a transcript after an offset, and the offset of the byte after the last of
// them. With no full line, the end is the offset of the read.
package struct TranscriptTail: Sendable, Equatable {
    package var text: String
    package var end: Int

    package init(text: String, end: Int) {
        self.text = text
        self.end = end
    }
}

// Why a read of the tail of a transcript failed.
package enum TailFailure: Error, Sendable, Equatable {
    // A call of the system failed, with its error number.
    case file(Int32)
    // The file has more than the limit after the offset.
    case tooLong
    // The offset is after the end of the file.
    case shorter

    // The reason in the failure text of Hand over. Hand over shows no reason for a file error,
    // because the session stopped for Bifrost.
    package var reason: String {
        switch self {
        case .file(let code): "\(ErrorText.reason(code))."
        case .tooLong: "The reply is too long to read."
        case .shorter: "The transcript got shorter while Bifrost read it."
        }
    }
}

extension TranscriptReader {
    // A read of the tail takes at most this part of a transcript after the offset.
    package static let tailLimit = 4 * 1024 * 1024

    private static let newline = UInt8(ascii: "\n")

    // The transcript of the conversation that the row shows now: <id>.jsonl as a regular file in
    // the first project folder, by name, that has it. The ID is currentId, else the row ID, and
    // it must be a UUID, so no path is made from another text. No file gives nil. The reads run
    // off the actor of the caller.
    @concurrent package static func transcript(of row: SessionRow, projects: URL) async -> URL? {
        let id = row.currentId ?? row.sessionId
        guard SessionID(id) != nil else { return nil }
        let folder = projects.path(percentEncoded: false)
        guard case .success(let names) = entries(of: folder) else { return nil }
        for name in names.sorted() {
            let file = URL(filePath: folder, directoryHint: .isDirectory)
                .appending(components: name, "\(id).jsonl", directoryHint: .notDirectory)
            var info = stat()
            if lstat(file.path(percentEncoded: false), &info) == 0
                && info.st_mode & S_IFMT == S_IFREG
            {
                return file
            }
        }
        return nil
    }

    // The size of the file in bytes, or nil when the read fails. The read runs off the actor of
    // the caller.
    @concurrent package static func size(of file: URL) async -> Int? {
        var info = stat()
        guard stat(file.path(percentEncoded: false), &info) == 0 else { return nil }
        return Int(info.st_size)
    }

    // The full lines of the file from the offset to the end. Claude Code can write the file
    // while Bifrost reads it. When the byte before the offset is not a line break, the offset is
    // inside a line, and the text up to the next line break goes. A last line with no line
    // break is not complete yet, so it goes too, and a later read gets it in full. More than
    // limit bytes after the offset, and an offset after the end of the file, fail. The open does
    // not wait for a writer of a named pipe. The read runs off the actor of the caller.
    @concurrent package static func tail(
        of file: URL, after offset: Int, limit: Int = tailLimit
    ) async throws(TailFailure) -> TranscriptTail {
        let fd = open(file.path(percentEncoded: false), O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw .file(errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .file(errno) }
        let size = Int(info.st_size)
        let offset = max(offset, 0)
        guard offset <= size else { throw .shorter }
        guard size - offset <= limit else { throw .tooLong }
        // One byte more before the offset shows if the offset is at the start of a line.
        let from = offset == 0 ? 0 : offset - 1
        let bytes = try readRange(fd, from: from, count: size - from)
        let none = TranscriptTail(text: "", end: offset)
        var start = offset - from
        guard start <= bytes.count else { return none }
        if offset > 0 && bytes.first != newline {
            guard let first = bytes[start...].firstIndex(of: newline) else { return none }
            start = first + 1
        }
        guard let end = bytes.lastIndex(of: newline), end >= start else { return none }
        return TranscriptTail(
            text: String(decoding: bytes[start...end], as: UTF8.self), end: from + end + 1)
    }

    // The changes of the file: one event when the watch starts, then one event after each write,
    // extend, delete or rename of the file. The watch is a file-system object source on the
    // file. Its first event comes when the source is registered, so a write before that event
    // is in the read of that event. Events that wait while the reader reads become one event. No
    // file gives one event and the end. The end of the iteration stops the watch and closes the
    // file.
    package static func changes(of file: URL) -> AsyncStream<Void> {
        let (stream, events) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let fd = open(file.path(percentEncoded: false), O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else {
            events.yield()
            events.finish()
            return stream
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .global(qos: .utility))
        source.setRegistrationHandler { events.yield() }
        source.setEventHandler { events.yield() }
        source.setCancelHandler { close(fd) }
        events.onTermination = { _ in source.cancel() }
        source.activate()
        return stream
    }

    // The count bytes of the file from the offset, or fewer at the end of the file.
    private static func readRange(_ fd: Int32, from offset: Int, count: Int) throws(TailFailure)
        -> [UInt8]
    {
        var buffer = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            let got = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                return pread(fd, base + filled, count - filled, off_t(offset + filled))
            }
            if got < 0 {
                if errno == EINTR { continue }
                throw .file(errno)
            }
            if got == 0 { break }
            filled += got
        }
        return Array(buffer.prefix(filled))
    }
}

// The error number of a failed system call.
private struct CallError: Error {
    var code: Int32
}
