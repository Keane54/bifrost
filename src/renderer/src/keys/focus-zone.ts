// Find the focus zone of an element (spec 9.3, D6).
import type { FocusZone } from '../../../shared/keys'

// The part of a DOM element that this module reads. A test passes a fake.
export interface ZoneElement {
  tagName: string
  type?: string
  isContentEditable?: boolean
  closest(selector: string): unknown
}

// The element of a chat window has this attribute. Its value is the session ID.
export const CHAT_ATTR = 'data-chat-terminal'
export const SEND_BOX_ATTR = 'data-send-box'
export const OVERVIEW_ROWS_ATTR = 'data-overview-rows'
// The key recorder of Settings > Keys. Bifrost keys pause while it records (ruling C4).
export const KEY_RECORDER_ATTR = 'data-key-recorder'

const MODAL = '[role="dialog"],[role="alertdialog"],[role="menu"],[role="listbox"]'
const CONTROL_ROLES =
  '[role="button"],[role="tab"],[role="menuitem"],[role="checkbox"],[role="radio"],[role="switch"],[role="option"]'
// The types of an input that do not take text.
const CONTROL_INPUTS: ReadonlySet<string> = new Set([
  'checkbox',
  'radio',
  'button',
  'submit',
  'reset',
  'range',
  'color',
])

export function focusZone(el: ZoneElement | null): FocusZone {
  if (el === null) return 'other'
  if (el.closest(MODAL) || el.closest(`[${KEY_RECORDER_ATTR}]`)) return 'modal'
  if (el.closest(`[${CHAT_ATTR}]`)) return 'chat'
  if (el.closest(`[${SEND_BOX_ATTR}]`)) return 'send-box'
  const tag = el.tagName.toUpperCase()
  const isControlInput = tag === 'INPUT' && CONTROL_INPUTS.has((el.type ?? '').toLowerCase())
  if (tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable === true) return 'text'
  if (tag === 'INPUT' && !isControlInput) return 'text'
  if (tag === 'BUTTON' || tag === 'A' || tag === 'SUMMARY' || isControlInput) return 'control'
  return el.closest(CONTROL_ROLES) ? 'control' : 'other'
}

// The part of a DOM element that focusChange reads. A test passes a fake.
export interface FocusElement extends ZoneElement {
  closest(selector: string): { getAttribute(name: string): string | null } | null
}

// What a new focus changes, apart from the keys.
export interface FocusChange {
  // The session to select, or null for no change.
  select: string | null
  // True when the hold gate must forget all keys.
  clearGate: boolean
}

// A focus in a chat window selects its session. So the Selected Item panel shows that session,
// and each session key acts on it (final review Important 1). Only a known session that is not
// selected now changes the selection.
// While the key recorder records, the library calls no hotkey callback. So the keyup of a hold
// key that is down never gets to the gate. A focus on the recorder clears the gate
// (final review Minor 4).
export function focusChange(
  el: FocusElement | null,
  selectedId: string | null,
  rows: readonly { sessionId: string }[],
): FocusChange {
  if (el === null) return { clearGate: false, select: null }
  const clearGate = el.closest(`[${KEY_RECORDER_ATTR}]`) !== null
  const sessionId = el.closest(`[${CHAT_ATTR}]`)?.getAttribute(CHAT_ATTR) ?? null
  const known = sessionId !== null && rows.some(row => row.sessionId === sessionId)
  return { clearGate, select: known && sessionId !== selectedId ? sessionId : null }
}

// The panel ID of the Overview whose rows hold the element, or null. A dialog that opens from the
// rows gives the focus back to them when it closes (M5a carry-over 1).
export function overviewRowsOf(el: FocusElement | null): string | null {
  const panelId = el?.closest(`[${OVERVIEW_ROWS_ATTR}]`)?.getAttribute(OVERVIEW_ROWS_ATTR)
  return panelId ? panelId : null
}
