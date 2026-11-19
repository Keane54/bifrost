// The edits of the list of slash commands in Settings > Slash commands
// (docs/behaviour/settings.md, "The slash list"). Each edit gives a new list. The section saves
// the new list with an edit of the settings.
package enum SlashList {
    // The list with the command at the end. The command is the trimmed text. The checks are in
    // this order: the form of the command, a copy of a command in the list, then the size of
    // the list.
    package static func add(_ list: [String], _ text: String) -> Result<[String], SettingsRefusal>
    {
        let command: String
        do {
            command = try SettingsText.checkSlashCommand(text)
        } catch {
            return .failure(error)
        }
        if list.contains(command) { return .failure(.slashCopy) }
        if list.count >= SettingsText.maxSlashCommands { return .failure(.slashFull) }
        return .success(list + [command])
    }

    // The list with no item at the index. An index out of range gives the same list.
    package static func remove(_ list: [String], at index: Int) -> [String] {
        guard list.indices.contains(index) else { return list }
        var next = list
        next.remove(at: index)
        return next
    }

    // The list with the item at the index moved by step: -1 is up, 1 is down. An index out of
    // range, or a move past an end, gives the same list.
    package static func move(_ list: [String], at index: Int, by step: Int) -> [String] {
        let (target, overflow) = index.addingReportingOverflow(step)
        guard !overflow, list.indices.contains(index), list.indices.contains(target) else {
            return list
        }
        var next = list
        next.insert(next.remove(at: index), at: target)
        return next
    }
}
