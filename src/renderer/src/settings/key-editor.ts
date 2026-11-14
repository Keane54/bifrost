// The pure part of Settings > Keys (spec 9.4): the rows of the key list and the check of a
// recorded key.
import {
  type CustomKeys,
  checkBinding,
  DICTATION_SLOT,
  effectiveKeys,
  KEY_SLOTS,
  type KeySlot,
  REASON_BAD_KEY,
  recordedToBinding,
  type SlotGroup,
  slotById,
} from '../../../shared/keys'
import type { LabelSet } from '../../../shared/settings'
import { groupTitle, slotLabel } from '../keys/key-labels'

export interface KeyRow {
  slot: KeySlot
  label: string
  // The effective binding, or null for no key.
  binding: string | null
  // True when the user changed this slot.
  changed: boolean
}

const GROUP_ORDER: readonly SlotGroup[] = ['always', 'single', 'hold', 'dictation']

// Return the groups in order. The rows of a group keep the KEY_SLOTS order.
export function keyGroups(
  custom: CustomKeys,
  labels: LabelSet,
): { group: SlotGroup; title: string; rows: KeyRow[] }[] {
  const keys = effectiveKeys(custom)
  return GROUP_ORDER.map(group => ({
    group,
    rows: KEY_SLOTS.filter(slot => slot.group === group).map(slot => ({
      binding: keys[slot.id] ?? null,
      changed: Object.hasOwn(custom, slot.id),
      label: slotLabel(slot, labels),
      slot,
    })),
    title: groupTitle(group),
  }))
}

// The recorder gives "[Space]" for the space bar. Only the dictation key can be Space, because a
// tap of it still types a space. For the other slots, "[Space]" stays a key that Bifrost cannot
// use.
function bindingOf(slotId: string, recorded: string): string | null {
  if (slotId !== DICTATION_SLOT) return recordedToBinding(recorded)
  return recordedToBinding(recorded.replace(/\[Space\]$/, 'Space'))
}

// Check a key from the recorder. The recorder gives physical codes, like "Mod+[KeyK]".
export function checkRecorded(
  slotId: string,
  recorded: string,
  custom: CustomKeys,
  labels: LabelSet,
): { ok: true; binding: string } | { ok: false; message: string } {
  const binding = bindingOf(slotId, recorded)
  if (binding === null) return { message: REASON_BAD_KEY, ok: false }
  const check = checkBinding(slotId, binding, effectiveKeys(custom))
  if (check.ok) return { binding: check.binding, ok: true }
  const other = check.conflict === undefined ? undefined : slotById(check.conflict)
  if (other) return { message: `${slotLabel(other, labels)} already uses this key.`, ok: false }
  return { message: check.reason, ok: false }
}
