import BifrostFoundation
import Darwin
import Foundation

// The extra usage flag of ~/.claude.json, for the usage notification (docs/behaviour/usage.md,
// "The usage notification"). The monitor reads the file only when a notification is about to show
// and the account values give no flag. The home is the resolved home of the app, so a test home
// uses its own file.
//
// SECURITY: the file holds account data. The read never writes the file and never logs. A read
// problem gives the flag off and goes nowhere, because an error text can hold a part of the file.
package enum ClaudeJSON {
    // The read skips a file above this size.
    package static let maxBytes = 20 * 1024 * 1024

    // The file .claude.json in the home.
    package static func file(home: URL) -> URL {
        home.appending(path: ".claude.json", directoryHint: .notDirectory)
    }

    // True only when the file has the value true at oauthAccount.hasExtraUsageEnabled. A missing
    // file, an item that is not a regular file, a file above maxBytes and a file that is not JSON
    // give false. The read runs on the blocking executor, because a slow disk can hold it.
    @concurrent package static func extraUsageFlag(home: URL) async -> Bool {
        await BlockingExecutor.run {
            guard let data = cappedRead(file(home: home)),
                let flag = try? JSONDecoder().decode(FlagPath.self, from: data)
            else { return false }
            return flag.isOn
        }
    }

    // The bytes of the file, or nil: a missing file, an item that is not a regular file and a
    // file above maxBytes give nil. The open follows a link and does not wait (O_NONBLOCK), so a
    // FIFO at the path cannot hold the read. The type and the size come from the open file. The
    // read takes at most maxBytes + 1 bytes, because the file can get larger after the check of
    // its size. The read never writes the file and never logs. The call can wait for a slow
    // disk, so the caller runs it on the blocking executor. The flag of the usage notification
    // and the trust check of Reviews (TrustCheck) share it.
    package static func cappedRead(_ file: URL) -> Data? {
        let descriptor = open(file.path(percentEncoded: false), O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size <= off_t(maxBytes),
            let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes
        else { return nil }
        return data
    }
}

// The one key path of the file that the flag needs. The decode reads no other value, so a value
// elsewhere in the file that a JSON value cannot hold (row S6 of the stores port) does not stop
// the read. The file must still be JSON, and its top level and oauthAccount must be objects.
private struct FlagPath: Decodable {
    struct Account: Decodable {
        var hasExtraUsageEnabled: JSONValue?
    }

    var oauthAccount: Account?

    // True only for the value true at oauthAccount.hasExtraUsageEnabled.
    var isOn: Bool { oauthAccount?.hasExtraUsageEnabled == .bool(true) }
}
