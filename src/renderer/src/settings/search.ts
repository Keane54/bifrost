// The search of the Settings panel (spec 12). This module is pure.
// The search finds the rows of all sections by their label. In Keys, it also finds a row by its
// key, in the shown form (for example "⇧ ⌘ T") or in a typed form (for example "cmd shift t").
import { parseBinding } from '../../../shared/keys'
import type { KeyRow } from './key-editor'
import type { SettingsSection } from './settings-nav'

// The titles of the sections, in the order of the tabs.
export const SECTION_TITLES: Readonly<Record<SettingsSection, string>> = {
  general: 'General',
  keys: 'Keys',
  live: 'Live details',
  slash: 'Slash commands',
}
const SECTION_ORDER: readonly SettingsSection[] = ['general', 'slash', 'keys', 'live']

// The label of each row of Settings > General, in order. A test checks this list against the
// source of the section. Add the label of a new row here, or the search cannot find the row.
export const GENERAL_LABELS: readonly string[] = [
  'Labels',
  'Terminal app',
  'Default app for "Open project"',
  'Escalation time',
  'Row flash',
  'macOS notification',
  'Sound for a red box',
  'Start at login',
  'Poll interval',
  'Snap distance',
  'Panel transparency',
  'Interface scale',
  'Terminal font',
  'Display mode',
  'Introduction',
]

// One row that the search can find. The ID is the label of a General row, the slash command, the
// slot ID of a key, or "live" for Live details.
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
  ctrl: ['⌃', 'ctrl', 'control'],
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

// The symbols that a query can write with no space between them, for example "⌘⇧T".
const SYMBOLS = /([⌘⇧⌃⌥↑↓←→↵↩⌫⌦⇥␣⎋↖↘⇞⇟])/g

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

// True when each part of the query names a part of the binding. A part of one character must be
// a name, for example "t" is only the key T. A longer part can be the start of a name, for
// example "sh" for Shift or "ta" for Tab.
export function keyMatches(binding: string | null | undefined, query: string): boolean {
  if (binding === null || binding === undefined) return false
  const parts = keyParts(query)
  const names = bindingNames(binding)
  if (parts.length === 0 || names === null) return false
  return parts.every(part =>
    names.some(list =>
      list.some(name => (part.length === 1 ? name === part : name.startsWith(part))),
    ),
  )
}

function rowMatches(row: SearchRow, query: string): boolean {
  return textMatches(row.text, query) || keyMatches(row.binding, query)
}

// The rows of all sections, in the order of the tabs.
export function settingsIndex(input: {
  slash: readonly string[]
  keys: readonly { rows: readonly KeyRow[] }[]
  // The words of Live details: its title, its state line and the labels of its buttons.
  live: readonly string[]
}): SearchSection[] {
  const rows: Record<SettingsSection, SearchRow[]> = {
    general: GENERAL_LABELS.map(label => ({ id: label, text: label })),
    keys: input.keys.flatMap(group =>
      group.rows.map(row => ({ binding: row.binding, id: row.slot.id, text: row.label })),
    ),
    live: [{ id: 'live', text: input.live.join(' ') }],
    slash: input.slash.map(command => ({ id: command, text: command })),
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
    const rows = section.rows.filter(row => whole || rowMatches(row, query)).map(row => row.id)
    if (whole || rows.length > 0) hits.push({ id: section.id, rows, title: section.title, whole })
  }
  return hits
}

// The line when nothing matches.
export function noMatchText(query: string): string {
  return `No settings match "${query.trim()}".`
}

// Esc in the search field clears the query first. In an empty field, Esc closes Settings, as the
// Esc key does outside a text field (spec 9.4).
export function searchEscape(value: string): 'clear' | 'close' {
  return value === '' ? 'close' : 'clear'
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
