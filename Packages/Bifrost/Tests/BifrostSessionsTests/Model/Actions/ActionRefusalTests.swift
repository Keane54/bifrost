// The refusals of the session actions (docs/behaviour/actions.md, "Refusals"): each refusal has
// one friendly text, with no code in it.
import BifrostTestSupport
import Testing

@testable import BifrostSessions

// The text of each refusal, character for character. The switch has no default, so a new case
// does not compile until it gets its text here. The compiler does not check samples: a new case
// also needs a value there.
private func expectedText(_ refusal: ActionRefusal) -> String {
    switch refusal {
    case .noFolder: "Choose a project folder."
    case .noName: "Type a name."
    case .nameTooLong: "The name is too long. The maximum is 64 characters."
    case .nameLines: "The name has one line."
    case .nameHidden: "A name can't hold control or hidden characters."
    case .nameFlag: #"The name cannot start with "-"."#
    case .promptTooLong: "The text is too long. The maximum is 20,000 characters."
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
    case .trust(let dir):
        "Claude Code doesn't trust this folder yet. Run claude in \(dir) once, accept the trust "
            + "prompt, then try again."
    case .claudeReported(let text): "Claude Code reported a problem: \(text)"
    case .claudeExited(let code):
        "Claude Code stopped before it finished (code \(code)). Try again in a moment."
    case .claudeFailed: "A Claude Code command failed. Try again in a moment."
    case .claudeNotFound:
        "Bifrost can't find Claude Code. Check that the claude command works in a terminal."
    case .startGaveNoId: "Claude Code didn't give the new session an ID. Try again in a moment."
    case .notStarted(let shortId):
        "The session \(shortId) did not start in 30 seconds. Run claude logs \(shortId) to see "
            + "the cause."
    case .notResumed: "The session did not start again in 30 seconds."
    case .notEnded:
        "The session process did not end in 5 seconds. Bifrost did not start a copy of the "
            + "session."
    case .resumeFailed(nil): "Claude Code could not resume this session."
    case .resumeFailed(let shortId?):
        "Claude Code could not resume this session. Run claude logs \(shortId) to see the cause."
    case .unknownSession: "This session isn't in the list any more."
    case .locked: "Another action is still running on this session. Try again in a moment."
    case .creating: "A new session is already starting. Please wait."
    case .resumeAllRuns: "Resume all is already running."
    case .cancelled: "Bifrost stopped this action before it finished."
    case .external: "This session runs in another terminal, so Bifrost can only show its status."
    case .parked: "This session is parked. Resume it first."
    case .onlyExternal: "This only works for a session that runs in another terminal."
    case .onlyRunning: "This only works for a Bifrost session that is running."
    case .notParked: "This session isn't parked, so there's nothing to resume."
    case .prResume:
        "A review session can't be resumed. Click Review in the Reviews panel to start a new one."
    case .working: "This session is working right now. Try again when it has finished."
    case .openPrompt: "This session is waiting on a prompt. Answer it in the chat window first."
    case .notIdle: "Take control only works while the session is idle or has just finished."
    case .noShortId: "Waiting for the session ID."
    case .noPid: "Bifrost doesn't know the process ID of this session."
    case .processChanged: "The process of this session changed, so Bifrost left it alone."
    case .unconfirmed(nil):
        "Bifrost couldn't check that this session has stopped. Try again in a moment."
    case .unconfirmed(.commandFailed?):
        "Bifrost couldn't check that this session has stopped, because Claude Code ran into a "
            + "problem. Try again in a moment."
    case .unconfirmed(.emptyOutput?):
        "Bifrost couldn't check that this session has stopped, because Claude Code sent an empty "
            + "list of sessions. Try again in a moment."
    case .unconfirmed(.noArray?), .unconfirmed(.notAnArray?), .unconfirmed(.badJSON?):
        "Bifrost couldn't check that this session has stopped, because it doesn't understand the "
            + "list of sessions from Claude Code. Try again in a moment."
    case .unconfirmed(.claudeNotFound?):
        "Bifrost couldn't check that this session has stopped, because it can't find Claude "
            + "Code. Try again in a moment."
    case .noMessages:
        "This session has no messages yet, so there's nothing to take over. Send a message in "
            + "its terminal first."
    case .deleteNotConfirmed: "Delete needs your confirmation first."
    case .takeControlNotConfirmed: "Take control needs your confirmation first."
    case .deleteExternal: "Bifrost can't delete a session that runs in another terminal."
    case .kept:
        "Claude Code kept this session, because its worktree has commits that exist on no "
            + "remote. Open the worktree to check them, then delete again."
    case .uncommitted:
        "This worktree has changes that aren't committed, so Claude Code won't delete it. Open "
            + "the worktree, commit or discard them, then delete again."
    case .rmTooSlow:
        "Claude Code took too long to delete this session. Check the worktree, then delete again."
    case .worktreeChanged: "The worktree changed after the check. Check it again, then delete."
    case .notStopped: "The session didn't stop in time. Try Delete again in a moment."
    case .noProjectFolder: "Bifrost doesn't know the project folder of this session."
    case .folderMissing(let path): "The folder \(path) doesn't exist."
    case .notAFolder(let path): "\(path) isn't a folder, so Bifrost didn't open it."
    case .folderUnreadable(let path):
        "Bifrost can't read the folder \(path). Check that you can open it in Finder."
    case .folderUnchecked: "Bifrost couldn't check this folder in time. Try again."
    case .noWorktree: "This session doesn't have a worktree."
    case .unknownApp: "Bifrost doesn't know that app."
    case .noTerminal: "No supported terminal app is installed."
    case .terminalUnknown: "Bifrost doesn't know which terminal app this session runs in."
    case .openFailed(let text): withoutHiddenCharacters(text)
    case .commandFileFailed:
        "Bifrost couldn't write the file that opens this session in your terminal. Try again."
    case .input(let refusal): refusal.message
    case .alias(.control): "A name can't hold control or hidden characters."
    case .alias(.tooLong): "The name is too long. The maximum is 64 characters."
    }
}

