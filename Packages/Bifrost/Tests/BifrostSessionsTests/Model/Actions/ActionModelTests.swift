// The action model (docs/behaviour/actions.md, "Which actions are on"): the labels of the
// actions, the row class, and the state and the reason of each action for a row.
import BifrostFoundation
import BifrostTestSupport
import Darwin
import Testing

@testable import BifrostSessions

// A row that each action of its class accepts: idle, with a short ID, a PID and a project folder.
// An external row also has its terminal app.
private func row(
    _ kind: SessionKind = .owned, state: SessionState = .idle, shortId: ShortID? = "abcd1234",
    pid: pid_t? = 10, cwd: String = "/p", change: (inout SessionRow) -> Void = { _ in }
) -> SessionRow {
    var row = SessionRow.test(
        sessionId: "s", shortId: shortId, kind: kind, pid: pid, cwd: cwd, state: state)
    if kind == .external { row.terminalApp = "Warp" }
    change(&row)
    return row
}

private let owned = row()
private let external = row(.external, shortId: nil, pid: 20)
private let parked = row(state: .parked, pid: nil)

private func context(
    chatOpen: Bool = true, folderShared: Bool = false,
    apps: [ProjectApp] = [
        ProjectApp(id: .finder, label: "Finder"), ProjectApp(id: .warp, label: "Warp"),
    ],
    labels: LabelSet = .plain, running: Bool = false
) -> ActionContext {
    ActionContext(
        chatOpen: chatOpen, folderShared: folderShared, apps: apps, labels: labels,
        running: running, slashFavourites: [], slashRecent: [])
}

// The reason of the action for the row, or nil when the action is on.
private func reason(
    _ id: ActionID, _ row: SessionRow?, _ ctx: ActionContext = context()
) -> String? {
    let state = ActionModel.state(id, row, ctx)
    #expect(state.enabled == (state.reason == nil))
    return state.reason
}

private let watched = RowWatch(colour: .green, order: 0)

@Suite("the labels of the actions")
struct ActionLabelTests {
    // The plain and the space label of each action.
    static let titles: [ActionID: (plain: String, space: String)] = [
        .newSession: ("New session", "Launch"), .open: ("Open", "Warp to"),
        .sendMessage: ("Send message", "Hail"), .runSlash: ("Run slash command", "Activate module"),
        .compact: ("Compact", "Compress cargo"), .handOver: ("Hand over", "Transfer command"),
        .interrupt: ("Interrupt", "Full stop"), .rename: ("Rename", "Set callsign"),
        .setPriority: ("Set priority", "Set threat level"), .resume: ("Resume", "Reactivate"),
        .resumeAll: ("Resume all", "Reactivate all"), .showInfo: ("Show Info", "Scan"),
        .copyId: ("Copy session ID", "Copy transponder ID"),
        .openProject: ("Open project", "Open cargo hold"),
        .openInTerminal: ("Open in terminal", "Jump to terminal"),
        .takeControl: ("Take control", "Commandeer"), .closeWindow: ("Close window", "Disengage"),
        .stop: ("Stop session", "Power down"), .delete: ("Delete session", "Self-destruct"),
        .watchAdd: ("Add to watchlist", "Track"),
        .watchColour: ("Change colour", "Change colour"),
        .watchRemove: ("Remove from watchlist", "Stop tracking"),
    ]

    @Test(arguments: ActionID.allCases)
    func eachActionHasAPlainAndASpaceTitle(id: ActionID) throws {
        let titles = try #require(Self.titles[id])
        #expect(id.title(.plain) == titles.plain)
        #expect(id.title(.space) == titles.space)
    }

    // An action that asks for more input gets three full stops in its label.
    @Test(arguments: ActionID.allCases)
    func onlyAnActionThatAsksForMoreGetsThreeFullStops(id: ActionID) {
        let asks: Set<ActionID> = [.sendMessage, .rename, .stop, .delete]
        for labels in LabelSet.allCases {
            let dots = asks.contains(id) ? "..." : ""
            #expect(id.label(labels) == id.title(labels) + dots)
        }
    }

