import BifrostTestSupport
import Observation
import Synchronization
import Testing

@testable import BifrostSessions

// The model of the session list: it reads the rows and the error from their one source (the
// registry service in the app) and gives the status of the list. A test gives a fake source.

private func row(_ id: String) -> SessionRow {
    SessionRow.test(sessionId: id, shortId: nil, name: id)
}

// A model that reads from a new fake source.
@MainActor
private func model() -> (SessionListModel, FakeRowSource) {
    let model = SessionListModel()
    let source = FakeRowSource()
    model.read(from: source)
    return (model, source)
}

@MainActor
@Suite("session list model")
struct SessionListModelTests {
    // The window shows "starting" at once, before the registry exists.
    @Test func startsInTheStartingStatus() {
        let model = SessionListModel()
        #expect(model.status == .starting)
        #expect(model.rows.isEmpty)
    }

    // Before the first active poll, the list shows no rows, also when the source has some.
    @Test func theListShowsNoRowsBeforeTheFirstPoll() {
        let (model, source) = model()
        #expect(!source.loaded)
        #expect(model.status == .starting)
        #expect(model.rows.isEmpty)
    }

    @Test func anUpdateWithNoErrorIsReady() {
        let (model, source) = model()
        source.apply(rows: [row("a"), row("b")], error: nil)
        #expect(model.status == .ready)
        #expect(model.rows.map(\.sessionId) == ["a", "b"])
    }

    // The rows of an update with an error stay on screen.
    @Test func anErrorKeepsTheRows() {
        let (model, source) = model()
        source.apply(rows: [row("a")], error: nil)
        source.apply(rows: [row("b"), row("c")], error: .emptyOutput)
        #expect(model.status == .failed(.emptyOutput))
        #expect(model.rows.map(\.sessionId) == ["b", "c"])
        source.apply(rows: [row("a"), row("b")], error: nil)
        #expect(model.status == .ready)
        #expect(model.rows.map(\.sessionId) == ["a", "b"])
    }

    // Nothing replaces "claude not found".
    @Test func aMissingClaudeShowsClaudeNotFound() {
        let (model, source) = model()
        model.claudeMissing()
        #expect(model.status == .claudeNotFound)
        source.apply(rows: [row("a")], error: nil)
        #expect(model.status == .claudeNotFound)
        #expect(model.rows.isEmpty)
        model.read(from: source)
        #expect(model.status == .claudeNotFound)
        #expect(!model.loaded)
    }

    // A chat shows "Waiting for the session list." until the list is loaded: from the first
    // update of the registry, also an update with an error.
    @Test func theListIsLoadedFromTheFirstUpdate() {
        let (model, source) = model()
        #expect(!model.loaded)
        source.apply(rows: [], error: .emptyOutput)
        #expect(model.loaded)
        source.apply(rows: [row("a")], error: nil)
        #expect(model.loaded)
    }

    // The rows are observable through the model: a change of the source reaches an observer of
    // the model.
    @Test func aChangeOfTheSourceReachesAnObserverOfTheModel() {
        let (model, source) = model()
        source.apply(rows: [row("a")], error: nil)
        let changes = Mutex(0)
        withObservationTracking {
            _ = model.rows
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        source.apply(rows: [row("b")], error: nil)
        #expect(changes.withLock { $0 } == 1)
        #expect(model.rows.map(\.sessionId) == ["b"])
    }
}
