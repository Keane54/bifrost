import BifrostSessions

// The glyph of the row icon: the Bifrost mark of an owned row, the terminal of an external row,
// and the parked glyph of a parked row.
package enum IconKind: String, Sendable {
    case owned, external, parked
}

// The app that shows a session to the user. The row icon shows the icon of this app.
package enum SessionHolder: Sendable, Equatable {
    // A chat window of Bifrost attaches the session.
    case bifrost
    // A terminal app shows the session: an external session runs in it, or a "claude attach"
    // client of an owned session runs in it (SessionRegistry.terminalOf).
    case terminal(TerminalApp)
}

// The rules of the row icon: its project colour and its glyph.
package enum SessionIconRules {
    // The repository of the working folder, as for the Project column. A worktree gives its
    // repository.
    package static func projectKey(_ cwd: String) -> String {
        repoPath(cwd)
    }

    // A stable index from 1 to 8 for a project key: the 32-bit FNV-1a hash of the UTF-8 bytes,
    // modulo 8, plus 1.
    package static func projectColourIndex(_ key: String) -> Int {
        var hash: UInt32 = 0x811C_9DC5
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return Int(hash % 8) + 1
    }

    // The app that shows the row, or nil. A parked row has no app. A chat window of Bifrost
    // comes before a terminal app: Bifrost knows its own attach for sure, with no process read,
    // and the chat is in the window of the Overview, one click away. When the chat ends, the
    // row shows its terminal app again.
    package static func holder(_ row: SessionRow, inChat: Bool, terminal: TerminalApp?)
        -> SessionHolder?
    {
        guard row.state != .parked else { return nil }
        if inChat { return .bifrost }
        return terminal.map(SessionHolder.terminal)
    }

    package static func iconKind(_ row: SessionRow) -> IconKind {
        if row.state == .parked { return .parked }
        switch row.kind {
        case .owned: return .owned
        case .external: return .external
        }
    }
}