    @Test func theIdsAreTheTextsOfTheStoredForm() {
        #expect(ActionID.allCases.count == 22)
        #expect(ActionID.newSession.rawValue == "new-session")
        #expect(ActionID.openInTerminal.rawValue == "open-in-terminal")
        #expect(ActionID.watchColour.rawValue == "watch-colour")
        #expect(ActionID.stop.rawValue == "stop")
    }

    // The tip of a button has no three full stops. An action that is off adds its reason on a
    // second line.
    @Test func theTipIsTheTitleAndTheReasonOfAnActionThatIsOff() {
        let on = ActionModel.state(.stop, owned, context())
        #expect(ActionModel.buttonTip(.stop, on, .plain) == "Stop session")
        let off = ActionModel.state(.stop, parked, context())
        #expect(
            ActionModel.buttonTip(.stop, off, .plain) == "Stop session\n\(ActionReasons.noProcess)")
        let space = ActionModel.state(.open, parked, context())
        #expect(ActionModel.buttonTip(.open, space, .space) == "Warp to\n\(ActionReasons.parked)")
        let idle = row(state: .working)
        let compact = ActionModel.state(.compact, idle, context())
        #expect(
            ActionModel.buttonTip(.compact, compact, .space) == "Compress cargo\n"
                + "Wait until the session is idle.")
    }
}

@Suite("the state of an action")
struct ActionStateTests {
    @Test func aRowIsParkedElseItsKind() {
        #expect(ActionModel.rowClass(owned) == .owned)
        #expect(ActionModel.rowClass(external) == .external)
        #expect(ActionModel.rowClass(parked) == .parked)
        #expect(ActionModel.rowClass(row(.external, state: .parked)) == .parked)
    }

    // The reason of each action for a row of each class that has every value the action needs.
    // nil is an action that is on.
    static let byClass: [ActionID: (owned: String?, external: String?, parked: String?)] = [
        .newSession: (nil, nil, nil),
        .open: (nil, ActionReasons.external, ActionReasons.parked),
        .sendMessage: (nil, ActionReasons.external, ActionReasons.parked),
        .runSlash: (nil, ActionReasons.external, ActionReasons.parked),
        .compact: (nil, ActionReasons.external, ActionReasons.parked),
        .handOver: (nil, ActionReasons.external, ActionReasons.parked),
        .interrupt: (nil, ActionReasons.external, ActionReasons.parked),
        .rename: (nil, nil, nil),
        .setPriority: (nil, nil, nil),
        .resume: (ActionReasons.onlyParked, ActionReasons.onlyParked, nil),
        .resumeAll: (nil, nil, nil),
        .showInfo: (nil, nil, nil),
        .copyId: (nil, nil, nil),
        .openProject: (nil, nil, nil),
        .openInTerminal: (nil, nil, ActionReasons.parked),
        .takeControl: (ActionReasons.onlyExternal, nil, ActionReasons.onlyExternal),
        .closeWindow: (nil, nil, nil),
        .stop: (nil, ActionReasons.external, ActionReasons.noProcess),
        .delete: (nil, ActionReasons.external, nil),
        .watchAdd: (nil, nil, nil),
        .watchColour: (
            ActionReasons.notWatched, ActionReasons.notWatched, ActionReasons.notWatched
        ),
        .watchRemove: (
            ActionReasons.notWatched, ActionReasons.notWatched, ActionReasons.notWatched
        ),
    ]

    @Test(arguments: ActionID.allCases)
    func eachActionGivesTheReasonOfEachRowClass(id: ActionID) throws {
        let expected = try #require(Self.byClass[id])
        #expect(reason(id, owned) == expected.owned)
        #expect(reason(id, external) == expected.external)
        #expect(reason(id, parked) == expected.parked)
    }

