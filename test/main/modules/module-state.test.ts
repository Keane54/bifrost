import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  carriedDiscussSession,
  MAX_DISCUSS_SESSIONS,
  type ModulesState,
  moduleCodeDir,
  moduleDataFile,
  modulesStateFile,
  openModulesStateStore,
  parseModulesState,
  withDiscussSession,
  withoutDiscussSession,
} from '../../../src/main/modules/module-state'

const MANIFEST = {
  description: 'A test.',
  id: 'demo',
  minBifrost: '0.5.0',
  name: 'Demo',
  panels: [{ entry: 'panels/main.html', icon: 'chart-bar', id: 'main', title: 'Demo' }],
  permissions: [{ id: 'notify', reason: 'To tell you.' }],
  suggests: { dailyCap: null, model: null },
  version: '1.0.0',
}

function entry(extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    dailyCap: 10,
    enabled: true,
    granted: ['notify'],
    hash: 'a'.repeat(64),
    jobs: { count: 2, day: '2026-11-13' },
    manifest: MANIFEST,
    model: 'sonnet',
    pendingUpdate: null,
    source: { kind: 'folder', path: '/x/demo' },
    ...extra,
  }
}

describe('paths', () => {
  it('gives the file paths', () => {
    expect(modulesStateFile('/h')).toBe('/h/modules/state.json')
    expect(moduleCodeDir('/h', 'demo', 'current')).toBe('/h/modules/demo/current')
    expect(moduleCodeDir('/h', 'demo', 'next')).toBe('/h/modules/demo/next')
    expect(moduleDataFile('/h', 'demo')).toBe('/h/modules-data/demo.json')
  })
})

describe('parseModulesState', () => {
  it('keeps good entries and drops bad ones', () => {
    const state = parseModulesState({
      modules: {
        bad: entry({ manifest: { nope: 1 } }),
        badgrant: entry({ granted: ['root'] }),
        badid: entry(),
        demo: entry(),
        junk: 5,
      },
    })
    expect(Object.keys(state.modules)).toEqual(['demo'])
    expect(state.modules.demo?.dailyCap).toBe(10)
  })
  it('gives an empty state for bad data', () => {
    expect(parseModulesState(null)).toEqual({ modules: {} })
    expect(parseModulesState({ modules: [] })).toEqual({ modules: {} })
  })
  it('parses a dev source and a git source', () => {
    const state = parseModulesState({
      modules: {
        demo: entry({ source: { kind: 'dev', path: '/x' } }),
        other: entry({ source: { kind: 'git', url: 'https://github.com/a/b' } }),
      },
    })
    expect(state.modules.demo?.source).toEqual({ kind: 'dev', path: '/x' })
  })
  it('drops an entry with a bad source', () => {
    expect(
      Object.keys(
        parseModulesState({ modules: { demo: entry({ source: { kind: 'ftp' } }) } }).modules,
      ),
    ).toEqual([])
  })
  it('parses a pending update and drops one that is bad', () => {
    const good = parseModulesState({
      modules: { demo: entry({ pendingUpdate: { hash: 'b'.repeat(64), manifest: MANIFEST } }) },
    })
    expect(good.modules.demo?.pendingUpdate?.hash).toBe('b'.repeat(64))
    const bad = parseModulesState({ modules: { demo: entry({ pendingUpdate: { hash: 1 } }) } })
    expect(bad.modules.demo?.pendingUpdate).toBeNull()
  })
  it('drops a pending update with another id', () => {
    const other = { ...MANIFEST, id: 'other' }
    const state = parseModulesState({
      modules: { demo: entry({ pendingUpdate: { hash: 'a'.repeat(64), manifest: other } }) },
    })
    expect(state.modules.demo?.pendingUpdate).toBeNull()
  })
  it('drops an entry with a bad hash', () => {
    for (const hash of ['abc', 'A'.repeat(64), 'g'.repeat(64), 5]) {
      expect(parseModulesState({ modules: { demo: entry({ hash }) } }).modules).toEqual({})
    }
  })
  it('resets the count for a bad day', () => {
    const state = parseModulesState({
      modules: { demo: entry({ jobs: { count: 3, day: 'yesterday' } }) },
    })
    expect(state.modules.demo?.jobs).toEqual({ count: 0, day: '' })
  })
  it('keeps granted ids only for the ids of the manifest', () => {
    const state = parseModulesState({
      modules: { demo: entry({ granted: ['notify', 'discuss'] }) },
    })
    expect(state.modules.demo?.granted).toEqual(['notify'])
  })
})

