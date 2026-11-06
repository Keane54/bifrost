// The key map model. This module imports no library, so the main process uses it too.
// A binding is a chord text with Mod in place of Cmd. Example: "Mod+Shift+M".
import { isPlainObject } from './plain-object'

export type KeyCommandId =
  | 'new-session'
  | 'select-row'
  | 'select-prev'
  | 'select-next'
  | 'focus-overview'
  | 'open'
  | 'send-message'
  | 'run-slash'
  | 'interrupt'
  | 'rename'
  | 'show-info'
  | 'copy-id'
  | 'open-project'
  | 'open-in-terminal'
  | 'take-control'
  | 'resume'
  | 'resume-all'
  | 'set-priority'
  | 'close-panel'
  | 'stop'
  | 'delete'
  | 'prev-stack-tab'
  | 'next-stack-tab'
  | 'next-overview-tab'
  | 'prev-overview-tab'
  | 'load-layout'
  | 'save-layout'
  | 'event-log'
  | 'usage-hud'
  | 'settings'
  | 'toggle-fullscreen'
  | 'escape'

// The three tables of spec 9.4.
export type SlotGroup = 'always' | 'single' | 'hold'

export interface KeySlot {
  id: string
  command: KeyCommandId
  arg?: number
  group: SlotGroup
  default: string
  // True when the Electron menu owns the accelerator. The renderer does not register it.
  menu?: true
}

// Build one slot. The ID has the form <command>[.<arg>]:<variant>.
function slot(
  command: KeyCommandId,
  variant: string,
  group: SlotGroup,
  def: string,
  arg?: number,
  menu?: true,
): KeySlot {
  const id = `${command}${arg === undefined ? '' : `.${arg}`}:${variant}`
  const result: KeySlot = { command, default: def, group, id }
  if (arg !== undefined) result.arg = arg
  if (menu) result.menu = true
  return result
}

function range(
  command: KeyCommandId,
  from: number,
  to: number,
  key: (n: number) => string,
  variant: string,
  group: SlotGroup,
): KeySlot[] {
  const slots: KeySlot[] = []
  for (let n = from; n <= to; n++) slots.push(slot(command, variant, group, key(n), n))
  return slots
}

function always(command: KeyCommandId, def: string, menu?: true): KeySlot {
  return slot(command, 'mod', 'always', def, undefined, menu)
}

function single(command: KeyCommandId, def: string, variant = 'key'): KeySlot {
  return slot(command, variant, 'single', def)
}

function hold(command: KeyCommandId, def: string): KeySlot {
  return slot(command, 'hold', 'hold', def)
}

// The 83 key slots of spec 9.4, in the order of the spec.
export const KEY_SLOTS: readonly KeySlot[] = [
  // Always (49).
  always('new-session', 'Mod+N'),
  ...range('select-row', 1, 9, n => `Mod+${n}`, 'mod', 'always'),
  always('select-prev', 'Mod+ArrowUp'),
  always('select-next', 'Mod+ArrowDown'),
  always('focus-overview', 'Mod+0'),
  always('open', 'Mod+Enter'),
  always('send-message', 'Mod+Shift+M'),
  always('run-slash', 'Mod+/'),
  always('interrupt', 'Mod+.'),
  always('show-info', 'Mod+I'),
  always('copy-id', 'Mod+Shift+C'),
  always('open-project', 'Mod+Shift+O'),
  always('open-in-terminal', 'Mod+Shift+J'),
  always('take-control', 'Mod+Shift+T'),
  always('resume', 'Mod+R'),
  always('resume-all', 'Mod+Shift+R'),
  ...range('set-priority', 1, 5, n => `Mod+Control+${n}`, 'mod', 'always'),
  slot('set-priority', 'mod', 'always', 'Mod+Control+0', 0),
  always('close-panel', 'Mod+W', true),
  always('stop', 'Mod+Shift+Backspace'),
  always('delete', 'Mod+Alt+Shift+Backspace'),
  always('prev-stack-tab', 'Mod+['),
  always('next-stack-tab', 'Mod+]'),
  ...range('load-layout', 1, 9, n => `Mod+Alt+${n}`, 'mod', 'always'),
  always('save-layout', 'Mod+Alt+S'),
  always('event-log', 'Mod+L'),
  always('usage-hud', 'Mod+U'),
  always('settings', 'Mod+,'),
  always('toggle-fullscreen', 'Mod+Control+F', true),
  // Single (24).
  single('select-prev', 'ArrowUp'),
  single('select-next', 'ArrowDown'),
  single('next-overview-tab', 'Tab'),
  single('prev-overview-tab', 'Shift+Tab'),
  single('open', 'O'),
  single('open', 'Enter', 'key2'),
  single('send-message', 'M'),
  single('run-slash', '/'),
  single('interrupt', 'X'),
  single('show-info', 'I'),
  single('open-in-terminal', 'J'),
  single('open-project', 'P'),
  single('copy-id', 'C'),
  single('rename', 'R'),
  single('take-control', 'T'),
  ...range('set-priority', 1, 5, n => `${n}`, 'key', 'single'),
  slot('set-priority', 'key', 'single', '0', 0),
  single('stop', 'Backspace'),
  single('delete', 'Shift+Backspace'),
  single('escape', 'Escape'),
  // Hold (10).
  hold('open', 'O'),
  hold('send-message', 'M'),
  hold('show-info', 'I'),
  hold('open-in-terminal', 'J'),
  hold('interrupt', 'X'),
  ...range('set-priority', 1, 5, n => `${n}`, 'hold', 'hold'),
]

