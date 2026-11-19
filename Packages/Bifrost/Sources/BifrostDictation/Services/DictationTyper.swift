
// The typer of one dictation (docs/behaviour/dictation.md, "The typer"). It types the text of the
// speech engine into Claude's prompt with the rules of TypingRules, and it corrects the words that
// the recognizer changes. The chat writes the parts (ChatDictation): one write, then the gap of
// that write (TypingRules.gap(afterDeletes:)), then the next write. Each write goes from the typed
// text to the newest text, so no old step stays.
//
// The typer gets its turn when the text before it in the chat is typed. Before its turn, only the
// newest text of the dictation waits. The typer reads the last sent text of the chat one time: at
// its first text that is not empty after the clean.
@MainActor
final class DictationTyper {
    // The text in the prompt from this dictation, after all writes so far.
    private var typed = ""
    // The text that the prompt must get from this dictation.
    private var target = ""
    // The final text at the start of target. An update never removes it.
    private var fixed = ""
    // True when a space goes between the text of the user and the dictation. nil until the first
    // text that is not empty.
    private var spaceFirst: Bool?
    // The newest text before the turn of the typer.
    private var waiting: (final: String, volatile: String, end: Bool)?
    // True after the turn of the typer started.
    private(set) var started = false
    // True after the final text of the end came.
    private(set) var ended = false
    // True after a stop. The typed text stays, and the typer writes nothing more.
    private(set) var cancelled = false

    // True while a text waits for the turn of the typer.
    var waitsForTurn: Bool { !started && !cancelled && waiting != nil }

    // The newest text of the dictation. The final part does not change any more, and the
    // volatile part can change. With end, the final text is the text of the end: after it, the
    // dictation in the prompt is exactly this text. The end is the text of the recognizer, so it
    // can change earlier final text.
    func give(final: String, volatile: String, end: Bool, lastSent: String) {
        guard !ended, !cancelled else { return }
        ended = end
        if started {
            apply(final, volatile, end: end, lastSent: lastSent)
        } else {
            waiting = (final, volatile, end)
        }
    }

    // The turn of the typer. The text that waits applies now, with the last sent text of now.
    func start(lastSent: String) {
        guard !started else { return }
        started = true
        guard let text = waiting else { return }
        waiting = nil
        apply(text.final, text.volatile, end: text.end, lastSent: lastSent)
    }

    // Stop the writes that did not start. The typed text stays.
    func cancel() {
        cancelled = true
        waiting = nil
    }

    // The next write, and its number of DELs: the DELs first, then the first part of the new
    // text. nil when the prompt has the newest text. After a part of a long DEL run, the next
    // write plans the rest again.
    func nextWrite() -> (data: String, deletes: Int)? {
        guard started, !cancelled else { return nil }
        let edit = TypingRules.planEdit(typed: typed, next: target)
        guard edit.deletes > 0 || !edit.insert.isEmpty else { return nil }
        let deletes = min(edit.deletes, TypingRules.maxWriteDeletes)
        let text = deletes < edit.deletes ? "" : TypingRules.firstPart(edit.insert)
        typed = String(typed.dropLast(deletes)) + text
        return (String(repeating: TypingRules.del, count: deletes) + text, deletes)
    }

    private func apply(_ final: String, _ volatile: String, end: Bool, lastSent: String) {
        if end {
            target = shape(final, lastSent: lastSent)
            return
        }
        let next = shape(final + volatile, lastSent: lastSent)
        // A text that removes final text is not correct. The typer waits for the end.
        guard TypingRules.startsWith(next, fixed) else { return }
        target = next
        let nextFixed = shape(final, lastSent: lastSent)
        if TypingRules.startsWith(nextFixed, fixed) && TypingRules.startsWith(next, nextFixed) {
            fixed = nextFixed
        }
    }

    // The text to type for a text of the recognizer, with a leading space when it needs one. The
    // clean text is empty or not empty for both values of promptEmpty.
    private func shape(_ raw: String, lastSent: String) -> String {
        if let spaceFirst {
            return TypingRules.clean(raw, atStart: true, promptEmpty: !spaceFirst)
        }
        let text = TypingRules.clean(raw, atStart: true, promptEmpty: true)
        guard !text.isEmpty else { return "" }
        let first = TypingRules.spaceFirst(after: lastSent)
        spaceFirst = first
        return first ? TypingRules.clean(raw, atStart: true, promptEmpty: false) : text
    }
}
