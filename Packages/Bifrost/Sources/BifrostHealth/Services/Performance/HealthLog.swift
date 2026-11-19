import BifrostFoundation
import Darwin
import Foundation
import OSLog

// The health log file (docs/behaviour/health.md, "Performance"): health.log in the logs folder of
// the app, one line for each past event, so the user can look back after a Clear. Each line
// starts with the ISO time. At 1 MB the file moves to health.old.log (an older one goes), and a
// new file starts. A write error never stops Bifrost: it goes only to the log of the system.
// Clear does not change the file.
package struct HealthLog: Sendable {
    package static let name = "health.log"
    package static let oldName = "health.old.log"
    package static let maxBytes = 1_000_000
    private static let logger = Logger(bifrost: "performance")

    package let folder: URL

    // folder: the logs folder of the app (DataFolders.logs).
    package init(folder: URL) {
        self.folder = folder
    }

    // Write one line. A line break in the text becomes a space, so one event stays one line. The
    // caller writes one line at a time, so the lines keep their order.
    @concurrent package func write(_ text: String, at time: Date) async {
        let one = text.replacing(/\r\n|\r|\n/, with: " ")
        let line = "\(time.formatted(.iso8601WithMilliseconds)) \(one)\n"
        let folder = folder
        let failure = await BlockingExecutor.run { Self.append(line, in: folder) }
        if let failure {
            Self.logger.error(
                "Bifrost cannot write the health log: \(failure.message, privacy: .private)")
        }
    }

    private static func append(_ line: String, in folder: URL) -> FileError? {
        let manager = FileManager.default
        let file = folder.appending(path: name)
        let path = file.path(percentEncoded: false)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return FileError(error, call: .createFolder, path: folder.path(percentEncoded: false))
        }
        let size = (try? manager.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        if size >= maxBytes {
            let old = folder.appending(path: oldName)
            try? manager.removeItem(at: old)
            do {
                try manager.moveItem(at: file, to: old)
            } catch {
                return FileError(
                    error, call: .rename(to: old.path(percentEncoded: false)), path: path)
            }
        }
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .system(.save, path: path, code: errno) }
        defer { close(descriptor) }
        let bytes = Array(line.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        return written == bytes.count ? nil : .system(.save, path: path, code: errno)
    }
}

extension FormatStyle where Self == Date.ISO8601FormatStyle {
    // "2026-11-18T09:03:12.345Z": the time in UTC with milliseconds.
    fileprivate static var iso8601WithMilliseconds: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    }
}