const SLOT_MAP: ReadonlyMap<string, KeySlot> = new Map(KEY_SLOTS.map(item => [item.id, item]))

// Return the slot with this ID, or undefined.
export function slotById(id: string): KeySlot | undefined {
  return SLOT_MAP.get(id)
}

// The changed slots only. A string is a binding. null means no key.
export type CustomKeys = Record<string, string | null>
// All slots with their binding.
export type KeyMap = Record<string, string | null>

export interface Chord {
  mod: boolean
  ctrl: boolean
  alt: boolean
  shift: boolean
  key: string
}

const MODIFIERS: Readonly<Record<string, 'mod' | 'ctrl' | 'alt' | 'shift'>> = {
  alt: 'alt',
  cmd: 'mod',
  command: 'mod',
  control: 'ctrl',
  ctrl: 'ctrl',
  meta: 'mod',
  mod: 'mod',
  option: 'alt',
  shift: 'shift',
}

const NAMED_KEYS: readonly string[] = [
  'ArrowUp',
  'ArrowDown',
  'ArrowLeft',
  'ArrowRight',
  'Enter',
  'Escape',
  'Tab',
  'Backspace',
  'Delete',
  'Space',
  'Home',
  'End',
  'PageUp',
  'PageDown',
  ...Array.from({ length: 12 }, (_, index) => `F${index + 1}`),
]

const KEY_BY_LOWER: ReadonlyMap<string, string> = new Map([
  ...NAMED_KEYS.map(name => [name.toLowerCase(), name] as [string, string]),
  ['esc', 'Escape'],
  ['return', 'Enter'],
  ['up', 'ArrowUp'],
  ['down', 'ArrowDown'],
  ['left', 'ArrowLeft'],
  ['right', 'ArrowRight'],
])

const PUNCTUATION = "/.,[];'`-=\\"

// Read one key token. Return the key name, or null.
function parseKeyToken(token: string): string | null {
  if (token.length === 1) {
    if (/^[a-z]$/i.test(token)) return token.toUpperCase()
    if (/^[0-9]$/.test(token)) return token
    return PUNCTUATION.includes(token) ? token : null
  }
  return KEY_BY_LOWER.get(token.toLowerCase()) ?? null
}

// Read a binding text. Return null when the text is not a binding.
export function parseBinding(text: string): Chord | null {
  if (typeof text !== 'string' || text === '') return null
  const chord: Chord = { alt: false, ctrl: false, key: '', mod: false, shift: false }
  for (const token of text.split('+')) {
    const lower = token.toLowerCase()
    if (Object.hasOwn(MODIFIERS, lower)) {
      const modifier = MODIFIERS[lower]
      if (chord[modifier]) return null
      chord[modifier] = true
      continue
    }
    const key = parseKeyToken(token)
    if (key === null || chord.key !== '') return null
    chord.key = key
  }
  return chord.key === '' ? null : chord
}

// Write a chord in the standard form: Mod, Control, Alt, Shift, then the key.
export function formatBinding(chord: Chord): string {
  const parts: string[] = []
  if (chord.mod) parts.push('Mod')
  if (chord.ctrl) parts.push('Control')
  if (chord.alt) parts.push('Alt')
  if (chord.shift) parts.push('Shift')
  parts.push(chord.key)
  return parts.join('+')
}

// Return the standard form of a binding text, or null.
export function canonicalBinding(text: string): string | null {
  const chord = parseBinding(text)
  return chord ? formatBinding(chord) : null
}

const CODE_CHARS: Readonly<Record<string, string>> = {
  Backquote: '`',
  Backslash: '\\',
  BracketLeft: '[',
  BracketRight: ']',
  Comma: ',',
  Equal: '=',
  Minus: '-',
  Period: '.',
  Quote: "'",
  Semicolon: ';',
  Slash: '/',
}

