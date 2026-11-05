import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { MAX_UI_BYTES, openUiStore } from '../../../src/main/store/ui-store'

let dir: string
beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'bifrost-ui-'))
})
afterEach(async () => {
  await rm(dir, { force: true, recursive: true })
})

test('openUiStore gives null data and a working save for a missing file', async () => {
  const file = join(dir, 'ui-state.json')
  const opened = await openUiStore(file)
  expect(opened.load()).toBeNull()
  await opened.save({ version: 1 })
  expect(JSON.parse(await readFile(file, 'utf8'))).toEqual({ version: 1 })
})

test('openUiStore gives null data and a working save for bad JSON', async () => {
  const file = join(dir, 'ui-state.json')
  await writeFile(file, '{ no')
  const opened = await openUiStore(file)
  expect(opened.load()).toBeNull()
  await opened.save({ version: 1 })
  expect(JSON.parse(await readFile(file, 'utf8'))).toEqual({ version: 1 })
})

test('openUiStore gives the data of a good file', async () => {
  const file = join(dir, 'ui-state.json')
  await writeFile(file, '{"version":1,"x":2}')
  expect((await openUiStore(file)).load()).toEqual({ version: 1, x: 2 })
})

test('openUiStore turns saving off after a read error', async () => {
  const log = vi.fn()
  const opened = await openUiStore(dir, log)
  expect(opened.load()).toBeNull()
  expect(log).toHaveBeenCalledOnce()
  await opened.save({ version: 1 })
  await expect(readFile(join(dir, 'ui-state.json'), 'utf8')).rejects.toThrow()
})

test('save rejects a value that is not a plain object and a value over 1 MB', async () => {
  const file = join(dir, 'ui-state.json')
  const opened = await openUiStore(file)
  for (const bad of [null, [], 'x', 7, undefined, new Map(), new Set(), new Date()]) {
    await expect(opened.save(bad)).rejects.toThrow()
  }
  await expect(opened.save({ big: 'x'.repeat(MAX_UI_BYTES) })).rejects.toThrow()
  await expect(readFile(file, 'utf8')).rejects.toThrow()
})

test('save counts bytes, not characters', async () => {
  const opened = await openUiStore(join(dir, 'ui-state.json'))
  await expect(opened.save({ big: '\u20ac'.repeat(400_000) })).rejects.toThrow()
})

test('load gives the last saved value', async () => {
  const file = join(dir, 'ui-state.json')
  await writeFile(file, '{"version":1,"x":"A"}')
  const opened = await openUiStore(file)
  await opened.save({ version: 1, x: 'B' })
  expect(opened.load()).toEqual({ version: 1, x: 'B' })
})

test('two quick saves write in call order', async () => {
  const file = join(dir, 'ui-state.json')
  const opened = await openUiStore(file)
  await Promise.all([
    opened.save({ n: 1, pad: 'x'.repeat(500_000) }),
    opened.save({ n: 2 }),
    opened.save({ n: 3 }),
  ])
  expect(JSON.parse(await readFile(file, 'utf8'))).toEqual({ n: 3 })
  expect(opened.load()).toEqual({ n: 3 })
})
