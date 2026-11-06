// Change a Bifrost binding to the chord object of TanStack Hotkeys.
import type { RawHotkeyChord } from '@tanstack/react-hotkeys'
import { parseBinding } from '../../../shared/keys'

// Return the chord object of a binding, or null when the text is not a binding.
// The object has only the modifiers that the binding has. The other modifiers are false.
export function toRawChord(binding: string): RawHotkeyChord | null {
  const chord = parseBinding(binding)
  if (!chord) return null
  const raw: RawHotkeyChord = { key: chord.key }
  if (chord.mod) raw.mod = true
  if (chord.ctrl) raw.ctrl = true
  if (chord.alt) raw.alt = true
  if (chord.shift) raw.shift = true
  return raw
}

// The part of a keyup event that releasedHoldKey reads. A test passes a plain object.
export interface ReleasedKey {
  key: string
  code: string
  shiftKey?: boolean
  ctrlKey?: boolean
  altKey?: boolean
  metaKey?: boolean
}

// Return the hold key of a keyup that has a modifier, or null.
// The hotkey of a hold key matches only the key without a modifier. When the user pushes a
// modifier before the release of a hold key, this function finds the key. Then the hold gate
// can forget it. A key that stays in the gate would change the next row click.
export function releasedHoldKey(event: ReleasedKey, holdKeys: ReadonlySet<string>): string | null {
  if (!event.shiftKey && !event.ctrlKey && !event.altKey && !event.metaKey) return null
  let key: string | null = null
  if (/^[a-z0-9]$/i.test(event.key)) key = event.key.toUpperCase()
  else if (/^Key[A-Z]$/.test(event.code)) key = event.code.slice(3)
  else if (/^Digit[0-9]$/.test(event.code)) key = event.code.slice(5)
  return key !== null && holdKeys.has(key) ? key : null
}
