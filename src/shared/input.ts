// The text that Bifrost types into a session, and the checks on it (spec 8.4).
// The main process runs the plan. The renderer uses the same checks to show a reason early.
import type { SessionRow } from './types'

export const PASTE_START = '\x1b[200~'
export const PASTE_END = '\x1b[201~'
export const CR = '\r'
export const ESC = '\x1b'

// The gap between the text and the CR. M0 question 5 used 300 ms for a paste.
export const PASTE_CR_DELAY_MS = 300
export const TYPED_CR_DELAY_MS = 500
export const MAX_TEXT = 20_000
export const MAX_RENAME = 64

// How a slash command goes to the session. M4 Task 1 found that a paste works.
export type SlashForm = 'paste' | 'typed'
export const SLASH_FORM: SlashForm = 'paste'

// The block message of spec 8.4.
export const RED_BOX_BLOCK = 'Answer the prompt in the chat window first.'
export const REASON_EMPTY = 'Type a message first.'
export const REASON_TOO_LONG = 'The text is too long. The maximum is 20,000 characters.'
export const REASON_SLASH_LINES = 'A slash command has one line.'
export const REASON_NO_NAME = 'Type a name first.'
export const REASON_NAME_LONG = 'The name is too long. The maximum is 64 characters.'

// Wait delayMs, then write data.
export interface InputStep {
  delayMs: number
  data: string
}

export type InputPlan =
  | { ok: true; slash: boolean; steps: InputStep[] }
  | { ok: false; reason: string }

// The control characters that the text cannot hold: C0 without tab and LF, DEL and C1.
// The text cannot hold ESC, so it cannot end the paste early or press a key.
// biome-ignore lint/suspicious/noControlCharactersInRegex: The regex matches control characters.
const CONTROL = /[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/g

// Change CRLF and a lone CR to LF. Then remove the control characters. Keep tab and LF.
export function cleanText(text: string): string {
  return text.replace(/\r\n?/g, '\n').replace(CONTROL, '')
}

// Make the steps that send the text. Each plan writes the text first, then CR.
// No plan has only a CR, so Bifrost never sends CR to an empty prompt.
// The length limit applies to the text as the user typed it, before the clean-up.
// So the send box can count the characters itself, and a large text costs no clean-up time.
export function planText(text: string, form: SlashForm = SLASH_FORM): InputPlan {
  if (text.length > MAX_TEXT) return { ok: false, reason: REASON_TOO_LONG }
  const t = cleanText(text).trim()
  if (t === '') return { ok: false, reason: REASON_EMPTY }
  const slash = t.startsWith('/')
  if (slash && t.includes('\n')) return { ok: false, reason: REASON_SLASH_LINES }
  if (slash && form === 'typed') {
    return {
      ok: true,
      slash,
      steps: [
        { data: t, delayMs: 0 },
        { data: CR, delayMs: TYPED_CR_DELAY_MS },
      ],
    }
  }
  // xterm.js changes each line break in a paste to CR. This plan does the same.
  return {
    ok: true,
    slash,
    steps: [
      { data: PASTE_START + t.replaceAll('\n', CR) + PASTE_END, delayMs: 0 },
      { data: CR, delayMs: PASTE_CR_DELAY_MS },
    ],
  }
}

// Interrupt sends one Esc. Two Esc open the rewind menu.
export const INTERRUPT_STEPS: readonly InputStep[] = Object.freeze([
  Object.freeze({ data: ESC, delayMs: 0 }),
])

// The slash command that renames a session. Each run of white space becomes one space.
export function renameText(
  name: string,
): { ok: true; text: string } | { ok: false; reason: string } {
  // The 64 character limit applies to the name after the clean-up.
  // A name that is longer than MAX_TEXT gets no clean-up.
  if (name.length > MAX_TEXT) return { ok: false, reason: REASON_NAME_LONG }
  const n = cleanText(name).replace(/\s+/g, ' ').trim()
  if (n === '') return { ok: false, reason: REASON_NO_NAME }
  if (n.length > MAX_RENAME) return { ok: false, reason: REASON_NAME_LONG }
  return { ok: true, text: `/rename ${n}` }
}

// A red box of a prompt blocks Send message, Run slash command, Compact and Rename (spec 8.4).
// Typed text can answer the prompt by accident. An old yellow box and an error box do not block.
// A red box with no known cause blocks, because it can be a prompt.
export function promptBlocks(row: Pick<SessionRow, 'box' | 'boxReason'>): boolean {
  return row.box === 'red' && row.boxReason !== 'escalated' && row.boxReason !== 'error'
}

// Enter sends the text. Shift+Enter adds a line break.
// Enter during an input method composition does not send.
export function isSendKey(ev: { key: string; shiftKey: boolean; isComposing: boolean }): boolean {
  return ev.key === 'Enter' && !ev.shiftKey && !ev.isComposing
}
