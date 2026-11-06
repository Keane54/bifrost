import { describe, expect, test } from 'vitest'
import {
  activeBindings,
  type CustomKeys,
  canonicalBinding,
  checkBinding,
  effectiveKeys,
  type FocusZone,
  KEY_SLOTS,
  type KeyMap,
  keyAllowed,
  keyConflicts,
  parseBinding,
  parseCustomKeys,
  REASON_BAD_KEY,
  REASON_HOLD_FORM,
  REASON_MAC_KEEPS,
  REASON_MENU_KEEPS,
  recordedToBinding,
  reservedReason,
  resetSlotKey,
  setSlotKey,
  slotById,
  toAccelerator,
} from '../../src/shared/keys'

const ZONES: FocusZone[] = ['chat', 'send-box', 'text', 'control', 'modal', 'other']

function allowedZones(slotId: string, binding: string): FocusZone[] {
  const slot = slotById(slotId)
  if (!slot) throw new Error(`no slot ${slotId}`)
  return ZONES.filter(zone => keyAllowed(slot, binding, zone))
}

test('KEY_SLOTS has the 83 slots of spec 9.4 with unique IDs', () => {
  expect(KEY_SLOTS).toHaveLength(83)
  expect(new Set(KEY_SLOTS.map(slot => slot.id)).size).toBe(83)
  expect(KEY_SLOTS.filter(slot => slot.group === 'always')).toHaveLength(49)
  expect(KEY_SLOTS.filter(slot => slot.group === 'single')).toHaveLength(24)
  expect(KEY_SLOTS.filter(slot => slot.group === 'hold')).toHaveLength(10)
  expect(
    KEY_SLOTS.filter(slot => slot.menu)
      .map(slot => slot.id)
      .sort(),
  ).toEqual(['close-panel:mod', 'toggle-fullscreen:mod'])
})

test('KEY_SLOTS keeps the order and the defaults of spec 9.4', () => {
  const ids = KEY_SLOTS.map(slot => slot.id)
  expect(ids[0]).toBe('new-session:mod')
  expect(ids[1]).toBe('select-row.1:mod')
  expect(ids[9]).toBe('select-row.9:mod')
  expect(ids[48]).toBe('toggle-fullscreen:mod')
  expect(ids[49]).toBe('select-prev:key')
  expect(ids[72]).toBe('escape:key')
  expect(ids[73]).toBe('open:hold')
  expect(ids[82]).toBe('set-priority.5:hold')
  expect(slotById('select-row.3:mod')).toMatchObject({
    arg: 3,
    command: 'select-row',
    default: 'Mod+3',
  })
  expect(slotById('set-priority.0:mod')).toMatchObject({ arg: 0, default: 'Mod+Control+0' })
  expect(slotById('set-priority.4:hold')).toMatchObject({ default: '4', group: 'hold' })
  expect(slotById('load-layout.9:mod')?.default).toBe('Mod+Alt+9')
  expect(slotById('open:key2')?.default).toBe('Enter')
  expect(slotById('delete:mod')?.default).toBe('Mod+Alt+Shift+Backspace')
  expect(slotById('nope:mod')).toBeUndefined()
})

test('the default map has no conflict and no reserved key', () => {
  expect(keyConflicts(effectiveKeys({}))).toEqual([])
  for (const slot of KEY_SLOTS) {
    expect(reservedReason(slot.default)).toBeNull()
    expect(canonicalBinding(slot.default)).toBe(slot.default)
  }
})

test('canonicalBinding orders the modifiers and reads the aliases', () => {
  expect(canonicalBinding('shift+cmd+m')).toBe('Mod+Shift+M')
  expect(canonicalBinding('Ctrl+Cmd+1')).toBe('Mod+Control+1')
  expect(canonicalBinding('Option+Cmd+Shift+Backspace')).toBe('Mod+Alt+Shift+Backspace')
  expect(canonicalBinding('esc')).toBe('Escape')
  expect(canonicalBinding('return')).toBe('Enter')
  expect(canonicalBinding('meta+up')).toBe('Mod+ArrowUp')
  expect(canonicalBinding('Command+f12')).toBe('Mod+F12')
  expect(canonicalBinding('Mod+\\')).toBe('Mod+\\')
  expect(canonicalBinding('Mod+Shift')).toBeNull()
  expect(canonicalBinding('Mod+A+B')).toBeNull()
  expect(canonicalBinding('Mod+Mod+A')).toBeNull()
  expect(canonicalBinding('Cmd+Mod+A')).toBeNull()
  expect(canonicalBinding('Hyper+A')).toBeNull()
  expect(canonicalBinding('Mod+F13')).toBeNull()
  expect(canonicalBinding('')).toBeNull()
  expect(parseBinding('Mod+Alt+K')).toEqual({
    alt: true,
    ctrl: false,
    key: 'K',
    mod: true,
    shift: false,
  })
})