    @Test(arguments: ActionID.allCases)
    func aRowThatIsGoneTurnsEachActionOff(id: ActionID) {
        #expect(
            ActionModel.state(id, nil, context())
                == ActionState(enabled: false, reason: ActionReasons.gone))
    }

    @Test func theWatchActionsFitTheWatchOfTheRow() {
        for row in [owned, external, parked] {
            var on = row
            on.watch = watched
            #expect(reason(.watchAdd, on) == ActionReasons.watched)
            #expect(reason(.watchColour, on) == nil)
            #expect(reason(.watchRemove, on) == nil)
        }
    }

    // An escalated yellow box and an error box show no prompt, so only a prompt box blocks.
    @Test func onlyAPromptBoxBlocksTheActionsThatType() {
        let prompt = row(state: .needsYou) { $0.alert = .red(.prompt, since: 1) }
        for id in [ActionID.sendMessage, .runSlash, .compact] {
            #expect(reason(id, prompt) == ActionReasons.redBox)
        }
        #expect(ActionReasons.redBox == "Answer the prompt in the chat window first.")
        #expect(reason(.interrupt, prompt) == nil)
        #expect(reason(.rename, prompt) == nil)
        for box in [
            SessionAlert.red(.escalated, since: 1), .red(.error, since: 1), .yellow(since: 1),
        ] {
            let other = row(state: .needsYou) { $0.alert = box }
            for id in [ActionID.sendMessage, .runSlash, .compact] {
                #expect(reason(id, other) == nil)
            }
        }
    }

    @Test func theActionsThatTypeOrStopNeedTheShortId() {
        let noId = row(shortId: nil)
        for id in [ActionID.sendMessage, .runSlash, .compact, .interrupt, .stop, .openInTerminal] {
            #expect(reason(id, noId) == ActionReasons.waitForId)
        }
        for id in [ActionID.rename, .delete, .copyId, .setPriority, .open, .showInfo] {
            #expect(reason(id, noId) == nil)
        }
        // An external row opens its own terminal app, so it needs no short ID.
        #expect(reason(.openInTerminal, external) == nil)
    }

    // Compact waits while Claude is in the middle of a reply (user decision, 2026-11-10).
    @Test func compactWaitsForAnIdleSession() {
        #expect(reason(.compact, row(state: .working)) == ActionReasons.waitForIdle)
        #expect(ActionReasons.waitForIdle == "Wait until the session is idle.")
        for state in [SessionState.needsYou, .error, .idle] {
            #expect(reason(.compact, row(state: state)) == nil)
        }
        #expect(reason(.compact, owned, context(running: true)) == nil)
    }

    @Test func anotherActionThatRunsTurnsOffTheActionsThatChangeTheProcess() {
        let running = context(running: true)
        #expect(reason(.stop, owned, running) == ActionReasons.running)
        #expect(reason(.delete, owned, running) == ActionReasons.running)
        #expect(reason(.delete, parked, running) == ActionReasons.running)
        #expect(reason(.resume, parked, running) == ActionReasons.running)
        #expect(reason(.takeControl, external, running) == ActionReasons.running)
        for id in [ActionID.sendMessage, .interrupt, .rename, .openInTerminal, .compact] {
            #expect(reason(id, owned, running) == nil)
        }
    }

    // Take control needs an idle external row with a yellow box at most, a PID and a folder.
    @Test func takeControlNeedsAQuietExternalRowWithAPidAndAFolder() {
        #expect(reason(.takeControl, external) == nil)
        let yellow = row(.external, state: .needsYou) { $0.alert = .yellow(since: 1) }
        #expect(reason(.takeControl, yellow) == nil)
        #expect(reason(.takeControl, row(.external, state: .working)) == ActionReasons.takeBusy)
        for box in [
            SessionAlert.red(.prompt, since: 1), .red(.escalated, since: 1), .red(.error, since: 1),
        ] {
            let red = row(.external, state: .needsYou) { $0.alert = box }
            #expect(reason(.takeControl, red) == ActionReasons.takePrompt)
        }
        #expect(reason(.takeControl, row(.external, pid: nil)) == ActionReasons.noPid)
        #expect(reason(.takeControl, row(.external, cwd: "")) == ActionReasons.noProjectFolder)
        #expect(reason(.takeControl, row(.external, cwd: "p")) == ActionReasons.noProjectFolder)
    }

    @Test func resumeNeedsAFolderAndIsNotForAReviewSession() {
        #expect(reason(.resume, row(state: .parked, cwd: "")) == ActionReasons.noProjectFolder)
        let review = row(state: .parked) { $0.prSession = true }
        #expect(reason(.resume, review) == ActionReasons.prResume)
    }

    @Test func openProjectNeedsAFolderAndAnApp() {
        #expect(reason(.openProject, row(cwd: "")) == ActionReasons.noProjectFolder)
        #expect(reason(.openProject, owned, context(apps: [])) == ActionReasons.noApps)
        #expect(
            reason(.openProject, row(cwd: ""), context(apps: [])) == ActionReasons.noProjectFolder)
    }

    @Test func closeWindowNeedsAnOpenChatWindow() {
        #expect(reason(.closeWindow, owned, context(chatOpen: false)) == ActionReasons.noWindow)
    }

    // An owned row needs an installed terminal app, and an external row the app it runs in.
    @Test func openInTerminalNeedsATerminalApp() {
        #expect(reason(.openInTerminal, owned, context(apps: [])) == ActionReasons.noTerminal)
        let finder = [ProjectApp(id: .finder, label: "Finder")]
        #expect(reason(.openInTerminal, owned, context(apps: finder)) == ActionReasons.noTerminal)
        for app in ProjectAppID.allCases where app.terminal != nil {
            let apps = [ProjectApp(id: app, label: "App")]
            #expect(reason(.openInTerminal, owned, context(apps: apps)) == nil)
        }
        let unknown = row(.external) { $0.terminalApp = nil }
        #expect(reason(.openInTerminal, unknown) == ActionReasons.terminalUnknown)
        let empty = row(.external) { $0.terminalApp = "" }
        #expect(reason(.openInTerminal, empty) == ActionReasons.terminalUnknown)
        #expect(reason(.openInTerminal, external, context(apps: [])) == nil)
    }

    // A shared folder changes what Delete does, not whether it is on.
    @Test func deleteStaysOnInASharedFolder() {
        #expect(reason(.delete, parked, context(folderShared: true)) == nil)
        #expect(reason(.delete, owned, context(folderShared: true)) == nil)
        #expect(
            reason(.delete, parked, context(folderShared: true, running: true))
                == ActionReasons.running)
    }

    // The first check that matches gives the reason, in the order of the rules.
    @Test func theFirstCheckThatMatchesGivesTheReason() {
        var watchedParked = parked
        watchedParked.watch = watched
        #expect(reason(.watchAdd, watchedParked) == ActionReasons.watched)
        #expect(reason(.stop, row(.external, state: .parked)) == ActionReasons.noProcess)
        let redNoId = row(state: .needsYou, shortId: nil) { $0.alert = .red(.prompt, since: 1) }
        #expect(reason(.sendMessage, redNoId) == ActionReasons.redBox)
        let workingExternal = row(.external, state: .working)
        #expect(
            reason(.takeControl, workingExternal, context(running: true)) == ActionReasons.running)
        let redNoPid = row(.external, state: .needsYou, pid: nil) {
            $0.alert = .red(.prompt, since: 1)
        }
        #expect(reason(.takeControl, redNoPid) == ActionReasons.takePrompt)
        #expect(reason(.compact, row(state: .working, shortId: nil)) == ActionReasons.waitForId)
        #expect(reason(.compact, row(.external, state: .working)) == ActionReasons.external)
        let reviewNoFolder = row(state: .parked, cwd: "") { $0.prSession = true }
        #expect(reason(.resume, reviewNoFolder, context(running: true)) == ActionReasons.prResume)
        #expect(
            reason(.openProject, row(cwd: ""), context(chatOpen: false))
                == ActionReasons.noProjectFolder)
        let review = row { $0.prSession = true }
        #expect(reason(.resume, review) == ActionReasons.onlyParked)
        let busyRed = row(.external, state: .working) { $0.alert = .red(.prompt, since: 1) }
        #expect(reason(.takeControl, busyRed) == ActionReasons.takeBusy)
        let prompt = row(state: .needsYou) { $0.alert = .red(.prompt, since: 1) }
        #expect(reason(.handOver, prompt, context(running: true)) == ActionReasons.running)
        let noId = row(shortId: nil)
        #expect(reason(.openInTerminal, noId, context(apps: [])) == ActionReasons.waitForId)
    }

    // The texts of the reasons that no refusal shares.
    @Test func theReasonsHaveTheirTexts() {
        let texts: [(String, String)] = [
            (ActionReasons.onlyParked, "This only works for a parked session."),
            (ActionReasons.noWindow, "The chat window isn't open."),
            (ActionReasons.noApps, "No app is available to open this."),
            (ActionReasons.prSession, "A review session has no hand-over."),
            (
                ActionReasons.takeBusy,
                "This session is working right now. Taking control would stop that work."
            ),
            (
                ActionReasons.takePrompt,
                "This session is waiting on a prompt. Taking control would cancel it."
            ),
            (ActionReasons.noPid, "Bifrost doesn't know the process ID of this session yet."),
            (ActionReasons.running, "Another action is still running on this session."),
            (ActionReasons.noProcess, "This session is parked, so there's nothing to stop."),
            (
                ActionReasons.nothingToResume,
                "None of the parked sessions were active when Bifrost last closed."
            ),
            (ActionReasons.watched, "This session is already on the watchlist."),
            (ActionReasons.notWatched, "This session isn't on the watchlist."),
        ]
        for (reason, text) in texts { #expect(reason == text) }
    }

    // Hand over is on for an owned, idle session with a short ID, also with a yellow box. Each
    // other check gives its own reason.
    @Test func handOverIsOnForAnOwnedIdleSessionWithAShortID() {
        #expect(reason(.handOver, owned) == nil)
        let yellow = row(state: .needsYou) { $0.alert = .yellow(since: 1) }
        #expect(reason(.handOver, yellow) == nil)
        #expect(reason(.handOver, external) == ActionReasons.external)
        #expect(reason(.handOver, parked) == ActionReasons.parked)
        let review = row { $0.prSession = true }
        #expect(reason(.handOver, review, context(running: true)) == ActionReasons.prSession)
        #expect(reason(.handOver, owned, context(running: true)) == ActionReasons.running)
        let prompt = row(state: .needsYou) { $0.alert = .red(.prompt, since: 1) }
        #expect(reason(.handOver, prompt) == ActionReasons.redBox)
        #expect(reason(.handOver, row(shortId: nil)) == ActionReasons.waitForId)
        #expect(reason(.handOver, row(state: .working)) == ActionReasons.waitForIdle)
    }
}

