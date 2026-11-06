// The text of a key slot in the key editor (spec 9.1, D-9).
import type { KeyCommandId, KeySlot, SlotGroup } from '../../../shared/keys'
import type { LabelSet } from '../../../shared/settings'
import { ACTIONS, type ActionId, actionLabel } from '../actions/action-model'

const FIXED: Partial<Record<KeyCommandId, string>> = {
  'close-panel': 'Close the focused panel',
  escape: 'Clear the selection, or leave the send box',
  'event-log': 'Event log',
  'focus-overview': 'Move focus to the Overview',
  'next-overview-tab': 'Next Overview tab',
  'next-stack-tab': 'Next tab in the stack',
  'prev-overview-tab': 'Previous Overview tab',
  'prev-stack-tab': 'Previous tab in the stack',
  'save-layout': 'Save the layout',
  'select-next': 'Select the next row',
  'select-prev': 'Select the previous row',
  settings: 'Settings',
  'toggle-fullscreen': 'Toggle Fullscreen',
  'usage-hud': 'Usage HUD',
}

const GROUP_TITLES: Record<SlotGroup, string> = {
  always: 'Shortcuts that work at all times',
  hold: 'Hold a key and click a row',
  single: 'Single keys (not in a chat window or a text box)',
}

function isAction(command: KeyCommandId): command is ActionId & KeyCommandId {
  return Object.hasOwn(ACTIONS, command)
}

// The label of the action without the trailing dots of a menu entry.
function plainActionLabel(id: ActionId, labels: LabelSet): string {
  return actionLabel(id, labels).replace(/\.{3}$/, '')
}

export function slotLabel(slot: KeySlot, labels: LabelSet): string {
  const { command, arg } = slot
  if (command === 'set-priority') {
    return arg === 0 || arg === undefined
      ? 'Clear the priority'
      : `${plainActionLabel(command, labels)} ${arg}`
  }
  if (command === 'open-project') return `${plainActionLabel(command, labels)} in the default app`
  if (command === 'select-row') return `Select row ${arg}`
  if (command === 'load-layout') return `Load layout ${arg}`
  const fixed = FIXED[command]
  if (fixed !== undefined) return fixed
  return isAction(command) ? plainActionLabel(command, labels) : command
}

export function groupTitle(group: SlotGroup): string {
  return GROUP_TITLES[group]
}