// One value of each case, both forms of resumeFailed, and unconfirmed with each reason. The
// detail of a failed list never shows.
private let samples: [ActionRefusal] = [
    .noFolder, .noName, .nameTooLong, .nameLines, .nameHidden, .nameFlag, .promptTooLong,
    .promptFlag, .promptIsCommand, .dirMissing, .noGit, .badSessionId, .badPid,
    .notClaudeProcess(pid: 4242), .signalFailed, .noResumeId, .trust(dir: "/p"),
    .claudeReported("bad"), .claudeExited(code: 2), .claudeFailed, .claudeNotFound,
    .startGaveNoId, .notStarted(shortId: "abcd1234"), .notResumed, .notEnded,
    .resumeFailed(shortId: nil), .resumeFailed(shortId: "abcd1234"), .unknownSession, .locked,
    .creating, .resumeAllRuns, .cancelled, .external, .parked, .onlyExternal, .onlyRunning,
    .notParked, .prResume, .working, .openPrompt, .notIdle, .noShortId, .noPid, .processChanged,
    .unconfirmed(nil), .unconfirmed(.commandFailed(detail: "/p: boom")), .unconfirmed(.emptyOutput),
    .unconfirmed(.noArray), .unconfirmed(.notAnArray), .unconfirmed(.badJSON(detail: "/p")),
    .unconfirmed(.claudeNotFound), .noMessages,
    .deleteNotConfirmed, .takeControlNotConfirmed, .deleteExternal, .kept, .uncommitted,
    .rmTooSlow, .worktreeChanged, .notStopped, .noProjectFolder, .folderMissing("/p/app"),
    .notAFolder("/p/run.command"), .folderUnreadable("/p"), .folderUnchecked, .noWorktree,
    .unknownApp, .noTerminal, .terminalUnknown, .openFailed("LSOpen failed"),
    .commandFileFailed, .input(.prompt), .alias(.control), .alias(.tooLong),
]

