import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  createHeimdall,
  type HeimdallDeps,
  MODULE_IN_FLIGHT,
  MODULE_MESSAGE_BYTES,
  MODULE_RATE,
  NOTIFY_PER_MINUTE,
  PR_LOOKUPS,
  PR_RETRY_MS,
  STORAGE_SETS_PER_SECOND,
} from '../../../src/main/modules/heimdall'
import {
  createModuleDataStore,
  type DataStoreIo,
  MODULE_STORAGE_BYTES,
} from '../../../src/main/modules/module-data'
import type { ModuleEntry, ModulesState } from '../../../src/main/modules/module-state'
import {
  moduleDataFile,
  modulesStateFile,
  openModulesStateStore,
  withDiscussSession,
} from '../../../src/main/modules/module-state'
import type { PermissionId } from '../../../src/shared/module-manifest'
import type {
  AccountUsage,
  PrInfo,
  ServiceStatus,
  SessionRow,
  UsageSnapshot,
} from '../../../src/shared/types'

const OFF = 'refused: module off'
const NOT_ALLOWED = 'refused: not allowed for this module'
const UNKNOWN = 'refused: unknown module call'
const BAD = 'refused: bad module input'
const TOO_MANY = 'refused: too many module calls'
const TOO_LARGE = 'refused: module message too large'
const FULL = 'refused: module storage is full'
const FAILED = 'refused: module call failed'

// A fake token. The test builds it from parts.
const TOKEN = `ghp_${'A1b2C3d4E5f6G7h8I9j0'}`

const ALL: PermissionId[] = [
  'notify',
  'read-sessions',
  'read-usage',
  'read-service-status',
  'claude-jobs',
  'discuss',
]

function entry(
  id: string,
  granted: PermissionId[] = ALL,
  extra: Partial<ModuleEntry> = {},
): ModuleEntry {
  return {
    dailyCap: 10,
    enabled: true,
    granted,
    hash: 'a'.repeat(64),
    jobs: { count: 0, day: '' },
    manifest: {
      description: 'A test.',
      id,
      minBifrost: '0.1.0',
      name: `Module ${id}`,
      panels: [{ entry: 'panels/main.html', icon: 'bell', id: 'main', title: 'Main' }],
      permissions: ALL.map(p => ({ id: p, reason: 'For the test.' })),
      suggests: { dailyCap: null, model: null },
      version: '1.0.0',
    },
    model: 'sonnet',
    pendingUpdate: null,
    source: { kind: 'folder', path: `/src/${id}` },
    ...extra,
  }
}

function row(extra: Partial<SessionRow> = {}): SessionRow {
  return {
    box: 'none',
    boxSince: null,
    branch: 'main',
    claudeName: 'claude name',
    cwd: '/work/app',
    flashing: false,
    kind: 'owned',
    lastActivity: 1,
    lastMessage: 'a private message',
    name: 'Build the app',
    pid: 4242,
    sessionId: '11111111-2222-3333-4444-555555555555',
    startedAt: 1,
    state: 'working',
    status: 'running',
    transcriptPath: '/Users/x/.claude/projects/a.jsonl',
    ...extra,
  }
}

const SERVICE: ServiceStatus = {
  checkedAt: 5,
  error: 'a fetch error',
  id: 'claude',
  incidents: [{ impact: 'minor', name: 'Slow API', rank: 1, startedAt: 3, status: 'monitoring' }],
  level: 'minor',
  name: 'Claude',
  since: 3,
}

interface Deferred<T> {
  promise: Promise<T>
  resolve(value: T): void
}

function deferred<T>(): Deferred<T> {
  let resolve: (value: T) => void = () => {}
  const promise = new Promise<T>(r => {
    resolve = r
  })
  return { promise, resolve }
}

const PR: PrInfo = {
  kind: 'pr',
  number: 7,
  state: 'OPEN',
  title: 'A PR',
  url: 'https://github.com/acme/app/pull/7',
}

// The Bifrost folder of the store in this test. The files stay in memory.
const HOME = '/test-home/.bifrost'

