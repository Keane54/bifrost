// The saves that the Save button of Settings waits for, and the rule of a draft field
// (docs/behaviour/settings.md, "Saving").
import Testing

@testable import BifrostSettings

// Two rows of the Settings panel. The tracker takes any row value, so the tests give texts.
private let snap = "Snap distance"
private let font = "Terminal font"
// The row of the draft of a new slash command.
private let slashDraft = "New slash command"

// The draft of a new slash command with this text.
private func slash(_ text: String, id: Int = 1) -> SaveTracker<String>.Draft {
    SaveTracker<String>.Draft(id: id, row: slashDraft, text: text)
}

extension SaveTracker where Row == String {
    // One save of the row that ends at once, as a refusal with no await does.
    fileprivate mutating func save(_ row: String, ok: Bool) {
        let save = started(row: row)
        ended(save: save, ok: ok)
    }
}

@Suite("the save tracker")
struct SaveTrackerTests {
    // The end of a save tells its owner whether the save gives the state of its row: only the
    // last save that the row started, and only while the row is there.
    @Test func endedTellsWhetherTheSaveGivesTheStateOfItsRow() {
        var tracker = SaveTracker<String>()
        let first = tracker.started(row: snap)
        let second = tracker.started(row: snap)
        let lastEnds = tracker.ended(save: second, ok: true)
        let firstEnds = tracker.ended(save: first, ok: false)
        #expect(lastEnds)
        #expect(!firstEnds)
        #expect(tracker.settle() == .done(true))
        let gone = tracker.started(row: snap)
        tracker.remove(snap)
        let goneEnds = tracker.ended(save: gone, ok: false)
        let againEnds = tracker.ended(save: gone, ok: false)
        #expect(!goneEnds)
        #expect(!againEnds)
        #expect(tracker.settle() == .done(true))
    }

    @Test func aSaveIsDoneAtOnceWhenNoSaveRuns() {
        var tracker = SaveTracker<String>()
        #expect(tracker.settle() == .done(true))
    }

    @Test func aSaveWhileASaveIsSuspendedDoesNotFinishUntilItEnds() {
        var tracker = SaveTracker<String>()
        let save = tracker.started(row: snap)
        #expect(tracker.settle() == .wait)
        #expect(tracker.settle() == .wait)
        tracker.ended(save: save, ok: true)
        #expect(tracker.settle() == .done(true))
    }

    @Test func aFailedSaveKeepsSettingsOpenAlsoAtTheNextSave() {
        var tracker = SaveTracker<String>()
        tracker.save(snap, ok: false)
        #expect(tracker.settle() == .done(false))
        #expect(tracker.settle() == .done(false))
    }

    // The user corrects the value, and the error of the row goes away.
    @Test func aGoodSaveOfTheSameRowClearsItsFailure() {
        var tracker = SaveTracker<String>()
        tracker.save(snap, ok: false)
        #expect(tracker.settle() == .done(false))
        tracker.save(snap, ok: true)
        #expect(tracker.settle() == .done(true))
    }

    // The user closed the error of the row.
    @Test func forgetClearsTheFailureOfARow() {
        var tracker = SaveTracker<String>()
        tracker.save(snap, ok: false)
        tracker.forget(snap)
        #expect(tracker.settle() == .done(true))
    }

    @Test func aGoodSaveOfAnotherRowDoesNotClearTheFailure() {
        var tracker = SaveTracker<String>()
        tracker.save(snap, ok: false)
        tracker.save(font, ok: true)
        #expect(tracker.settle() == .done(false))
    }

    @Test func theLastSaveThatARowStartedGivesItsStateInAnyOrderOfTheResults() {
        var tracker = SaveTracker<String>()
        let first = tracker.started(row: snap)
        let second = tracker.started(row: snap)
        tracker.ended(save: second, ok: true)
        tracker.ended(save: first, ok: false)
        #expect(tracker.settle() == .done(true))
    }

    @Test func aSaveAlsoWaitsForASaveThatStartsWhileItWaits() {
        var tracker = SaveTracker<String>()
        let first = tracker.started(row: snap)
        #expect(tracker.settle() == .wait)
        let second = tracker.started(row: font)
        tracker.ended(save: first, ok: true)
        #expect(tracker.settle() == .wait)
        tracker.ended(save: second, ok: false)
        #expect(tracker.settle() == .done(false))
    }

    @Test func aForgetDoesNotStopASaveThatStillRuns() {
        var tracker = SaveTracker<String>()
        let save = tracker.started(row: snap)
        tracker.forget(snap)
        #expect(tracker.settle() == .wait)
        tracker.ended(save: save, ok: false)
        #expect(tracker.settle() == .done(false))
    }

    // A row that goes away while its save runs can never close its error, so the tracker ignores
    // the result of that save. The Save still waits for it.
    @Test func removeClearsARowAndIgnoresItsSavesThatStillRun() {
        var tracker = SaveTracker<String>()
        tracker.save(snap, ok: false)
        let save = tracker.started(row: font)
        tracker.remove(snap)
        tracker.remove(font)
        #expect(tracker.settle() == .wait)
        tracker.ended(save: save, ok: false)
        #expect(tracker.settle() == .done(true))
    }

    @Test func theEndOfAnUnknownSaveChangesNothing() {
        var tracker = SaveTracker<String>()
        tracker.ended(save: 7, ok: false)
        #expect(tracker.settle() == .done(true))
        let save = tracker.started(row: snap)
        tracker.ended(save: save, ok: true)
        tracker.ended(save: save, ok: false)
        #expect(tracker.settle() == .done(true))
    }

