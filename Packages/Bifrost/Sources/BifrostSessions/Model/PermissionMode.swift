// The permission modes that a new session can start with. The raw value is the value of the
// --permission-mode flag of claude. The list has the modes of "claude --help" without
// bypassPermissions. A session with no mode gets the default mode of Claude Code and no flag.
package enum PermissionMode: String, Sendable, CaseIterable {
    case acceptEdits, auto, manual, dontAsk, plan
}
