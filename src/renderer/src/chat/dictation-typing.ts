// The typing engine of dictation. It types the text of the speech helper into Claude's prompt
// through the PTY input of the chat window, and it corrects the words that the recognizer
// changes. A spike measured these rules in Claude's prompt:
// - One DEL removes one grapheme, for example a letter with a mark, an emoji or a CJK character.
//   The engine counts graphemes with Intl.Segmenter.
// - The engine sends DELs only for the text that it typed. So the text of the user stays.
// - One write has the DELs first, then the text. The text of a write is cut at a grapheme
//   boundary. Claude shows a write of more than 800 UTF-16 units as a paste.
// - Two writes in the same tick join. So two writes are WRITE_GAP_MS apart or more.
// - Claude needs about 0.25 ms for each DEL. So after a write with DELs, the engine waits more.
// - The engine never sends Enter, a line break, a tab or ESC. It never reads the screen.

// The character that xterm.js sends for Backspace.
export const DEL = '\x7f'
// The most text in one write, in UTF-16 units. DELs do not count. Writes that wait in the PTY
// can join in one read of Claude. Small parts keep that read below the paste limit.
export const MAX_WRITE_TEXT = 100
// The most DELs in one write. The spike found exact DEL runs up to 1190.
export const MAX_WRITE_DELETES = 1000
// The time between two writes. The spike asks for 10 ms or more.
export const WRITE_GAP_MS = 20

// The wait after a write: the write gap, and 1 ms for each 2 DELs (twice the time that Claude
// needs for them). The next typer of the chat also waits this time after the last write.
export function gapAfter(deletes: number): number {
  return WRITE_GAP_MS + Math.ceil(deletes / 2)
}

const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' })

function graphemes(text: string): string[] {
  return Array.from(segmenter.segment(text), s => s.segment)
}

export interface Edit {
  // The number of DELs: one for each grapheme to remove from the end of the typed text.
  deletes: number
  // The text to type after the DELs.
  insert: string
}

// The edit that changes typed into next. It keeps the longest common start of whole graphemes.
export function planEdit(typed: string, next: string): Edit {
  const old = graphemes(typed)
  const now = graphemes(next)
  let same = 0
  while (same < old.length && same < now.length && old[same] === now[same]) same++
  return { deletes: old.length - same, insert: now.slice(same).join('') }
}

// True when the first graphemes of text are the graphemes of start.
const startsWith = (text: string, start: string): boolean => planEdit(start, text).deletes === 0

// A line break or a tab becomes a space. The other control characters (ESC, DEL, C1) go.
const LINE_BREAK = /\r\n?|[\n\t\v\f\u0085\u2028\u2029]/g
// The format characters go too, for example a zero-width space or a direction mark. The spike
// did not test how Claude counts them. If Claude counts fewer graphemes, a DEL removes the text
// of the user. ZWJ, ZWNJ and the tags stay, because emoji and some languages use them inside a
// grapheme.
const DROP = /\p{Cc}|(?!\u{200C}|\u{200D}|[\u{E0020}-\u{E007F}])\p{Cf}/gu
// Marks, joiners, skin tones and tags join the character before them. At the start of a
// dictation they can join the last character of the user. So the engine removes them there.
const JOINS_BEFORE = /^(?:\p{M}|\u{200C}|\u{200D}|[\u{1F3FB}-\u{1F3FF}]|[\u{E0020}-\u{E007F}])+/u
// At the start of an empty prompt, these characters open a menu or a mode of Claude. The engine
// types a space before them. It does not remove them, so the text of the recognizer stays.
// @ is not in the list: a space before it does not stop the file suggestions of Claude, and an @
// inside a word opens no menu.
const OPENS_MODE = new Set(['/', '!', '?', '#'])

function clean(text: string): string {
  return text.replace(LINE_BREAK, ' ').replace(DROP, '').replace(JOINS_BEFORE, '')
}

// The first part of text: MAX_WRITE_TEXT UTF-16 units or less, cut at a grapheme boundary. A
// grapheme that is longer than the limit is a part alone.
function firstPart(text: string): string {
  if (text.length <= MAX_WRITE_TEXT) return text
  let end = 0
  for (const { index, segment } of segmenter.segment(text)) {
    const stop = index + segment.length
    if (stop > MAX_WRITE_TEXT) return text.slice(0, end === 0 ? stop : end)
    end = stop
  }
  return text
}

export interface TyperDeps {
  // Send one string to the PTY of the chat window.
  write(data: string): void
  // The last text that the chat window sent to the PTY. The typer reads it one time, before its
  // first write.
  lastSent(): string
  // Call fn one time after ms milliseconds. The result stops the timer.
  after(ms: number, fn: () => void): () => void
}

export interface Typer {
  // The text so far. The final part does not change any more. The volatile part can change.
  update(final: string, volatile: string): void
  // The final text of the end. After it, the dictation in the prompt is exactly this text.
  finish(final: string): void
  // Stop the writes that did not start. The typed text stays.
  cancel(): void
  // True while parts of an edit wait for their write.
  busy(): boolean
}

// Make one typer for each dictation. The typer writes at once, then waits gapAfter() before the
// next write. Each write goes from the typed text to the newest text, so no old step stays.
export function createTyper(deps: TyperDeps): Typer {
  // The text in the prompt from this dictation, after all writes so far.
  let typed = ''
  // The text that the prompt must get from this dictation.
  let target = ''
  // The final text at the start of target. An update never removes it.
  let fixed = ''
  let spaceFirst: boolean | null = null
  let stopTimer: (() => void) | null = null
  let finished = false
  let cancelled = false

  // The text to type for a text of the recognizer, with a leading space when it needs one.
  function shape(raw: string): string {
    const text = clean(raw)
    if (text === '') return ''
    if (spaceFirst === null) {
      // A space goes between the text of the user and the dictation, unless the prompt can be
      // empty or ends with whitespace.
      const last = deps.lastSent()
      spaceFirst = last !== '' && !/\s$/u.test(last)
    }
    if (/^\s/u.test(text)) return text
    return spaceFirst || OPENS_MODE.has(text[0]) ? ` ${text}` : text
  }

  function pump(): void {
    if (cancelled || stopTimer !== null) return
    const edit = planEdit(typed, target)
    if (edit.deletes === 0 && edit.insert === '') return
    const deletes = Math.min(edit.deletes, MAX_WRITE_DELETES)
    // After a part of a long DEL run, the next write plans the rest again.
    const text = deletes < edit.deletes ? '' : firstPart(edit.insert)
    const old = graphemes(typed)
    deps.write(DEL.repeat(deletes) + text)
    typed = old.slice(0, old.length - deletes).join('') + text
    stopTimer = deps.after(gapAfter(deletes), () => {
      stopTimer = null
      pump()
    })
  }

  return {
    busy() {
      return !cancelled && typed !== target
    },
    cancel() {
      cancelled = true
      stopTimer?.()
      stopTimer = null
    },
    finish(final) {
      if (finished || cancelled) return
      finished = true
      // The end is the text of the recognizer. It can change earlier final text.
      target = shape(final)
      pump()
    },
    update(final, volatile) {
      if (finished || cancelled) return
      const next = shape(final + volatile)
      // A text that removes final text is not correct. The typer waits for the end.
      if (!startsWith(next, fixed)) return
      target = next
      const nextFixed = shape(final)
      if (startsWith(nextFixed, fixed) && startsWith(next, nextFixed)) fixed = nextFixed
      pump()
    },
  }
}
