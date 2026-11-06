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
  const emptyStore = {
    aliases: {},
    current: {},
    jobs: {},
    lastActive: [],
    names: {},
    priorities: {},
    started: [],
    watch: [],
    worktrees: [],
  }
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
      worktrees: [],
    }),
  )
  expect(await loadStore(file)).toEqual({
    aliases: {},
    current: {},
    jobs: {},
    lastActive: [],
    names: { s1: 'alpha' },
    priorities: {},
    started: ['s1'],
    watch: [],
    worktrees: [],
  })

  await writeFile(file, JSON.stringify({ names: ['x'], priorities: {}, started: 'x' }))
  expect(await loadStore(file)).toEqual({
    aliases: {},
    current: {},
    jobs: {},
    lastActive: [],
    names: {},
    priorities: {},
    started: [],
    watch: [],
    worktrees: [],
  })
})

test('saveStore then loadStore gives the same store', async () => {
  const file = join(dir, 'registry.json')
  const store = {
    aliases: { s1: 'Work' },
    current: {},
    jobs: {},
    lastActive: [],
    names: { s1: 'alpha', s2: 'beta' },
    priorities: {},
    started: ['s2'],
    watch: [],
    worktrees: [],
  }
  await saveStore(file, store)
  expect(await loadStore(file)).toEqual(store)

  const next = {
    aliases: {},
    current: {},
    jobs: {},
    lastActive: [],
    names: { s3: 'gamma' },
    priorities: {},
    started: [],
    watch: [],
    worktrees: [],
  }
  await saveStore(file, next)
  expect(await loadStore(file)).toEqual(next)
})

test('saveStore makes the directory and leaves no temporary file', async () => {
  const file = join(dir, 'user-data', 'registry.json')
  await saveStore(file, {
    lastActive: [],
    names: {},
    priorities: {},
    started: [],
    watch: [],
    worktrees: [],
  })
  await saveStore(file, {
    lastActive: [],
    names: { s1: 'alpha' },
    priorities: {},
    started: [],
    watch: [],
    worktrees: [],
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
    worktrees: [],
  })
  const log = vi.fn()
  const opened = await openStore(file, log)
  expect(opened.store).toEqual({
    aliases: {},
    current: {},
    jobs: {},
    lastActive: [],
    names: { s1: 'alpha' },
    priorities: {},
    started: [],
    watch: [],
    worktrees: [],
  })
  await opened.save({
    lastActive: [],
    names: { s2: 'beta' },
    priorities: {},
    started: ['s2'],
    watch: [],
    worktrees: [],
  })
  expect(await loadStore(file)).toEqual({
    aliases: {},
    current: {},
    jobs: {},
    lastActive: [],
    names: { s2: 'beta' },
    priorities: {},
    started: ['s2'],
    watch: [],
    worktrees: [],
  })
  expect(log).not.toHaveBeenCalled()
})

test('openStore uses an empty store and does not save when it cannot read the file', async () => {
  const file = join(dir, 'registry.json')
  await mkdir(file)
  const log = vi.fn()
  const opened = await openStore(file, log)
  expect(opened.store).toEqual({
    aliases: {},
    current: {},
    jobs: {},
    lastActive: [],
    names: {},
    priorities: {},
    started: [],
    watch: [],
    worktrees: [],
  })
  expect(log).toHaveBeenCalledTimes(1)
  await opened.save({
    lastActive: [],
    names: { s1: 'alpha' },
    priorities: {},
    started: [],
    watch: [],
    worktrees: [],
  })
  expect((await stat(file)).isDirectory()).toBe(true)
  expect(await readdir(file)).toEqual([])
  expect(await readdir(dir)).toEqual(['registry.json'])
})