function setup(over: Partial<HeimdallDeps> = {}) {
  let now = 1_000_000
  const state: ModulesState = {
    modules: { demo: entry('demo'), other: entry('other'), plain: entry('plain', []) },
  }
  const notes: unknown[] = []
  const events: unknown[] = []
  const files = new Map<string, string>()
  const io: DataStoreIo = {
    read: async file => files.get(file) ?? null,
    write: async (file, text) => {
      files.set(file, text)
    },
    writeSync: (file, text) => {
      files.set(file, text)
    },
  }
  const store = createModuleDataStore(HOME, { io })
  let rows: SessionRow[] = [row()]
  let usage: { snapshot: UsageSnapshot | null; account: AccountUsage | null } = {
    account: null,
    snapshot: null,
  }
  const logs: string[] = []
  const deps: HeimdallDeps = {
    devAllowed: true,
    emit: (moduleId, event, data) => events.push({ data, event, moduleId }),
    log: message => logs.push(message),
    notify: n => notes.push(n),
    now: () => now,
    serviceStatus: () => [SERVICE],
    sessions: {
      pr: async () => PR,
      rows: () => rows,
    },
    state: () => state,
    store,
    usage: () => usage,
    ...over,
  }
  return {
    events,
    heimdall: createHeimdall(deps),
    logs,
    notes,
    // The saved object of a module after a write of all changes, or undefined with no file.
    saved: async (id: string): Promise<Record<string, unknown> | undefined> => {
      await store.flush()
      const text = files.get(moduleDataFile(HOME, id))
      return text === undefined ? undefined : JSON.parse(text)
    },
    setRows: (next: SessionRow[]) => {
      rows = next
    },
    setUsage: (next: typeof usage) => {
      usage = next
    },
    state,
    tick: (ms: number) => {
      now += ms
    },
  }
}

describe('the module check', () => {
  it('refuses a module that is gone, off, or a dev module when packaged', async () => {
    const t = setup({ devAllowed: false })
    t.state.modules.off = entry('off', ALL, { enabled: false })
    t.state.modules.dev = entry('dev', ALL, { source: { kind: 'dev', path: '/src/dev' } })
    for (const id of ['gone', 'off', 'dev', '__proto__', 'constructor', 'toString', '']) {
      await expect(t.heimdall.call(id, 'storage.get', { key: 'a' }), id).rejects.toThrow(OFF)
    }
  })

  it('accepts a dev module when the app is not packaged', async () => {
    const t = setup({ devAllowed: true })
    t.state.modules.dev = entry('dev', ALL, { source: { kind: 'dev', path: '/src/dev' } })
    await expect(t.heimdall.call('dev', 'storage.get', { key: 'a' })).resolves.toBe(null)
  })

  it('refuses a module id that is not a string', async () => {
    const t = setup()
    await expect(t.heimdall.call(5 as unknown as string, 'storage.get', {})).rejects.toThrow(OFF)
  })
})

describe('unknown calls', () => {
  it('refuses a call that Heimdall does not know', async () => {
    const t = setup()
    for (const name of ['storage.delete', 'constructor', '__proto__', 'toString', '', 'shell']) {
      await expect(t.heimdall.call('demo', name, null), name).rejects.toThrow(UNKNOWN)
    }
    await expect(t.heimdall.call('demo', 7 as unknown as string, null)).rejects.toThrow(UNKNOWN)
  })

  it('refuses claude.job and discuss.request until their parts exist', async () => {
    const t = setup()
    await expect(t.heimdall.call('demo', 'claude.job', { prompt: 'Hi' })).rejects.toThrow(UNKNOWN)
    await expect(t.heimdall.call('demo', 'discuss.request', { title: 'x' })).rejects.toThrow(
      UNKNOWN,
    )
  })
})

