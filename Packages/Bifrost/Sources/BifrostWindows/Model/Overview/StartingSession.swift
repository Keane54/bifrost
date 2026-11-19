import BifrostSessions

// A New session start that runs after the close of its dialog (docs/behaviour/actions.md, "New
// session"). The action runner keeps it from the acceptance of the start to its end. The Overview
// shows it as a Starting row until the session list has the row of its short ID. It is not a row
// of the session list: it has no row ID, no state, no menu and no selection.
package struct StartingSession: Sendable, Equatable, Identifiable {
    // The number of the start in this run of the app.
    package let id: Int
    package let name: String
    // The folder of the start.
    package let cwd: String
    // The short ID that claude --bg gave, or nil while claude --bg runs.
    package var shortId: ShortID?

    package init(id: Int, name: String, cwd: String, shortId: ShortID? = nil) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.shortId = shortId
    }

    // True when the rows have the owned row of the short ID of the start. Then the real row
    // shows, and the Starting row does not.
    package func isListed(in rows: [SessionRow]) -> Bool {
        guard let shortId else { return false }
        return rows.contains { $0.kind == .owned && $0.shortId == shortId }
    }

    // The starts that show as Starting rows: each start whose row is not in the rows yet.
    package static func shown(_ starts: [StartingSession], rows: [SessionRow])
        -> [StartingSession]
    {
        starts.filter { !$0.isListed(in: rows) }
    }
}
