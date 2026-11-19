// The order rules of the Watchlist (docs/behaviour/panels.md, "The Watchlist"): the watched rows
// in watch order, the drop target, the move and cancel rules, and
// the empty text. The colour list and the old colour names live in the registry model, and its
// tests check them.
import BifrostFoundation
import BifrostTestSupport
import Testing

@testable import BifrostSessions

private let order = ["a", "b", "c", "d"]

private func watched(_ id: String, _ colour: WatchColour, _ place: Int) -> SessionRow {
    var row = SessionRow.test(sessionId: id)
    row.watch = RowWatch(colour: colour, order: place)
    return row
}

@Suite("the watch order")
struct WatchOrderTests {
    @Test func theWatchedRowsComeInWatchOrder() {
        let rows = [
            SessionRow.test(sessionId: "x"), watched("p", .red, 1), watched("q", .darkBlue, 0),
        ]
        #expect(WatchOrder.watched(rows).map(\.sessionId) == ["q", "p"])
        #expect(WatchOrder.watched([SessionRow.test(sessionId: "x")]).isEmpty)
    }

    // The upper half of a row puts the dragged row before it, and the lower half after it.
    @Test func aDropBelowMovesTheRowDown() {
        #expect(WatchOrder.dropTarget(order, dragged: "a", over: 2, upperHalf: true) == "c")
        #expect(WatchOrder.dropTarget(order, dragged: "a", over: 1, upperHalf: false) == "c")
    }

    @Test func aDropAboveMovesTheRowUp() {
        #expect(WatchOrder.dropTarget(order, dragged: "d", over: 1, upperHalf: true) == "b")
        #expect(WatchOrder.dropTarget(order, dragged: "c", over: 0, upperHalf: true) == "a")
        #expect(WatchOrder.dropTarget(order, dragged: "d", over: 0, upperHalf: false) == "b")
    }

    // The place of a row is before the row that follows it, so a drop on the row itself gives
    // that row.
    @Test func aDropOnTheRowItselfKeepsItsPlace() {
        #expect(WatchOrder.dropTarget(order, dragged: "b", over: 1, upperHalf: true) == "c")
        #expect(WatchOrder.dropTarget(order, dragged: "b", over: 1, upperHalf: false) == "c")
        #expect(WatchOrder.dropTarget(order, dragged: "d", over: 3, upperHalf: true) == nil)
    }

    @Test func aDropAtTheEndOrTheTopGoesThere() {
        #expect(WatchOrder.dropTarget(order, dragged: "a", over: 3, upperHalf: false) == nil)
        #expect(WatchOrder.dropTarget(order, dragged: "a", over: 9, upperHalf: false) == nil)
        #expect(WatchOrder.dropTarget(order, dragged: "c", over: -4, upperHalf: true) == "a")
        #expect(WatchOrder.dropTarget([], dragged: "a", over: 0, upperHalf: true) == nil)
    }

    @Test func onlyADropAtAnotherPlaceIsAMove() {
        #expect(!WatchOrder.isMove(order, dragged: "b", before: "c"))
        #expect(!WatchOrder.isMove(order, dragged: "d", before: nil))
        #expect(WatchOrder.isMove(order, dragged: "a", before: "c"))
        #expect(WatchOrder.isMove(order, dragged: "a", before: nil))
        #expect(WatchOrder.isMove(order, dragged: "d", before: "a"))
        // A row that is not in the list never moves.
        #expect(!WatchOrder.isMove(order, dragged: "x", before: nil))
        for half in [true, false] {
            let before = WatchOrder.dropTarget(order, dragged: "b", over: 1, upperHalf: half)
            #expect(!WatchOrder.isMove(order, dragged: "b", before: before))
        }
    }

    // A cancelled drag never moves, also when the order would change.
    @Test func aCancelledDragDoesNotMove() {
        #expect(WatchOrder.shouldMove(order, dragged: "a", before: "c", cancelled: false))
        #expect(!WatchOrder.shouldMove(order, dragged: "a", before: "c", cancelled: true))
        #expect(!WatchOrder.shouldMove(order, dragged: "b", before: "c", cancelled: false))
    }

    @Test func theEmptyTextNamesTheMenuItem() {
        #expect(
            WatchOrder.emptyText(.plain)
                == "Nothing on your watchlist yet. Right-click a session and choose Add to "
                + "watchlist.")
        #expect(
            WatchOrder.emptyText(.space)
                == "Nothing on your watchlist yet. Right-click a session and choose Track.")
    }
}