describe('permissions', () => {
  const calls: { name: string; args: unknown; permission: PermissionId }[] = [
    { args: { body: 'b', title: 't' }, name: 'notify', permission: 'notify' },
    { args: null, name: 'sessions.list', permission: 'read-sessions' },
    { args: null, name: 'usage.get', permission: 'read-usage' },
    { args: null, name: 'serviceStatus.get', permission: 'read-service-status' },
    { args: { prompt: 'Hi' }, name: 'claude.job', permission: 'claude-jobs' },
    { args: { title: 'Talk' }, name: 'discuss.request', permission: 'discuss' },
  ]
  const parts = {
    discuss: { request: async () => ({ opened: true }) },
    jobs: { run: async () => ({ text: 'done' }) },
  }

  it('runs each call when its permission is granted', async () => {
    const t = setup(parts)
    for (const c of calls) {
      await expect(t.heimdall.call('demo', c.name, c.args), c.name).resolves.toBeDefined()
    }
  })

  it('refuses each call with no grant', async () => {
    const t = setup(parts)
    for (const c of calls) {
      await expect(t.heimdall.call('plain', c.name, c.args), c.name).rejects.toThrow(NOT_ALLOWED)
    }
  })

  it('refuses a call after the user removes its permission', async () => {
    const t = setup(parts)
    for (const c of calls) {
      const granted = ALL.filter(p => p !== c.permission)
      t.state.modules.demo = entry('demo', granted)
      await expect(t.heimdall.call('demo', c.name, c.args), c.name).rejects.toThrow(NOT_ALLOWED)
    }
    expect(t.notes).toEqual([])
  })

  it('needs no permission for storage', async () => {
    const t = setup()
    await expect(t.heimdall.call('plain', 'storage.set', { key: 'a', value: 1 })).resolves.toBe(
      null,
    )
    await expect(t.heimdall.call('plain', 'storage.get', { key: 'a' })).resolves.toBe(1)
  })

  it('refuses the answer when the permission goes while the call runs', async () => {
    const wait = deferred<PrInfo>()
    const t = setup({ sessions: { pr: () => wait.promise, rows: () => [row()] } })
    const call = t.heimdall.call('demo', 'sessions.list', null)
    t.state.modules.demo = entry('demo', [])
    wait.resolve(PR)
    await expect(call).rejects.toThrow(NOT_ALLOWED)
  })

  it('refuses the answer when the module goes off while the call runs', async () => {
    const wait = deferred<PrInfo>()
    const t = setup({ sessions: { pr: () => wait.promise, rows: () => [row()] } })
    const call = t.heimdall.call('demo', 'sessions.list', null)
    t.state.modules.demo = entry('demo', ALL, { enabled: false })
    wait.resolve(PR)
    await expect(call).rejects.toThrow(OFF)
  })
})

describe('bad input', () => {
  it('refuses a bad storage key', async () => {
    const t = setup()
    for (const key of ['', 'A', 'a/b', 'a b', 'é', 'k'.repeat(65), 5, null]) {
      await expect(t.heimdall.call('demo', 'storage.get', { key }), String(key)).rejects.toThrow(
        BAD,
      )
      await expect(t.heimdall.call('demo', 'storage.set', { key, value: 1 })).rejects.toThrow(BAD)
    }
  })

  it('accepts each key of the key pattern', async () => {
    const t = setup()
    for (const key of ['a', 'a.b-c_d', '0', 'k'.repeat(64)]) {
      await expect(t.heimdall.call('demo', 'storage.get', { key }), key).resolves.toBe(null)
    }
  })

  it('refuses storage arguments of the wrong shape', async () => {
    const t = setup()
    for (const args of [null, undefined, 'a', ['a'], { key: 'a', more: 1 }, {}]) {
      await expect(t.heimdall.call('demo', 'storage.get', args)).rejects.toThrow(BAD)
    }
    for (const args of [{ key: 'a' }, { key: 'a', more: 2, value: 1 }, { value: 1 }]) {
      await expect(t.heimdall.call('demo', 'storage.set', args)).rejects.toThrow(BAD)
    }
  })

  it('refuses a value that is not JSON', async () => {
    const t = setup()
    await expect(t.heimdall.call('demo', 'storage.set', { key: 'a', value: 10n })).rejects.toThrow(
      BAD,
    )
    const cyclic: Record<string, unknown> = {}
    cyclic.self = cyclic
    await expect(
      t.heimdall.call('demo', 'storage.set', { key: 'a', value: cyclic }),
    ).rejects.toThrow(BAD)
  })

  it('refuses a stored value that is nested too deep', async () => {
    const t = setup()
    let deep: unknown = 1
    for (let i = 0; i < 100; i++) deep = [deep]
    await expect(t.heimdall.call('demo', 'storage.set', { key: 'a', value: deep })).rejects.toThrow(
      BAD,
    )
  })

  it('refuses bad notify input', async () => {
    const t = setup()
    for (const args of [
      null,
      {},
      { title: '' },
      { title: '   ' },
      { title: 't'.repeat(81) },
      { body: 'b'.repeat(301), title: 't' },
      { body: 5, title: 't' },
      { title: 5 },
      { more: 1, title: 't' },
    ]) {
      await expect(t.heimdall.call('demo', 'notify', args), JSON.stringify(args)).rejects.toThrow(
        BAD,
      )
    }
    expect(t.notes).toEqual([])
  })

  it('refuses arguments for a call that takes none', async () => {
    const t = setup()
    for (const name of ['sessions.list', 'usage.get', 'serviceStatus.get']) {
      await expect(t.heimdall.call('demo', name, { a: 1 }), name).rejects.toThrow(BAD)
      await expect(t.heimdall.call('demo', name, 'x'), name).rejects.toThrow(BAD)
      await expect(t.heimdall.call('demo', name, {}), name).resolves.toBeDefined()
      await expect(t.heimdall.call('demo', name, undefined), name).resolves.toBeDefined()
    }
  })
})

