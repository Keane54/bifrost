// The local name of a session. Bifrost keeps it and never sends it to Claude Code.
import { MAX_RENAME } from './input'

// The characters that a local name cannot hold: C0 with tab and LF, DEL and C1, zero-width
// characters, and the bidi controls. A bidi control could reverse the text after the name.
// biome-ignore lint/suspicious/noControlCharactersInRegex: The regex matches control characters.
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/

export const REASON_ALIAS_CONTROL = "A name can't hold control or hidden characters."
export const REASON_ALIAS_LONG = `The name is too long. The maximum is ${MAX_RENAME} characters.`

// Trim the name. Refuse control characters and a name longer than MAX_RENAME.
// An empty name is valid. It means "no local name".
export function cleanAlias(
  text: string,
): { ok: true; name: string } | { ok: false; reason: string } {
  const name = text.trim()
  if (CONTROL.test(name)) return { ok: false, reason: REASON_ALIAS_CONTROL }
  if (name.length > MAX_RENAME) return { ok: false, reason: REASON_ALIAS_LONG }
  return { name, ok: true }
}

// Check the input of the set-alias request from the page.
export function checkAliasRequest(
  sessionId: unknown,
  name: unknown,
): { ok: true; name: string | null } | { ok: false } {
  if (typeof sessionId !== 'string' || sessionId === '') return { ok: false }
  if (name === null) return { name: null, ok: true }
  if (typeof name !== 'string') return { ok: false }
  const result = cleanAlias(name)
  return result.ok ? { name: result.name, ok: true } : { ok: false }
}

// The tooltip of the name in the Selected Item panel.
// A row with a local name gives the Claude Code name. Any other row gives the name itself,
// so a name that the panel cuts off can be read.
export function aliasTip(row: { name: string; claudeName: string }): string {
  return row.name === row.claudeName ? row.name : `Claude Code name: ${row.claudeName}`
}
