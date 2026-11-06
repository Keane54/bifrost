// Pure edits of the list of slash favourites (spec 9.6).
import { checkSlashCommand, MAX_SLASH_COMMANDS } from '../../../shared/settings'

export type AddSlashResult = { ok: true; list: string[] } | { ok: false; reason: string }

export const REASON_SLASH_COPY = 'That command is already in the list.'
export const REASON_SLASH_FULL = `You can keep up to ${MAX_SLASH_COMMANDS} commands.`

// Add the command to the end of the list. The result has the reason when the list refuses it.
export function addSlash(list: string[], text: string): AddSlashResult {
  const check = checkSlashCommand(text)
  if (!check.ok) return check
  if (list.includes(check.text)) return { ok: false, reason: REASON_SLASH_COPY }
  if (list.length >= MAX_SLASH_COMMANDS) return { ok: false, reason: REASON_SLASH_FULL }
  return { list: [...list, check.text], ok: true }
}

// Remove one item. An index out of range gives the same array.
export function removeSlash(list: string[], index: number): string[] {
  if (!Number.isInteger(index) || index < 0 || index >= list.length) return list
  return list.filter((_, i) => i !== index)
}

// Move one item up (-1) or down (1). An index out of range, or a move past an end, gives the
// same array.
export function moveSlash(list: string[], index: number, by: -1 | 1): string[] {
  const to = index + by
  if (!Number.isInteger(index) || index < 0 || index >= list.length) return list
  if (to < 0 || to >= list.length) return list
  const next = [...list]
  const item = next[index] as string
  next[index] = next[to] as string
  next[to] = item
  return next
}
