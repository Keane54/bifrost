// The notices of the actions while a Delete runs (docs/behaviour/actions.md, "Notices"): the
// Delete notice stays until the last Delete ends, and a new notice waits for that end.
import Testing

@testable import BifrostSessions

private let deleting = "Deleting the session..."
private let checking = "Checking for unmerged work..."

// The notices and a notice line that applies their effects: a new text replaces the last one,
// and a hide removes the text only when it is still the text of that ID.
private struct Line {
    var notices = DeleteNotices(deletingText: deleting)
    var text: String?
    var untilHidden = false
    private var shownId = 0

    // Make the change, then apply its effects to the line.
    mutating func run(_ change: (inout DeleteNotices) -> Void) {
        change(&notices)
        for effect in notices.takeEffects() {
            switch effect {
            case .show(let id, let next, let until):
                shownId = id
                text = next
                untilHidden = until
            case .hide(let id):
                if id == shownId { text = nil }
            }
        }
    }
}

@Suite("the notices while a Delete runs")
struct NoticeLinesTests {
    @Test func aNoticeShowsAtOnceWhenNoDeleteRuns() {
        var line = Line()
        line.run { $0.notify("Resumed 1 session.") }
        #expect(line.text == "Resumed 1 session.")
        #expect(!line.untilHidden)
    }

    @Test func theDeleteNoticeStaysUntilTheDeleteEnds() {
        var line = Line()
        line.run { $0.startDelete() }
        #expect(line.text == deleting)
        #expect(line.untilHidden)
        line.run { $0.endDelete() }
        #expect(line.text == nil)
    }

    @Test func theLastNewNoticeShowsOnlyAfterTheDeleteEnds() {
        var line = Line()
        line.run { $0.startDelete() }
        line.run { $0.notify("Another dialog is open. Finish that one first.") }
        #expect(line.text == deleting)
        line.run { $0.notify("Resumed 2 sessions.") }
        #expect(line.text == deleting)
        line.run { $0.endDelete() }
        // The last notice shows, for the normal time.
        #expect(line.text == "Resumed 2 sessions.")
        #expect(!line.untilHidden)
    }

    @Test func theDeleteNoticeStaysUntilTheLastOfTwoDeletesEnds() {
        var line = Line()
        line.run { $0.startDelete() }
        line.run { $0.startDelete() }
        line.run { $0.notify("Resumed 1 session.") }
        line.run { $0.endDelete() }
        #expect(line.text == deleting)
        line.run { $0.endDelete() }
        #expect(line.text == "Resumed 1 session.")
    }

    @Test func aNoticeUntilHiddenShowsUntilItsHideWhenNoDeleteRuns() {
        var line = Line()
        var shown: Int?
        line.run { shown = $0.showUntilHidden(checking) }
        #expect(shown != nil)
        #expect(line.text == checking)
        #expect(line.untilHidden)
        line.run { $0.hide(shown) }
        #expect(line.text == nil)
    }

    @Test func aNoticeUntilHiddenDuringADeleteNeverShows() {
        var line = Line()
        var shown: Int?
        line.run { $0.startDelete() }
        line.run { shown = $0.showUntilHidden(checking) }
        #expect(shown == nil)
        #expect(line.text == deleting)
        line.run { $0.hide(shown) }
        #expect(line.text == deleting)
        // A notice until hidden does not wait, so it does not show after the Delete either.
        line.run { $0.endDelete() }
        #expect(line.text == nil)
    }

    @Test func aDeleteThatStartsDuringACheckReplacesTheCheckNotice() {
        var line = Line()
        var shown: Int?
        line.run { shown = $0.showUntilHidden(checking) }
        line.run { $0.startDelete() }
        line.run { $0.hide(shown) }
        #expect(line.text == deleting)
    }

    @Test func anExtraEndDoesNothing() {
        var line = Line()
        line.run { $0.endDelete() }
        line.run { $0.notify("Resumed 1 session.") }
        #expect(line.text == "Resumed 1 session.")
        // The count stays at 0, so the next Delete still keeps its notice until it ends.
        line.run { $0.startDelete() }
        line.run { $0.notify("Resumed 2 sessions.") }
        #expect(line.text == deleting)
        line.run { $0.endDelete() }
        #expect(line.text == "Resumed 2 sessions.")
    }

    @Test func eachShowHasANewIdAndTheEffectsGoAfterATake() {
        var notices = DeleteNotices(deletingText: deleting)
        notices.notify("a")
        notices.notify("b")
        #expect(
            notices.takeEffects() == [
                .show(1, "a", untilHidden: false), .show(2, "b", untilHidden: false),
            ])
        #expect(notices.takeEffects().isEmpty)
        notices.hide(nil)
        #expect(notices.takeEffects().isEmpty)
    }
}
