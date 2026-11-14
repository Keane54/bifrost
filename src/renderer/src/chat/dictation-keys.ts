// The hold key of dictation in a chat window (dictation design 5), and the end of the typed text.
// This module is pure.
//
// The hold key:
// - When the key goes down, the hold key waits HOLD_MS. When the key goes up before that, the key
//   types its text, as a normal key.
// - When the key stays down for HOLD_MS, dictation starts, and the key types nothing. When the key
//   goes up, dictation stops.
// - When another key goes down during the wait, the key types its text first. Then the other key
//   goes to xterm.js, and dictation does not start. So fast typing with rollover keeps each space
//   in its place.
// - Another key, a blur or a close during the hold stops dictation early.
// - A release or another key during the hold before the first level or text types the key first.
//   No green showed yet, so the user typed a slow space. After the first level or text, or during
//   the download, the key types nothing (rulings D8, D10).
// - The key-repeat events of the key do nothing.
// - The key with Cmd, Ctrl, Option or Shift is a normal key. So is a key during the composition of
//   an input method. While blocked() is true, the key is a normal key too.
import { promptBlocks } from '../../../shared/input'
import { physicalCode } from '../../../shared/keys'
import type { SessionRow } from '../../../shared/types'
import { keyOverride } from './key-rules'

export const HOLD_MS = 250

// The part of a KeyboardEvent that the hold key reads. A test gives a plain object.
export interface HoldKeyEvent {
  type: string
  key: string
  code: string
  repeat: boolean
  isComposing: boolean
  keyCode: number
  shiftKey: boolean
  altKey: boolean
  ctrlKey: boolean
  metaKey: boolean
}

export interface HoldKeyDeps<T> {
  // The binding of the dictation key, or null when the key is Off.
  key(): string | null
  setTimeout(fn: () => void, ms: number): T
  clearTimeout(timer: T): void
  // True when dictation cannot start now, for example while Claude shows a choice.
  blocked(): boolean
  // Type the text of the key into the chat.
  typeKey(text: string): void
  // The key stays down: start dictation.
  start(): void
  // The key went up after the start: stop dictation and type the final text.
  stop(): void
  // Another key, a blur or a close during the hold: stop dictation early.
  cancel(): void
  // True when the dictation of the hold got its first level or text, showed the download, or
  // stopped for another cause. While it is false, a release or another key types the key first.
  heard(): boolean
}

export interface HoldKey {
  // True when the hold key handles the event. Then xterm.js must not handle it.
  keydown(event: HoldKeyEvent): boolean
  keyup(event: HoldKeyEvent): boolean
  // keydown, keyup or keypress.
  handle(event: HoldKeyEvent): boolean
  // The terminal lost the focus. A waiting key types its text.
  blur(): void
  // The chat closes. A waiting key types nothing.
  close(): void
  // Dictation could not start. The held key types its text, as a normal key.
  fallback(): void
}

type State<T> =
  | { kind: 'idle' }
  | { kind: 'waiting'; code: string; text: string; timer: T }
  | { kind: 'holding'; code: string; text: string }
  // The key is a normal key until it goes up. Its repeats do nothing.
  | { kind: 'passed'; code: string }

const IDLE = { kind: 'idle' } as const
// The keyCode of a key during the composition of an input method.
const COMPOSING_KEY_CODE = 229

function plain(event: HoldKeyEvent): boolean {
  return !event.shiftKey && !event.altKey && !event.ctrlKey && !event.metaKey
}

// True when the key types one character, for example a space or a letter. A dead key does not.
function typesCharacter(key: string): boolean {
  return [...key].length === 1 && !/\p{Cc}/u.test(key)
}