test('loadStore reads an M1 file without priorities', async () => {
  const file = join(dir, 'registry.json')
  await writeFile(file, JSON.stringify({ names: { a: 'x' }, started: [] }))
  expect(await loadStore(file)).toEqual({
    aliases: {},
    current: {},
    jobs: {},
    lastActive: [],
    names: { a: 'x' },
    priorities: {},
    started: [],
    watch: [],
    worktrees: [],
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
    aliases: {},
    current: {},
    jobs: {},
    lastActive: [],
    names: { a: 'x' },
    priorities: { a: 2 },
    started: [],
    watch: [],
    worktrees: [],
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
    { colour: 'dark-blue', sessionId: 's2' },
    { colour: 'amber', sessionId: 's1' },
  ]
  await writeFile(file, JSON.stringify({ names: {}, started: [], watch }))
  expect((await loadStore(file)).watch).toEqual(watch)
})

test('loadStore maps the old watch colours', async () => {
  const file = join(dir, 'registry.json')
  const watch = [
    { colour: 'orange', sessionId: 's1' },
    { colour: 'cyan', sessionId: 's2' },
    { colour: 'purple', sessionId: 's3' },
    { colour: 'pink', sessionId: 's4' },
    { colour: 'teal', sessionId: 's5' },
    { colour: 'constructor', sessionId: 's6' },
    { colour: '__proto__', sessionId: 's7' },
  ]
  await writeFile(file, JSON.stringify({ names: {}, started: [], watch }))
  expect((await loadStore(file)).watch).toEqual([
    { colour: 'amber', sessionId: 's1' },
    { colour: 'light-blue', sessionId: 's2' },
    { colour: 'dark-blue', sessionId: 's3' },
    { colour: 'red', sessionId: 's4' },
  ])
})

test('loadStore drops watch entries with a bad colour, a bad ID or a repeated ID', async () => {
  const file = join(dir, 'registry.json')
  const watch = [
    { colour: 'dark-blue', sessionId: 's1' },
    { colour: 'teal', sessionId: 's2' },
    { colour: 'pink', sessionId: 7 },
    { colour: 'green', sessionId: 's1' },
    null,
    'text',
    { colour: 'white', sessionId: 's3' },
  ]
  await writeFile(file, JSON.stringify({ names: {}, started: [], watch }))
  expect((await loadStore(file)).watch).toEqual([
    { colour: 'dark-blue', sessionId: 's1' },
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
  expect(await loadStore(file)).toEqual({
    ...m3,
    aliases: {},
    current: {},
    jobs: {},
    watch: [],
    worktrees: [],
  })
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
  expect(await loadStore(file)).toEqual({
    ...rest,
    aliases: {},
    current: {},
    jobs: {},
    watch: [],
    worktrees: [],
  })
  await writeFile(file, JSON.stringify({ ...rest, watch: [1, null, { colour: 'red' }, []] }))
  expect(await loadStore(file)).toEqual({
    ...rest,
    aliases: {},
    current: {},
    jobs: {},
    watch: [],
    worktrees: [],
  })
})

test('loadStore gives no worktrees for a file without worktrees', async () => {
  const file = join(dir, 'registry.json')
  await writeFile(file, JSON.stringify({ names: {}, started: [], watch: [] }))
  expect((await loadStore(file)).worktrees).toEqual([])
  await writeFile(file, JSON.stringify({ names: {}, started: [], worktrees: 'x' }))
  expect((await loadStore(file)).worktrees).toEqual([])
})

test('loadStore keeps only worktree entries with a string ID and a worktree path', async () => {
  const file = join(dir, 'registry.json')
  const worktrees = [
    { path: '/r/.claude/worktrees/a', sessionId: 's1' },
    { path: '/r/.claude/worktrees/b', sessionId: 7 },
    { path: 'r/.claude/worktrees/c', sessionId: 's3' },
    { path: '/r/src', sessionId: 's4' },
    { path: '/r/.claude/worktrees/../x', sessionId: 's5' },
    { path: 7, sessionId: 's6' },
    { path: '/r/.claude/worktrees/d', sessionId: 's1' },
    null,
    'text',
    { path: '/q/.claude/worktrees/e', sessionId: 's7' },
  ]
  await writeFile(file, JSON.stringify({ names: {}, started: [], worktrees }))
  expect((await loadStore(file)).worktrees).toEqual([
    { path: '/r/.claude/worktrees/a', sessionId: 's1' },
    { path: '/q/.claude/worktrees/e', sessionId: 's7' },
  ])
})

test('saveStore then loadStore keeps the worktrees', async () => {
  const file = join(dir, 'registry.json')
  const store = {
    aliases: {},
    current: {},
    jobs: {},
    lastActive: [],
    names: {},
    priorities: {},
    started: ['s1'],
    watch: [],
    worktrees: [{ path: '/r/.claude/worktrees/a', sessionId: 's1' }],
  }
  await saveStore(file, store)
  expect(await loadStore(file)).toEqual(store)
})

test('loadStore gives no aliases for a file without the field', async () => {
  const file = join(dir, 'old.json')
  await writeFile(file, JSON.stringify({ names: {}, priorities: {}, started: [] }))
  expect((await loadStore(file)).aliases).toEqual({})
})

test('loadStore keeps good aliases and drops bad values', async () => {
  const file = join(dir, 'aliases.json')
  await writeFile(
    file,
    JSON.stringify({
      aliases: { s1: 'Work', s2: 7, s3: '', s4: 'a\x1bb', s5: 'x'.repeat(65), s6: '  pad  ' },
      names: {},
    }),
  )
  expect((await loadStore(file)).aliases).toEqual({ s1: 'Work', s6: 'pad' })
  await writeFile(file, JSON.stringify({ aliases: ['x'], names: {} }))
  expect((await loadStore(file)).aliases).toEqual({})
})

test('loadStore gives no current IDs and no short IDs for a file without the fields', async () => {
  const file = join(dir, 'old.json')
  await writeFile(file, JSON.stringify({ names: {}, started: [] }))
  const store = await loadStore(file)
  expect(store.current).toEqual({})
  expect(store.jobs).toEqual({})
})

test('loadStore keeps good current IDs and short IDs and drops bad values', async () => {
  const A = '2f493bf0-1598-4b3b-b419-8acb9cb11bcb'
  const B = '1db82d17-d5fd-4e53-a042-7dd67ea654d8'
  const file = join(dir, 'current.json')
  await writeFile(
    file,
    JSON.stringify({
      // Two processes can run one conversation, so r1 and r2 keep one current ID. A has its own
      // row ID, r4 is not a UUID and r5 is no text.
      current: { r1: B, r2: B, [A]: A, r4: 'not-a-uuid', r5: 7 },
      jobs: { [A]: '2f493bf0', r2: 'ABCDEF12', r3: '123', r4: 9, r5: '' },
      names: {},
    }),
  )
  const store = await loadStore(file)
  expect(store.current).toEqual({ r1: B, r2: B })
  expect(store.jobs).toEqual({ [A]: '2f493bf0' })
  await writeFile(file, JSON.stringify({ current: ['x'], jobs: 'x', names: {} }))
  expect(await loadStore(file)).toMatchObject({ current: {}, jobs: {} })
})

test('saveStore then loadStore keeps the current IDs and the short IDs', async () => {
  const file = join(dir, 'registry.json')
  const store = {
    aliases: {},
    current: { '2f493bf0-1598-4b3b-b419-8acb9cb11bcb': '1db82d17-d5fd-4e53-a042-7dd67ea654d8' },
    jobs: { '2f493bf0-1598-4b3b-b419-8acb9cb11bcb': '2f493bf0' },
    lastActive: [],
    names: {},
    priorities: {},
    started: [],
    watch: [],
    worktrees: [],
  }
  await saveStore(file, store)
  expect(await loadStore(file)).toEqual(store)
})
