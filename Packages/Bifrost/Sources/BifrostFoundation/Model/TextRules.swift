// The text rules of the app. One rule finds white space: Character.isWhitespace, the Unicode
// White_Space property of the first scalar of a Character. So NEL (U+0085) is white space, and
// U+FEFF and U+200B are not. Each length limit counts Characters, so an emoji or a letter with a
// combining mark counts one. Two limits count UTF-16 units, because another program sets them:
// the paste limit of Claude in TypingRules and the cuts of the Live mod.

extension StringProtocol {
    // The text with no white space Character at the start and at the end. A combining mark after
    // a white space is a part of the same Character, so the trim removes the mark too: " \u{301}a"
    // gives "a". A Character with no white space base stays.
    package func trimmed() -> String {
        guard let first = firstIndex(where: { !$0.isWhitespace }),
            let last = lastIndex(where: { !$0.isWhitespace })
        else { return "" }
        return String(self[first...last])
    }
}