export function createHoldKey<T>(deps: HoldKeyDeps<T>): HoldKey {
  let state: State<T> = IDLE

  // True for the dictation key with no modifier, outside a composition.
  function own(event: HoldKeyEvent, code: string | null): boolean {
    if (code === null || event.code !== code || !plain(event)) return false
    if (event.isComposing || event.keyCode === COMPOSING_KEY_CODE) return false
    return typesCharacter(event.key)
  }

  function held(): void {
    if (state.kind !== 'waiting') return
    const { code, text } = state
    if (deps.blocked()) {
      state = { code, kind: 'passed' }
      deps.typeKey(text)
      return
    }
    state = { code, kind: 'holding', text }
    deps.start()
  }

  // Another key goes down.
  function other(): void {
    if (state.kind === 'waiting') {
      deps.clearTimeout(state.timer)
      const { text } = state
      state = { code: state.code, kind: 'passed' }
      deps.typeKey(text)
    } else if (state.kind === 'holding') {
      const { text } = state
      state = { code: state.code, kind: 'passed' }
      if (!deps.heard()) deps.typeKey(text)
      deps.cancel()
    }
  }

  // Leave the current state. A waiting key types its text when type is true.
  function leave(type: boolean): void {
    const before = state
    state = IDLE
    if (before.kind === 'waiting') {
      deps.clearTimeout(before.timer)
      if (type) deps.typeKey(before.text)
    } else if (before.kind === 'holding') {
      deps.cancel()
    }
  }

  function keydown(event: HoldKeyEvent): boolean {
    const code = physicalCode(deps.key() ?? '')
    if (!own(event, code)) {
      other()
      return false
    }
    if (state.kind !== 'idle') {
      // A repeat, or a second key down with no key up.
      if (event.repeat || state.kind !== 'passed') return true
      // The key up did not come, because macOS sends none while Cmd is down. Start again.
      state = IDLE
    }
    if (event.repeat || deps.blocked() || code === null) return false
    state = { code, kind: 'waiting', text: event.key, timer: deps.setTimeout(held, HOLD_MS) }
    return true
  }

  function keyup(event: HoldKeyEvent): boolean {
    if (state.kind === 'idle' || event.code !== state.code) return false
    const before = state
    state = IDLE
    if (before.kind === 'waiting') {
      deps.clearTimeout(before.timer)
      deps.typeKey(before.text)
    } else if (before.kind === 'holding') {
      if (!deps.heard()) deps.typeKey(before.text)
      deps.stop()
    }
    return true
  }

  return {
    blur: () => leave(true),
    close: () => leave(false),
    fallback() {
      if (state.kind !== 'holding') return
      const { text } = state
      state = { code: state.code, kind: 'passed' }
      deps.typeKey(text)
    },
    handle(event) {
      if (event.type === 'keydown') return keydown(event)
      if (event.type === 'keyup') return keyup(event)
      // A keypress of the key that the hold key took.
      return event.type === 'keypress' && state.kind !== 'idle' && event.code === state.code
    },
    keydown,
    keyup,
  }
}

// A key event of xterm.js. KeyboardEvent has these parts. A test gives a plain object.
export interface ChatKeyEvent extends HoldKeyEvent {
  preventDefault(): void
}

export interface ChatInputDeps {
  hold: Pick<HoldKey, 'handle'>
  // Stop a hold of dictation. A final text still types (DictationSession.interrupt).
  interrupt(): void
  // Stop a dictation and each typer at once. The keys that wait go away (DictationSession.block).
  block(): void
  // True when a key must not stop the typer of a final text (DictationSession.waits).
  waits(): boolean
  // Keep the speech helper ready.
  warm(): void
  // Send text to the PTY.
  input(text: string): void
}

export interface ChatInput {
  // The custom key handler of xterm.js. False means that xterm.js must not handle the event.
  key(event: ChatKeyEvent): boolean
  // Each registry update gives the row of the window.
  row(row: Pick<SessionRow, 'box' | 'boxReason'> | undefined): void
  // A mouse down, a paste or a drop: input that comes with no key down.
  other(): void
  // The data of xterm.js for the PTY (onData): the text of the keys, a paste and the replies.
  data(data: string): void
}

// The input rules of a chat terminal, in one place that tests can reach:
// - The dictation key goes to the hold key first (dictation design 5).
// - Each other key stops a dictation and its typer before the key goes to the PTY. So a key
//   cannot break the count of the typed text. A modifier key alone writes nothing, so it does not.
// - After a release, while the final text types, a key does not stop the typer. The key waits
//   in the input of the dictation (ruling D9).
// - Escape and Ctrl+C stop each typer at once, also while a final text types. The keys that wait
//   go away, so a waiting Enter cannot submit a part of the text. Then the key goes (ruling D12).
// - Shift+Enter gives a new line, not a submit (spec 8.5, key-rules.ts).
// - A choice that typed text can answer stops a dictation and its typer at once.
// - A click, a paste or a drop can send text or move the cursor of Claude's prompt. So it stops a
//   dictation and its typer too. While a final text types, it does not stop the typer, and the
//   text of a paste or a drop waits as a key does.
// - A cursor key in the data of xterm.js stops a dictation before it goes to the PTY. A mouse
//   wheel with no mouse tracking sends the arrow keys with no key down. So the next DELs of the
//   typer cannot remove other text.
export function createChatInput(deps: ChatInputDeps): ChatInput {
  return {
    data(data) {
      if (movesCursor(data) && !deps.waits()) deps.interrupt()
      deps.input(data)
    },
    key(event) {
      // Read the wait before the hold key acts. So a key of a live dictation still stops it.
      const waits = event.type === 'keydown' && deps.waits()
      if (deps.hold.handle(event)) {
        event.preventDefault()
        if (event.type === 'keydown' && !event.repeat) deps.warm()
        return false
      }
      if (event.type === 'keydown' && !isModifierKey(event.key)) {
        if (stopsAtOnce(event)) deps.block()
        else if (!waits) deps.interrupt()
      }
      const text = keyOverride(event)
      if (text === null) return true
      event.preventDefault()
      if (text !== '') deps.input(text)
      return false
    },
    other() {
      if (!deps.waits()) deps.interrupt()
    },
    row(row) {
      if (row !== undefined && promptBlocks(row)) deps.block()
    },
  }
}

