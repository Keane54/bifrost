// The notices of the actions while a Delete runs (docs/behaviour/actions.md, "Notices"). A
// Delete can take some minutes. While one runs, its notice stays, and a new notice does not
// replace it. The last new notice shows after the last Delete ends.

// A change of the notice line. A show replaces the text of the line. A hide removes the text
// only when it is still the text of that ID. The line removes a text that is not untilHidden
// after its normal time.
package enum NoticeEffect: Sendable, Equatable {
    case show(Int, String, untilHidden: Bool)
    case hide(Int)
}

// The rules of the notice line while Deletes run. The runner applies the effects to the line.
package struct DeleteNotices: Sendable {
    private let deletingText: String
    // The number of the Deletes that run.
    private var deletes = 0
    // The ID of the notice of the Deletes.
    private var deletingId = 0
    // The last notice that came while a Delete ran.
    private var waiting: String?
    // The ID of the last show. Each show gets the next ID.
    private var lastId = 0
    private var effects: [NoticeEffect] = []

    package init(deletingText: String) {
        self.deletingText = deletingText
    }

    // Show a notice for the normal time. While a Delete runs, the notice waits.
    package mutating func notify(_ text: String) {
        if deletes > 0 {
            waiting = text
        } else {
            show(text, untilHidden: false)
        }
    }

    // Show a notice until hide. While a Delete runs, it does not show, and the result is nil.
    package mutating func showUntilHidden(_ text: String) -> Int? {
        guard deletes == 0 else { return nil }
        return show(text, untilHidden: true)
    }

    // Remove a notice of showUntilHidden. nil does nothing.
    package mutating func hide(_ id: Int?) {
        if let id { effects.append(.hide(id)) }
    }

    // Call startDelete when a Delete starts to run, and endDelete when it ends. An extra end does
    // nothing.
    package mutating func startDelete() {
        deletes += 1
        deletingId = show(deletingText, untilHidden: true)
    }

    package mutating func endDelete() {
        guard deletes > 0 else { return }
        deletes -= 1
        guard deletes == 0 else { return }
        effects.append(.hide(deletingId))
        if let text = waiting {
            waiting = nil
            show(text, untilHidden: false)
        }
    }

    // The effects since the last take, in order.
    package mutating func takeEffects() -> [NoticeEffect] {
        defer { effects = [] }
        return effects
    }

    @discardableResult
    private mutating func show(_ text: String, untilHidden: Bool) -> Int {
        lastId += 1
        effects.append(.show(lastId, text, untilHidden: untilHidden))
        return lastId
    }
}