test('recordedToBinding changes physical codes to key names', () => {
  expect(recordedToBinding('Mod+[KeyS]')).toBe('Mod+S')
  expect(recordedToBinding('Mod+Alt+[Digit1]')).toBe('Mod+Alt+1')
  expect(recordedToBinding('Mod+[Slash]')).toBe('Mod+/')
  expect(recordedToBinding('Mod+[BracketLeft]')).toBe('Mod+[')
  expect(recordedToBinding('Control+[Backquote]')).toBe('Control+`')
  expect(recordedToBinding('Shift+Backspace')).toBe('Shift+Backspace')
  expect(recordedToBinding('Mod+[Foo]')).toBeNull()
})

test('reservedReason refuses the shortcuts of spec 9.7 and of the menus', () => {
  const mac = [
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
  ]
  const menu = [
    'Mod+Z',
    'Mod+Shift+Z',
    'Mod+X',
    'Mod+C',
    'Mod+V',
    'Mod+A',
    'Mod+Alt+H',
    'Mod+=',
    'Mod+-',
  ]
  for (const binding of mac) expect(reservedReason(binding)).toBe(REASON_MAC_KEEPS)
  for (const binding of menu) expect(reservedReason(binding)).toBe(REASON_MENU_KEEPS)
  expect(reservedReason('cmd+q')).toBe(REASON_MAC_KEEPS)
  expect(reservedReason('Mod+N')).toBeNull()
})

describe('checkBinding', () => {
  const keys = effectiveKeys({})

  test('refuses a conflict and names the other slot', () => {
    expect(checkBinding('new-session:mod', 'Mod+L', keys)).toEqual({
      conflict: 'event-log:mod',
      ok: false,
      reason: 'conflict',
    })
  })

  test('accepts the current key of the slot', () => {
    expect(checkBinding('open:mod', 'cmd+enter', keys)).toEqual({ binding: 'Mod+Enter', ok: true })
  })

  test('a hold slot and a single slot can share a key', () => {
    expect(checkBinding('open:hold', 'O', keys)).toEqual({ binding: 'O', ok: true })
    expect(checkBinding('send-message:hold', 'O', keys)).toEqual({
      conflict: 'open:hold',
      ok: false,
      reason: 'conflict',
    })
    expect(checkBinding('send-message:key', 'O', keys)).toEqual({
      conflict: 'open:key',
      ok: false,
      reason: 'conflict',
    })
  })

  test('allows only one letter or one digit in a hold slot', () => {
    for (const binding of ['Shift+O', 'Control+O', 'Mod+O', 'Enter', 'Alt+7', '/']) {
      expect(checkBinding('open:hold', binding, keys)).toEqual({
        ok: false,
        reason: REASON_HOLD_FORM,
      })
    }
    expect(checkBinding('open:hold', '7', keys)).toEqual({ binding: '7', ok: true })
    expect(checkBinding('open:hold', 'k', keys)).toEqual({ binding: 'K', ok: true })
  })

  test('refuses an unknown slot, a bad key and a reserved key', () => {
    expect(checkBinding('nope:mod', 'Mod+K', keys)).toEqual({ ok: false, reason: REASON_BAD_KEY })
    expect(checkBinding('open:mod', 'Mod+Shift', keys)).toEqual({
      ok: false,
      reason: REASON_BAD_KEY,
    })
    expect(checkBinding('open:mod', 'Mod+Q', keys)).toEqual({ ok: false, reason: REASON_MAC_KEEPS })
    expect(checkBinding('open:mod', 'Mod+Z', keys)).toEqual({
      ok: false,
      reason: REASON_MENU_KEEPS,
    })
  })

  test('the slot itself does not count as a conflict, a null key does not conflict', () => {
    const changed: KeyMap = { ...keys, 'event-log:mod': null }
    expect(checkBinding('event-log:mod', 'Mod+L', changed)).toEqual({ binding: 'Mod+L', ok: true })
    expect(checkBinding('new-session:mod', 'Mod+L', changed)).toEqual({
      binding: 'Mod+L',
      ok: true,
    })
  })
})

describe('parseCustomKeys', () => {
  test('keeps known slots with good keys', () => {
    expect(
      parseCustomKeys({
        'copy-id:key': null,
        'foo:mod': 'Mod+J',
        'open:hold': 'Shift+O',
        'open:mod': 'cmd+k',
        'stop:mod': 'Mod+Q',
        x: 5,
      }),
    ).toEqual({ 'copy-id:key': null, 'open:mod': 'Mod+K' })
  })

  test('gives an empty object for data that is not a plain object', () => {
    expect(parseCustomKeys(null)).toEqual({})
    expect(parseCustomKeys([])).toEqual({})
    expect(parseCustomKeys('x')).toEqual({})
    expect(parseCustomKeys(undefined)).toEqual({})
  })

  test('keeps a conflict of the file', () => {
    expect(parseCustomKeys({ 'new-session:mod': 'cmd+l' })).toEqual({ 'new-session:mod': 'Mod+L' })
  })

  test('ignores the prototype key', () => {
    const data = JSON.parse('{"__proto__": "Mod+K", "open:mod": "Mod+K"}')
    const result = parseCustomKeys(data)
    expect(Object.keys(result)).toEqual(['open:mod'])
  })
})

