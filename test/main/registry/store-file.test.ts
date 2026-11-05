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
  const emptyStore = { lastActive: [], names: {}, priorities: {}, started: [], watch: [] }
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
    JSON.stringify({
      names: { s1: 'alpha', s2: 7, s3: null },
      priorities: {},
      started: ['s1', 4, null],
      watch: [],
    }),
  )
  expect(await loadStore(file)).toEqual({
    lastActive: [],
    names: { s1: 'alpha' },
    priorities: {},
    started: ['s1'],
    watch: [],
  })

  await writeFile(file, JSON.stringify({ names: ['x'], priorities: {}, started: 'x' }))
  expect(await loadStore(file)).toEqual({
    lastActive: [],
    names: {},
    priorities: {},
    started: [],
    watch: [],
  })
})

test('saveStore then loadStore gives the same store', async () => {
  const file = join(dir, 'registry.json')
  const store = {
    lastActive: [],
    names: { s1: 'alpha', s2: 'beta' },
    priorities: {},
    started: ['s2'],
    watch: [],
  }
  await saveStore(file, store)
  expect(await loadStore(file)).toEqual(store)

  const next = { lastActive: [], names: { s3: 'gamma' }, priorities: {}, started: [], watch: [] }
  await saveStore(file, next)
  expect(await loadStore(file)).toEqual(next)
})

test('saveStore makes the directory and leaves no temporary file', async () => {
  const file = join(dir, 'user-data', 'registry.json')
  await saveStore(file, { lastActive: [], names: {}, priorities: {}, started: [], watch: [] })
  await saveStore(file, {
    lastActive: [],
    names: { s1: 'alpha' },
    priorities: {},
    started: [],
    watch: [],
  })
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
  await saveStore(file, {
    lastActive: [],
    names: { s1: 'alpha' },
    priorities: {},
    started: [],
    watch: [],
  })
  const log = vi.fn()
  const opened = await openStore(file, log)
  expect(opened.store).toEqual({
    lastActive: [],
    names: { s1: 'alpha' },
    priorities: {},
    started: [],
    watch: [],
  })
  await opened.save({
    lastActive: [],
    names: { s2: 'beta' },
    priorities: {},
    started: ['s2'],
    watch: [],
  })
  expect(await loadStore(file)).toEqual({
    lastActive: [],
    names: { s2: 'beta' },
    priorities: {},
    started: ['s2'],
    watch: [],
  })
  expect(log).not.toHaveBeenCalled()
})

test('openStore uses an empty store and does not save when it cannot read the file', async () => {
  const file = join(dir, 'registry.json')
  await mkdir(file)
  const log = vi.fn()
  const opened = await openStore(file, log)
  expect(opened.store).toEqual({
    lastActive: [],
    names: {},
    priorities: {},
    started: [],
    watch: [],
  })
  expect(log).toHaveBeenCalledTimes(1)
  await opened.save({
    lastActive: [],
    names: { s1: 'alpha' },
    priorities: {},
    started: [],
    watch: [],
  })
  expect((await stat(file)).isDirectory()).toBe(true)
  expect(await readdir(file)).toEqual([])
  expect(await readdir(dir)).toEqual(['registry.json'])
})

test('loadStore reads an M1 file without priorities', async () => {
  const file = join(dir, 'registry.json')
  await writeFile(file, JSON.stringify({ names: { a: 'x' }, started: [] }))
  expect(await loadStore(file)).toEqual({
    lastActive: [],
    names: { a: 'x' },
    priorities: {},
    started: [],
    watch: [],
  })
})

test('loadStore drops bad priorities', async () => {
  const file = join(dir, 'registry.json')
  const priorities = { a: 3, b: 7, c: '2', d: 1.5 }
  await writeFile(file, JSON.stringify({ names: {}, priorities, started: [] }))
  expect((await loadStore(file)).priorities).toEqual({ a: 3 })
})

test('loadStore reads a file without lastActive', async () => {
  const file = join(dir, 'registry.json')
  await writeFile(file, JSON.stringify({ names: { a: 'x' }, priorities: { a: 2 }, started: [] }))
  expect(await loadStore(file)).toEqual({
    lastActive: [],
    names: { a: 'x' },
    priorities: { a: 2 },
    started: [],
    watch: [],
  })
})

test('loadStore keeps only strings in lastActive, each one time', async () => {
  const file = join(dir, 'registry.json')
  await writeFile(file, JSON.stringify({ lastActive: ['a', 3, 'a', null, 'b'] }))
  expect((await loadStore(file)).lastActive).toEqual(['a', 'b'])
})

test('loadStore gives an empty watchlist for a file without watch', async () => {
  const file = join(dir, 'registry.json')
  await writeFile(file, JSON.stringify({ names: {}, started: [] }))
  expect((await loadStore(file)).watch).toEqual([])
})

test('loadStore keeps good watch entries in order', async () => {
  const file = join(dir, 'registry.json')
  const watch = [
    { colour: 'blue', sessionId: 's2' },
    { colour: 'orange', sessionId: 's1' },
  ]
  await writeFile(file, JSON.stringify({ names: {}, started: [], watch }))
  expect((await loadStore(file)).watch).toEqual(watch)
})

test('loadStore drops watch entries with a bad colour, a bad ID or a repeated ID', async () => {
  const file = join(dir, 'registry.json')
  const watch = [
    { colour: 'blue', sessionId: 's1' },
    { colour: 'red', sessionId: 's2' },
    { colour: 'pink', sessionId: 7 },
    { colour: 'green', sessionId: 's1' },
    null,
    'text',
    { colour: 'white', sessionId: 's3' },
  ]
  await writeFile(file, JSON.stringify({ names: {}, started: [], watch }))
  expect((await loadStore(file)).watch).toEqual([
    { colour: 'blue', sessionId: 's1' },
    { colour: 'white', sessionId: 's3' },
  ])
  await writeFile(file, JSON.stringify({ names: {}, started: [], watch: 'x' }))
  expect((await loadStore(file)).watch).toEqual([])
})

test('loadStore keeps a full M3 file that has no watch', async () => {
  const file = join(dir, 'registry.json')
  const m3 = {
    lastActive: ['s1', 's2'],
    names: { s1: 'alpha', s2: 'beta' },
    priorities: { s1: 2, s2: 5 },
    started: ['s1'],
  }
  await writeFile(file, JSON.stringify(m3))
  expect(await loadStore(file)).toEqual({ ...m3, watch: [] })
})

test('loadStore keeps the other fields when watch is damaged', async () => {
  const file = join(dir, 'registry.json')
  const rest = {
    lastActive: ['s1'],
    names: { s1: 'alpha' },
    priorities: { s1: 3 },
    started: ['s1'],
  }
  await writeFile(file, JSON.stringify({ ...rest, watch: 'broken' }))
  expect(await loadStore(file)).toEqual({ ...rest, watch: [] })
  await writeFile(file, JSON.stringify({ ...rest, watch: [1, null, { colour: 'red' }, []] }))
  expect(await loadStore(file)).toEqual({ ...rest, watch: [] })
})