// Escape and Ctrl+C stop each typer at once, also while a final text types (ruling D12).
function stopsAtOnce(event: HoldKeyEvent): boolean {
  if (event.key === 'Escape') return true
  return event.ctrlKey && (event.code === 'KeyC' || event.key.toLowerCase() === 'c')
}

// A cursor key: ESC [ or ESC O, then A, B, C or D. CSI keys can have parameters, for example
// Ctrl+Right. The replies of xterm.js end with other letters.
// biome-ignore lint/suspicious/noControlCharactersInRegex: The regex matches ESC.
const CURSOR_KEY = /\x1b(?:\[[\d;]*|O)[A-D]/

// True when the data has a cursor key, for example the arrow keys of a mouse wheel.
export function movesCursor(data: string): boolean {
  return CURSOR_KEY.test(data)
}

// The keys that type nothing alone.
const MODIFIER_KEYS: ReadonlySet<string> = new Set([
  'Alt',
  'AltGraph',
  'CapsLock',
  'Control',
  'Fn',
  'Meta',
  'OS',
  'Shift',
])

export function isModifierKey(key: string): boolean {
  return MODIFIER_KEYS.has(key)
}

// The most text that typedTail keeps, in UTF-16 units.
const MAX_TAIL = 1000
const ESC = '\x1b'

const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' })

// Remove count graphemes from the end of text.
function dropGraphemes(text: string, count: number): string {
  const parts = Array.from(segmenter.segment(text), s => s.segment)
  return parts.slice(0, Math.max(0, parts.length - count)).join('')
}

// The length of the escape sequence at index i of text. text[i] is ESC.
function escapeLength(text: string, i: number): number {
  const next = text[i + 1]
  if (next === undefined) return 1
  // CSI: the parameter and intermediate bytes, then one final byte.
  if (next === '[') {
    let j = i + 2
    while (j < text.length && text.charCodeAt(j) >= 0x20 && text.charCodeAt(j) <= 0x3f) j++
    return Math.min(j + 1, text.length) - i
  }
  // OSC, DCS, SOS, PM and APC: a string up to BEL or ST.
  if (']PX^_'.includes(next)) {
    for (let j = i + 2; j < text.length; j++) {
      if (text[j] === '\x07') return j + 1 - i
      if (text[j] === ESC && text[j + 1] === '\\') return j + 2 - i
    }
    return text.length - i
  }
  // SS3 and its key, or ESC and one character.
  return Math.min(next === 'O' ? 3 : 2, text.length - i)
}

function isControl(char: string): boolean {
  const code = char.charCodeAt(0)
  return code < 0x20 || (code >= 0x7f && code <= 0x9f)
}

// The end of the text that the user typed into the prompt, after one more write to the PTY. The
// typer of dictation reads it for its leading space.
// - The escape sequences go, for example the arrow keys, the bracket marks of a paste and the
//   replies of xterm.js. ESC and CR is the new line of Shift+Enter (key-rules.ts).
// - A DEL or a backspace removes one grapheme. Enter adds a new line.
// - Ctrl+C and Ctrl+U clear the line in Claude's prompt. The other control characters go.
export function typedTail(tail: string, data: string): string {
  let next = tail
  let deletes = 0
  const applyDeletes = (): void => {
    if (deletes > 0) next = dropGraphemes(next, deletes)
    deletes = 0
  }
  let i = 0
  while (i < data.length) {
    const char = data[i]
    if (char === '\x7f' || char === '\b') {
      deletes += 1
      i += 1
      continue
    }
    applyDeletes()
    if (char === ESC && data[i + 1] === '\r') {
      next += '\n'
      i += 2
    } else if (char === ESC) {
      i += escapeLength(data, i)
    } else {
      if (char === '\r' || char === '\n') next += '\n'
      else if (char === '\x03' || char === '\x15') next = ''
      else if (!isControl(char)) next += char
      i += 1
    }
  }
  applyDeletes()
  return next.length > MAX_TAIL ? next.slice(next.length - MAX_TAIL) : next
}
