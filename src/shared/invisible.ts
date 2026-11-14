// The invisible characters of Discuss with Claude (Modules design 8.4). Heimdall removes them from
// the card texts that it copies and from the text that the user pastes into the prompt box. They
// are the soft hyphen, the joiners, the fillers, the zero-width characters, the direction
// controls, the variation selectors, the byte order mark and the tag characters. A module can use
// them to hide text that Claude reads. This rule keeps tabs and new lines.
//
// The rule also removes each default ignorable code point of Unicode, U+061C and U+FFA0 (ruling
// P11). So the variation selectors 17 to 256 (U+E0100 to U+E01EF) cannot hide a text after an
// emoji.
//
// The manifest check (HIDDEN_CHARACTER in module-manifest.ts) is a different rule. It refuses a
// manifest text with any control or format character. Do not merge the two rules.

// The ranges of code points to remove, from the first to the last: the list of plan Task 10,
// then the two characters of ruling P11.
const RANGES: readonly (readonly [number, number])[] = [
  [0x00ad, 0x00ad],
  [0x034f, 0x034f],
  [0x115f, 0x1160],
  [0x180e, 0x180e],
  [0x200b, 0x200f],
  [0x202a, 0x202e],
  [0x2060, 0x2064],
  [0x2066, 0x2069],
  [0x3164, 0x3164],
  [0xfe00, 0xfe0f],
  [0xfeff, 0xfeff],
  [0xe0000, 0xe007f],
  [0x061c, 0x061c],
  [0xffa0, 0xffa0],
]

const point = (c: number): string => `\\u{${c.toString(16)}}`
const listed = RANGES.map(([from, to]) => `${point(from)}-${point(to)}`).join('')
const INVISIBLE = new RegExp(`[${listed}\\p{Default_Ignorable_Code_Point}]`, 'gu')

// The text with each invisible character removed.
export function stripInvisible(text: string): string {
  return text.replace(INVISIBLE, '')
}