describe('storage', () => {
  it('keeps one object for each module', async () => {
    const t = setup()
    await t.heimdall.call('demo', 'storage.set', { key: 'n', value: { list: [1, 'two'] } })
    await t.heimdall.call('other', 'storage.set', { key: 'n', value: 'other' })
    await expect(t.heimdall.call('demo', 'storage.get', { key: 'n' })).resolves.toEqual({
      list: [1, 'two'],
    })
    await expect(t.heimdall.call('other', 'storage.get', { key: 'n' })).resolves.toBe('other')
    expect(await t.saved('demo')).toEqual({ n: { list: [1, 'two'] } })
    expect(await t.saved('other')).toEqual({ n: 'other' })
  })

  it('gives null for a missing key and removes a key that gets null', async () => {
    const t = setup()
    await expect(t.heimdall.call('demo', 'storage.get', { key: 'gone' })).resolves.toBe(null)
    await t.heimdall.call('demo', 'storage.set', { key: 'a', value: 1 })
    await t.heimdall.call('demo', 'storage.set', { key: 'a', value: null })
    expect(await t.saved('demo')).toEqual({})
  })

  it('keeps a __proto__ key as data and does not change any prototype', async () => {
    const t = setup()
    await t.heimdall.call('demo', 'storage.set', { key: '__proto__', value: { polluted: true } })
    await expect(t.heimdall.call('demo', 'storage.get', { key: '__proto__' })).resolves.toEqual({
      polluted: true,
    })
    await expect(t.heimdall.call('demo', 'storage.get', { key: 'polluted' })).resolves.toBe(null)
    expect(({} as Record<string, unknown>).polluted).toBeUndefined()
    const data = (await t.saved('demo')) ?? {}
    expect(Object.hasOwn(data, '__proto__')).toBe(true)
  })

  it('does not lose a change when two sets run at the same time', async () => {
    const t = setup()
    await Promise.all([
      t.heimdall.call('demo', 'storage.set', { key: 'a', value: 1 }),
      t.heimdall.call('demo', 'storage.set', { key: 'b', value: 2 }),
      t.heimdall.call('demo', 'storage.set', { key: 'c', value: 3 }),
    ])
    expect(await t.saved('demo')).toEqual({ a: 1, b: 2, c: 3 })
  })

  it('refuses a set that makes the data larger than 1 MB, and keeps the old data', async () => {
    const t = setup()
    const big = 'x'.repeat(200 * 1024)
    for (const key of ['a', 'b', 'c', 'd', 'e']) {
      await t.heimdall.call('demo', 'storage.set', { key, value: big })
      // Wait out the cap of storage sets.
      t.tick(1000)
    }
    await expect(t.heimdall.call('demo', 'storage.set', { key: 'f', value: big })).rejects.toThrow(
      FULL,
    )
    expect(Object.keys((await t.saved('demo')) ?? {})).toEqual(['a', 'b', 'c', 'd', 'e'])
    // A smaller value in place of a big one fits.
    await expect(t.heimdall.call('demo', 'storage.set', { key: 'a', value: 1 })).resolves.toBe(null)
    expect(MODULE_STORAGE_BYTES).toBe(1024 * 1024)
  })

  it('masks a token in a stored value', async () => {
    const t = setup()
    await t.heimdall.call('demo', 'storage.set', { key: 'a', value: { t: `x ${TOKEN}` } })
    await expect(t.heimdall.call('demo', 'storage.get', { key: 'a' })).resolves.toEqual({
      t: 'x ***',
    })
  })

  it('gives a friendly code, not the error text, when the store fails', async () => {
    const failing: DataStoreIo = {
      read: async () => {
        throw new Error('EACCES: permission denied, open /Users/x/.bifrost/modules-data/demo')
      },
      write: async () => {},
      writeSync: () => {},
    }
    const t = setup({ store: createModuleDataStore(HOME, { io: failing }) })
    await expect(t.heimdall.call('demo', 'storage.get', { key: 'a' })).rejects.toThrow(
      new Error(FAILED),
    )
  })

  it('refuses more than 10 storage sets in one second, and keeps the gets', async () => {
    const t = setup()
    expect(STORAGE_SETS_PER_SECOND).toBe(10)
    for (let i = 0; i < STORAGE_SETS_PER_SECOND; i++) {
      await t.heimdall.call('demo', 'storage.set', { key: 'n', value: i })
    }
    await expect(t.heimdall.call('demo', 'storage.set', { key: 'n', value: 99 })).rejects.toThrow(
      TOO_MANY,
    )
    await expect(t.heimdall.call('demo', 'storage.get', { key: 'n' })).resolves.toBe(9)
    await expect(t.heimdall.call('other', 'storage.set', { key: 'n', value: 1 })).resolves.toBe(
      null,
    )
    t.tick(1000)
    await expect(t.heimdall.call('demo', 'storage.set', { key: 'n', value: 10 })).resolves.toBe(
      null,
    )
  })

  it('stays fast under a flood of sets when the storage is almost full', async () => {
    const t = setup()
    const big = 'x'.repeat(250 * 1024)
    for (const key of ['a', 'b', 'c', 'd']) {
      await t.heimdall.call('demo', 'storage.set', { key, value: big })
      t.tick(1000)
    }
    const started = performance.now()
    const results = await Promise.allSettled(
      Array.from({ length: 2000 }, (_, i) =>
        t.heimdall.call('demo', 'storage.set', { key: 'n', value: i }),
      ),
    )
    const elapsed = performance.now() - started
    expect(results.filter(r => r.status === 'fulfilled')).toHaveLength(STORAGE_SETS_PER_SECOND)
    // 2000 calls in well under a second: no set handles the whole 1 MB object.
    expect(elapsed).toBeLessThan(500)
  })
})

