// The reasons why a session action does not run, or failed. message is the text that the user
// reads (docs/behaviour/actions.md, "Refusals"): plain, friendly English with no code in it.
import Foundation

package enum ActionRefusal: Error, Sendable, Hashable {
    // The values of the New session dialog (NewSessionSpec.check), in the order of the checks.
    case noFolder, noName, nameTooLong, nameLines, nameHidden, nameFlag
    case promptTooLong, promptFlag, promptIsCommand
    // The folder of a new session: it is not a folder, or it is not in a git repository, so a
    // worktree cannot start in it.
    case dirMissing, noGit
    // A session ID or a process ID that is not valid. Bifrost never signals a PID of 1 or less.
    case badSessionId, badPid
    // The process of the PID is not the claude process of the check (another program, another
    // start time, or gone), so Bifrost does not signal it.
    case notClaudeProcess(pid: pid_t)
    // The system refused the SIGTERM for a reason other than a process that already ended.
    case signalFailed
    // An owned row with no resume ID yet: a resume by another ID would start a second job.
    case noResumeId
    // claude does not trust the folder yet. The text shows the folder without the hidden
    // characters of a name (withoutHiddenCharacters).
    case trust(dir: String)
    // claude ended with an exit code and wrote this text, with no control characters and no
    // hidden characters (ClaudeOutput.claudeFailure).
    case claudeReported(String)
    // claude ended with an exit code and wrote no text.
    case claudeExited(code: Int32)
    // The runner ended the claude command (the time limit, a signal, the output limit or a
    // cancel), or the command did not start. That text can hold the raw arguments, so the user
    // gets a plain text.
    case claudeFailed
    // Bifrost found no claude command in the login environment.
    case claudeNotFound

    // A start of claude: claude --bg gave no short ID, the new session did not show in time, a
    // resumed session did not show again in time, the old process of Take control did not end
    // in time, or the resumed session of Take control did not stay. A short ID that Bifrost
    // knows goes into the text, so the user can read the logs of the session.
    case startGaveNoId
    case notStarted(shortId: ShortID)
    case notResumed
    case notEnded
    case resumeFailed(shortId: ShortID?)

    // The row and the lock: the row is not in the list, another action runs on the session,
    // a New session start runs, or Resume all runs.
    case unknownSession, locked, creating, resumeAllRuns
    // The job of a session command ended before its last step: its caller cancelled it, or the
    // registry stopped (the app quits). The job runs no step after that.
    case cancelled

    // The row does not fit the action: an external row, a parked row, an action only for an
    // external row, an action only for an owned row that runs, a row that is not parked, and a
    // review session that cannot resume.
    case external, parked, onlyExternal, onlyRunning, notParked, prResume
    // The session works on a reply, waits on a prompt, or is not idle (Take control).
    case working, openPrompt, notIdle
    // The row has no short ID or no PID yet, or its process changed during the checks.
    case noShortId, noPid, processChanged
    // Only an --all read lists the row (ActiveListing.unconfirmed), and the check of the active
    // list gave no list, with the reason of the failed list when the registry has it. Bifrost
    // does not know if the session runs, so Resume, Resume all and Delete leave it alone.
    case unconfirmed(AgentListError?)
    // The transcript of the session has no user message, so Claude Code cannot resume it.
    case noMessages

    // Delete and Take control run only after the confirmation of the user.
    case deleteNotConfirmed, takeControlNotConfirmed
    // Delete: Bifrost does not delete an external session; claude rm kept a worktree with
    // commits on no remote, or with changes that are not committed; claude rm took too long;
    // the worktree changed after the check of the dialog; the session did not stop in time.
    case deleteExternal, kept, uncommitted, rmTooSlow, worktreeChanged, notStopped

    // The folders and the apps: the row has no project folder, the folder of the row is not
    // there, the row has no worktree, the app is not installed, no terminal app is installed,
    // or Bifrost does not know the terminal app of an external row. The text of folderMissing
    // shows the path without the hidden characters of a name.
    case noProjectFolder
    case folderMissing(String)
    // The path of an open is not a folder (for example a file), Bifrost could not read what is at
    // the path, or it could not check it in time. The texts show the path without the hidden
    // characters of a name.
    case notAFolder(String)
    case folderUnreadable(String)
    case folderUnchecked
    case noWorktree, unknownApp, noTerminal, terminalUnknown
    // An open of a folder or an app failed. The text says why. The text shows without the hidden
    // characters of a name, because it can hold a path.
    case openFailed(String)
    // Open in terminal could not write the command file in the run folder.
    case commandFileFailed

    // The session input refused the text (Send message, Run slash command, Compact, Rename).
    case input(InputRefusal)
    // Rename refused the local name.
    case alias(AliasRefusal)

    package var message: String {
        switch self {
        case .noFolder: "Choose a project folder."
        case .noName: "Type a name."
        case .nameTooLong:
            "The name is too long. The maximum is \(NewSessionSpec.maxName) characters."
        case .nameLines: "The name has one line."
        case .nameHidden: AliasRefusal.control.reason
        case .nameFlag: #"The name cannot start with "-"."#
        case .promptTooLong: InputRefusal.tooLong.message
        case .promptFlag: #"The first prompt cannot start with "-"."#
        case .promptIsCommand: "That prompt is also a Claude command name. Add a few more words."
        case .dirMissing: "This folder doesn't exist."
        case .noGit: "This folder isn't in a git repository, so it can't use a worktree."
        case .badSessionId: "That session ID isn't valid."
        case .badPid: "The process ID of this session isn't valid."
        case .notClaudeProcess(let pid):
            "Process \(pid) isn't a Claude process, so Bifrost left it alone."
        case .signalFailed: "Bifrost couldn't stop the terminal session. Try again."
        case .noResumeId:
            "Bifrost doesn't know which ID resumes this session yet. Try again in 30 seconds."
        case .trust(let dir): ClaudeOutput.trustMessage(withoutHiddenCharacters(dir))
        case .claudeReported(let text): "Claude Code reported a problem: \(text)"
        case .claudeExited(let code):
            "Claude Code stopped before it finished (code \(code)). Try again in a moment."
        case .claudeFailed: "A Claude Code command failed. Try again in a moment."
        case .claudeNotFound:
            "Bifrost can't find Claude Code. Check that the claude command works in a terminal."
        case .startGaveNoId: "Claude Code didn't give the new session an ID. Try again in a moment."
        case .notStarted(let shortId):
            "The session \(shortId.text) did not start in 30 seconds. Run claude logs "
                + "\(shortId.text) to see the cause."
        case .notResumed: "The session did not start again in 30 seconds."
        case .notEnded:
            "The session process did not end in 5 seconds. Bifrost did not start a copy of the "
                + "session."
        case .resumeFailed(let shortId):
            "Claude Code could not resume this session."
                + (shortId.map { " Run claude logs \($0.text) to see the cause." } ?? "")
        case .unknownSession: ActionReasons.gone
        case .locked: "Another action is still running on this session. Try again in a moment."
        case .creating: "A new session is already starting. Please wait."
        case .resumeAllRuns: ActionReasons.resumeAllRuns
        case .cancelled: "Bifrost stopped this action before it finished."
        case .external: ActionReasons.external
        case .parked: ActionReasons.parked
        case .onlyExternal: ActionReasons.onlyExternal
        case .onlyRunning: "This only works for a Bifrost session that is running."
        case .notParked: "This session isn't parked, so there's nothing to resume."
        case .prResume: ActionReasons.prResume
        case .working: "This session is working right now. Try again when it has finished."
        case .openPrompt:
            "This session is waiting on a prompt. Answer it in the chat window first."
        case .notIdle: "Take control only works while the session is idle or has just finished."
        case .noShortId: ActionReasons.waitForId
        case .noPid: "Bifrost doesn't know the process ID of this session."
        case .processChanged: "The process of this session changed, so Bifrost left it alone."
        case .unconfirmed(let reason):
            "Bifrost couldn't check that this session has stopped"
                + (reason.map { ", because \($0.cause)" } ?? "") + ". Try again in a moment."
        case .noMessages:
            "This session has no messages yet, so there's nothing to take over. Send a message "
                + "in its terminal first."
        case .deleteNotConfirmed: "Delete needs your confirmation first."
        case .takeControlNotConfirmed: "Take control needs your confirmation first."
        case .deleteExternal: "Bifrost can't delete a session that runs in another terminal."
        case .kept:
            "Claude Code kept this session, because its worktree has commits that exist on no "
                + "remote. Open the worktree to check them, then delete again."
        case .uncommitted:
            "This worktree has changes that aren't committed, so Claude Code won't delete it. "
                + "Open the worktree, commit or discard them, then delete again."
        case .rmTooSlow:
            "Claude Code took too long to delete this session. Check the worktree, then delete "
                + "again."
        case .worktreeChanged: "The worktree changed after the check. Check it again, then delete."
        case .notStopped: "The session didn't stop in time. Try Delete again in a moment."
        case .noProjectFolder: ActionReasons.noProjectFolder
        case .folderMissing(let path): "The folder \(withoutHiddenCharacters(path)) doesn't exist."
        case .notAFolder(let path):
            "\(withoutHiddenCharacters(path)) isn't a folder, so Bifrost didn't open it."
        case .folderUnreadable(let path):
            "Bifrost can't read the folder \(withoutHiddenCharacters(path)). Check that you can "
                + "open it in Finder."
        case .folderUnchecked: "Bifrost couldn't check this folder in time. Try again."
        case .noWorktree: "This session doesn't have a worktree."
        case .unknownApp: "Bifrost doesn't know that app."
        case .noTerminal: ActionReasons.noTerminal
        case .terminalUnknown: ActionReasons.terminalUnknown
        case .openFailed(let text): withoutHiddenCharacters(text)
        case .commandFileFailed:
            "Bifrost couldn't write the file that opens this session in your terminal. Try again."
        case .input(let refusal): refusal.message
        case .alias(let refusal): refusal.reason
        }
    }
}

extension ActionRefusal {
    // The refusal of an action that sends input to the session. It keeps the text of the input.
    package static func of(_ error: InputRefusal) -> ActionRefusal {
        .input(error)
    }
}
