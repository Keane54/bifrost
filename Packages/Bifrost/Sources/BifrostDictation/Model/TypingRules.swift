// The typing rules of dictation (docs/behaviour/dictation.md, "The typer"). The typer of the
// dictation services (DictationTyper) types the text of the speech engine into Claude's prompt with
// these rules, through the PTY input of the chat window. A spike measured these rules in Claude's
// prompt:
// - One DEL removes one Character (a grapheme), for example a letter with a mark, an emoji or a CJK
//   character.
// - The typer sends DELs only for the text that it typed. So the text of the user stays.
// - One write has the DELs first, then the text. The text of a write is cut at a Character
//   boundary. Claude counts its paste limit in UTF-16 units, so the cut counts UTF-16 units.
// - Two writes in the same tick join. So two writes are writeGap apart or more.
// - Claude needs about 0.25 ms for each DEL. So after a write with DELs, the typer waits more.
// - The typer never sends Enter, a line break, a tab or ESC. It never reads the screen.
//
// Two Characters are the same only when they have the same Unicode scalars. String == of Swift uses
// canonical equivalence (U+00E9 is equal to U+0065 U+0301), but Claude gets the bytes.

// One edit of the typed text: DELs, then a text.
package struct TypingEdit: Sendable, Equatable {
    // The number of DELs: one for each Character to remove from the end of the typed text.
    package var deletes: Int
    // The text to type after the DELs.
    package var insert: String

    package init(deletes: Int, insert: String) {
        self.deletes = deletes
        self.insert = insert
    }

    // Two edits are equal when they send the same bytes.
    package static func == (a: TypingEdit, b: TypingEdit) -> Bool {
        a.deletes == b.deletes && TypingRules.same(a.insert, b.insert)
    }
}

package enum TypingRules {
    // The character that a terminal sends for Backspace.
    package static let del = "\u{7F}"
    // The most text in one write, in UTF-16 units. DELs do not count. Writes that wait in the PTY
    // can join in one read of Claude. Small parts keep that read below the paste limit.
    package static let maxWriteText = 100
    // The most DELs in one write. The spike found exact DEL runs up to 1190.
    package static let maxWriteDeletes = 1000
    // The time between two writes. The spike asks for 10 ms or more.
    package static let writeGap = Duration.milliseconds(20)

    // The characters that open a menu or a mode of Claude at the start of an empty prompt. The
    // typer types a space before them. It does not remove them, so the text of the recognizer
    // stays. @ is not in the list: a space before it does not stop the file suggestions of
    // Claude, and an @ inside a word opens no menu.
    private static let opensMode: Set<Unicode.Scalar> = ["/", "!", "?", "#"]

    // The wait after a write: the write gap, and 1 ms for each 2 DELs (twice the time that
    // Claude needs for them). The next typer of the chat also waits this time after the last
    // write.
    package static func gap(afterDeletes deletes: Int) -> Duration {
        writeGap + .milliseconds((deletes + 1) / 2)
    }

    // True when the two texts have the same Unicode scalars.
    package static func same(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    private static func same(_ a: Character, _ b: Character) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    // The edit that changes typed into next. It keeps the longest common start of whole
    // Characters.
    package static func planEdit(typed: String, next: String) -> TypingEdit {
        let old = Array(typed)
        let now = Array(next)
        var common = 0
        while common < old.count, common < now.count, same(old[common], now[common]) {
            common += 1
        }
        return TypingEdit(deletes: old.count - common, insert: String(now[common...]))
    }

    // True when the first Characters of text are the Characters of start.
    package static func startsWith(_ text: String, _ start: String) -> Bool {
        planEdit(typed: start, next: text).deletes == 0
    }

    // A line break or a tab: it becomes a space. CR LF is one line break.
    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x85, 0x2028, 0x2029: true
        default: false
        }
    }

    // ZWNJ, ZWJ and the tags. They stay, because emoji and some languages use them inside a
    // Character.
    private static func isJoiner(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200C, 0x200D, 0xE0020...0xE007F: true
        default: false
        }
    }

    // A control character (ESC, DEL, C1) or a format character, for example a zero-width space
    // or a direction mark. The spike did not test how Claude counts the format characters. If
    // Claude counts fewer Characters, a DEL removes the text of the user. So they go.
    private static func drops(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control: true
        case .format: !isJoiner(scalar)
        default: false
        }
    }

    // A mark, a joiner, a skin tone or a tag: it joins the Character before it. At the start of a
    // dictation it can join the last Character of the user.
    private static func joinsBefore(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return isJoiner(scalar) || (0x1F3FB...0x1F3FF).contains(scalar.value)
        }
    }

    // The text to type for a text of the recognizer. The rule reads Unicode scalars:
    // - A line break or a tab becomes a space. The other control characters and the format
    //   characters go. ZWJ, ZWNJ and the tags stay.
    // - atStart: the text is at the start of the dictation. Then the marks and the joiners at
    //   its start go, so that they never join the text of the user. A text that is not empty
    //   then gets a space first, unless it starts with white space: always when promptEmpty is
    //   false, and only before a menu character (/, !, ? and #) when promptEmpty is true.
    // - promptEmpty: the prompt can be empty before the dictation, or its text ends with white
    //   space (spaceFirst(after:) is false).
    package static func clean(_ text: String, atStart: Bool, promptEmpty: Bool) -> String {
        var scalars = String.UnicodeScalarView()
        var afterCR = false
        for scalar in text.unicodeScalars {
            defer { afterCR = scalar == "\r" }
            if scalar == "\n" && afterCR { continue }
            if isLineBreak(scalar) {
                scalars.append(" ")
            } else if !drops(scalar) {
                scalars.append(scalar)
            }
        }
        guard atStart else { return String(scalars) }
        let kept = String(scalars.drop(while: joinsBefore))
        guard let first = kept.first, !first.isWhitespace else { return kept }
        // The first scalar opens a menu, also with a mark after it.
        let opens = first.unicodeScalars.first.map { opensMode.contains($0) } ?? false
        return !promptEmpty || opens ? " " + kept : kept
    }

    // True when a dictation after this last sent text needs a space first: the text is not
    // empty and does not end with white space.
    package static func spaceFirst(after lastSent: String) -> Bool {
        guard let last = lastSent.last else { return false }
        return !last.isWhitespace
    }

    // The first part of a text: maxWriteText UTF-16 units or less, cut at a Character boundary.
    // A Character that is longer than the limit is a part alone.
    package static func firstPart(_ text: String) -> String {
        guard text.utf16.count > maxWriteText else { return text }
        var units = 0
        var count = 0
        for character in text {
            let stop = units + character.utf16.count
            if stop > maxWriteText { return String(text.prefix(max(count, 1))) }
            units = stop
            count += 1
        }
        return text
    }
}
