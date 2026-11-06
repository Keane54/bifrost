// The logic of the Rename dialog (spec 9.1). The dialog only draws what these functions give.
import { cleanAlias } from '../../../shared/alias'
import { promptBlocks, renameText } from '../../../shared/input'
import type { SessionRow } from '../../../shared/types'
import { REASON_EXTERNAL, REASON_PARKED, REASON_RED_BOX, REASON_WAIT_ID } from './reasons'

// The texts of the dialog.
export const NAME_FIELD_LABEL = 'Name in Bifrost'
export const CLAUDE_BOX_LABEL = 'Also rename it in Claude Code'
export const RESET_LABEL = 'Use the Claude Code name'
export const CLAUDE_BOX_LOST_NOTE =
  "Bifrost can't rename it in Claude Code right now. Save keeps the name in Bifrost only."

export interface RenameControls {
  // hidden: the row cannot take /rename. disabled: it can, but not now.
  claudeBox: 'hidden' | 'enabled' | 'disabled'
  claudeBoxReason: string | null
  // True when the row has a local name.
  showReset: boolean
}

// Say which controls the dialog shows for a row.
export function renameControls(row: SessionRow): RenameControls {
  const showReset = row.name !== row.claudeName
  if (row.kind !== 'owned' || row.state === 'parked') {
    return { claudeBox: 'hidden', claudeBoxReason: null, showReset }
  }
  if (promptBlocks(row)) {
    return { claudeBox: 'disabled', claudeBoxReason: REASON_RED_BOX, showReset }
  }
  if (!row.shortId) return { claudeBox: 'disabled', claudeBoxReason: REASON_WAIT_ID, showReset }
  return { claudeBox: 'enabled', claudeBoxReason: null, showReset }
}

// The check box counts only while the dialog shows it as usable.
export function effectiveAlsoClaude(row: SessionRow, alsoClaude: boolean): boolean {
  return alsoClaude && renameControls(row).claudeBox === 'enabled'
}

// A note for the user when the check box was on but the row cannot take /rename now.
export function claudeBoxLostNote(row: SessionRow, alsoClaude: boolean): string | null {
  return alsoClaude && !effectiveAlsoClaude(row, alsoClaude) ? CLAUDE_BOX_LOST_NOTE : null
}

// What one save does.
// alias: the new local name, or null to clear it. send: the text to type, or null for none.
export type RenamePlan =
  | { ok: true; alias: string | null; send: string | null }
  | { ok: false; reason: string }

export function planRename(
  row: SessionRow,
  input: { name: string; alsoClaude: boolean },
): RenamePlan {
  if (input.alsoClaude) {
    const controls = renameControls(row)
    if (controls.claudeBox !== 'enabled') {
      if (controls.claudeBoxReason !== null) return { ok: false, reason: controls.claudeBoxReason }
      return { ok: false, reason: row.kind === 'external' ? REASON_EXTERNAL : REASON_PARKED }
    }
    const result = renameText(input.name)
    // The real name changes, so the local name goes away.
    return result.ok ? { alias: null, ok: true, send: result.text } : result
  }
  const result = cleanAlias(input.name)
  if (!result.ok) return result
  return { alias: result.name === '' ? null : result.name, ok: true, send: null }
}
