import Foundation

// The parts of a safe write that a test can replace: the sync of the temporary file, the rename,
// and the path of the temporary file. The system sync is a full sync (see fullSync). The system
// rename calls rename. The system temporary path has a new UUID, so two writes never use the same
// temporary file.
package struct WriteSteps: Sendable {
    package var sync: @Sendable (FileHandle) throws -> Void
    package var rename: @Sendable (String, String) throws -> Void
    // The path of the temporary file for the path of the file.
    package var temporaryPath: @Sendable (String) -> String

    package init(
        sync: @escaping @Sendable (FileHandle) throws -> Void,
        rename: @escaping @Sendable (String, String) throws -> Void,
        temporaryPath: @escaping @Sendable (String) -> String = WriteSteps.uniqueTemporaryPath
    ) {
        self.sync = sync
        self.rename = rename
        self.temporaryPath = temporaryPath
    }

    // The path of the file with a new UUID and ".tmp" at the end.
    package static func uniqueTemporaryPath(_ path: String) -> String {
        "\(path).\(UUID().uuidString.lowercased()).tmp"
    }

    package static let system = system()

    // The system steps. The two calls of the sync are parameters, so a test can record them.
    static func system(
        control: @escaping @Sendable (Int32, Int32) -> Int32 = { fcntl($0, $1) },
        flush: @escaping @Sendable (Int32) -> Int32 = { fsync($0) }
    ) -> WriteSteps {
        WriteSteps(
            sync: { handle in
                try fullSync(handle.fileDescriptor, control: control, flush: flush)
            },
            rename: { from, to in
                if Darwin.rename(from, to) != 0 { throw POSIXError.fromErrno() }
            })
    }

    // A full sync of the file. On macOS, fsync does not flush the write cache of the drive, so a
    // power cut can still lose the data. F_FULLFSYNC flushes that cache. A file system without
    // F_FULLFSYNC gets F_BARRIERFSYNC, then fsync. If all three fail, the function throws the
    // error of fsync.
    static func fullSync(
        _ descriptor: Int32, control: (Int32, Int32) -> Int32, flush: (Int32) -> Int32
    ) throws {
        if control(descriptor, F_FULLFSYNC) == 0 { return }
        if control(descriptor, F_BARRIERFSYNC) == 0 { return }
        if flush(descriptor) == 0 { return }
        throw POSIXError.fromErrno()
    }
}

// The JSON files of the stores. Each function is synchronous. The callers run them in
// @concurrent functions, so the file work does not run on the main actor.
package enum JSONFile {
    // The bytes of the file. A missing file gives nil. Other read errors throw, for example a
    // folder at the path or no permission.
    package static func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    // Write the data to a temporary name in the same folder, sync it, then rename it to the
    // file. So a crash cannot leave a part of a file. The system sync flushes the write cache of
    // the drive before the rename, so a power cut cannot leave an empty file. The file gets the
    // mode 0600. If a step fails, the temporary file is removed, the old file stays, and the
    // error of the step is thrown. The temporary file opens with O_EXCL, so a write never takes
    // a file that is already at the temporary path (S8).
    package static func write(_ data: Data, to url: URL, steps: WriteSteps = .system) throws {
        let path = url.path(percentEncoded: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = steps.temporaryPath(path)
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError.fromErrno() }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            do {
                try handle.write(contentsOf: data)
                try steps.sync(handle)
            } catch {
                try? handle.close()
                throw error
            }
            try handle.close()
            try steps.rename(temporary, path)
        } catch {
            // A failed clean-up must not hide the first error.
            unlink(temporary)
            throw error
        }
    }

    // Copy the file at source to target with the safe write, so the copy gets the mode 0600 and
    // replaces an old copy. The error of the read or of the write is thrown.
    package static func copy(_ source: String, to target: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: source))
        try write(data, to: URL(fileURLWithPath: target))
    }

    // Keep the data as the first copy of a file, for example state.json.before-native: a new
    // file with the mode 0600, with the safe write (the sync and the temporary path of the
    // steps). The rename never replaces an item at the path (RENAME_EXCL), so nothing writes
    // over a first copy, also when two writes run at the same time. The result is false when an
    // item is at the path: the copy that is there stays as it is. Each other failure throws.
    package static func keepFirstCopy(
        _ data: Data, at url: URL, steps: WriteSteps = .system
    ) throws -> Bool {
        var info = stat()
        if lstat(url.path(percentEncoded: false), &info) == 0 { return false }
        let exclusive = WriteSteps(
            sync: steps.sync,
            rename: { from, to in
                guard renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 else {
                    throw POSIXError.fromErrno()
                }
            }, temporaryPath: steps.temporaryPath)
        do {
            try write(data, to: url, steps: exclusive)
            return true
        } catch let error as POSIXError where error.code == .EEXIST {
            return false
        }
    }

    // The text form of the stores: two spaces of indent, sorted keys, "/" not escaped, and a
    // newline at the end.
    package static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    // The bytes of the compact JSON (no spaces, "/" not escaped) of a text in the form of encode.
    // The pretty form adds only spaces and line breaks outside the strings, and a string holds no
    // raw line break. So the count skips each space and line break outside a string, and the
    // value needs no second encode.
    package static func compactSize(ofStoreText data: Data) -> Int {
        var count = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                count += 1
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if byte != UInt8(ascii: " "), byte != UInt8(ascii: "\n") {
                count += 1
                if byte == UInt8(ascii: "\"") { inString = true }
            }
        }
        return count
    }
}

extension POSIXError {
    // The error of the last failed system call.
    static func fromErrno() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