describe('the caps', () => {
  it('refuses calls over 100 in one second, for each module on its own', async () => {
    const t = setup()
    expect(MODULE_RATE).toBe(100)
    for (let i = 0; i < MODULE_RATE; i++) {
      await t.heimdall.call('demo', 'storage.get', { key: 'a' })
    }
    await expect(t.heimdall.call('demo', 'storage.get', { key: 'a' })).rejects.toThrow(TOO_MANY)
    await expect(t.heimdall.call('other', 'storage.get', { key: 'a' })).resolves.toBe(null)
    t.tick(999)
    await expect(t.heimdall.call('demo', 'storage.get', { key: 'a' })).rejects.toThrow(TOO_MANY)
    t.tick(1)
    await expect(t.heimdall.call('demo', 'storage.get', { key: 'a' })).resolves.toBe(null)
  })

  it('stays fast under a flood of calls', async () => {
    const t = setup()
    const started = performance.now()
    const results = await Promise.allSettled(
      Array.from({ length: 10_000 }, () => t.heimdall.call('demo', 'storage.get', { key: 'a' })),
    )
    // The first 32 calls run. The in-flight cap refuses the next calls up to the rate cap, and
    // the rate cap refuses the rest.
    expect(results.filter(r => r.status === 'fulfilled')).toHaveLength(MODULE_IN_FLIGHT)
    const reasons = new Set(
      results.flatMap(r => (r.status === 'rejected' ? [(r.reason as Error).message] : [])),
    )
    expect([...reasons]).toEqual([TOO_MANY])
    expect(performance.now() - started).toBeLessThan(2000)
  })

  it('refuses more than 32 calls in flight', async () => {
    const waits: Deferred<unknown>[] = []
    const t = setup({
      jobs: {
        run: () => {
          const d = deferred<unknown>()
          waits.push(d)
          return d.promise
        },
      },
    })
    expect(MODULE_IN_FLIGHT).toBe(32)
    const open = Array.from({ length: MODULE_IN_FLIGHT }, () =>
      t.heimdall.call('demo', 'claude.job', { prompt: 'Hi' }),
    )
    await new Promise(r => setTimeout(r, 0))
    expect(waits).toHaveLength(MODULE_IN_FLIGHT)
    await expect(t.heimdall.call('demo', 'storage.get', { key: 'a' })).rejects.toThrow(TOO_MANY)
    await expect(t.heimdall.call('other', 'storage.get', { key: 'a' })).resolves.toBe(null)
    waits[0]?.resolve({ text: 'one' })
    await open[0]
    await expect(t.heimdall.call('demo', 'storage.get', { key: 'a' })).resolves.toBe(null)
    for (const w of waits) w.resolve({ text: 'x' })
    await Promise.all(open)
  })

  it('frees the in-flight place of a call that fails', async () => {
    const t = setup({
      jobs: {
        run: async () => {
          throw new Error('boom')
        },
      },
    })
    for (let i = 0; i < MODULE_IN_FLIGHT + 5; i++) {
      await expect(t.heimdall.call('demo', 'claude.job', { prompt: 'Hi' })).rejects.toThrow(FAILED)
    }
  })

  it('refuses a message larger than 256 KB', async () => {
    const t = setup()
    expect(MODULE_MESSAGE_BYTES).toBe(256 * 1024)
    const value = 'x'.repeat(MODULE_MESSAGE_BYTES)
    await expect(t.heimdall.call('demo', 'storage.set', { key: 'a', value })).rejects.toThrow(
      TOO_LARGE,
    )
    // Characters outside ASCII count in UTF-8 bytes.
    const wide = 'é'.repeat(MODULE_MESSAGE_BYTES / 2)
    await expect(t.heimdall.call('demo', 'storage.set', { key: 'a', value: wide })).rejects.toThrow(
      TOO_LARGE,
    )
    expect(await t.saved('demo')).toBe(undefined)
  })

  it('refuses an answer larger than 256 KB', async () => {
    const t = setup({ jobs: { run: async () => ({ text: 'x'.repeat(MODULE_MESSAGE_BYTES) }) } })
    await expect(t.heimdall.call('demo', 'claude.job', { prompt: 'Hi' })).rejects.toThrow(TOO_LARGE)
  })

  it('refuses more than 10 notifications in a minute', async () => {
    const t = setup()
    expect(NOTIFY_PER_MINUTE).toBe(10)
    for (let i = 0; i < NOTIFY_PER_MINUTE; i++) {
      await t.heimdall.call('demo', 'notify', { title: `n${i}` })
    }
    await expect(t.heimdall.call('demo', 'notify', { title: 'more' })).rejects.toThrow(TOO_MANY)
    t.tick(60_000)
    await expect(t.heimdall.call('demo', 'notify', { title: 'later' })).resolves.toBe(null)
    expect(t.notes).toHaveLength(NOTIFY_PER_MINUTE + 1)
  })
})

