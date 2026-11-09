// Pure edits of the ignore list of Reviews: owner/repo or owner/*.
import { MAX_REVIEWS_IGNORE, REVIEWS_IGNORE_ENTRY } from '../../../shared/settings'

export type AddIgnoreResult = { ok: true; list: string[] } | { ok: false; reason: string }

export const REASON_IGNORE_BAD = 'Use owner/repo or owner/*.'
export const REASON_IGNORE_COPY = 'That repository is already in the list.'
export const REASON_IGNORE_FULL = `You can keep up to ${MAX_REVIEWS_IGNORE} entries.`

// Add the entry to the end of the list, in lower case, as the settings store it. The result has
// the reason when the list refuses it.
export function addIgnore(list: string[], text: string): AddIgnoreResult {
  const entry = text.trim().toLowerCase()
  if (!REVIEWS_IGNORE_ENTRY.test(entry)) return { ok: false, reason: REASON_IGNORE_BAD }
  if (list.includes(entry)) return { ok: false, reason: REASON_IGNORE_COPY }
  if (list.length >= MAX_REVIEWS_IGNORE) return { ok: false, reason: REASON_IGNORE_FULL }
  return { list: [...list, entry], ok: true }
}

// Remove one entry. An index out of range gives the same array.
export function removeIgnore(list: string[], index: number): string[] {
  if (!Number.isInteger(index) || index < 0 || index >= list.length) return list
  return list.filter((_, i) => i !== index)
}
