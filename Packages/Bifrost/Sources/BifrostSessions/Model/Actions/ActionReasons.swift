// The texts that tell the user why a session action is off (docs/behaviour/actions.md, "Which
// actions are on"). A button tip and a menu item show the text. Some refusals of ActionRefusal
// use the same text.
package enum ActionReasons {
    // The row class.
    package static let external =
        "This session runs in another terminal, so Bifrost can only show its status."
    package static let parked = "This session is parked. Resume it first."
    package static let onlyExternal = "This only works for a session that runs in another terminal."
    package static let onlyParked = "This only works for a parked session."

    // The row and its values.
    package static let gone = "This session isn't in the list any more."
    package static let noWindow = "The chat window isn't open."
    package static let noProjectFolder = "Bifrost doesn't know the project folder of this session."
    package static let noApps = "No app is available to open this."
    package static let waitForId = "Waiting for the session ID."
    package static let prSession = "A review session has no hand-over."
    package static let prResume =
        "A review session can't be resumed. Click Review in the Reviews panel to start a new one."
    // Compact and Hand over wait while the session works on a reply (user decision,
    // 2026-11-10).
    package static let waitForIdle = "Wait until the session is idle."

    // A red box of a prompt blocks the actions that type into the session.
    package static let redBox = InputRefusal.prompt.message
    package static let takeBusy =
        "This session is working right now. Taking control would stop that work."
    package static let takePrompt =
        "This session is waiting on a prompt. Taking control would cancel it."
    package static let noPid = "Bifrost doesn't know the process ID of this session yet."
    package static let running = "Another action is still running on this session."
    package static let noProcess = "This session is parked, so there's nothing to stop."
    package static let noTerminal = "No supported terminal app is installed."
    package static let terminalUnknown =
        "Bifrost doesn't know which terminal app this session runs in."

    // Resume all.
    package static let nothingToResume =
        "None of the parked sessions were active when Bifrost last closed."
    package static let resumeAllRuns = "Resume all is already running."

    // The watchlist.
    package static let watched = "This session is already on the watchlist."
    package static let notWatched = "This session isn't on the watchlist."
}