test('effectiveKeys applies the changes and null removes a key', () => {
  const keys = effectiveKeys({ 'open:mod': 'Mod+K', 'stop:mod': null })
  expect(keys['open:mod']).toBe('Mod+K')
  expect(keys['stop:mod']).toBeNull()
  expect(keys['new-session:mod']).toBe('Mod+N')
  expect(Object.keys(keys)).toHaveLength(83)
})

test('setSlotKey removes an entry that equals the default and keeps the object when nothing changes', () => {
  const empty: CustomKeys = {}
  expect(setSlotKey(empty, 'open:mod', 'cmd+enter')).toBe(empty)
  expect(setSlotKey(empty, 'nope:mod', 'Mod+K')).toBe(empty)
  const changed = setSlotKey(empty, 'open:mod', 'Mod+K')
  expect(changed).toEqual({ 'open:mod': 'Mod+K' })
  expect(empty).toEqual({})
  expect(setSlotKey(changed, 'open:mod', 'Mod+K')).toBe(changed)
  expect(setSlotKey(changed, 'open:mod', 'Mod+Enter')).toEqual({})
  expect(setSlotKey(changed, 'stop:mod', null)).toEqual({ 'open:mod': 'Mod+K', 'stop:mod': null })
  expect(resetSlotKey(changed, 'open:mod')).toEqual({})
  expect(resetSlotKey(changed, 'stop:mod')).toBe(changed)
})

test('keyConflicts lists the pairs of one class in slot order', () => {
  const keys = effectiveKeys({ 'event-log:mod': 'Mod+N', 'send-message:hold': 'O' })
  expect(keyConflicts(keys)).toEqual([
    ['new-session:mod', 'event-log:mod'],
    ['open:hold', 'send-message:hold'],
  ])
  expect(keyConflicts(effectiveKeys({ 'open:key': null, 'send-message:key': null }))).toEqual([])
})

test('activeBindings skips the menu slots, null keys and later conflicts', () => {
  const list = activeBindings(effectiveKeys({ 'event-log:mod': 'Mod+N', 'stop:mod': null }))
  const modN = list.filter(entry => entry.binding === 'Mod+N')
  expect(modN.map(entry => entry.slot.id)).toEqual(['new-session:mod'])
  expect(list.some(entry => entry.slot.menu)).toBe(false)
  expect(list.some(entry => entry.slot.id === 'stop:mod')).toBe(false)
  expect(list.some(entry => entry.slot.id === 'event-log:mod')).toBe(false)
  expect(list).toHaveLength(83 - 2 - 1 - 1)
})

test('activeBindings lets a menu slot keep its key against a later slot', () => {
  const list = activeBindings(effectiveKeys({ 'event-log:mod': 'Mod+W' }))
  expect(list.some(entry => entry.slot.id === 'event-log:mod')).toBe(false)
})

test('keyAllowed follows spec 9.3', () => {
  const noModal: FocusZone[] = ['chat', 'send-box', 'text', 'control', 'other']
  expect(allowedZones('new-session:mod', 'Mod+N')).toEqual(noModal)
  expect(allowedZones('copy-id:mod', 'Control+K')).toEqual(['send-box', 'text', 'control', 'other'])
  expect(allowedZones('open:key', 'O')).toEqual(['control', 'other'])
  expect(allowedZones('open:key2', 'Enter')).toEqual(['other'])
  expect(allowedZones('next-overview-tab:key', 'Tab')).toEqual(['other'])
  expect(allowedZones('prev-overview-tab:key', 'Shift+Tab')).toEqual(['other'])
  expect(allowedZones('escape:key', 'Escape')).toEqual(['send-box', 'control', 'other'])
  expect(allowedZones('select-next:key', 'ArrowDown')).toEqual(['control', 'other'])
  expect(allowedZones('delete:key', 'Shift+Backspace')).toEqual(['control', 'other'])
})

test('keyAllowed lets a hold key act only in the other zone (ruling C3)', () => {
  expect(allowedZones('open:hold', 'O')).toEqual(['other'])
  expect(allowedZones('set-priority.3:hold', '3')).toEqual(['other'])
})

test('toAccelerator gives Electron accelerators', () => {
  expect(toAccelerator('Mod+W')).toBe('Cmd+W')
  expect(toAccelerator('Mod+Control+F')).toBe('Cmd+Ctrl+F')
  expect(toAccelerator('Mod+ArrowUp')).toBe('Cmd+Up')
  expect(toAccelerator('Mod+Enter')).toBe('Cmd+Return')
  expect(toAccelerator('Mod+Alt+Shift+Backspace')).toBe('Cmd+Alt+Shift+Backspace')
  expect(toAccelerator('Escape')).toBe('Esc')
  expect(toAccelerator('Mod+ArrowLeft')).toBe('Cmd+Left')
})
