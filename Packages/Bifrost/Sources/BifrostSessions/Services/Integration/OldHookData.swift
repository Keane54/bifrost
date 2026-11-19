import BifrostFoundation
import Foundation

// The data of the old hook install in the dot folder of Bifrost: the file active and the folders
// events and sessions, which the old hooks and the old app wrote, and the folder bin with the
// scripts of the old hook entries. No other code removes them, so the start of the app removes
// them one time (docs/behaviour/live.md, "The old hook data").
package enum OldHookData {
    // The items that the clean-up always removes.
    package static let names = ["active", "events", "sessions"]
    // The folder of the old scripts. Old hook entries in the settings still run them.
    package static let scripts = "bin"

    // Remove the old hook data in the folder, and bin only when keepScripts is false
    // (ClaudeSettingsFile.keepOldScripts). A missing item is fine. The clean-up never touches mod,
    // live.sock, statusline-original.json or backups. An item that is a link goes as a link, and
    // the removal never goes into a folder that a link names. A failure is logged, and the
    // clean-up goes on with the next item.
    // A dot folder that is a link stays refused (user decision, 2026-11-17), so the clean-up then
    // removes nothing.
    @concurrent package static func remove(
        _ bifrostHome: URL, keepScripts: Bool, log: any IntegrationLog = SystemIntegrationLog()
    ) async {
        let items = keepScripts ? names : names + [scripts]
        let removed = await BlockingExecutor.run { () -> [String] in
            // A "/" at the end would make lstat follow the link.
            var home = bifrostHome.path(percentEncoded: false)
            while home.count > 1, home.hasSuffix("/") { home.removeLast() }
            var info = stat()
            if lstat(home, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { return [] }
            return items.filter { name in
                removeItem(bifrostHome.appending(path: name).path(percentEncoded: false), log: log)
            }
        }
        if !removed.isEmpty { log.record(.oldHookDataRemoved(removed)) }
    }

    // Remove the file or the folder at the path, with all of its content. True when an item was
    // there and went.
    private static func removeItem(_ path: String, log: any IntegrationLog) -> Bool {
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return false
        } catch {
            let failure = FileError(error, call: .remove, path: path)
            log.record(.oldHookDataNotRemoved(path: path, failure))
            return false
        }
    }
}
