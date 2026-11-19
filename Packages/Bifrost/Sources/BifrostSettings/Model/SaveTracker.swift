// The saves that the Save button of the Settings panel waits for (docs/behaviour/settings.md,
// "Saving"). Each change of Settings still saves at once. The tracker follows these saves, so
// that Save can save the drafts, wait for the saves that run, and keep Settings open while a row
// has a failed save.
import BifrostFoundation

// The tracker keeps the state of each row. A row is a value that stays the same for the row: the
// app gives SettingsRowID. The last save that a row started gives the state of the row. A failed
// row stays failed until a good save of the row, a close of its error (forget) or the end of the
// row (remove).
//
// The tracker is a value, so its owner must obey these rules:
// - Keep one copy of the tracker, in the @MainActor settings model. Do not give the tracker to a
//   row view as a value: a change of a copy does not change the tracker.
// - Call started(row:) before the first await of each save, so that a Save that starts during
//   the save waits for it. Call ended(save:ok:) in a defer, so that each save ends, also a save
//   that throws or is cancelled. A refusal with no await, for example a copy that SlashList.add
//   refuses, also calls started(row:) and then ended(save:ok: false).
// - Save calls settle(). On .save, it calls started(row:) for each draft in that loop, with no
//   await and not in the body of a new Task, before it calls settle() again. Then it waits for
//   a signal each time a save ends, while settle() gives .wait. On .done, Save closes Settings
//   when the value is true.
// - A Save that ends before .done, for example a cancelled Save, calls cancelSettle() in its
//   defer. Else the next Save does not get the drafts.
// - Run one Save at a time. A second Save during the wait of the first gets .wait and no drafts,
//   so it must wait for the result of the first Save, not settle again after .done.
package struct SaveTracker<Row: Hashable & Sendable>: Sendable {
    // A text field whose text saves only on demand, for example a new slash command that the
    // user typed. Save saves each draft with text before it waits.
    package struct Draft: Sendable, Equatable {
        package var id: Int
        // The row of the save of the draft.
        package var row: Row
        package var text: String

        package init(id: Int, row: Row, text: String) {
            self.id = id
            self.row = row
            self.text = text
        }
    }

    // The next step of a Save.
    package enum Step: Sendable, Equatable {
        // Start a save of each of these drafts, then settle again. Only the first step of a Save
        // gives the drafts.
        case save([Draft])
        // A save runs. Settle again when a save ends.
        case wait
        // No save runs, and the Save ends. true when no row has a failed save.
        case done(Bool)
    }

    // The row of each save that runs, by the number of the save.
    private var running: [Int: Row] = [:]
    // The number of the last save that each row started.
    private var latest: [Row: Int] = [:]
    private var failed: Set<Row> = []
    // The drafts, in the order of their first add.
    private var drafts: [Draft] = []
    // The number of the last save that started. Each save gets the next number.
    private var count = 0
    // True from the first step of a Save until its step .done.
    private var settling = false

    package init() {}

    // A save of the row starts. The result is the number of the save for ended(save:ok:).
    package mutating func started(row: Row) -> Int {
        count += 1
        running[count] = row
        latest[row] = count
        return count
    }

    // A save ends. ok is false for a refused or a failed save. The result gives the state of the
    // row only when it is the last save that the row started, and the row did not go away
    // (remove). The return value is true then, so the owner shows the result on the row.
    @discardableResult
    package mutating func ended(save: Int, ok: Bool) -> Bool {
        guard let row = running.removeValue(forKey: save), latest[row] == save else { return false }
        if ok {
            failed.remove(row)
        } else {
            failed.insert(row)
        }
        return true
    }

    // The user closed the error of the row. A save of the row that still runs still counts.
    package mutating func forget(_ row: Row) {
        failed.remove(row)
    }

    // The row went away, for example a search hides it. Its failure goes away, and the results
    // of its saves that still run do not count, because nothing can show or close their error.
    // The settle still waits for those saves.
    package mutating func remove(_ row: Row) {
        failed.remove(row)
        latest[row] = nil
    }

    // Add a draft, or give a draft its new text. A draft keeps its place in the list. A draft
    // with a new row drops the state of its old row.
    package mutating func addDraft(_ id: Int, row: Row, text: String) {
        let draft = Draft(id: id, row: row, text: text)
        guard let index = drafts.firstIndex(where: { $0.id == id }) else {
            drafts.append(draft)
            return
        }
        if drafts[index].row != row { remove(drafts[index].row) }
        drafts[index] = draft
    }

    // Remove a draft and the state of its row.
    package mutating func removeDraft(_ id: Int) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        remove(drafts.remove(at: index).row)
    }

    // The next step of Save. The first step of a Save drops the state of each draft with no
    // text, because it has nothing to save, and gives the drafts with text in their order. While
    // a save runs, also a save that started during the wait, the step is wait.
    package mutating func settle() -> Step {
        if !settling {
            settling = true
            for draft in drafts where draft.text.trimmed().isEmpty {
                remove(draft.row)
            }
            let toSave = drafts.filter { !$0.text.trimmed().isEmpty }
            if !toSave.isEmpty { return .save(toSave) }
        }
        guard running.isEmpty else { return .wait }
        settling = false
        return .done(failed.isEmpty)
    }

    // The Save ended before .done. The next settle() is the first step of a new Save, so it gives
    // the drafts again. The saves that run still count.
    package mutating func cancelSettle() {
        settling = false
    }
}

// The rule of a text field with a draft that saves at the blur, for example the family of the
// terminal font.
package enum DraftRule {
    // The text to save: the trimmed draft, so the saved value has no white space at the start or
    // at the end. nil when the trimmed draft is the saved value: then the field shows the saved
    // value again. An empty draft still saves, so the save gives the reason of the refusal.
    package static func toSave(_ draft: String, saved: String) -> String? {
        let text = draft.trimmed()
        return text == saved ? nil : text
    }
}
