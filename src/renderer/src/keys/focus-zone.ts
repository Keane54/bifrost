// Find the focus zone of an element (spec 9.3, D6).
import type { FocusZone } from '../../../shared/keys'

// The part of a DOM element that this module reads. A test passes a fake.
export interface ZoneElement {
  tagName: string
  type?: string
  isContentEditable?: boolean
  closest(selector: string): unknown
}

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
