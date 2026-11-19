// The values of the New session dialog and the checks on them (docs/behaviour/actions.md, "New
// session"). The dialog uses the checks to show a reason early, and the New session command
// checks the values again before it starts claude.
import BifrostFoundation

// The clean values of a new session. Only check makes one, so each value passed the checks.
package struct NewSessionSpec: Sendable, Equatable {
    package static let maxName = 64

    package private(set) var cwd: String
    package private(set) var name: String
    package private(set) var model: ModelChoice
    // nil: no flag, so claude uses its default mode.
    package private(set) var permissionMode: PermissionMode?
    // Empty: the session starts with no prompt.
    package private(set) var prompt: String
    package private(set) var worktree: Bool

    private init(
        cwd: String, name: String, model: ModelChoice, permissionMode: PermissionMode?,
        prompt: String, worktree: Bool
    ) {
        self.cwd = cwd
        self.name = name
        self.model = model
        self.permissionMode = permissionMode
        self.prompt = prompt
        self.worktree = worktree
    }

    // Check the values. The first failure gives the reason. The cwd loses its white space and
    // its last "/" characters, and cannot hold a NUL. The name and the prompt get the clean of
    // the session input and the trim. The name has one line (no tab, LF, U+2028 or U+2029) and
    // no hidden character of a local name (isHiddenInAName). claude reads an argument that
    // starts with "-" as a flag, so a name or a prompt cannot start with it. claude reads a
    // prompt that is only a command name as that command. The checks read Unicode scalars,
    // because claude reads bytes.
    package static func check(
        cwd: String, name: String, model: ModelChoice, permissionMode: PermissionMode?,
        prompt: String, worktree: Bool
    ) -> Result<NewSessionSpec, ActionRefusal> {
        let cwd = trimmingLastSlashes(cwd.trimmed())
        guard cwd.unicodeScalars.first == "/", !cwd.unicodeScalars.contains("\0") else {
            return .failure(.noFolder)
        }
        let name = InputPlan.clean(name).trimmed()
        guard !name.isEmpty else { return .failure(.noName) }
        guard name.count <= maxName else { return .failure(.nameTooLong) }
        if name.unicodeScalars.contains(where: isLineBreakInAName) { return .failure(.nameLines) }
        if name.unicodeScalars.contains(where: isHiddenInAName) { return .failure(.nameHidden) }
        guard name.unicodeScalars.first != "-" else { return .failure(.nameFlag) }
        let prompt = InputPlan.clean(prompt).trimmed()
        guard prompt.count <= InputPlan.maxText else { return .failure(.promptTooLong) }
        guard prompt.unicodeScalars.first != "-" else { return .failure(.promptFlag) }
        guard !NewSessionRules.isClaudeCommand(prompt) else { return .failure(.promptIsCommand) }
        return .success(
            NewSessionSpec(
                cwd: cwd, name: name, model: model, permissionMode: permissionMode,
                prompt: prompt, worktree: worktree))
    }

    // A tab, a line feed, or the line and paragraph separators. The clean of the session input
    // has changed each CR to a line feed.
    private static func isLineBreakInAName(_ scalar: Unicode.Scalar) -> Bool {
        ["\t", "\n", "\u{2028}", "\u{2029}"].contains(scalar)
    }

    // The path with no "/" at its end. The root folder stays "/".
    private static func trimmingLastSlashes(_ path: String) -> String {
        let scalars = path.unicodeScalars
        guard let last = scalars.lastIndex(where: { $0 != "/" }) else {
            return scalars.first == "/" ? "/" : ""
        }
        return String(Substring(scalars[...last]))
    }
}

package enum NewSessionRules {
    // The top-level commands and aliases of claude, also the hidden ones, and "help". The prompt
    // is the last argument of "claude --bg", and claude reads a prompt that is only one of these
    // names as that command, for example "update". The list has each command of the help text of
    // Claude Code 2.1.318, and also "config" and "migrate-installer" of older versions. An extra
    // name only refuses a prompt of one word, so the list can have more names than claude.
    package static let claudeCommands = [
        "agents", "attach", "auth", "auto-mode", "config", "design-login", "doctor",
        "drop-worktree-registrations", "edit-chrome-settings", "edit-hook",
        "edit-memory-settings", "edit-permission-rules", "edit-sandbox-settings",
        "edit-skill-overrides", "gateway", "help", "import", "import-conversations", "install",
        "kill", "logs", "mcp", "migrate-installer", "plugin", "plugins", "project", "purge", "rc",
        "remote-control", "respawn", "rm", "sandbox", "setup-token", "stop", "ultrareview",
        "update", "upgrade",
    ]

    // The reasons of the worktree box of the New session form while the folder check runs, and
    // after the check failed.
    package static let reasonChecking = "Checking the folder..."
    package static let reasonCheckFailed = "Bifrost couldn't check this folder."

    // The longest worktree name. Claude Code adds "worktree-" to it for the branch name.
    package static let maxWorktreeName = 40

    // The model choices of the New session dialog. standard gives no --model flag.
    package static let modelChoices: [(value: ModelChoice, label: String)] = [
        (.standard, "Default"), (.opus, "Opus"), (.sonnet, "Sonnet"), (.haiku, "Haiku"),
    ]

    // True when the text, after the trim, is a claude command name.
    package static func isClaudeCommand(_ text: String) -> Bool {
        claudeCommands.contains(text.trimmed())
    }

    // The name of the git worktree of a session name. Each run of characters outside a-z and 0-9
    // becomes one "-", the "-" characters at the ends go, and the name has at most
    // maxWorktreeName characters. An empty result gives "session".
    package static func worktreeName(_ name: String) -> String {
        var base = String.UnicodeScalarView()
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                base.append(scalar)
            } else if base.last != "-" {
                base.append("-")
            }
        }
        let cut = trimmingDashes(String(trimmingDashes(String(base)).prefix(maxWorktreeName)))
        return cut.isEmpty ? "session" : cut
    }

    // The options of a model select in the settings. The empty value is the default of Claude
    // Code.
    package static func modelOptions() -> [(value: ModelChoice, label: String)] {
        modelChoices.map { ($0.value, $0.value == .standard ? "Claude Code default" : $0.label) }
    }

    // The text is ASCII here, so a Character is a scalar.
    private static func trimmingDashes(_ text: String) -> String {
        guard let first = text.firstIndex(where: { $0 != "-" }),
            let last = text.lastIndex(where: { $0 != "-" })
        else { return "" }
        return String(text[first...last])
    }
}

// What a path is, and for a folder, whether it is in a git repository. ProcessProbe.dirInfo
// makes it.
package struct DirInfo: Sendable, Equatable {
    package enum Kind: String, Sendable {
        case dir, missing, other
    }

    package var kind: Kind
    package var git: Bool

    package init(kind: Kind, git: Bool) {
        self.kind = kind
        self.git = git
    }
}
