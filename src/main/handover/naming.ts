// The names of the Hand over button: the name of the new session (spec 8, step 5) and the name
// of the note file (step 4). The note file name follows the rule of the bifrost-hand-over skill,
// so a note from the button and a note from the skill get the same form of name.
import { MAX_NAME } from '../../shared/new-session'

// A number at the end of a name, as " (n)".
const NUMBER_AT_END = / \((\d+)\)$/

// The first n UTF-16 code units of the text. The cut does not split a surrogate pair.
function cut(text: string, n: number): string {
  if (text.length <= n) return text
  const code = text.charCodeAt(n - 1)
  const isHighSurrogate = code >= 0xd800 && code <= 0xdbff
  return text.slice(0, isHighSurrogate ? n - 1 : n)
}

// The name of the new session: the old name with the next free number.
// "x" gives "x (2)". "x (2)" gives "x (3)", never "x (2) (2)". Each taken name is skipped, so
// "x (2)" gives "x (4)" while "x (3)" exists (Review Focus 4). The base is cut so that the name
// has MAX_NAME characters or less.
export function handOverName(oldName: string, taken: readonly string[]): string {
  let base = oldName
  let start = 2
  const match = NUMBER_AT_END.exec(oldName)
  if (match !== null && Number.isSafeInteger(Number(match[1]))) {
    base = oldName.slice(0, match.index)
    start = Number(match[1]) + 1
  }
  for (let n = start; ; n++) {
    const suffix = ` (${n})`
    const name = cut(base, MAX_NAME - suffix.length).trimEnd() + suffix
    if (!taken.includes(name)) return name
  }
}

// The name part of a note file name has this many characters or less.
const MAX_FILE_NAME = 64

// The numbers with two digits each, without a separator.
function digits(...numbers: number[]): string {
  return numbers.map(n => String(n).padStart(2, '0')).join('')
}

// The name of the note file: <session name>-<YYYYMMDD-HHmmss>.md, from the local time.
// In the session name, each run of characters other than ASCII letters, digits, ".", "_" and "-"
// becomes one "-". A "-" at the start or the end goes. An empty name gives "session".
export function noteFileName(sessionName: string, at: Date): string {
  const trimEnds = (text: string): string => text.replace(/^-+|-+$/g, '')
  const dashed = trimEnds(sessionName.replace(/[^A-Za-z0-9._-]+/g, '-'))
  // The cut can leave a "-" at the end.
  const safe = trimEnds(dashed.slice(0, MAX_FILE_NAME))
  const date = `${at.getFullYear()}${digits(at.getMonth() + 1, at.getDate())}`
  const time = digits(at.getHours(), at.getMinutes(), at.getSeconds())
  return `${safe === '' ? 'session' : safe}-${date}-${time}.md`
}