    @Test func theSaveNumbersAreUnique() {
        var tracker = SaveTracker<String>()
        let numbers = (0..<100).map { tracker.started(row: $0.isMultiple(of: 2) ? snap : font) }
        #expect(Set(numbers).count == numbers.count)
        for number in numbers {
            tracker.ended(save: number, ok: true)
        }
        #expect(tracker.started(row: snap) > numbers.max() ?? 0)
    }

    @Test func theFirstStepOfASaveGivesEachDraftWithTextAndADraftWithNoTextHasNoSave() {
        var tracker = SaveTracker<String>()
        tracker.addDraft(1, row: "Empty draft", text: "  ")
        tracker.addDraft(2, row: slashDraft, text: "/b")
        tracker.addDraft(3, row: "Ignore entry", text: "owner/repo")
        #expect(
            tracker.settle() == .save([
                slash("/b", id: 2),
                SaveTracker<String>.Draft(id: 3, row: "Ignore entry", text: "owner/repo"),
            ]))
        let slash = tracker.started(row: slashDraft)
        let ignore = tracker.started(row: "Ignore entry")
        #expect(tracker.settle() == .wait)
        tracker.ended(save: slash, ok: true)
        tracker.ended(save: ignore, ok: true)
        #expect(tracker.settle() == .done(true))
    }

    // A copy that the slash list refuses ends with no await.
    @Test func aRefusedDraftKeepsTheResultDoneFalse() {
        var tracker = SaveTracker<String>()
        tracker.addDraft(1, row: slashDraft, text: "/compact")
        #expect(tracker.settle() == .save([slash("/compact")]))
        tracker.save(slashDraft, ok: false)
        #expect(tracker.settle() == .done(false))
    }

    @Test func aSecondSaveDuringTheWaitGetsWaitNotASecondSave() {
        var tracker = SaveTracker<String>()
        tracker.addDraft(1, row: slashDraft, text: "/b")
        #expect(tracker.settle() == .save([slash("/b")]))
        let save = tracker.started(row: slashDraft)
        // The second Save.
        #expect(tracker.settle() == .wait)
        tracker.ended(save: save, ok: true)
        #expect(tracker.settle() == .done(true))
        // After .done, the next Save starts with the drafts again.
        #expect(tracker.settle() == .save([slash("/b")]))
    }

    @Test func aSaveAfterAnAbandonedSaveGetsTheDraftsAgain() {
        var tracker = SaveTracker<String>()
        tracker.addDraft(1, row: slashDraft, text: "/b")
        #expect(tracker.settle() == .save([slash("/b")]))
        tracker.cancelSettle()
        #expect(tracker.settle() == .save([slash("/b")]))
    }

    // The cancel ends only the Save. A save that still runs still counts.
    @Test func aCancelledSaveKeepsTheSavesThatRun() {
        var tracker = SaveTracker<String>()
        let save = tracker.started(row: snap)
        #expect(tracker.settle() == .wait)
        tracker.cancelSettle()
        #expect(tracker.settle() == .wait)
        tracker.ended(save: save, ok: false)
        #expect(tracker.settle() == .done(false))
    }

    @Test func aDraftGetsItsNewTextAndKeepsItsPlace() {
        var tracker = SaveTracker<String>()
        tracker.addDraft(1, row: "First", text: "/a")
        tracker.addDraft(2, row: "Second", text: "/b")
        tracker.addDraft(1, row: "First", text: "/c")
        guard case .save(let drafts) = tracker.settle() else {
            Issue.record("no drafts to save")
            return
        }
        #expect(drafts.map(\.text) == ["/c", "/b"])
    }

    @Test func aRefusedDraftStopsTheNextSaveOnlyWhileItStillHasText() {
        var tracker = SaveTracker<String>()
        tracker.addDraft(1, row: slashDraft, text: "/bad command")
        #expect(tracker.settle() == .save([slash("/bad command")]))
        tracker.save(slashDraft, ok: false)
        #expect(tracker.settle() == .done(false))
        tracker.addDraft(1, row: slashDraft, text: "")
        #expect(tracker.settle() == .done(true))
    }

    @Test func aRemovedDraftHasNoSaveAndNoFailure() {
        var tracker = SaveTracker<String>()
        tracker.addDraft(1, row: slashDraft, text: "/bad command")
        tracker.save(slashDraft, ok: false)
        tracker.removeDraft(1)
        #expect(tracker.settle() == .done(true))
    }

    @Test func aDraftWithANewRowDropsTheStateOfItsOldRow() {
        var tracker = SaveTracker<String>()
        tracker.addDraft(1, row: "Old row", text: "/a")
        tracker.save("Old row", ok: false)
        tracker.addDraft(1, row: "New row", text: "")
        #expect(tracker.settle() == .done(true))
    }
}

@Suite("the rule of a draft field")
struct DraftRuleTests {
    @Test func theTextIsTrimmedBeforeTheSave() {
        #expect(DraftRule.toSave("  Menlo ", saved: "SF Mono") == "Menlo")
        #expect(DraftRule.toSave("Menlo", saved: "SF Mono") == "Menlo")
    }

    @Test func aTextThatOnlyAddsSpacesToTheSavedValueHasNothingToSave() {
        #expect(DraftRule.toSave(" SF Mono  ", saved: "SF Mono") == nil)
        #expect(DraftRule.toSave("13", saved: "13") == nil)
    }

    // The save of an empty text gives the reason of the refusal.
    @Test func anEmptyTextStillSaves() {
        #expect(DraftRule.toSave("   ", saved: "SF Mono") == "")
    }
}
