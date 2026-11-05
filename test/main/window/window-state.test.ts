import { mkdir, mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, test, vi } from 'vitest'
import {
  openWindowStateStore,
  parseWindowState,
  restoreBounds,
} from '../../../src/main/window/window-state'

const FALLBACK = { height: 900, width: 1440 }
const SCREEN = { height: 1000, width: 1600, x: 0, y: 0 }

test('parseWindowState gives the defaults for bad data', () => {
  const defaults = { bounds: null, mode: 'window' }
  expect(parseWindowState(null)).toEqual(defaults)
  expect(parseWindowState('x')).toEqual(defaults)
  expect(parseWindowState({ bounds: { height: 600, width: 100, x: 0, y: 0 }, mode: 'x' })).toEqual(
    defaults,
  )
  expect(parseWindowState({ bounds: { height: 600, width: 800, x: Number.NaN, y: 0 } })).toEqual(
    defaults,
  )
  expect(parseWindowState({ bounds: { height: 299, width: 800, x: 0, y: 0 } }).bounds).toBeNull()
  expect(parseWindowState({ bounds: { height: 300, width: 399, x: 0, y: 0 } }).bounds).toBeNull()
})

test('parseWindowState keeps a good mode and good bounds', () => {
  const bounds = { height: 300, width: 400, x: -20, y: 10 }
  expect(parseWindowState({ bounds, mode: 'borderless' })).toEqual({ bounds, mode: 'borderless' })
  expect(parseWindowState({ mode: 'fullscreen' })).toEqual({ bounds: null, mode: 'fullscreen' })
})

test('restoreBounds keeps bounds whose top edge area is on a screen', () => {
  const saved = { height: 700, width: 900, x: 100, y: 80 }
  expect(restoreBounds(saved, [SCREEN], FALLBACK)).toEqual(saved)
  // Only a 100 x 40 part of the top edge area must be on the screen.
  const mostlyOff = { height: 700, width: 900, x: 1500, y: 960 }
  expect(restoreBounds(mostlyOff, [SCREEN], FALLBACK)).toEqual(mostlyOff)
  // The window can be on a second screen.
  const second = { height: 1000, width: 1600, x: 1600, y: 0 }
  const onSecond = { height: 700, width: 900, x: 1700, y: 50 }
  expect(restoreBounds(onSecond, [SCREEN, second], FALLBACK)).toEqual(onSecond)
})

test('restoreBounds gives only the fallback size for bounds off all screens', () => {
  expect(restoreBounds(null, [SCREEN], FALLBACK)).toEqual(FALLBACK)
  const off = { height: 700, width: 900, x: 3000, y: 80 }
  expect(restoreBounds(off, [SCREEN], FALLBACK)).toEqual(FALLBACK)
  // The top edge area is above the screen.
  const above = { height: 700, width: 900, x: 100, y: -700 }
  expect(restoreBounds(above, [SCREEN], FALLBACK)).toEqual(FALLBACK)
  // Only 50 pixels of the width is on the screen.
  const narrow = { height: 700, width: 900, x: 1550, y: 80 }
  expect(restoreBounds(narrow, [SCREEN], FALLBACK)).toEqual(FALLBACK)
  expect(restoreBounds(off, [], FALLBACK)).toEqual(FALLBACK)
})

test('the store gives the defaults, then saves each change', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'bifrost-window-'))
  try {
    const file = join(dir, 'window-state.json')
    const store = await openWindowStateStore(file)
    expect(store.state).toEqual({ bounds: null, mode: 'window' })
    await store.update({ mode: 'borderless' })
    const bounds = { height: 600, width: 800, x: 10, y: 20 }
    await store.update({ bounds })
    expect(JSON.parse(await readFile(file, 'utf8'))).toEqual({ bounds, mode: 'borderless' })
    expect((await openWindowStateStore(file)).state).toEqual({ bounds, mode: 'borderless' })
  } finally {
    await rm(dir, { force: true, recursive: true })
  }
})

test('the store does not write over a file that it cannot read', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'bifrost-window-'))
  try {
    // A directory in place of the file gives a read error that is not ENOENT.
    const file = join(dir, 'window-state.json')
    await mkdir(file)
    const log = vi.fn()
    const store = await openWindowStateStore(file, log)
    await store.update({ mode: 'fullscreen' })
    expect(log).toHaveBeenCalledOnce()
    expect((await stat(file)).isDirectory()).toBe(true)
  } finally {
    await rm(dir, { force: true, recursive: true })
  }
})
