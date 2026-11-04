import { mkdir, mkdtemp, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { loadStore, openStore, saveStore } from '../../../src/main/registry/store-file'

let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'bifrost-store-'))
})

afterEach(async () => {
  await rm(dir, { force: true, recursive: true })
})

test('loadStore returns an empty store for a missing or bad file', async () => {
  const emptyStore = { names: {}, started: [] }
  expect(await loadStore(join(dir, 'missing.json'))).toEqual(emptyStore)

  const bad = join(dir, 'bad.json')
  await writeFile(bad, '{ not json')
  expect(await loadStore(bad)).toEqual(emptyStore)

  for (const text of ['null', '[]', '"text"', '7']) {
    await writeFile(bad, text)
    expect(await loadStore(bad)).toEqual(emptyStore)
  }
})

test('loadStore removes the values that have the wrong type', async () => {
  const file = join(dir, 'registry.json')
  await writeFile(
    file,
    JSON.stringify({ names: { s1: 'alpha', s2: 7, s3: null }, started: ['s1', 4, null] }),
  )
  expect(await loadStore(file)).toEqual({ names: { s1: 'alpha' }, started: ['s1'] })

  await writeFile(file, JSON.stringify({ names: ['x'], started: 'x' }))
  expect(await loadStore(file)).toEqual({ names: {}, started: [] })
})

test('saveStore then loadStore gives the same store', async () => {
  const file = join(dir, 'registry.json')
  const store = { names: { s1: 'alpha', s2: 'beta' }, started: ['s2'] }
  await saveStore(file, store)
  expect(await loadStore(file)).toEqual(store)

  const next = { names: { s3: 'gamma' }, started: [] }
  await saveStore(file, next)
  expect(await loadStore(file)).toEqual(next)
})

test('saveStore makes the directory and leaves no temporary file', async () => {
  const file = join(dir, 'user-data', 'registry.json')
  await saveStore(file, { names: {}, started: [] })
  await saveStore(file, { names: { s1: 'alpha' }, started: [] })
  expect(await readdir(join(dir, 'user-data'))).toEqual(['registry.json'])
  expect((await stat(file)).mode & 0o777).toBe(0o600)
})

test('loadStore rejects for a file that it cannot read', async () => {
  const file = join(dir, 'registry.json')
  await mkdir(file)
  await expect(loadStore(file)).rejects.toThrow(/EISDIR/)
})

test('openStore loads the file and saves to it', async () => {
  const file = join(dir, 'registry.json')
  await saveStore(file, { names: { s1: 'alpha' }, started: [] })
  const log = vi.fn()
  const opened = await openStore(file, log)
  expect(opened.store).toEqual({ names: { s1: 'alpha' }, started: [] })
  await opened.save({ names: { s2: 'beta' }, started: ['s2'] })
  expect(await loadStore(file)).toEqual({ names: { s2: 'beta' }, started: ['s2'] })
  expect(log).not.toHaveBeenCalled()
})

test('openStore uses an empty store and does not save when it cannot read the file', async () => {
  const file = join(dir, 'registry.json')
  await mkdir(file)
  const log = vi.fn()
  const opened = await openStore(file, log)
  expect(opened.store).toEqual({ names: {}, started: [] })
  expect(log).toHaveBeenCalledTimes(1)
  await opened.save({ names: { s1: 'alpha' }, started: [] })
  expect((await stat(file)).isDirectory()).toBe(true)
  expect(await readdir(file)).toEqual([])
  expect(await readdir(dir)).toEqual(['registry.json'])
})