@Suite("the actions with no row")
struct GlobalActionTests {
    private func global(resumable: Int = 2, running: Bool = false) -> GlobalContext {
        GlobalContext(resumable: resumable, resumeAllRunning: running, labels: .plain)
    }

    @Test func newSessionIsAlwaysOn() {
        #expect(ActionModel.globalState(.newSession, global(resumable: 0, running: true)).enabled)
    }

    @Test func resumeAllNeedsAResumableRowAndOneRunAtATime() {
        #expect(
            ActionModel.globalState(.resumeAll, global()) == ActionState(enabled: true, reason: nil)
        )
        let none = ActionModel.globalState(.resumeAll, global(resumable: 0))
        #expect(none == ActionState(enabled: false, reason: ActionReasons.nothingToResume))
        let runs = ActionModel.globalState(.resumeAll, global(resumable: 0, running: true))
        #expect(runs == ActionState(enabled: false, reason: ActionReasons.resumeAllRuns))
    }
}

@Suite("the Selected Item buttons")
struct SelectedItemActionTests {
    @Test func theButtonsHideOpenWhileTheChatWindowIsOpen() {
        let all: [ActionID] = [
            .open, .sendMessage, .runSlash, .compact, .handOver, .interrupt, .showInfo,
            .openInTerminal, .stop,
        ]
        #expect(ActionModel.selectedItemActions == all)
        #expect(ActionModel.selectedItemActions(chatOpen: false) == all)
        #expect(ActionModel.selectedItemActions(chatOpen: true) == all.filter { $0 != .open })
    }

    // The Hand over button shows its warning colour from 80 percent of the context, rounded.
    @Test func theHandOverWarningStartsAt80PercentAfterTheRound() {
        #expect(ActionModel.handOverWarnPercent == 80)
        func warns(_ percent: Double?) -> Bool {
            ActionModel.handOverWarning(row { $0.usage = LiveUsage(contextPercent: percent) })
        }
        #expect(!ActionModel.handOverWarning(owned))
        #expect(!warns(nil))
        #expect(!warns(79.4))
        #expect(warns(79.5))
        #expect(warns(80))
        #expect(warns(100))
    }
}
