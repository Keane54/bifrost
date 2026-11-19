// The action model (docs/behaviour/actions.md, "Which actions are on"): which session action is
// on for a row, and the reason when it is off. The buttons, the menus and the keys show the
// state that it gives. The session commands check their own rules again when they run.
import BifrostFoundation

// The session actions. The raw value is the stored form of the ID.
package enum ActionID: String, Sendable, CaseIterable {
    case newSession = "new-session"
    case open
    case sendMessage = "send-message"
    case runSlash = "run-slash"
    case compact
    case handOver = "hand-over"
    case interrupt, rename
    case setPriority = "set-priority"
    case resume
    case resumeAll = "resume-all"
    case showInfo = "show-info"
    case copyId = "copy-id"
    case openProject = "open-project"
    case openInTerminal = "open-in-terminal"
    case takeControl = "take-control"
    case closeWindow = "close-window"
    case stop, delete
    case watchAdd = "watch-add"
    case watchColour = "watch-colour"
    case watchRemove = "watch-remove"

    // The label of a button or a menu item. An action that asks for more input (a text, a name
    // or a confirmation) gets three full stops after its title.
    package func label(_ labels: LabelSet) -> String {
        switch self {
        case .sendMessage, .rename, .stop, .delete: title(labels) + "..."
        default: title(labels)
        }
    }

    // The plain or the space title, with no three full stops. A tooltip shows it.
    package func title(_ labels: LabelSet) -> String {
        let (plain, space) = titles
        return labels == .plain ? plain : space
    }

    private var titles: (plain: String, space: String) {
        switch self {
        case .newSession: ("New session", "Launch")
        case .open: ("Open", "Warp to")
        case .sendMessage: ("Send message", "Hail")
        case .runSlash: ("Run slash command", "Activate module")
        case .compact: ("Compact", "Compress cargo")
        case .handOver: ("Hand over", "Transfer command")
        case .interrupt: ("Interrupt", "Full stop")
        case .rename: ("Rename", "Set callsign")
        case .setPriority: ("Set priority", "Set threat level")
        case .resume: ("Resume", "Reactivate")
        case .resumeAll: ("Resume all", "Reactivate all")
        case .showInfo: ("Show Info", "Scan")
        case .copyId: ("Copy session ID", "Copy transponder ID")
        case .openProject: ("Open project", "Open cargo hold")
        case .openInTerminal: ("Open in terminal", "Jump to terminal")
        case .takeControl: ("Take control", "Commandeer")
        case .closeWindow: ("Close window", "Disengage")
        case .stop: ("Stop session", "Power down")
        case .delete: ("Delete session", "Self-destruct")
        case .watchAdd: ("Add to watchlist", "Track")
        case .watchColour: ("Change colour", "Change colour")
        case .watchRemove: ("Remove from watchlist", "Stop tracking")
        }
    }

    // The row classes that the action is for. nil means each class.
    fileprivate var rowClasses: Set<RowClass>? {
        switch self {
        case .open, .sendMessage, .runSlash, .compact, .handOver, .interrupt, .stop: [.owned]
        case .resume: [.parked]
        case .takeControl: [.external]
        case .openInTerminal: [.owned, .external]
        case .delete: [.owned, .parked]
        default: nil
        }
    }
}

// The class of a row for the actions: a parked row, else the kind of the row.
package enum RowClass: String, Sendable {
    case owned, external, parked
}

// What the state of an action depends on, other than the row.
package struct ActionContext: Sendable, Equatable {
    package var chatOpen: Bool
    // True when another row uses the worktree of the row (folderSharer). Delete then keeps the
    // folder, but Delete stays on.
    package var folderShared: Bool
    // The installed apps of Open project.
    package var apps: [ProjectApp]
    package var labels: LabelSet
    // True while another action runs on the session.
    package var running: Bool
    package var slashFavourites: [String]
    package var slashRecent: [String]

    package init(
        chatOpen: Bool, folderShared: Bool, apps: [ProjectApp], labels: LabelSet, running: Bool,
        slashFavourites: [String], slashRecent: [String]
    ) {
        self.chatOpen = chatOpen
        self.folderShared = folderShared
        self.apps = apps
        self.labels = labels
        self.running = running
        self.slashFavourites = slashFavourites
        self.slashRecent = slashRecent
    }
}

// The state of an action: on, or off with the reason that the tooltip shows.
package struct ActionState: Sendable, Equatable {
    package var enabled: Bool
    package var reason: String?

    package init(enabled: Bool, reason: String?) {
        self.enabled = enabled
        self.reason = reason
    }

    package static let on = ActionState(enabled: true, reason: nil)

    package static func off(_ reason: String) -> ActionState {
        ActionState(enabled: false, reason: reason)
    }
}

// The actions that need no row.
package enum GlobalActionID: String, Sendable {
    case newSession = "new-session"
    case resumeAll = "resume-all"

    // The session action of the global action, for its label and its tooltip.
    package var action: ActionID {
        switch self {
        case .newSession: .newSession
        case .resumeAll: .resumeAll
        }
    }
}

package struct GlobalContext: Sendable, Equatable {
    // The number of parked rows that Resume all resumes.
    package var resumable: Int
    package var resumeAllRunning: Bool
    package var labels: LabelSet

    package init(resumable: Int, resumeAllRunning: Bool, labels: LabelSet) {
        self.resumable = resumable
        self.resumeAllRunning = resumeAllRunning
        self.labels = labels
    }
}

