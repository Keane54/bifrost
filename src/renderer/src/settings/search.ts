// The search of the Settings panel (spec 12). This module is pure.
// The search finds the rows of all sections by their label. In Keys, it also finds a row by its
// key, in the shown form (for example "⇧ ⌘ T") or in a typed form (for example "cmd shift t").
import { parseBinding } from '../../../shared/keys'
import { GENERAL_ROWS } from './general-rows'
import type { KeyRow } from './key-editor'
import { REVIEWS_ROWS } from './reviews-rows'
import type { SettingsSection } from './settings-nav'
import { UPDATES_ROWS } from './updates-rows'

// The titles of the sections, in the order of the tabs.
export const SECTION_TITLES: Readonly<Record<SettingsSection, string>> = {
  general: 'General',
  keys: 'Keys',
  live: 'Live details',
  reviews: 'Reviews',
  skills: 'Skills',
  slash: 'Slash commands',
  updates: 'Updates',
}
const SECTION_ORDER: readonly SettingsSection[] = [
  'general',
  'slash',
  'keys',
  'reviews',
  'live',
  'skills',
  'updates',
]

// The labels of the rows of Settings > General. GENERAL_ROWS is their one source.
export const GENERAL_LABELS: readonly string[] = Object.values(GENERAL_ROWS)

// One row that the search can find. The ID is the label of a General row, the slash command, the
// slot ID of a key, the label of a Reviews row, or "live" for Live details.
export interface SearchRow {
  id: string
  text: string
  // The binding of a key row, or null for a key row with no key.
  binding?: string | null
}

export interface SearchSection {
  id: SettingsSection
  title: string
  rows: SearchRow[]
}

// The matches of one section. whole is true when the query matches the title of the section.
// Then the section shows all its rows.
export interface SearchHit {
  id: SettingsSection
  title: string
  whole: boolean
  rows: string[]
}

function words(query: string): string[] {
  return query
    .toLowerCase()
    .split(/\s+/)
    .filter(word => word !== '')
}

// True when each word of the query is in the text, case-insensitive, in any order.
export function textMatches(text: string, query: string): boolean {
  const list = words(query)
  const lower = text.toLowerCase()
  return list.length > 0 && list.every(word => lower.includes(word))
}

// The names of the modifiers: the symbol of the key list, then the typed names.
const MODIFIER_NAMES = {
  alt: ['⌥', 'alt', 'opt', 'option'],
  ctrl: ['⌃', '^', 'ctrl', 'control'],
  mod: ['⌘', 'cmd', 'command', 'mod', 'meta'],
  shift: ['⇧', 'shift'],
} as const

// The names of the named keys: the symbols, then the typed names. Another key is its own name.
const KEY_NAMES: Readonly<Record<string, readonly string[]>> = {
  ArrowDown: ['↓', 'down', 'arrowdown'],
  ArrowLeft: ['←', 'left', 'arrowleft'],
  ArrowRight: ['→', 'right', 'arrowright'],
  ArrowUp: ['↑', 'up', 'arrowup'],
  Backspace: ['⌫', 'backspace', 'delete'],
  Delete: ['⌦', 'delete', 'del', 'forwarddelete'],
  End: ['↘', 'end'],
  Enter: ['↵', '↩', 'enter', 'return'],
  Escape: ['⎋', 'esc', 'escape'],
  Home: ['↖', 'home'],
  PageDown: ['⇟', 'pagedown', 'pgdn'],
  PageUp: ['⇞', 'pageup', 'pgup'],
  Space: ['␣', 'space'],
  Tab: ['⇥', 'tab'],
}

// The symbols that a query can write with no space between them, for example "⌘⇧T". The caret
// ^ is a typed form of ⌃ (Ctrl).
const SYMBOLS = /([⌘⇧⌃^⌥↑↓←→↵↩⌫⌦⇥␣⎋↖↘⇞⇟])/g

// The parts of a key query: "cmd+shift+t", "cmd shift t" and "⌘⇧T" all give cmd, shift and t.
function keyParts(query: string): string[] {
  return query
    .toLowerCase()
    .replace(/\+/g, ' ')
    .replace(SYMBOLS, ' $1 ')
    .split(/\s+/)
    .filter(Boolean)
}

// The names of each part of a binding.
function bindingNames(binding: string): (readonly string[])[] | null {
  const chord = parseBinding(binding)
  if (!chord) return null
  const names: (readonly string[])[] = []
  if (chord.mod) names.push(MODIFIER_NAMES.mod)
  if (chord.ctrl) names.push(MODIFIER_NAMES.ctrl)
  if (chord.alt) names.push(MODIFIER_NAMES.alt)
  if (chord.shift) names.push(MODIFIER_NAMES.shift)
  names.push(KEY_NAMES[chord.key] ?? [chord.key.toLowerCase()])
  return names
}