// Each case of InputRefusal.
private let inputRefusals: [InputRefusal] = [
    .empty, .tooLong, .slashLines, .noName, .nameTooLong, .prompt, .notOwned, .noPid, .noSize,
    .notReady, .endedBeforeReady, .agentView, .chatGone, .attachGone, .oldAttach, .cancelled,
]

@Suite("the refusals of the session actions")
struct ActionRefusalTests {
    @Test(arguments: samples)
    func eachRefusalHasAFriendlyText(refusal: ActionRefusal) {
        #expect(refusal.message == expectedText(refusal))
    }

    // The log gives the reason of a refusal in public as one fixed word: the name of its case.
    // The data of the case can hold a path or a text of claude, so it never goes there.
    @Test(arguments: samples)
    func theLogReasonIsTheNameOfTheCaseWithNoData(refusal: ActionRefusal) {
        let reason = SystemSessionsLog.reason(refusal)
        #expect(reason.wholeMatch(of: /[a-z][A-Za-z]*/) != nil)
    }

    @Test func theLogReasonOfACaseWithDataIsOnlyItsName() {
        #expect(SystemSessionsLog.reason(.claudeReported("no such job in /p")) == "claudeReported")
        #expect(SystemSessionsLog.reason(.folderMissing("/Users/x/p")) == "folderMissing")
        #expect(SystemSessionsLog.reason(.notClaudeProcess(pid: 4242)) == "notClaudeProcess")
        #expect(SystemSessionsLog.reason(.input(.prompt)) == "input")
        #expect(SystemSessionsLog.reason(.locked) == "locked")
    }

    // The error line wraps to more lines, so a text can have two sentences.
    @Test(arguments: samples)
    func aTextHasNoCodeNoEmDashAndAtMost150Characters(refusal: ActionRefusal) {
        let text = refusal.message
        #expect(!text.isEmpty)
        #expect(!text.hasPrefix("refused"))
        #expect(!text.unicodeScalars.contains("\u{2014}"))
        #expect(text.count <= 150)
    }

    // The texts that tell why an action is off are also the texts of the refusals of the same
    // rule.
    @Test func aRefusalOfARuleOfTheActionModelHasTheTextOfItsReason() {
        let pairs: [(ActionRefusal, String)] = [
            (.unknownSession, ActionReasons.gone), (.resumeAllRuns, ActionReasons.resumeAllRuns),
            (.external, ActionReasons.external), (.parked, ActionReasons.parked),
            (.onlyExternal, ActionReasons.onlyExternal), (.prResume, ActionReasons.prResume),
            (.noShortId, ActionReasons.waitForId),
            (.noProjectFolder, ActionReasons.noProjectFolder),
            (.noTerminal, ActionReasons.noTerminal),
            (.terminalUnknown, ActionReasons.terminalUnknown),
            (.input(.prompt), ActionReasons.redBox),
        ]
        for (refusal, reason) in pairs { #expect(refusal.message == reason) }
    }

    // A bidi control in a path could reverse the rest of the text, so the path of a text loses
    // the hidden characters of a name.
    @Test func aPathInATextHasNoHiddenCharacters() {
        let path = "/p/\u{202E}gpj\u{061C}.\u{200B}exe\u{2066}"
        #expect(ActionRefusal.folderMissing(path).message == "The folder /p/gpj.exe doesn't exist.")
        #expect(ActionRefusal.trust(dir: path).message == ClaudeOutput.trustMessage("/p/gpj.exe"))
        #expect(ActionRefusal.folderMissing(path) != .folderMissing("/p/gpj.exe"))
        #expect(
            ActionRefusal.openFailed("The file \(path) couldn't be opened.").message
                == "The file /p/gpj.exe couldn't be opened.")
    }

    @Test(arguments: inputRefusals)
    func aRefusalOfTheSessionInputKeepsItsText(refusal: InputRefusal) {
        #expect(ActionRefusal.of(refusal) == .input(refusal))
        #expect(ActionRefusal.of(refusal).message == refusal.message)
    }
}