package enum ActionModel {
    // The context percent from which the Hand over button shows the warning colour.
    package static let handOverWarnPercent = 80

    // The buttons of the Selected Item panel, in order.
    package static let selectedItemActions: [ActionID] = [
        .open, .sendMessage, .runSlash, .compact, .handOver, .interrupt, .showInfo,
        .openInTerminal, .stop,
    ]

    // The number of recent slash commands in the Run slash command submenu.
    package static let slashMenuRecent = 5

    // The actions that another running action of the session turns off.
    private static let runningBlocked: Set<ActionID> = [
        .stop, .delete, .resume, .takeControl, .handOver,
    ]
    // The actions that type into the session, which a red box of a prompt turns off.
    private static let promptBlocked: Set<ActionID> = [
        .sendMessage, .runSlash, .compact, .handOver,
    ]
    // The actions that need the short ID of the session.
    private static let needsShortId: Set<ActionID> = [
        .sendMessage, .runSlash, .compact, .handOver, .interrupt, .stop,
    ]

    package static func rowClass(_ row: SessionRow) -> RowClass {
        if row.state == .parked { return .parked }
        return row.kind == .owned ? .owned : .external
    }

    // The state of the action for the row. No row means a row that is gone.
    package static func state(_ id: ActionID, _ row: SessionRow?, _ ctx: ActionContext)
        -> ActionState
    {
        guard let row else { return .off(ActionReasons.gone) }
        return reason(id, row, ctx).map(ActionState.off) ?? .on
    }

    // The tooltip of a button or a menu item: the title, and for an action that is off, the
    // reason on a second line.
    package static func buttonTip(_ id: ActionID, _ state: ActionState, _ labels: LabelSet)
        -> String
    {
        let title = id.title(labels)
        guard !state.enabled, let reason = state.reason else { return title }
        return "\(title)\n\(reason)"
    }

    // The buttons of the Selected Item panel. Open shows only while the chat window is closed.
    package static func selectedItemActions(chatOpen: Bool) -> [ActionID] {
        chatOpen ? selectedItemActions.filter { $0 != .open } : selectedItemActions
    }

    // True when the context of the row is at the warning percent or more, after a round to the
    // nearest whole percent.
    package static func handOverWarning(_ row: SessionRow) -> Bool {
        guard let percent = row.usage?.contextPercent else { return false }
        return percent.rounded() >= Double(handOverWarnPercent)
    }

    package static func globalState(_ id: GlobalActionID, _ ctx: GlobalContext) -> ActionState {
        switch id {
        case .newSession: return .on
        case .resumeAll:
            if ctx.resumeAllRunning { return .off(ActionReasons.resumeAllRuns) }
            if ctx.resumable == 0 { return .off(ActionReasons.nothingToResume) }
            return .on
        }
    }

    // The reason why the action is off for the row, or nil when it is on. The rules apply in
    // order, and the first rule that matches gives the reason (docs/behaviour/actions.md).
    private static func reason(_ id: ActionID, _ row: SessionRow, _ ctx: ActionContext)
        -> String?
    {
        let rowClass = rowClass(row)
        let hasFolder = row.cwd.unicodeScalars.first == "/"
        if id == .watchAdd && row.watch != nil { return ActionReasons.watched }
        if (id == .watchColour || id == .watchRemove) && row.watch == nil {
            return ActionReasons.notWatched
        }
        if id == .stop && rowClass == .parked { return ActionReasons.noProcess }
        if let classes = id.rowClasses, !classes.contains(rowClass) {
            if classes == [.external] { return ActionReasons.onlyExternal }
            if classes == [.parked] { return ActionReasons.onlyParked }
            return rowClass == .external ? ActionReasons.external : ActionReasons.parked
        }
        if id == .handOver && row.prSession { return ActionReasons.prSession }
        if id == .resume && row.prSession { return ActionReasons.prResume }
        if id == .closeWindow && !ctx.chatOpen { return ActionReasons.noWindow }
        if id == .openProject {
            if !hasFolder { return ActionReasons.noProjectFolder }
            if ctx.apps.isEmpty { return ActionReasons.noApps }
        }
        if runningBlocked.contains(id) && ctx.running { return ActionReasons.running }
        if promptBlocked.contains(id) && row.alert.blocksPrompt { return ActionReasons.redBox }
        if needsShortId.contains(id) && row.shortId == nil { return ActionReasons.waitForId }
        if id == .openInTerminal && rowClass == .owned && row.shortId == nil {
            return ActionReasons.waitForId
        }
        // The working state means that Claude is in the middle of a reply.
        if (id == .compact || id == .handOver) && row.state == .working {
            return ActionReasons.waitForIdle
        }
        if id == .takeControl {
            if row.state == .working { return ActionReasons.takeBusy }
            // Each red box blocks Take control, also an escalated box and an error box.
            if case .red = row.alert { return ActionReasons.takePrompt }
            if row.pid == nil { return ActionReasons.noPid }
            if !hasFolder { return ActionReasons.noProjectFolder }
        }
        if id == .resume && !hasFolder { return ActionReasons.noProjectFolder }
        if id == .openInTerminal {
            if rowClass == .owned && !ctx.apps.contains(where: { $0.id.terminal != nil }) {
                return ActionReasons.noTerminal
            }
            if rowClass == .external && (row.terminalApp ?? "").isEmpty {
                return ActionReasons.terminalUnknown
            }
        }
        return nil
    }
}
