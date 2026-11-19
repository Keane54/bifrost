// The cases of the text rules (TextRules.swift of BifrostFoundation): white space is
// Character.isWhitespace, and each length limit counts Characters. The tests of each module check
// that its rules read white space and count a length in the same way.

// A text of one Character, and true when the Character is white space.
package struct SpaceCase: Sendable, CustomStringConvertible {
    package let text: String
    package let isSpace: Bool

    // The Unicode scalars of the text, as the name of the case.
    package var description: String {
        text.unicodeScalars.map { scalar in
            "U+" + String(scalar.value, radix: 16, uppercase: true)
        }.joined(separator: " ")
    }
}

// NEL is white space, and U+FEFF and U+200B are not (the Unicode White_Space property). A space
// with a combining mark is one Character with a white space base, so it is white space too.
// U+FEFF and U+200B are hidden characters, so a local name with them is refused.
package let spaceCases: [SpaceCase] = [
    (" ", true), ("\t", true), ("\u{B}", true), ("\u{C}", true), ("\r\n", true),
    ("\u{85}", true), ("\u{A0}", true), ("\u{1680}", true), ("\u{2000}", true),
    ("\u{2009}", true), ("\u{200A}", true), ("\u{2028}", true), ("\u{2029}", true),
    ("\u{202F}", true), ("\u{205F}", true), ("\u{3000}", true), (" \u{301}", true),
    ("\u{FEFF}", false), ("\u{200B}", false), ("x", false), ("😀", false), ("e\u{301}", false),
].map { SpaceCase(text: $0, isSpace: $1) }

// One Character of each kind: ASCII, a letter and a combining mark, an emoji, an emoji with a
// skin tone and a flag. They have 1, 2, 2, 4 and 4 UTF-16 units.
package let limitUnits = ["x", "e\u{301}", "😀", "👍🏽", "🇰🇷"]