// Change a recorded text with physical codes, like "Mod+[KeyS]", to a binding.
export function recordedToBinding(recorded: string): string | null {
  const tokens = recorded.split('+').map(token => {
    const match = /^\[(.+)\]$/.exec(token)
    if (!match) return token
    const code = match[1]
    if (/^Key[A-Z]$/.test(code)) return code.slice(3)
    if (/^Digit[0-9]$/.test(code)) return code.slice(5)
    return Object.hasOwn(CODE_CHARS, code) ? CODE_CHARS[code] : token
  })
  return canonicalBinding(tokens.join('+'))
}

// Return the map of all slots. A key in `custom` replaces the default (null means no key).
export function effectiveKeys(custom: CustomKeys): KeyMap {
  const keys: KeyMap = {}
  for (const item of KEY_SLOTS) {
    keys[item.id] = Object.hasOwn(custom, item.id) ? custom[item.id] : item.default
  }
  return keys
}

export const REASON_MAC_KEEPS = 'macOS keeps this shortcut for itself.'
export const REASON_MENU_KEEPS = 'A Bifrost menu already uses this shortcut.'
export const REASON_HOLD_FORM =
  'A hold key must be a single letter or number, without Cmd, Ctrl, Option or Shift.'
export const REASON_BAD_KEY = "Bifrost can't use this key."
// The menu gets the key of a menu slot. A key without Cmd would act in a chat window and in a text
// box, against spec 9.3. So a menu slot needs Mod (final review Important 3).
export const REASON_MENU_NEEDS_MOD = 'A menu shortcut needs Cmd.'

// Shortcuts of macOS (spec 9.7).
const MAC_KEEPS: ReadonlySet<string> = new Set([
  'Mod+Tab',
  'Mod+Space',
  'Mod+H',
  'Mod+M',
  'Mod+Q',
  'Mod+Alt+Escape',
  'Mod+Shift+3',
  'Mod+Shift+4',
  'Mod+Shift+5',
  'Mod+Shift+Q',
  'Mod+Shift+/',
  'Mod+Control+Q',
  'Control+Space',
])

// Shortcuts of the Edit menu, the app menu and the Zoom items of the View menu.
const MENU_KEEPS: ReadonlySet<string> = new Set([
  'Mod+Z',
  'Mod+Shift+Z',
  'Mod+X',
  'Mod+C',
  'Mod+V',
  'Mod+A',
  'Mod+Alt+H',
  'Mod+=',
  'Mod+-',
])

// Return the reason when macOS or a Bifrost menu keeps this binding, else null.
export function reservedReason(binding: string): string | null {
  const canonical = canonicalBinding(binding)
  if (canonical === null) return null
  if (MAC_KEEPS.has(canonical)) return REASON_MAC_KEEPS
  if (MENU_KEEPS.has(canonical)) return REASON_MENU_KEEPS
  return null
}

export type BindingCheck =
  | { ok: true; binding: string }
  | { ok: false; reason: string; conflict?: string }

// The two classes of slots. A hold slot and another slot can share a key.
function isHold(item: KeySlot): boolean {
  return item.group === 'hold'
}

// Return the ID of the first other slot of the same class that has this binding, or undefined.
function findConflict(item: KeySlot, binding: string, keys: KeyMap): string | undefined {
  for (const other of KEY_SLOTS) {
    if (other.id === item.id || isHold(other) !== isHold(item)) continue
    const value = keys[other.id]
    if (typeof value === 'string' && canonicalBinding(value) === binding) return other.id
  }
  return undefined
}

// Check a new binding for a slot. The first failure gives the result.
export function checkBinding(slotId: string, binding: string, keys: KeyMap): BindingCheck {
  const item = slotById(slotId)
  const chord = item ? parseBinding(binding) : null
  if (!item || !chord) return { ok: false, reason: REASON_BAD_KEY }
  const canonical = formatBinding(chord)
  if (isHold(item)) {
    const plain = !chord.mod && !chord.ctrl && !chord.alt && !chord.shift
    if (!plain || !/^[A-Z0-9]$/.test(chord.key)) return { ok: false, reason: REASON_HOLD_FORM }
  } else if (item.menu && !chord.mod) {
    return { ok: false, reason: REASON_MENU_NEEDS_MOD }
  } else {
    const reason = reservedReason(canonical)
    if (reason) return { ok: false, reason }
  }
  const conflict = findConflict(item, canonical, keys)
  if (conflict) return { conflict, ok: false, reason: 'conflict' }
  return { binding: canonical, ok: true }
}

// Read the changed slots from stored data. A bad entry goes away. A conflict stays.
export function parseCustomKeys(data: unknown): CustomKeys {
  if (!isPlainObject(data)) return {}
  const defaults = effectiveKeys({})
  const custom: CustomKeys = {}
  for (const item of KEY_SLOTS) {
    if (!Object.hasOwn(data, item.id)) continue
    const value = data[item.id]
    if (value === null) {
      custom[item.id] = null
    } else if (typeof value === 'string') {
      const check = checkBinding(item.id, value, defaults)
      if (check.ok) custom[item.id] = check.binding
      else if (check.reason === 'conflict') custom[item.id] = canonicalBinding(value)
    }
  }
  return custom
}