describe('the calls', () => {
  it('shows a notification with the name of the module', async () => {
    const t = setup()
    await t.heimdall.call('demo', 'notify', { body: 'It finished.', title: 'Done' })
    await t.heimdall.call('demo', 'notify', { title: 'No body' })
    expect(t.notes).toEqual([
      { body: 'It finished.', moduleId: 'demo', moduleName: 'Module demo', title: 'Done' },
      { body: '', moduleId: 'demo', moduleName: 'Module demo', title: 'No body' },
    ])
  })

  it('lists the sessions with only the name, state, folder, branch and PR link', async () => {
    const t = setup()
    t.setRows([row(), row({ branch: undefined, name: 'Parked one', state: 'parked' })])
    await expect(t.heimdall.call('demo', 'sessions.list', null)).resolves.toEqual([
      {
        branch: 'main',
        folder: '/work/app',
        name: 'Build the app',
        prUrl: 'https://github.com/acme/app/pull/7',
        state: 'working',
      },
      { branch: null, folder: '/work/app', name: 'Parked one', prUrl: null, state: 'parked' },
    ])
  })

  it('hides each session that Discuss started, from every module (ruling P12)', async () => {
    const hidden = '99999999-2222-3333-4444-555555555555'
    const t = setup({
      discuss: { isDiscussSession: id => id === hidden, request: async () => null },
    })
    t.setRows([row(), row({ name: 'From Discuss', sessionId: hidden })])
    for (const moduleId of ['demo', 'other']) {
      const list = (await t.heimdall.call(moduleId, 'sessions.list', null)) as { name: string }[]
      expect(list.map(s => s.name)).toEqual(['Build the app'])
    }
  })

  it('hides a Discuss session after a restart, through its saved state (ruling P12)', async () => {
    const hidden = '99999999-2222-3333-4444-555555555555'
    const dir = await mkdtemp(join(tmpdir(), 'bifrost-heimdall-state-'))
    try {
      const file = modulesStateFile(dir)
      const first = await openModulesStateStore(file)
      await first.change(s =>
        withDiscussSession({ ...s, modules: { demo: entry('demo') } }, hidden),
      )
      // A restart: a new store from the same file, and a new Heimdall with no Discuss part.
      const second = await openModulesStateStore(file)
      const t = setup({ state: () => second.get() })
      t.setRows([row(), row({ name: 'From Discuss', sessionId: hidden })])
      const list = (await t.heimdall.call('demo', 'sessions.list', null)) as { name: string }[]
      expect(list.map(s => s.name)).toEqual(['Build the app'])
    } finally {
      await rm(dir, { force: true, recursive: true })
    }
  })

  it('masks a token in a session name, folder and branch', async () => {
    const t = setup()
    t.setRows([row({ branch: `fix/${TOKEN}`, cwd: `/work/${TOKEN}`, name: `Use ${TOKEN} now` })])
    const [session] = (await t.heimdall.call('demo', 'sessions.list', null)) as Record<
      string,
      unknown
    >[]
    expect(session).toMatchObject({ branch: 'fix/***', folder: '/work/***', name: 'Use *** now' })
    expect(JSON.stringify(session)).not.toContain(TOKEN)
  })

  it('gives a PR link only when it starts with https://', async () => {
    const t = setup({
      sessions: { pr: async () => ({ ...PR, url: 'javascript:alert(1)' }), rows: () => [row()] },
    })
    const [session] = (await t.heimdall.call('demo', 'sessions.list', null)) as Record<
      string,
      unknown
    >[]
    expect(session?.prUrl).toBe(null)
  })

  it('runs at most 4 PR lookups at the same time', async () => {
    const waits: Deferred<PrInfo>[] = []
    let running = 0
    let most = 0
    const t = setup({
      sessions: {
        pr: async () => {
          running += 1
          most = Math.max(most, running)
          const d = deferred<PrInfo>()
          waits.push(d)
          const info = await d.promise
          running -= 1
          return info
        },
        rows: () => Array.from({ length: 10 }, (_, i) => row({ cwd: `/work/${i}` })),
      },
    })
    expect(PR_LOOKUPS).toBe(4)
    const call = t.heimdall.call('demo', 'sessions.list', null)
    for (let done = 0; done < 10; done++) {
      await new Promise(r => setTimeout(r, 0))
      waits[done]?.resolve(PR)
    }
    const list = (await call) as unknown[]
    expect(list).toHaveLength(10)
    expect(waits).toHaveLength(10)
    expect(most).toBe(PR_LOOKUPS)
  })

  it('looks up a PR again only 5 minutes after an unavailable result', async () => {
    const asked: string[] = []
    const t = setup({
      sessions: {
        pr: async r => {
          asked.push(r.cwd)
          return r.cwd === '/work/down' ? { kind: 'unavailable', reason: 'gh failed' } : PR
        },
        rows: () => [row({ cwd: '/work/down' }), row({ cwd: '/work/up' })],
      },
    })
    expect(PR_RETRY_MS).toBe(5 * 60_000)
    await t.heimdall.call('demo', 'sessions.list', null)
    t.tick(60_000)
    const list = (await t.heimdall.call('demo', 'sessions.list', null)) as Record<string, unknown>[]
    expect(list.map(s => s.prUrl)).toEqual([null, 'https://github.com/acme/app/pull/7'])
    expect(asked).toEqual(['/work/down', '/work/up', '/work/up'])
    t.tick(PR_RETRY_MS)
    await t.heimdall.call('demo', 'sessions.list', null)
    expect(asked.filter(c => c === '/work/down')).toHaveLength(2)
  })

  it('gives the usage of the account when it is new, else of the sessions', async () => {
    const t = setup()
    await expect(t.heimdall.call('demo', 'usage.get', null)).resolves.toBe(null)
    const limits = { fiveHour: { resetsAt: 9, usedPercent: 40 } }
    t.setUsage({
      account: {
        fetchedAt: 1_000_000 - 60_000,
        limits: { sevenDay: { resetsAt: 8, usedPercent: 10 } },
      },
      snapshot: { limits, name: `S ${TOKEN}`, sessionId: 's', updatedAt: 7 },
    })
    await expect(t.heimdall.call('demo', 'usage.get', null)).resolves.toEqual({
      fiveHour: null,
      sevenDay: { resetsAt: 8, usedPercent: 10 },
      source: 'account',
      updatedAt: 940_000,
    })
    t.tick(15 * 60_000)
    await expect(t.heimdall.call('demo', 'usage.get', null)).resolves.toEqual({
      fiveHour: { resetsAt: 9, usedPercent: 40 },
      sevenDay: null,
      source: 'session',
      updatedAt: 7,
    })
  })

  it('gives the service status with only the public fields', async () => {
    const t = setup()
    await expect(t.heimdall.call('demo', 'serviceStatus.get', null)).resolves.toEqual([
      {
        checkedAt: 5,
        id: 'claude',
        incidents: [{ impact: 'minor', name: 'Slow API', startedAt: 3, status: 'monitoring' }],
        level: 'minor',
        name: 'Claude',
        since: 3,
      },
    ])
  })

  it('masks a token in the input and the result of a module job', async () => {
    const got: unknown[] = []
    const t = setup({
      jobs: {
        run: async (moduleId, req) => {
          got.push({ moduleId, req })
          return { text: `result ${TOKEN}` }
        },
      },
    })
    await expect(
      t.heimdall.call('demo', 'claude.job', { input: `in ${TOKEN}`, prompt: 'Sum it' }),
    ).resolves.toEqual({ text: 'result ***' })
    expect(got).toEqual([{ moduleId: 'demo', req: { input: 'in ***', prompt: 'Sum it' } }])
  })

  it('gives the request of Discuss with Claude to its part, with the module id', async () => {
    const got: unknown[] = []
    const t = setup({
      discuss: {
        request: async (moduleId, req) => {
          got.push({ moduleId, req })
          return { opened: true }
        },
      },
    })
    await expect(t.heimdall.call('demo', 'discuss.request', { title: 'Talk' })).resolves.toEqual({
      opened: true,
    })
    expect(got).toEqual([{ moduleId: 'demo', req: { title: 'Talk' } }])
  })

  it('gives the friendly code, not the error text, when a part fails', async () => {
    const t = setup({
      serviceStatus: () => {
        throw new Error(`secret path /Users/x and ${TOKEN}`)
      },
    })
    await expect(t.heimdall.call('demo', 'serviceStatus.get', null)).rejects.toThrow(
      new Error(FAILED),
    )
    // The error goes to the log of the main process only.
    expect(t.logs).toHaveLength(1)
    expect(t.logs[0]).toContain('serviceStatus.get')
    expect(t.logs[0]).not.toContain(TOKEN)
  })

  it('keeps the refusal code of a part', async () => {
    const t = setup({
      jobs: {
        run: async () => {
          throw new Error('refused: daily job cap reached')
        },
      },
    })
    await expect(t.heimdall.call('demo', 'claude.job', { prompt: 'Hi' })).rejects.toThrow(
      'refused: daily job cap reached',
    )
  })

  it('masks a token in the refusal text of a part', async () => {
    const t = setup({
      jobs: {
        run: async () => {
          throw new Error(`refused: bad token ${TOKEN}`)
        },
      },
    })
    await expect(t.heimdall.call('demo', 'claude.job', { prompt: 'Hi' })).rejects.toThrow(
      new Error('refused: bad token ***'),
    )
  })
})

describe('events', () => {
  it('sends an event to a module that is on, with the data masked', () => {
    const t = setup()
    t.heimdall.event('demo', 'refresh', { note: `x ${TOKEN}` })
    expect(t.events).toEqual([{ data: { note: 'x ***' }, event: 'refresh', moduleId: 'demo' }])
  })

  it('sends no event to a module that is off or gone, and no event with a bad name', () => {
    const t = setup()
    t.state.modules.off = entry('off', ALL, { enabled: false })
    t.heimdall.event('off', 'refresh', null)
    t.heimdall.event('gone', 'refresh', null)
    t.heimdall.event('demo', 'Bad Name', null)
    t.heimdall.event('demo', '', null)
    expect(t.events).toEqual([])
  })

  it('sends no event with data larger than 256 KB', () => {
    const t = setup()
    t.heimdall.event('demo', 'refresh', 'x'.repeat(MODULE_MESSAGE_BYTES))
    expect(t.events).toEqual([])
  })
})
