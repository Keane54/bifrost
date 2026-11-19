import BifrostFoundation

// The history of the New session dialog: the recent folders, the model and the permission mode
// of the last new session, and the recent slash commands. ui-state.json keeps it under the key
// history, and BifrostWindows reads and writes it there (UIStateValues.swift).
package struct History: Sendable, Equatable {
    package static let maxRecentDirs = 10, maxRecentSlash = 8
    package static let empty = History()

    // The newest folder first. Each folder starts with "/" and is in the list one time.
    package var recentDirs: [String]
    package var model: ModelChoice
    // nil: the default mode of Claude Code.
    package var permissionMode: PermissionMode?
    // The newest command first. Each command passes SlashCommand.clean, has no white space at
    // its ends and is in the list one time.
    package var recentSlash: [String]
    // The fields of the saved history that this app does not know. The JSON form writes them
    // again.
    package var unknown = UnknownFields()

    package init(
        recentDirs: [String] = [], model: ModelChoice = .standard,
        permissionMode: PermissionMode? = nil, recentSlash: [String] = []
    ) {
        self.recentDirs = recentDirs
        self.model = model
        self.permissionMode = permissionMode
        self.recentSlash = recentSlash
    }

    // The known keys of a saved history. Each other key is an unknown field.
    private static let keys: Set<String> = ["model", "permissionMode", "recentDirs", "recentSlash"]

    // The history in a saved value of ui-state.json. A bad value gets its default value, and a
    // value that is not an object gives the empty history:
    // - A model that is not the text of a model choice gives the default model.
    // - A mode that is not the text of a permission mode gives the default mode.
    // - Each list keeps its first good items, in the order of the list, with no repeat, up to its
    //   limit. A folder is a text that starts with "/". A command is a text that
    //   SlashCommand.clean gives back with no change.
    // - The history keeps its unknown fields.
    package static func parse(_ value: JSONValue?) -> History {
        guard let fields = value?.object else { return empty }
        let mode = fields["permissionMode"]?.string.flatMap(PermissionMode.init(rawValue:))
        var history = History(
            recentDirs: clean(fields["recentDirs"], isFolder, limit: maxRecentDirs),
            model: fields["model"]?.string.flatMap(ModelChoice.init(rawValue:)) ?? .standard,
            permissionMode: mode,
            recentSlash: clean(fields["recentSlash"], isCommand, limit: maxRecentSlash))
        history.unknown = UnknownFields(fields, known: keys)
        return history
    }

    // The saved form of the history, with the field names of the file and the unknown fields.
    // The default model and the default mode are the empty text.
    package var json: JSONValue {
        .object(
            unknown.merged(with: [
                "model": .string(model.rawValue),
                "permissionMode": .string(permissionMode?.rawValue ?? ""),
                "recentDirs": .array(recentDirs.map(JSONValue.string)),
                "recentSlash": .array(recentSlash.map(JSONValue.string)),
            ]))
    }

    // The history after the user started a session: the folder goes first in the list, and the
    // model and the mode replace the last ones. The new session check already checked the folder.
    package func remembering(cwd: String, model: ModelChoice, mode: PermissionMode?) -> History {
        var next = self
        next.model = model
        next.permissionMode = mode
        next.recentDirs = Self.putFirst(cwd, in: recentDirs, limit: Self.maxRecentDirs)
        return next
    }

    // The history after the user ran a slash command: the trimmed command goes first in the
    // list. A text that is not a slash command changes nothing.
    package func rememberingSlash(_ text: String) -> History {
        let command = text.trimmed()
        guard Self.isCommand(command) else { return self }
        var next = self
        next.recentSlash = Self.putFirst(command, in: recentSlash, limit: Self.maxRecentSlash)
        return next
    }

    // The folders that the dialog offers: the recent folders, then the project folder of each
    // row (a worktree gives its repository), with no repeat and at most maxRecentDirs.
    package func recentDirectories(_ rows: [SessionRow]) -> [String] {
        var folders: [String] = []
        for folder in recentDirs + rows.map({ repoPath($0.cwd) }) {
            guard folders.count < Self.maxRecentDirs else { break }
            if Self.isFolder(folder), !folders.contains(folder) { folders.append(folder) }
        }
        return folders
    }

    // MARK: - The rules of the items

    // A folder starts with the scalar "/", so a combining mark after the slash does not change
    // the check.
    private static func isFolder(_ text: String) -> Bool {
        text.unicodeScalars.first == "/"
    }

    // A command passes SlashCommand.clean, and the clean-up does not change it: it has no white
    // space at its ends.
    private static func isCommand(_ text: String) -> Bool {
        (try? SlashCommand.clean(text)) == text
    }

    // The first good texts of a saved list, with no repeat, up to the limit. A list that is not
    // a JSON array gives no texts.
    private static func clean(_ value: JSONValue?, _ isGood: (String) -> Bool, limit: Int)
        -> [String]
    {
        var texts: [String] = []
        for case let text? in (value?.array ?? []).map(\.string) {
            guard texts.count < limit else { break }
            if isGood(text), !texts.contains(text) { texts.append(text) }
        }
        return texts
    }

    // The list with the item first, with no other copy of it, cut to the limit.
    private static func putFirst(_ item: String, in list: [String], limit: Int) -> [String] {
        Array(([item] + list.filter { $0 != item }).prefix(limit))
    }
}