// Set the binding of a slot. A binding that equals the default removes the entry.
// Return the same object when nothing changes, also for a text that is not a binding.
export function setSlotKey(custom: CustomKeys, slotId: string, binding: string | null): CustomKeys {
  const item = slotById(slotId)
  if (!item) return custom
  const value = binding === null ? null : canonicalBinding(binding)
  // A text that is not a binding changes nothing.
  if (binding !== null && value === null) return custom
  if (value === item.default) return resetSlotKey(custom, slotId)
  if (Object.hasOwn(custom, slotId) && custom[slotId] === value) return custom
  return { ...custom, [slotId]: value }
}

// Remove the change of a slot. Return the same object when the slot has no change.
export function resetSlotKey(custom: CustomKeys, slotId: string): CustomKeys {
  if (!Object.hasOwn(custom, slotId)) return custom
  const { [slotId]: _removed, ...rest } = custom
  return rest
}

// Return each pair [a, b] of slots of one class with the same binding. a comes before b.
export function keyConflicts(keys: KeyMap): Array<[string, string]> {
  const pairs: Array<[string, string]> = []
  const bound = KEY_SLOTS.flatMap(item => {
    const value = keys[item.id]
    const binding = typeof value === 'string' ? canonicalBinding(value) : null
    return binding === null ? [] : [{ binding, item }]
  })
  for (let i = 0; i < bound.length; i++) {
    for (let j = i + 1; j < bound.length; j++) {
      if (
        bound[i].binding === bound[j].binding &&
        isHold(bound[i].item) === isHold(bound[j].item)
      ) {
        pairs.push([bound[i].item.id, bound[j].item.id])
      }
    }
  }
  return pairs
}

// Return the bindings that the renderer registers. Menu slots and null keys are not in the list.
// When two slots of one class have a binding, the first slot in KEY_SLOTS order keeps it.
// A menu slot also keeps its binding, because Electron gives the key to the menu first.
export function activeBindings(keys: KeyMap): Array<{ slot: KeySlot; binding: string }> {
  const taken = new Set<string>()
  const list: Array<{ slot: KeySlot; binding: string }> = []
  for (const item of KEY_SLOTS) {
    const value = keys[item.id]
    const binding = typeof value === 'string' ? canonicalBinding(value) : null
    if (binding === null) continue
    const token = `${isHold(item) ? 'hold' : 'key'}:${binding}`
    if (taken.has(token)) continue
    taken.add(token)
    if (!item.menu) list.push({ binding, slot: item })
  }
  return list
}

// The place of the focus (spec 9.3, D6).
export type FocusZone = 'chat' | 'send-box' | 'text' | 'control' | 'modal' | 'other'

// The keys that a control keeps: Enter, Space and Tab (D27), and the keys that move in a tab list,
// a radio group, a select or a menu.
const CONTROL_KEYS: ReadonlySet<string> = new Set([
  'Enter',
  'Space',
  'Tab',
  'ArrowUp',
  'ArrowDown',
  'ArrowLeft',
  'ArrowRight',
  'Home',
  'End',
])

// Return true when a binding may act while the focus is in this zone.
export function keyAllowed(item: KeySlot, binding: string, zone: FocusZone): boolean {
  if (zone === 'modal') return false
  // A hold key acts only in the other zone (ruling C3, D8).
  if (isHold(item)) return zone === 'other'
  const chord = parseBinding(binding)
  if (!chord) return false
  if (chord.mod) return true
  if (item.command === 'escape')
    return zone === 'other' || zone === 'control' || zone === 'send-box'
  if (chord.ctrl) return zone !== 'chat'
  if (zone === 'other') return true
  // Enter, Space, Tab, the arrow keys, Home and End stay with a control (D27).
  return zone === 'control' && !CONTROL_KEYS.has(chord.key)
}

const ACCELERATOR_KEYS: Readonly<Record<string, string>> = {
  ArrowDown: 'Down',
  ArrowLeft: 'Left',
  ArrowRight: 'Right',
  ArrowUp: 'Up',
  Enter: 'Return',
  Escape: 'Esc',
}

// Change a binding to an Electron accelerator.
export function toAccelerator(binding: string): string {
  const chord = parseBinding(binding)
  if (!chord) return binding
  const parts: string[] = []
  if (chord.mod) parts.push('Cmd')
  if (chord.ctrl) parts.push('Ctrl')
  if (chord.alt) parts.push('Alt')
  if (chord.shift) parts.push('Shift')
  parts.push(Object.hasOwn(ACCELERATOR_KEYS, chord.key) ? ACCELERATOR_KEYS[chord.key] : chord.key)
  return parts.join('+')
}
