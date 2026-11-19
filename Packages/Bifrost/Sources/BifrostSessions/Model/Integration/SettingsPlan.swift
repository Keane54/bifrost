// The plan of the changes to the settings of Claude Code (docs/behaviour/live.md, "The edit of the
// Claude Code settings file"). The rules do no file work, and a plan changes only a copy of its
// input.
//
// The old hook install of Bifrost put two kinds of entries into the settings: a hook entry with
// the command hookCommand under each row of hookRows, and the wrapper, a statusLine with the
// command statusLineCommand. The live mod replaces that install, so Bifrost only removes it now.
package enum SettingsPlan {
    package typealias Document = ClaudeSettingsDocument
    package typealias Value = ClaudeSettingsDocument.Value

    package static let hookCommand = "~/.bifrost/bin/bifrost-hook"
    package static let statusLineCommand = "~/.bifrost/bin/bifrost-statusline"

    // A row of the old hook install: an event, with a matcher or with none.
    package struct HookRow: Sendable, Equatable {
        package let event: String
        package let matcher: String?

        // "<event>", or "<event>:<matcher>" for a row with a matcher.
        package var name: String { matcher.map { "\(event):\($0)" } ?? event }
    }

    // The ten rows of the old hook install, in its order.
    package static let hookRows: [HookRow] = [
        HookRow(event: "SessionStart", matcher: nil),
        HookRow(event: "SessionEnd", matcher: nil),
        HookRow(event: "UserPromptSubmit", matcher: nil),
        HookRow(event: "PreToolUse", matcher: "AskUserQuestion"),
        HookRow(event: "PermissionRequest", matcher: "*"),
        HookRow(event: "PostToolUse", matcher: "*"),
        HookRow(event: "Notification", matcher: "permission_prompt"),
        HookRow(event: "Notification", matcher: "idle_prompt"),
        HookRow(event: "Stop", matcher: nil),
        HookRow(event: "StopFailure", matcher: nil),
    ]

    // The settings with no Bifrost entry:
    // - Each Bifrost hook goes from each hook entry, under each event and each matcher. A hook
    //   entry with other hooks keeps them, in their order. A hook entry with no other hook goes.
    // - An event with no entry left goes. An event with no Bifrost hook stays as it is, also an
    //   empty list.
    // - The hooks key goes when the plan removed a hook and no event is left.
    // - The wrapper gets the original statusLine of the user, in its place. With no original
    //   (the user had no statusLine), the statusLine goes.
    // A value of an unexpected type stays as it is. Each key that stays keeps its place.
    package static func planUninstall(_ settings: Document, original: Document?) -> Document {
        var next = settings
        if case .object(let hooks)? = next["hooks"] {
            // One pass over the events, so a file with many events takes linear time.
            var touched = false
            let planned = hooks.compactMapValues { member -> Value? in
                guard case .array(let entries) = member.value else { return member.value }
                var kept: [Value] = []
                var removed = false
                for entry in entries {
                    guard entryHasBifrostHook(entry), case .object(var object) = entry,
                        case .array(let list)? = object["hooks"]
                    else {
                        kept.append(entry)
                        continue
                    }
                    removed = true
                    let rest = list.filter { !isBifrostHook($0) }
                    if !rest.isEmpty {
                        object.setValue(.array(rest), forKey: "hooks")
                        kept.append(.object(object))
                    }
                }
                guard removed else { return member.value }
                touched = true
                return kept.isEmpty ? nil : .array(kept)
            }
            if touched {
                if planned.isEmpty {
                    next.removeValue(forKey: "hooks")
                } else {
                    next.setValue(.object(planned), forKey: "hooks")
                }
            }
        }
        if isWrapper(next["statusLine"]) {
            if let original {
                next.setValue(.object(original), forKey: "statusLine")
            } else {
                next.removeValue(forKey: "statusLine")
            }
        }
        return next
    }

    // True when planUninstall changes the settings: a Bifrost hook under any event and any
    // matcher, or the wrapper. It uses the same checks as planUninstall.
    package static func hasBifrostEntry(_ settings: Document) -> Bool {
        if isWrapper(settings["statusLine"]) { return true }
        guard case .object(let hooks)? = settings["hooks"] else { return false }
        return hooks.members.contains { member in
            member.value.array?.contains(where: entryHasBifrostHook) ?? false
        }
    }

    // The rows of the old hook install that the settings do not have, by name, and whether the
    // statusLine is the wrapper. A row needs an entry under its event with the same matcher (or
    // with no matcher, for a row with none) and with a Bifrost hook.
    package static func checkInstall(_ settings: Document)
        -> (missingHooks: [String], statusLineInstalled: Bool)
    {
        let hooks = settings["hooks"]
        return (
            hookRows.filter { !hasRow(hooks, $0) }.map(\.name),
            isWrapper(settings["statusLine"])
        )
    }

    // MARK: - The checks

    // An object with the command of the Bifrost hook.
    private static func isBifrostHook(_ hook: Value) -> Bool {
        hook.object?["command"]?.text?.is(hookCommand) ?? false
    }

    // An object with a list of hooks that has a Bifrost hook.
    private static func entryHasBifrostHook(_ entry: Value) -> Bool {
        entry.object?["hooks"]?.array?.contains(where: isBifrostHook) ?? false
    }

    // An object with the command of the wrapper.
    private static func isWrapper(_ statusLine: Value?) -> Bool {
        statusLine?.object?["command"]?.text?.is(statusLineCommand) ?? false
    }

    private static func hasRow(_ hooks: Value?, _ row: HookRow) -> Bool {
        guard let entries = hooks?.object?[row.event]?.array else { return false }
        return entries.contains { entry in
            guard let object = entry.object else { return false }
            let sameMatcher =
                switch (object["matcher"], row.matcher) {
                case (nil, nil): true
                case (.string(let matcher)?, let wanted?): matcher.is(wanted)
                default: false
                }
            return sameMatcher && entryHasBifrostHook(entry)
        }
    }
}
