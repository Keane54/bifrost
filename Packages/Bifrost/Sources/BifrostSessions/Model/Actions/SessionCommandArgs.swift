// The arguments of the claude commands that start a session (docs/behaviour/actions.md, "The
// session commands"): New session, Resume, Resume all and Take control. Each value is one
// argument. No shell reads them.
import BifrostFoundation

package enum SessionCommandArgs {
    // A statusLine command that prints nothing. A new session and Take control get it, so the
    // chat window does not show the statusline of the user. It is one argument.
    package static let noStatusLineSettings =
        #"{"statusLine":{"type":"command","command":"true"}}"#

    // The arguments of "claude --bg --resume" for Resume and Resume all. The ID is the continue ID
    // of the row: the resume ID of an owned row, the current ID of an external row.
    // An owned row gets no flag: a resume with a new flag starts a copy of a stopped background
    // session with a new session ID. A background session keeps its saved options, so a session
    // that Bifrost started keeps the hidden statusline.
    // An external row is parked only after a failed Take control. It ran in the foreground, so it
    // has no saved options. It gets the arguments of Take control, which keep the session ID.
    // An owned row with no resume ID yet gives noResumeId. An ID that is not a session ID gives
    // badSessionId.
    package static func resume(_ row: SessionRow) throws(ActionRefusal) -> [String] {
        guard let id = row.continueId else {
            throw row.kind == .owned && row.resumeId == nil ? .noResumeId : .badSessionId
        }
        switch row.kind {
        case .owned: return ["--bg", "--resume", id.text]
        case .external: return takeControl(id)
        }
    }

    // The arguments of "claude --bg --resume" for Take control. Take control starts from a
    // foreground session, which has no saved options, so the resume keeps the session ID and the
    // statusline flag works.
    package static func takeControl(_ id: SessionID) -> [String] {
        ["--bg", "--settings", noStatusLineSettings, "--resume", id.text]
    }

    // The arguments of "claude --bg" for the New session values. The flags come first and the
    // prompt comes last, because "--worktree" takes an optional value. Only NewSessionSpec.check
    // makes a spec, so the name and the prompt passed its checks: neither starts with "-", the
    // prompt is no command name, and the mode is never bypassPermissions. The standard model and
    // no mode give no flag. An empty prompt gives no argument.
    package static func newSession(_ spec: NewSessionSpec) -> [String] {
        var args = ["--bg", "--settings", noStatusLineSettings]
        if spec.worktree { args += ["--worktree", NewSessionRules.worktreeName(spec.name)] }
        if spec.model != .standard { args += ["--model", spec.model.rawValue] }
        if let mode = spec.permissionMode { args += ["--permission-mode", mode.rawValue] }
        args += ["--name", spec.name]
        if !spec.prompt.isEmpty { args.append(spec.prompt) }
        return args
    }
}
