// The Starting rows of the New session starts (docs/behaviour/actions.md, "New session"): a start
// shows until the session list has the owned row of its short ID, and its cells show the name,
// the state text and the project.
import BifrostSessions
import BifrostTestSupport
import Testing

@testable import BifrostWindows

@Suite("the Starting rows")
struct StartingSessionTests {
    // A start with no short ID shows. With its short ID, only an owned row of that short ID hides
    // it: an external row or another short ID does not.
    @Test func aStartShowsUntilTheListHasItsOwnedRow() {
        let waiting = StartingSession(id: 1, name: "bifrost-test-a", cwd: "/p")
        let launched = StartingSession(
            id: 2, name: "bifrost-test-b", cwd: "/p", shortId: "4cb23c30")
        let other = SessionRow.test(sessionId: "s1", shortId: "aaaaaaaa")
        let external = SessionRow.test(sessionId: "s2", shortId: "4cb23c30", kind: .external)
        let own = SessionRow.test(sessionId: "s3", shortId: "4cb23c30")
        #expect(StartingSession.shown([waiting, launched], rows: []) == [waiting, launched])
        #expect(
            StartingSession.shown([waiting, launched], rows: [other, external])
                == [waiting, launched])
        #expect(StartingSession.shown([waiting, launched], rows: [other, own]) == [waiting])
    }

    @Test func theCellsOfAStartingRowShowTheNameTheStateAndTheProject() {
        let start = StartingSession(id: 1, name: "bifrost-test-a", cwd: "/Users/o/Developer/app")
        #expect(CellContent.of(start, .name) == CellContent("bifrost-test-a"))
        #expect(CellContent.of(start, .state) == CellContent("Starting…", .tone(.dim)))
        #expect(
            CellContent.of(start, .project)
                == CellContent("Developer/app", tooltip: "/Users/o/Developer/app"))
        for column in [OverviewColumn.kind, .priority, .branch, .model, .context, .cost, .activity]
        {
            #expect(CellContent.of(start, column) == CellContent(""))
        }
    }
}
