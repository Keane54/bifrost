import BifrostFoundation
import BifrostSessions
import Foundation

// The parse of the output of the claude plugin commands (docs/behaviour/live.md, The plugin
// commands): the JSON list of a list command and the JSON result line of a write command. The
// Live details and skills sections show the texts of the failures, so the texts are plain.

// The list that a list command gives. The text of a failure names it.
package enum PluginList: String, Sendable {
    case plugin, marketplace
}

// The failure of a plugin command, or of the lock of the plugin changes (SerialLock). message is
// the text that the app shows.
package enum PluginFailure: MessageError, Sendable, Equatable {
    // The command did not end within the time limit (PluginCLI.timeout), or a write command did
    // not end within the grace after its SIGTERM (PluginCLI.grace).
    case timedOut
    // A list command failed, or its output has no JSON list. stderr is the trimmed stderr.
    case unreadableList(PluginList, end: ExecEnd, stderr: String)
    // The result line of a write command has this message from claude.
    case refused(String)
    // A write command ended with code 0, but it gave no result line that Bifrost can use.
    case noResult
    // A write command failed with no message in its result line. stderr is the trimmed stderr.
    case commandFailed(end: ExecEnd, stderr: String)
    // The marketplace folder is not an absolute file path, or it has a line break.
    case badFolder
    // A plugin ID or a marketplace name starts with "-", so claude would read it as an option.
    case optionLike(String)
    // Another change holds the lock.
    case busy
    // A cancel of the calling task stopped a list command, or a change between two of its steps.
    // A write command never takes a cancel.
    case cancelled

    // The refusals of the Live details and skills actions (docs/behaviour/live.md, Live details
    // control). Each one comes before the step that would change something.

    // The app found no claude.
    case claudeNotFound
    // Live details needs ClaudeVersionCheck.liveMinimum or a later version. found is the version
    // of claude, or nil when the check got none.
    case liveVersionTooOld(found: ClaudeCodeVersion?)
    // Turn on found no plugin with these IDs.
    case notInstalled(PluginIDs)
    // A marketplace of another program has the name of the marketplace of Bifrost. place is its
    // path, else the kind of its source.
    case foreignMarketplace(name: String, place: String)
    // Bifrost cannot read the Claude Code settings file, so it does not look for the old hook
    // install. reason is the text of the read. keptOldHooks: Remove did its plugin steps, and
    // only the old hooks stay; else nothing changed.
    case unreadableSettings(reason: String, keptOldHooks: Bool)
    // The removal of the old hook install from the settings file failed.
    case settingsEdit(IntegrationFailure)
    // The copy or the removal of the mod folder or of the skills folder failed.
    case folder(SyncFailure)

    package var message: String {
        switch self {
        case .timedOut: "Claude Code didn't finish in 30 seconds."
        case .unreadableList(let list, let end, let stderr):
            "Bifrost couldn't read the \(list.rawValue) list from Claude Code: "
                + Self.listReason(end, stderr)
        case .refused(let text): text
        case .noResult: "Claude Code gave no result."
        case .commandFailed(let end, let stderr): stderr.isEmpty ? Self.endText(end) : stderr
        case .badFolder: "The plugin folder path must be absolute and have no line break"
        case .optionLike(let value):
            "Bifrost won't pass \(value) to Claude Code, because it starts with a dash."
        case .busy: "Another change is still running. Try again in a moment."
        case .cancelled: "Bifrost stopped the Claude Code command."
        case .claudeNotFound: "claude was not found."
        case .liveVersionTooOld(let found):
            "Live details needs Claude Code \(ClaudeVersionCheck.liveMinimum) or later. "
                + (found.map { "This Mac has \($0)." } ?? Self.claudeNotFound.message)
        case .notInstalled(let ids):
            ids == .skills ? "Bifrost skills are not installed." : "Live details is not installed."
        case .foreignMarketplace(let name, let place):
            // The place comes from another program, so it loses its unsafe characters
            // (cleanText).
            "A marketplace with the name \(name) already exists at "
                + "\(cleanText(place)). Bifrost did not change it."
        case .unreadableSettings(let reason, let keptOldHooks):
            "Bifrost can't read ~/.claude/settings.json, so it "
                + (keptOldHooks ? "didn't remove the old hooks. " : "didn't change anything. ")
                + reason
        case .settingsEdit(let failure): failure.message
        case .folder(let failure): failure.message
        }
    }

    // The reason of a list that Bifrost cannot read: the stderr, else the end, else "no list".
    private static func listReason(_ end: ExecEnd, _ stderr: String) -> String {
        if !stderr.isEmpty { return stderr }
        switch end {
        case .exited(0): return "it gave no list"
        case .exited(let code): return "it exited with code \(code)"
        default: return ErrorText.ended("claude", end)
        }
    }

    // The text of the end of a command that failed with no stderr.
    private static func endText(_ end: ExecEnd) -> String {
        if case .exited(let code) = end { return "claude exited with code \(code)" }
        return ErrorText.ended("claude", end)
    }
}

