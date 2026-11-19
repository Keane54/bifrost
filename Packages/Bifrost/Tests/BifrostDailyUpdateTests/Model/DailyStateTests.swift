import BifrostFoundation
import BifrostTestSupport
import Foundation
import Testing

@testable import BifrostDailyUpdate

// The changes of the day state (docs/behaviour/daily-update.md, "The day state").
@Suite("the Daily update state", .testTimeLimit)
struct DailyStateTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func result(_ id: String, _ draft: String, moved: Bool = true) -> DailyAreaResult {
        DailyAreaResult(
            id: id, moved: moved, items: [DailyItem(kind: .ticket, id: "T-1", title: "A")],
            draft: draft)
    }

    @Test func aRunKeepsAChangedDraftAndOffersTheNewOne() {
        var state = DailyState(marks: .fresh("2026-11-18"))
        state.apply(run: [result("a", "first")], unplaced: [], at: now)
        #expect(state.areas["a"]?.draft == "first")
        #expect(state.areas["a"]?.edited == false)
        // A draft that the user did not change is replaced.
        state.apply(run: [result("a", "second")], unplaced: [], at: now)
        #expect(state.areas["a"]?.draft == "second")
        #expect(state.areas["a"]?.pending == nil)
        // A draft that the user changed stays, and the new draft waits beside it.
        state.editDraft("a", text: "mine")
        state.apply(run: [result("a", "third")], unplaced: [], at: now)
        #expect(state.areas["a"]?.draft == "mine")
        #expect(state.areas["a"]?.edited == true)
        #expect(state.areas["a"]?.pending == "third")
        // The same text as the changed draft gives no pending draft.
        state.apply(run: [result("a", "mine")], unplaced: [], at: now)
        #expect(state.areas["a"]?.pending == nil)
        #expect(state.areas["a"]?.edited == true)
        // The user takes the pending draft, or keeps their own.
        state.apply(run: [result("a", "fourth")], unplaced: [], at: now)
        state.keepMine("a")
        #expect(state.areas["a"]?.pending == nil)
        #expect(state.areas["a"]?.draft == "mine")
        state.apply(run: [result("a", "fifth")], unplaced: [], at: now)
        state.usePending("a")
        #expect(state.areas["a"]?.draft == "fifth")
        #expect(state.areas["a"]?.edited == false)
        #expect(state.areas["a"]?.pending == nil)
        #expect(state.lastRun == DailyRun(at: now, ok: true))
    }

    @Test func redoReplacesItsOwnTabOnly() {
        var state = DailyState(marks: .fresh("2026-11-18"))
        state.apply(run: [result("a", "a1"), result("b", "b1")], unplaced: [], at: now)
        state.editDraft("a", text: "a mine")
        state.editDraft("b", text: "b mine")
        state.redo(result("a", "a2"), since: now)
        #expect(state.areas["a"]?.draft == "a2")
        #expect(state.areas["a"]?.edited == false)
        #expect(state.areas["a"]?.since == now)
        #expect(state.areas["b"]?.draft == "b mine")
        #expect(state.areas["b"]?.edited == true)
    }

    @Test func aNewDayGivesFreshMarks() {
        var state = DailyState(marks: .fresh("2026-11-17"))
        state.apply(run: [result("a", "one")], unplaced: [], at: now)
        state.editDraft("a", text: "mine")
        state.apply(run: [result("a", "two")], unplaced: [], at: now)
        state.markSent("a", at: now)
        state.setFirstShown()
        state.setSecondShown()
        state.setSkipped(true)
        state.rollDay(to: "2026-11-17")
        #expect(state.marks.skipped)
        state.rollDay(to: "2026-11-18")
        #expect(state.marks == .fresh("2026-11-18"))
        #expect(state.areas["a"]?.pending == nil)
        #expect(state.areas["a"]?.edited == false)
        #expect(state.areas["a"]?.draft == "mine")
        // The last send stays for the next period.
        #expect(state.lastSent["a"] == now)
        // The run of the new day replaces the draft that the user changed on the day before.
        state.apply(run: [result("a", "three")], unplaced: [], at: now)
        #expect(state.areas["a"]?.draft == "three")
    }

    @Test func markSentAndUndo() {
        let earlier = now.addingTimeInterval(-86400)
        var state = DailyState(marks: .fresh("2026-11-18"))
        state.markSent("a", at: earlier)
        state.markSent("a", at: now)
        #expect(state.lastSent["a"] == now)
        #expect(state.prevSent["a"] == earlier)
        #expect(state.marks.sent["a"] == now)
        state.undoSent("a")
        #expect(state.lastSent["a"] == earlier)
        #expect(state.prevSent["a"] == nil)
        #expect(state.marks.sent["a"] == nil)
        // The first send, undone, leaves no last send.
        var first = DailyState(marks: .fresh("2026-11-18"))
        first.markSent("b", at: now)
        first.undoSent("b")
        #expect(first.lastSent["b"] == nil)
        #expect(first.marks.sent.isEmpty)
    }

    @Test func skipTodayAndFailures() {
        var state = DailyState(marks: .fresh("2026-11-18"))
        state.setSkipped(true)
        #expect(state.marks.skipped)
        state.setSkipped(false)
        #expect(!state.marks.skipped)
        state.failRun(at: now, .sourceUnavailable, detail: "needs auth")
        #expect(
            state.lastRun
                == DailyRun(at: now, ok: false, failure: .sourceUnavailable, detail: "needs auth"))
        #expect(
            FailureCode.sourceUnavailable.text(detail: "needs auth", server: "board-one")
                == "Bifrost couldn't reach board-one (needs auth). "
                + "Check it in Claude Code with /mcp."
        )
        #expect(
            FailureCode.timeout.text() == "The run took more than 5 minutes, so Bifrost stopped it."
        )
    }

    @Test func aBadPartOfTheFileGivesItsEmptyValue() throws {
        let text = """
            {"version":1,"marks":"x","lastSent":{"a":1000,"b":"no","c":1e300},
             "areas":{"a":{"draft":"d"},"b":{"x":1}},
             "unplaced":[{"kind":"ticket","id":"1","title":"t"},{"kind":"other"}],
             "lastRun":{"at":"x"},"extra":true}
            """
        let state = try JSONDecoder().decode(DailyState.self, from: Data(text.utf8))
        #expect(state.marks == .fresh(""))
        #expect(state.lastSent == ["a": Date(timeIntervalSince1970: 1)])
        // A time that is too large reads as missing, and a save never traps.
        let huge =
            #"{"version":1,"areas":{"a":{"draft":"d","since":1e300}},"#
            + #""lastRun":{"at":1e300,"ok":true}}"#
        var big = try JSONDecoder().decode(DailyState.self, from: Data(huge.utf8))
        #expect(big.areas["a"]?.since == nil)
        #expect(big.lastRun == nil)
        big.markSent("a", at: Date(timeIntervalSince1970: 1e300))
        #expect(throws: Never.self) { try JSONEncoder().encode(big) }
        #expect(state.areas.keys.sorted() == ["a"])
        #expect(state.unplaced.count == 1)
        #expect(state.lastRun == nil)
        #expect(state.unknown.values["extra"] == true)
        let later = try JSONDecoder().decode(DailyState.self, from: Data(#"{"version":2}"#.utf8))
        #expect(later.areas.isEmpty)
    }
}