// True when the part of a query names a part of a binding. A part of one character must be a
// name, for example "t" is only the key T. A longer part can be the start of a name, for example
// "sh" for Shift or "ta" for Tab.
function namesPart(names: (readonly string[])[], part: string): boolean {
  return names.some(list =>
    list.some(name => (part.length === 1 ? name === part : name.startsWith(part))),
  )
}

// True when each part of the query names a part of the binding.
export function keyMatches(binding: string | null | undefined, query: string): boolean {
  if (binding === null || binding === undefined) return false
  const parts = keyParts(query)
  const names = bindingNames(binding)
  if (parts.length === 0 || names === null) return false
  return parts.every(part => namesPart(names, part))
}

// True when the row matches the query (review Minor 4). Each word of the label can match, as in
// textMatches. Or each part of the query matches the title of the section, the label or a part of
// the key. In such a mix, a part of one character must be a key name, so "cmd shift t" stays an
// exact key search.
function rowMatches(row: SearchRow, title: string, query: string): boolean {
  if (textMatches(row.text, query)) return true
  const parts = keyParts(query)
  if (parts.length === 0) return false
  const text = row.text.toLowerCase()
  const head = title.toLowerCase()
  const names = row.binding ? bindingNames(row.binding) : null
  return parts.every(
    part =>
      (part.length > 1 && (text.includes(part) || head.includes(part))) ||
      (names !== null && namesPart(names, part)),
  )
}

// The rows of all sections, in the order of the tabs.
export function settingsIndex(input: {
  slash: readonly string[]
  keys: readonly { rows: readonly KeyRow[] }[]
  // The words of Live details: its title, its state line and the labels of its buttons.
  live: readonly string[]
  // The words of the skills: the title, 'plugin', the state line, the buttons and the names.
  skills: readonly string[]
}): SearchSection[] {
  const rows: Record<SettingsSection, SearchRow[]> = {
    general: GENERAL_LABELS.map(label => ({ id: label, text: label })),
    keys: input.keys.flatMap(group =>
      group.rows.map(row => ({ binding: row.binding, id: row.slot.id, text: row.label })),
    ),
    live: [{ id: 'live', text: input.live.join(' ') }],
    reviews: Object.values(REVIEWS_ROWS).map(label => ({ id: label, text: label })),
    skills: [{ id: 'skills', text: input.skills.join(' ') }],
    slash: input.slash.map(command => ({ id: command, text: command })),
    updates: Object.values(UPDATES_ROWS).map(label => ({ id: label, text: label })),
  }
  return SECTION_ORDER.map(id => ({ id, rows: rows[id], title: SECTION_TITLES[id] }))
}

// The matches of a query, by section. null for an empty query: then the tabs show. A section
// with no match is not in the list.
export function searchSettings(
  query: string,
  sections: readonly SearchSection[],
): SearchHit[] | null {
  if (words(query).length === 0) return null
  const hits: SearchHit[] = []
  for (const section of sections) {
    const whole = textMatches(section.title, query)
    const rows = section.rows
      .filter(row => whole || rowMatches(row, section.title, query))
      .map(row => row.id)
    if (whole || rows.length > 0) hits.push({ id: section.id, rows, title: section.title, whole })
  }
  return hits
}

// The line when nothing matches.
export function noMatchText(query: string): string {
  return `No settings match "${query.trim()}".`
}

// The text of the live line for a screen reader (review Minor 5): the number of matching rows, or
// the no-match line. With no search, the line is empty.
export function resultCountText(hits: readonly SearchHit[] | null, query: string): string {
  if (hits === null) return ''
  if (hits.length === 0) return noMatchText(query)
  const count = hits.reduce((sum, hit) => sum + hit.rows.length, 0)
  return count === 1 ? '1 setting matches.' : `${count} settings match.`
}

// Esc in the search field clears the query first. In an empty field, Esc closes Settings, as the
// Esc key does outside a text field (spec 9.4). During an IME composition, Esc only cancels the
// composition (review Minor 2).
export function searchEscape(value: string, composing: boolean): 'clear' | 'close' | 'ignore' {
  if (composing) return 'ignore'
  return value === '' ? 'close' : 'clear'
}

// True when the last focused element of the results went away and the focus is nowhere: a
// change of a setting can remove a result (review Minor 6). Then the focus needs a new place.
export function focusLost(
  last: { isConnected: boolean } | null,
  active: unknown,
  body: unknown,
): boolean {
  return last !== null && !last.isConnected && (active === null || active === body)
}

// True for Cmd+F with no other modifier, while Settings has the focus. With no focus at all,
// Settings must be the front panel.
export function searchShortcut(
  event: { key: string; metaKey: boolean; ctrlKey: boolean; altKey: boolean; shiftKey: boolean },
  focus: 'settings' | 'none' | 'other',
  settingsOnTop: boolean,
): boolean {
  if (!event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return false
  if (event.key.toLowerCase() !== 'f') return false
  return focus === 'settings' || (focus === 'none' && settingsOnTop)
}
