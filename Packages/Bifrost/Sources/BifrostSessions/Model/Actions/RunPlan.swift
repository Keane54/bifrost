// The plan of one session action (docs/behaviour/actions.md, "What an action does"): what the
// action runner does for it. The plan is a value, and the runner carries it out.
import BifrostFoundation

// A call of a session action, with the choice of the menu where the call needs one. remove is
// the call of Delete.
package enum ApiCall: Sendable, Equatable {
    case interrupt, handOver, stop, remove, resume, takeControl, openInTerminal, copyId
    // nil: no priority.
    case setPriority(SessionPriority?)
    case openProject(ProjectAppID)
    case watchAdd(WatchColour)
    case watchColour(WatchColour)
    case watchRemove
}

// What the runner does with the chat window after a call that did not fail. Take control opens
// its chat window before the call, with the loader. After the call, the runner restarts the
// chat, because an ended terminal attaches again only after a restart. After a good Stop, the
// runner closes the chat window and keeps the selection, because the session stays in the list.
package enum AfterCall: Sendable {
    case none, closeChat, closeWindow, restartChat
}

// The next step of an Open from a click on a notification.
package enum NotifiedOpen: Sendable {
    case open, wait, drop
}

package enum RunPlan: Sendable, Equatable {
    case none, openChat, closeChat
    case showInfo(SessionID)
    // The Selected Item panel opens, and its send box takes the focus. With slash, the box
    // starts with "/".
    case focusSend(slash: Bool)
    case send(String)
    // The Rename dialog opens.
    case rename
    // The runner asks with the confirmation first, when the call has one.
    case call(ApiCall, confirm: ConfirmText?, after: AfterCall)

    // The text of Compact. It has no argument (user decision, 2026-11-10).
    package static let compactCommand = "/compact"
    // The colour of Add to watchlist with no colour choice, for example from a button or a key.
    package static let defaultWatchColour = WatchColour.lightBlue

    // The plan of the action for the row. An action that is off gives none, so a click on it does
    // nothing. A menu choice that does not fit the action also gives none.
    package static func plan(
        _ id: ActionID, _ row: SessionRow?, _ ctx: ActionContext, arg: MenuArg?
    ) -> RunPlan {
        guard let row, ActionModel.state(id, row, ctx).enabled else { return .none }
        switch id {
        case .open: return .openChat
        case .closeWindow: return .closeChat
        case .sendMessage: return .focusSend(slash: false)
        case .runSlash:
            guard case .slash(let command) = arg, isCommand(command) else {
                return .focusSend(slash: true)
            }
            return .send(command)
        // Compact sends its command as Run slash command does. It asks for no confirmation.
        case .compact: return .send(compactCommand)
        case .rename: return .rename
        case .showInfo: return SessionID(row.sessionId).map(RunPlan.showInfo) ?? .none
        case .handOver: return call(.handOver)
        case .interrupt: return call(.interrupt)
        case .copyId: return call(.copyId)
        case .openInTerminal: return call(.openInTerminal)
        case .watchRemove: return call(.watchRemove)
        case .setPriority:
            guard case .priority(let priority) = arg else { return .none }
            return call(.setPriority(priority))
        case .openProject:
            guard case .app(let app) = arg, ctx.apps.contains(where: { $0.id == app }) else {
                return .none
            }
            return call(.openProject(app))
        // No choice (a button or a key) gives the default colour.
        case .watchAdd:
            switch arg {
            case nil: return call(.watchAdd(defaultWatchColour))
            case .colour(let colour): return call(.watchAdd(colour))
            default: return .none
            }
        case .watchColour:
            guard case .colour(let colour) = arg else { return .none }
            return call(.watchColour(colour))
        case .resume: return .call(.resume, confirm: nil, after: .restartChat)
        case .takeControl:
            return .call(
                .takeControl, confirm: Confirm.text(.takeControl, row, ctx.labels),
                after: .restartChat)
        // A session that does not work gets no confirmation.
        case .stop:
            return .call(
                .stop, confirm: Confirm.text(.stop, row, ctx.labels), after: .closeWindow)
        // The runner makes the final text after the check for unmerged work.
        case .delete:
            return .call(
                .remove, confirm: Confirm.text(.delete(.unchecked), row, ctx.labels),
                after: .closeChat)
        // New session and Resume all need no row.
        case .newSession, .resumeAll: return .none
        }
    }

    // What the runner does with the chat window after a Delete that failed. A failed claude rm of
    // a deferred delete fails after the registry forgot the row of the Delete. rows are the rows
    // after the failure. When the row is not there, the chat window closes, as after a good
    // Delete.
    package static func afterFailedDelete(_ sessionId: String, rows: [SessionRow]) -> AfterCall {
        rows.contains { $0.sessionId == sessionId } ? .none : .closeChat
    }

    // The next step of an Open from a click on a notification. A new window can get the click
    // before it has the rows, so the Open waits for the row. When the session list has loaded
    // and the row is not there, the Open stops.
    package static func notifiedOpenStep(_ sessionId: String, rows: [SessionRow], loaded: Bool)
        -> NotifiedOpen
    {
        if rows.contains(where: { $0.sessionId == sessionId }) { return .open }
        return loaded ? .drop : .wait
    }

    private static func call(_ call: ApiCall) -> RunPlan {
        .call(call, confirm: nil, after: .none)
    }

    // A slash command of the submenu: a text that starts with "/" and is not "/" alone.
    private static func isCommand(_ text: String) -> Bool {
        text.unicodeScalars.first == "/" && text != "/"
    }
}