describe('openModulesStateStore', () => {
  let home: string
  beforeEach(async () => {
    home = await mkdtemp(join(tmpdir(), 'bifrost-modules-state-'))
  })
  afterEach(async () => {
    await chmod(home, 0o700)
    await rm(home, { force: true, recursive: true })
  })

  it('starts empty, saves in a queue and makes the folder 0700', async () => {
    const file = modulesStateFile(home)
    const store = await openModulesStateStore(file)
    expect(store.get()).toEqual({ modules: {} })
    const demo = parseModulesState({ modules: { demo: entry() } }).modules.demo
    if (!demo) throw new Error('bad fixture')
    const add = (id: string) => (s: ReturnType<typeof store.get>) => ({
      modules: { ...s.modules, [id]: demo },
    })
    await Promise.all([store.change(add('one')), store.change(add('two'))])
    expect(Object.keys(store.get().modules)).toEqual(['one', 'two'])
    expect(((await stat(join(home, 'modules'))).mode & 0o777).toString(8)).toBe('700')
    const saved = JSON.parse(await readFile(file, 'utf8'))
    expect(Object.keys(saved.modules)).toEqual(['one', 'two'])
  })
  it('reads the saved file again', async () => {
    const file = modulesStateFile(home)
    await mkdir(join(home, 'modules'))
    await writeFile(file, JSON.stringify({ modules: { demo: entry() } }))
    const store = await openModulesStateStore(file)
    expect(Object.keys(store.get().modules)).toEqual(['demo'])
  })
  it('gives the empty state for a file that is not JSON', async () => {
    const file = modulesStateFile(home)
    await mkdir(join(home, 'modules'))
    await writeFile(file, '{ nope')
    const store = await openModulesStateStore(file)
    expect(store.get()).toEqual({ modules: {} })
  })
  it('does not save when the file cannot be read', async () => {
    const file = modulesStateFile(home)
    await mkdir(file, { recursive: true })
    const logs: string[] = []
    const store = await openModulesStateStore(file, m => logs.push(m))
    expect(logs).toHaveLength(1)
    await store.change(() => ({ modules: {} }))
    expect((await stat(file)).isDirectory()).toBe(true)
  })
  it('keeps going after a failed change', async () => {
    const store = await openModulesStateStore(modulesStateFile(home))
    await expect(
      store.change(() => {
        throw new Error('boom')
      }),
    ).rejects.toThrow('boom')
    await expect(store.change(s => s)).resolves.toEqual({ modules: {} })
  })
  it('tells each listener after each change, and not after a failed change', async () => {
    const store = await openModulesStateStore(modulesStateFile(home))
    const demo = parseModulesState({ modules: { demo: entry() } }).modules.demo
    if (!demo) throw new Error('bad fixture')
    const seen: string[][] = []
    const stop = store.onChange(s => seen.push(Object.keys(s.modules)))
    await store.change(s => ({ modules: { ...s.modules, one: demo } }))
    expect(seen).toEqual([['one']])
    await store
      .change(() => {
        throw new Error('boom')
      })
      .catch(() => {})
    expect(seen).toEqual([['one']])
    stop()
    await store.change(s => ({ modules: { ...s.modules, two: demo } }))
    expect(seen).toEqual([['one']])
  })
  it('keeps the new state when a listener throws', async () => {
    const logs: string[] = []
    const store = await openModulesStateStore(modulesStateFile(home), m => logs.push(m))
    store.onChange(() => {
      throw new Error('listener')
    })
    await expect(store.change(() => ({ modules: {} }))).resolves.toEqual({ modules: {} })
    expect(store.get()).toEqual({ modules: {} })
    expect(logs).toHaveLength(1)
  })
})

// The sessions that Discuss with Claude started (ruling P12). Heimdall keeps their ids in its own
// state, not in a module storage, so they stay hidden from the modules after a restart.
describe('the Discuss sessions in the modules state', () => {
  const ids = (n: number, from = 1): string[] =>
    Array.from({ length: n }, (_, i) => `session-${from + i}`)

  it('keeps the good ids of the file, each one time, and leaves out an empty list', () => {
    expect(
      parseModulesState({
        discussSessions: ['session-1', 7, '', 'bad id', '-x'.repeat(60), 'session-1', 'session-2'],
        modules: {},
      }),
    ).toEqual({ discussSessions: ['session-1', 'session-2'], modules: {} })
    expect(parseModulesState({ discussSessions: [], modules: {} })).toEqual({ modules: {} })
    expect(parseModulesState({ discussSessions: 'session-1', modules: {} })).toEqual({
      modules: {},
    })
  })

  it('keeps only the newest ids of a file that has too many', () => {
    const state = parseModulesState({ discussSessions: ids(250), modules: {} })
    expect(MAX_DISCUSS_SESSIONS).toBe(200)
    expect(state.discussSessions).toEqual(ids(200, 51))
  })

  it('adds an id at the end, and drops the oldest id above the cap', () => {
    let state: ModulesState = { modules: {} }
    for (const id of ids(201)) state = withDiscussSession(state, id)
    expect(state.discussSessions).toHaveLength(200)
    expect(state.discussSessions?.[0]).toBe('session-2')
    expect(state.discussSessions?.at(-1)).toBe('session-201')
    // An id that is there already moves to the end.
    state = withDiscussSession(state, 'session-5')
    expect(state.discussSessions).toHaveLength(200)
    expect(state.discussSessions?.at(-1)).toBe('session-5')
    expect(withDiscussSession(state, 'bad id')).toBe(state)
  })

  it('removes the id of a session that Bifrost forgot', () => {
    const state: ModulesState = { discussSessions: ids(3), modules: {} }
    expect(withoutDiscussSession(state, 'session-2').discussSessions).toEqual([
      'session-1',
      'session-3',
    ])
    // An id that is not in the list gives the same object, so nothing is written.
    expect(withoutDiscussSession(state, 'session-9')).toBe(state)
    const empty: ModulesState = { modules: {} }
    expect(withoutDiscussSession(empty, 'session-1')).toBe(empty)
  })

  it('adds the new id of a hand-over only for a saved session', () => {
    const state: ModulesState = { discussSessions: ['session-1'], modules: {} }
    expect(carriedDiscussSession(state, 'session-1', 'session-2').discussSessions).toEqual([
      'session-1',
      'session-2',
    ])
    expect(carriedDiscussSession(state, 'session-7', 'session-8')).toBe(state)
  })

  it('saves the list in the state file, so it stays after a restart', async () => {
    const home = await mkdtemp(join(tmpdir(), 'bifrost-discuss-sessions-'))
    try {
      const file = modulesStateFile(home)
      const first = await openModulesStateStore(file)
      await first.change(s => withDiscussSession(s, 'session-1'))
      const second = await openModulesStateStore(file)
      expect(second.get().discussSessions).toEqual(['session-1'])
    } finally {
      await rm(home, { force: true, recursive: true })
    }
  })
})