// The entry of a plugin in the plugin list.
package struct PluginEntry: Sendable, Equatable {
    package var enabled: Bool
    // The folder that Claude Code reads the plugin from, or nil.
    package var folder: String?
    package var errors: [String]

    package init(enabled: Bool, folder: String?, errors: [String]) {
        self.enabled = enabled
        self.folder = folder
        self.errors = errors
    }

    // The entry from the fields of the list item. Only the JSON value true is on. A field of
    // another type gives no folder, and an error that is not a string is left out.
    package init(_ fields: [String: JSONValue]) {
        enabled = fields["enabled"] == .bool(true)
        folder = fields["readFromFolder"]?.string
        errors = fields["errors"]?.array?.compactMap(\.string) ?? []
    }
}

// The entry of a marketplace in the marketplace list.
package struct MarketplaceEntry: Sendable, Equatable {
    // The kind of the source, for example "directory". A source that is not a string is "".
    package var source: String
    package var path: String?

    package init(source: String, path: String?) {
        self.source = source
        self.path = path
    }

    package init(_ fields: [String: JSONValue]) {
        source = fields["source"]?.string ?? ""
        path = fields["path"]?.string
    }
}

// The checks of the two controls that compare a path of a list with a folder of Bifrost.
extension PluginEntry {
    // True when the plugin reads the folder, or when the list gives no folder.
    package func reads(_ folder: URL) -> Bool {
        self.folder.map { samePath($0, folder.path) } ?? true
    }
}

extension MarketplaceEntry {
    // True when the path of the marketplace is the folder. A marketplace with no path is not.
    package func isAt(_ folder: URL) -> Bool {
        path.map { samePath($0, folder.path) } ?? false
    }

    // The refusal of a marketplace of another program: a marketplace with the name of the
    // marketplace of Bifrost whose path is not the folder of Bifrost, or that has no path. The
    // place is its path, else the kind of its source. nil for the marketplace of Bifrost.
    package func foreignRefusal(_ ids: PluginIDs, folder: URL) -> PluginFailure? {
        isAt(folder) ? nil : .foreignMarketplace(name: ids.marketplace, place: path ?? source)
    }
}

// True when two absolute paths name the same place after the removal of the "." and ".." parts
// and of a "/" at the end. Two slashes in a row stay, so "/a//b" is not "/a/b". A "~" at the
// start expands to the home folder. The compare reads no file, so it does not follow links.
private func samePath(_ a: String, _ b: String) -> Bool {
    func standard(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false).standardized.path
    }
    return standard(a) == standard(b)
}

package enum PluginText {
    // The objects of the JSON list in the output of a list command. The list starts at the first
    // line that begins with "[", because claude can write a note before it. The list ends at the
    // end of the output. An item that is not an object is left out. A run that did not end with
    // code 0, or an output with no JSON list, gives unreadableList.
    package static func list(
        _ result: ExecResult, name: PluginList
    ) throws(PluginFailure) -> [[String: JSONValue]] {
        let failure = PluginFailure.unreadableList(
            name, end: result.end, stderr: result.stderr.trimmed())
        guard result.succeeded else { throw failure }
        let lines = result.stdout.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("[") }),
            let items = json(lines[start...].joined(separator: "\n"))?.array
        else { throw failure }
        return items.compactMap(\.object)
    }

    // Check the result of a write command. Only the last line that is not empty counts: claude
    // can write other lines first. The outcome "ok" passes. The failure code
    // "already_in_goal_state" passes too, because enable and disable exit with code 1 for a
    // plugin that is already on or off. A message in the line gives refused. Else: an exit with
    // code 0 gives noResult, and another end gives commandFailed with the stderr or the end.
    package static func check(_ result: ExecResult) throws(PluginFailure) {
        let last = result.stdout.components(separatedBy: "\n").last { !$0.trimmed().isEmpty }
        let fields = last.flatMap(json)?.object ?? [:]
        if fields["outcome"] == .string("ok") { return }
        if fields["failureCode"] == .string("already_in_goal_state") { return }
        if let message = fields["message"]?.string, !message.isEmpty { throw .refused(message) }
        if result.succeeded { throw .noResult }
        throw .commandFailed(end: result.end, stderr: result.stderr.trimmed())
    }

    // The JSON value of the text, or nil for text that is not JSON.
    private static func json(_ text: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
