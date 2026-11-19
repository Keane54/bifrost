// The env of a child process. The child processes must not see the terminal or the Claude Code
// session that started Bifrost. Claude Code changes its behavior when it sees these variables.
// When Bifrost starts from Finder, its env does not have these variables. The child env must be
// the same in development.
package enum ChildEnvironment {
    static let removedKeys: Set<String> = [
        "CLAUDECODE", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
    ]
    static let removedPrefixes = ["CLAUDE_CODE_", "WARP_"]

    static func isRemoved(_ key: String) -> Bool {
        removedKeys.contains(key) || removedPrefixes.contains { key.hasPrefix($0) }
    }

    // Make the env for a child process from the source env. Remove the variables above. Keep all
    // other variables, for example HOME, PATH and LANG. For a PTY, set TERM and COLORTERM for the
    // terminal view.
    package static func make(from source: [String: String], pty: Bool) -> [String: String] {
        var env = source.filter { key, _ in !isRemoved(key) }
        if pty {
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
        }
        return env
    }
}
