// The rules of an attach to a session: the target of a chat window, and the check of a PTY open.
// Bifrost opens a PTY only for "claude attach <short id>" of one owned session that is not
// parked. The check gives a CheckedAttach, and the PTY manager opens only that value: it makes
// the arguments from its ShortID, so no caller gives free arguments to claude and no caller can
// open a PTY without the check (docs/behaviour/pty.md).

// The reason why a chat window or the session input cannot attach to a session.
package enum AttachRefusal: Error, Sendable, Equatable {
    // The target of a chat window.
    case waitingForList, gone, external, parked, waitingForID
    // The check of a PTY open: the short ID is not the short ID of one owned session that runs,
    // or it is not the short ID of the session of the view.
    case notOwnedAttach, otherSession
    // The size of the terminal is not a size that a PTY accepts (TerminalSize.isValid).
    case badSize
    // The app did not find claude, so it has no PTY manager.
    case claudeNotFound

    // The text that a chat window shows.
    package var message: String {
        switch self {
        case .waitingForList: "Waiting for the session list."
        case .gone: "This session isn't in the list any more."
        case .external:
            "This session runs in another terminal, so Bifrost can only show its status."
        case .parked: "This session is parked. Resume it first."
        case .waitingForID: "Waiting for the session ID."
        case .notOwnedAttach: "Bifrost can only open a session it started that isn't parked."
        case .otherSession: "This window is for another session. Open the chat again."
        case .badSize: "The window is too small or too large for a terminal."
        case .claudeNotFound:
            "Bifrost can't find Claude Code. Install it, then open Bifrost again."
        }
    }
}

// The attach of a view: the short ID and the folder of the PTY, or the reason why the view
// cannot attach.
package enum AttachTarget: Sendable, Equatable {
    case ready(shortId: ShortID, directory: String)
    case refused(AttachRefusal)
}

// An attach that AttachRules.check allowed with the rows of that time: the view, the short ID
// and the folder of the PTY. Only the check makes this value, and PTYManager.open takes only this
// value, so each PTY open goes through the check.
package struct CheckedAttach: Sendable, Equatable {
    package let view: PTYView
    package let shortId: ShortID
    package let directory: String

    fileprivate init(view: PTYView, shortId: ShortID, directory: String) {
        self.view = view
        self.shortId = shortId
        self.directory = directory
    }
}

package enum AttachRules {
    // The attach of the chat window of a row. loaded is false until the first session list
    // comes. A row with no folder gets the root folder.
    package static func target(_ row: SessionRow?, loaded: Bool) -> AttachTarget {
        guard loaded else { return .refused(.waitingForList) }
        guard let row else { return .refused(.gone) }
        if row.kind == .external { return .refused(.external) }
        if row.state == .parked { return .refused(.parked) }
        guard let shortId = row.shortId else { return .refused(.waitingForID) }
        return .ready(shortId: shortId, directory: row.cwd.isEmpty ? "/" : row.cwd)
    }

    // The check of a PTY open with the rows of now (D1). The short ID must be the short ID of
    // one owned row that is not parked, and the first row of the session of the view must have
    // it, so the input of the view goes to that session. The folder comes from the row, never
    // from the caller: a chat attaches in the folder of the row (the root folder for a row with
    // no folder), and the hidden attach of the session input attaches in the root folder.
    package static func check(_ rows: [SessionRow], view: PTYView, shortId: ShortID)
        throws(AttachRefusal) -> CheckedAttach
    {
        let matches = rows.filter { $0.shortId == shortId }
        guard matches.count == 1, let row = matches.first, row.isOwnedAndNotParked else {
            throw .notOwnedAttach
        }
        guard rows.first(where: { $0.sessionId == view.session })?.shortId == shortId else {
            throw .otherSession
        }
        let directory =
            switch view {
            case .chat: row.cwd.isEmpty ? "/" : row.cwd
            case .input: "/"
            }
        return CheckedAttach(view: view, shortId: shortId, directory: directory)
    }
}

extension SessionRow {
    // An owned row that is not parked: its chat opens, and Bifrost can attach to its session.
    package var isOwnedAndNotParked: Bool { kind == .owned && state != .parked }
}
