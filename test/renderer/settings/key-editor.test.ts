import { expect, test } from 'vitest'
import { checkRecorded, keyGroups } from '../../../src/renderer/src/settings/key-editor'
import {
  DICTATION_SLOT,
  REASON_BAD_KEY,
  REASON_DICTATION_FORM,
  REASON_HOLD_FORM,
  REASON_MAC_KEEPS,
  REASON_MENU_NEEDS_MOD,
} from '../../../src/shared/keys'

test('keyGroups gives the three groups of spec 9.4 in order, then the dictation group', () => {
  const groups = keyGroups({}, 'plain')
  expect(groups.map(g => g.group)).toEqual(['always', 'single', 'hold', 'dictation'])
  expect(groups.map(g => g.rows.length)).toEqual([49, 24, 10, 1])
  expect(groups[0].rows[0].label).toBe('New session')
  expect(groups[0].rows[0].binding).toBe('Mod+N')
  expect(groups[0].rows[0].changed).toBe(false)
})

test('keyGroups marks a changed row and shows null as no key', () => {
  const rows = keyGroups({ 'copy-id:key': null }, 'plain').flatMap(g => g.rows)
  const row = rows.find(r => r.slot.id === 'copy-id:key')
  expect(row?.binding).toBeNull()
  expect(row?.changed).toBe(true)
  expect(rows.filter(r => r.changed)).toHaveLength(1)
})

test('keyGroups shows the changed binding and uses the label set', () => {
  const rows = keyGroups({ 'open:mod': 'Mod+K' }, 'space').flatMap(g => g.rows)
  expect(rows.find(r => r.slot.id === 'open:mod')?.binding).toBe('Mod+K')
  expect(rows.find(r => r.slot.id === 'open:mod')?.changed).toBe(true)
  expect(rows.find(r => r.slot.id === 'take-control:mod')?.label).toBe('Commandeer')
})

test('checkRecorded changes the physical code and accepts a free key', () => {
  expect(checkRecorded('open:mod', 'Mod+[KeyK]', {}, 'plain')).toEqual({
    binding: 'Mod+K',
    ok: true,
  })
})

test('checkRecorded names the other action of a conflict', () => {
  expect(checkRecorded('open:mod', 'Mod+[KeyL]', {}, 'plain')).toEqual({
    message: 'Event log already uses this key.',
    ok: false,
  })
  expect(checkRecorded('open:mod', 'Mod+Shift+[KeyT]', {}, 'space')).toEqual({
    message: 'Commandeer already uses this key.',
    ok: false,
  })
})

test('checkRecorded sees a conflict with a changed slot, not with the default of it', () => {
  // Event log moved to Mod+K, so Mod+L is free and Mod+K is taken.
  const custom = { 'event-log:mod': 'Mod+K' }
  expect(checkRecorded('open:mod', 'Mod+[KeyL]', custom, 'plain').ok).toBe(true)
  expect(checkRecorded('open:mod', 'Mod+[KeyK]', custom, 'plain')).toEqual({
    message: 'Event log already uses this key.',
    ok: false,
  })
})

test('checkRecorded refuses a key that macOS keeps', () => {
  expect(checkRecorded('open:mod', 'Mod+[KeyQ]', {}, 'plain')).toEqual({
    message: REASON_MAC_KEEPS,
    ok: false,
  })
})

test('checkRecorded refuses a modifier in a hold slot', () => {
  expect(checkRecorded('open:hold', 'Shift+[KeyO]', {}, 'plain')).toEqual({
    message: REASON_HOLD_FORM,
    ok: false,
  })
})

test('checkRecorded refuses a text that is not a key with the bad key reason', () => {
  expect(checkRecorded('open:mod', 'Mod+[Nonsense]', {}, 'plain')).toEqual({
    message: REASON_BAD_KEY,
    ok: false,
  })
})

test('checkRecorded refuses a menu key without Cmd', () => {
  expect(checkRecorded('close-panel:mod', 'Shift+[KeyW]', {}, 'plain')).toEqual({
    message: REASON_MENU_NEEDS_MOD,
    ok: false,
  })
  expect(checkRecorded('close-panel:mod', 'Mod+Shift+[KeyW]', {}, 'plain')).toEqual({
    binding: 'Mod+Shift+W',
    ok: true,
  })
})

test('keyGroups gives the dictation key a heading of its own', () => {
  const dictation = keyGroups({}, 'plain').find(g => g.group === 'dictation')
  expect(dictation?.title).toBe('Hold to dictate in a chat window')
  expect(dictation?.rows.map(r => [r.slot.id, r.label, r.binding])).toEqual([
    [DICTATION_SLOT, 'Dictation key', 'Space'],
  ])
  const off = keyGroups({ [DICTATION_SLOT]: null }, 'plain').find(g => g.group === 'dictation')
  expect(off?.rows[0].binding).toBeNull()
})

test('checkRecorded takes a plain Space for the dictation key only', () => {
  expect(checkRecorded(DICTATION_SLOT, '[Space]', { [DICTATION_SLOT]: null }, 'plain')).toEqual({
    binding: 'Space',
    ok: true,
  })
  expect(checkRecorded(DICTATION_SLOT, '[KeyK]', {}, 'plain')).toEqual({ binding: 'K', ok: true })
  expect(checkRecorded(DICTATION_SLOT, 'Shift+[Space]', {}, 'plain')).toEqual({
    message: REASON_DICTATION_FORM,
    ok: false,
  })
  expect(checkRecorded(DICTATION_SLOT, 'Mod+[Space]', {}, 'plain')).toEqual({
    message: REASON_DICTATION_FORM,
    ok: false,
  })
  // The other slots still refuse Space.
  for (const slotId of ['open:hold', 'copy-id:key', 'open:mod']) {
    expect(checkRecorded(slotId, '[Space]', {}, 'plain')).toEqual({
      message: REASON_BAD_KEY,
      ok: false,
    })
  }
})
