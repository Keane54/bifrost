import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import type { AgentEntry, AgentList } from '../../../src/main/claude/agents'
import type { LiveEvent, LiveUsage } from '../../../src/main/live/live-event'
import { type RegistryStore, SessionRegistry } from '../../../src/main/registry/registry'
import {
  RegistryService,
  SERVICE_TIMING,
  type ServiceDeps,
} from '../../../src/main/registry/service'
import { parseProcessTable } from '../../../src/main/registry/terminal-app'
import type { SessionRow, UsageSnapshot } from '../../../src/shared/types'

const START = 1_000_000

const bg = (o: Partial<AgentEntry> = {}): AgentEntry => ({
  cwd: '/p',
  id: 'aa',
  kind: 'background',
  name: 'alpha',
  pid: 5,
  sessionId: 's1',
  startedAt: 1,
  status: 'idle',
  ...o,
})

// Resolve with the value after ms of fake time.
const resolveLater = <T>(ms: number, value: T): Promise<T> =>
  new Promise(resolve => setTimeout(() => resolve(value), ms))

const empty = (): AgentList => ({ entries: [] })

function fakeDeps(o: Partial<ServiceDeps> = {}): ServiceDeps {
  return {
    listActive: vi.fn(async () => empty()),
    listAll: vi.fn(async () => empty()),
    now: () => Date.now(),
    readBranch: vi.fn(async () => 'main'),
    readProcessTable: vi.fn(async () => null),
    saveStore: vi.fn(async () => {}),
    ...o,
  }
}

const newRegistry = (
  store: RegistryStore = { lastActive: [], names: {}, priorities: {}, started: [], watch: [] },
) => new SessionRegistry({ escalationMs: 600_000, store })

interface Update {
  at: number
  rows: SessionRow[]
  error: string | null
}

let current: RegistryService | undefined

function startService(deps: ServiceDeps, registry = newRegistry(), timing = SERVICE_TIMING) {
  const updates: Update[] = []
  const service = new RegistryService(registry, deps, timing)
  current = service
  service.onUpdate((rows, error) => updates.push({ at: Date.now(), error, rows }))
  service.start()
  return { registry, service, updates }
}

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(START)
})

afterEach(() => {
  current?.stop()
  current = undefined
  vi.useRealTimers()
})

describe('brief', () => {
  test('the active poll runs every 2 s and never overlaps', async () => {
    let running = 0
    let most = 0
    const listActive = vi.fn(async () => {
      running += 1
      most = Math.max(most, running)
      await resolveLater(3000, null)
      running -= 1
      return empty()
    })
    startService(fakeDeps({ listActive }))
    await vi.advanceTimersByTimeAsync(7000)
    expect(listActive).toHaveBeenCalledTimes(2)
    expect(most).toBe(1)
  })

  test('the --all poll runs every 30 s', async () => {
    const deps = fakeDeps()
    startService(deps)
    await vi.advanceTimersByTimeAsync(60_000)
    const calls = vi.mocked(deps.listAll).mock.calls.length
    expect(calls).toBeGreaterThanOrEqual(2)
    expect(calls).toBeLessThanOrEqual(3)
  })

  // Changed for Task 4: the usage lines of the mod give the changes.
  test('updates are at most 4 each second', async () => {
    const deps = fakeDeps({ listActive: async () => ({ entries: [bg()] }) })
    const { service, updates } = startService(deps)
    // The first rows go out. The data does not change for 1000 ms, so the gap ends.
    await vi.advanceTimersByTimeAsync(1000)
    updates.length = 0
    // 10 data changes in 1000 ms.
    for (let i = 1; i <= 10; i++) {
      service.pushLive({ at: Date.now(), sessionId: 's1', type: 'usage', usage: { costUsd: i } })
      await vi.advanceTimersByTimeAsync(100)
    }
    await vi.advanceTimersByTimeAsync(SERVICE_TIMING.minUpdateGapMs)
    expect(updates.length).toBeGreaterThanOrEqual(4)
    expect(updates.length).toBeLessThanOrEqual(5)
    expect(updates.at(-1)?.rows[0].costUsd).toBe(10)
    for (let i = 1; i < updates.length; i++) {
      expect(updates[i].at - updates[i - 1].at).toBeGreaterThanOrEqual(
        SERVICE_TIMING.minUpdateGapMs,
      )
    }
  })

  test('a failed active poll sends the error and keeps the rows', async () => {
    const listActive = vi
      .fn<() => Promise<AgentList>>()
      .mockResolvedValueOnce({ entries: [bg()] })
      .mockResolvedValueOnce({ entries: [], error: 'boom' })
      .mockResolvedValueOnce({ entries: [], error: 'boom' })
      .mockResolvedValue({ entries: [bg()] })
    const registry = newRegistry()
    const apply = vi.spyOn(registry, 'applyAgents')
    const { service, updates } = startService(fakeDeps({ listActive }), registry)
    await vi.advanceTimersByTimeAsync(1000)
    expect(updates.at(-1)?.error).toBeNull()
    expect(updates.at(-1)?.rows.map(r => r.sessionId)).toEqual(['s1'])

    await vi.advanceTimersByTimeAsync(2000)
    expect(listActive).toHaveBeenCalledTimes(2)
    expect(apply).toHaveBeenCalledTimes(1)
    expect(updates.at(-1)?.error).toBe('boom')
    expect(updates.at(-1)?.rows.map(r => r.sessionId)).toEqual(['s1'])
    expect(service.rows().map(r => r.sessionId)).toEqual(['s1'])

    // Each failed poll sends the error again.
    const count = updates.length
    await vi.advanceTimersByTimeAsync(2000)
    expect(updates.length).toBe(count + 1)
    expect(updates.at(-1)?.error).toBe('boom')

    // The next good poll clears the error.
    await vi.advanceTimersByTimeAsync(2000)
    expect(updates.at(-1)?.error).toBeNull()
  })

  test('the branch is read one time for each cwd in each loop', async () => {
    const readBranch = vi.fn(async () => 'main')
    const deps = fakeDeps({
      listActive: async () => ({ entries: [bg(), bg({ id: 'bb', sessionId: 's2' })] }),
      readBranch,
    })
    const { service } = startService(deps)
    await vi.advanceTimersByTimeAsync(0)
    expect(readBranch).toHaveBeenCalledTimes(1)
    expect(readBranch).toHaveBeenCalledWith('/p')
    expect(service.rows().map(r => r.branch)).toEqual(['main', 'main'])
    await vi.advanceTimersByTimeAsync(SERVICE_TIMING.branchMs)
    expect(readBranch).toHaveBeenCalledTimes(2)
  })
})

describe('list polls', () => {
  test('the active poll and the --all poll never run at the same time', async () => {
    let running = 0
    let most = 0
    const slow = (ms: number) => async (): Promise<AgentList> => {
      running += 1
      most = Math.max(most, running)
      await resolveLater(ms, null)
      running -= 1
      return empty()
    }
    const deps = fakeDeps({ listActive: vi.fn(slow(1500)), listAll: vi.fn(slow(2500)) })
    startService(deps)
    await vi.advanceTimersByTimeAsync(120_000)
    expect(vi.mocked(deps.listAll).mock.calls.length).toBeGreaterThanOrEqual(3)
    expect(vi.mocked(deps.listActive).mock.calls.length).toBeGreaterThanOrEqual(20)
    expect(most).toBe(1)
  })

  test('the first --all poll runs only after the first active poll ends', async () => {
    const log: string[] = []
    const listActive = vi.fn(async () => {
      log.push('active start')
      await resolveLater(3000, null)
      log.push('active end')
      return empty()
    })
    const listAll = vi.fn(async () => {
      log.push('all')
      return empty()
    })
    startService(fakeDeps({ listActive, listAll }))
    await vi.advanceTimersByTimeAsync(2999)
    expect(listAll).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    expect(log).toEqual(['active start', 'active end', 'all'])
  })

  test('the sample time is the time just before listActive starts', async () => {
    const registry = newRegistry()
    const apply = vi.spyOn(registry, 'applyAgents')
    const deps = fakeDeps({
      // The first --all poll takes 5 s. The second active poll waits for it.
      listActive: vi.fn(async () => resolveLater(1000, { entries: [bg()] })),
      listAll: vi.fn(async () => resolveLater(5000, empty())),
    })
    startService(deps, registry)
    await vi.advanceTimersByTimeAsync(1000)
    expect(apply).toHaveBeenLastCalledWith([bg()], START)
    // The second active poll starts at 6000 ms, after the --all poll ends.
    await vi.advanceTimersByTimeAsync(6000)
    expect(apply).toHaveBeenCalledTimes(2)
    expect(apply).toHaveBeenLastCalledWith([bg()], START + 6000)
  })

  test('a failed --all poll keeps the last --all list', async () => {
    const parked = bg({ id: 'p7', pid: undefined, sessionId: 's7', status: '' })
    const listAll = vi
      .fn<() => Promise<AgentList>>()
      .mockResolvedValueOnce({ entries: [parked] })
      .mockResolvedValue({ entries: [], error: 'boom' })
    const registry = newRegistry()
    const applyAll = vi.spyOn(registry, 'applyAllAgents')
    const { service } = startService(fakeDeps({ listAll }), registry)
    await vi.advanceTimersByTimeAsync(0)
    expect(service.rows()).toMatchObject([{ sessionId: 's7', state: 'parked' }])
    await vi.advanceTimersByTimeAsync(SERVICE_TIMING.allMs)
    expect(listAll).toHaveBeenCalledTimes(2)
    expect(applyAll).toHaveBeenCalledTimes(1)
    expect(service.rows()).toMatchObject([{ sessionId: 's7', state: 'parked' }])
  })

  test('a rejected listActive counts as a failed poll', async () => {
    const listActive = vi.fn(async (): Promise<AgentList> => {
      throw new Error('spawn failed')
    })
    const { updates } = startService(fakeDeps({ listActive }))
    // The first update comes after the first active poll. It has the error.
    await vi.advanceTimersByTimeAsync(0)
    expect(updates).toHaveLength(1)
    expect(updates[0]).toMatchObject({ error: 'spawn failed', rows: [] })
    await vi.advanceTimersByTimeAsync(SERVICE_TIMING.activeMs)
    expect(listActive).toHaveBeenCalledTimes(2)
  })

  // Changed for Task 4: a usage line before the first poll gives the model.
  test('the first update holds the rows of the first active poll', async () => {
    const deps = fakeDeps({
      listActive: vi.fn(async () => resolveLater(1000, { entries: [bg()] })),
    })
    const { service, updates } = startService(deps)
    const usage = { model: 'claude-opus-5-5' }
    service.pushLive({ at: START, sessionId: 's1', type: 'usage', usage })
    await vi.advanceTimersByTimeAsync(999)
    expect(updates).toEqual([])
    await vi.advanceTimersByTimeAsync(1)
    expect(updates).toHaveLength(1)
    expect(updates[0].rows).toMatchObject([{ model: 'Opus 5.5', sessionId: 's1' }])
  })

  test('the tick loop starts after the first active poll', async () => {
    const registry = newRegistry()
    const tick = vi.spyOn(registry, 'tick')
    const listActive = vi.fn(async () => resolveLater(3000, empty()))
    startService(fakeDeps({ listActive }), registry)
    await vi.advanceTimersByTimeAsync(2999)
    expect(tick).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    expect(tick).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(SERVICE_TIMING.tickMs)
    expect(tick).toHaveBeenCalledTimes(2)
  })

  test('setActiveInterval changes the wait before the next active poll', async () => {
    // Each active poll takes 1000 ms. The interval is 2000 ms at the start.
    const listActive = vi.fn(async () => resolveLater(1000, empty()))
    const { service } = startService(fakeDeps({ listActive }))
    // The first poll runs. It ends normally at 1000 ms.
    await vi.advanceTimersByTimeAsync(500)
    expect(listActive).toHaveBeenCalledTimes(1)
    service.setActiveInterval(5000)
    // The second poll starts 5000 ms after the end of the first, at 6000 ms, not at 3000 ms.
    await vi.advanceTimersByTimeAsync(5499)
    expect(listActive).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(listActive).toHaveBeenCalledTimes(2)
    // A shorter interval applies to the wait after the poll that runs now.
    service.setActiveInterval(1000)
    await vi.advanceTimersByTimeAsync(1999)
    expect(listActive).toHaveBeenCalledTimes(2)
    await vi.advanceTimersByTimeAsync(1)
    expect(listActive).toHaveBeenCalledTimes(3)
  })
})

describe('updates and the store', () => {
  test('no update goes out when the rows did not change', async () => {
    const deps = fakeDeps({ listActive: async () => ({ entries: [bg()] }) })
    const { updates } = startService(deps)
    await vi.advanceTimersByTimeAsync(1000)
    const count = updates.length
    await vi.advanceTimersByTimeAsync(20_000)
    expect(updates.length).toBe(count)
  })

  // Changed for Task 4: the Stop event comes from the mod.
  test('acknowledge stops the flash and sends an update', async () => {
    const deps = fakeDeps({ listActive: async () => ({ entries: [bg()] }) })
    const { service, updates } = startService(deps)
    service.pushLive({ event: { at: START, name: 'Stop', sessionId: 's1' }, type: 'state' })
    await vi.advanceTimersByTimeAsync(1000)
    expect(updates.at(-1)?.rows[0]).toMatchObject({ box: 'yellow', flashing: true })
    service.acknowledge('s1')
    expect(updates.at(-1)?.rows[0]).toMatchObject({ box: 'yellow', flashing: false })
  })

  test('setPriority sends an update and saves the store', async () => {
    const saveStore = vi.fn(async () => {})
    const { service, updates } = startService(
      fakeDeps({ listActive: async () => ({ entries: [bg()] }), saveStore }),
    )
    await vi.advanceTimersByTimeAsync(1000)
    saveStore.mockClear()
    expect(service.setPriority('s1', 2)).toBe(true)
    expect(updates.at(-1)?.rows[0].priority).toBe(2)
    await vi.advanceTimersByTimeAsync(0)
    expect(saveStore).toHaveBeenCalledWith(expect.objectContaining({ priorities: { s1: 2 } }))
    expect(service.setPriority('nope', 2)).toBe(false)
  })

  test('rememberWorktree sends an update and saves the store', async () => {
    const saveStore = vi.fn(async () => {})
    const WT = '/r/.claude/worktrees/fix-a'
    const { service, updates } = startService(
      fakeDeps({ listActive: async () => ({ entries: [bg()] }), saveStore }),
    )
    await vi.advanceTimersByTimeAsync(1000)
    saveStore.mockClear()
    expect(service.rememberWorktree('s1', WT)).toBe(true)
    expect(updates.at(-1)?.rows[0].worktree).toBe(WT)
    await vi.advanceTimersByTimeAsync(0)
    expect(saveStore).toHaveBeenCalledWith(
      expect.objectContaining({ worktrees: [{ path: WT, sessionId: 's1' }] }),
    )
    expect(service.rememberWorktree('nope', WT)).toBe(false)
  })

  test('the watch changes send an update and save the store', async () => {
    const saveStore = vi.fn(async () => {})
    const entries = [bg(), bg({ id: 'bb', name: 'beta', pid: 6, sessionId: 's2' })]
    const { service, updates } = startService(
      fakeDeps({ listActive: async () => ({ entries }), saveStore }),
    )
    await vi.advanceTimersByTimeAsync(1000)
    const watchOf = () => saveStore.mock.calls.at(-1)?.[0].watch
    const rowWatch = (id: string) => updates.at(-1)?.rows.find(r => r.sessionId === id)?.watch

    saveStore.mockClear()
    expect(service.watchAdd('s1', 'dark-blue')).toBe(true)
    expect(service.watchAdd('s2', 'green')).toBe(true)
    await vi.advanceTimersByTimeAsync(300)
    expect(rowWatch('s1')).toEqual({ colour: 'dark-blue', order: 0 })
    expect(rowWatch('s2')).toEqual({ colour: 'green', order: 1 })
    await vi.advanceTimersByTimeAsync(0)
    expect(watchOf()).toEqual([
      { colour: 'dark-blue', sessionId: 's1' },
      { colour: 'green', sessionId: 's2' },
    ])

    saveStore.mockClear()
    expect(service.watchColour('s1', 'red')).toBe(true)
    await vi.advanceTimersByTimeAsync(300)
    expect(rowWatch('s1')?.colour).toBe('red')
    await vi.advanceTimersByTimeAsync(0)
    expect(watchOf()?.[0]).toEqual({ colour: 'red', sessionId: 's1' })

    saveStore.mockClear()
    expect(service.watchMove('s2', 's1')).toBe(true)
    await vi.advanceTimersByTimeAsync(300)
    expect(rowWatch('s2')?.order).toBe(0)
    expect(rowWatch('s1')?.order).toBe(1)
    await vi.advanceTimersByTimeAsync(0)
    expect(watchOf()?.map(w => w.sessionId)).toEqual(['s2', 's1'])

    saveStore.mockClear()
    expect(service.watchRemove('s2')).toBe(true)
    await vi.advanceTimersByTimeAsync(300)
    expect(rowWatch('s2')).toBeUndefined()
    await vi.advanceTimersByTimeAsync(0)
    expect(watchOf()).toEqual([{ colour: 'red', sessionId: 's1' }])

    saveStore.mockClear()
    expect(service.watchAdd('nope', 'dark-blue')).toBe(false)
    expect(service.watchRemove('nope')).toBe(false)
    expect(service.watchColour('nope', 'dark-blue')).toBe(false)
    expect(service.watchMove('nope', null)).toBe(false)
    await vi.advanceTimersByTimeAsync(0)
    expect(saveStore).not.toHaveBeenCalled()
  })

  test('the service saves the store after a change to the store', async () => {
    const saveStore = vi.fn(async () => {})
    startService(fakeDeps({ listActive: async () => ({ entries: [bg()] }), saveStore }))
    await vi.advanceTimersByTimeAsync(0)
    expect(saveStore).toHaveBeenCalledTimes(1)
    expect(saveStore).toHaveBeenCalledWith({
      lastActive: ['s1'],
      names: { s1: 'alpha' },
      priorities: {},
      started: [],
      watch: [],
      worktrees: [],
    })
    await vi.advanceTimersByTimeAsync(10_000)
    expect(saveStore).toHaveBeenCalledTimes(1)
  })

  test('a failed save is logged and the next loop saves again', async () => {
    const error = vi.spyOn(console, 'error').mockImplementation(() => {})
    const saveStore = vi
      .fn<ServiceDeps['saveStore']>()
      .mockRejectedValueOnce(new Error('disk full'))
      .mockResolvedValue(undefined)
    startService(fakeDeps({ listActive: async () => ({ entries: [bg()] }), saveStore }))
    await vi.advanceTimersByTimeAsync(0)
    expect(saveStore.mock.calls.length).toBeGreaterThanOrEqual(1)
    expect(error).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(SERVICE_TIMING.tickMs)
    expect(saveStore).toHaveBeenCalledTimes(2)
    expect(saveStore).toHaveBeenLastCalledWith({
      lastActive: ['s1'],
      names: { s1: 'alpha' },
      priorities: {},
      started: [],
      watch: [],
      worktrees: [],
    })
    await vi.advanceTimersByTimeAsync(10_000)
    expect(saveStore).toHaveBeenCalledTimes(2)
    expect(error).toHaveBeenCalledTimes(1)
    error.mockRestore()
  })

  test('a store change during a save goes out in the next save', async () => {
    const saveStore = vi.fn(async () => resolveLater(3000, undefined))
    const listActive = vi
      .fn<() => Promise<AgentList>>()
      .mockResolvedValueOnce({ entries: [bg()] })
      .mockResolvedValue({ entries: [bg({ name: 'beta' })] })
    // No other loop calls for a save at 3000 ms. The next active poll is at 4000 ms.
    const timing = { ...SERVICE_TIMING, tickMs: 60_000 }
    startService(fakeDeps({ listActive, saveStore }), newRegistry(), timing)
    // The first save runs from 0 ms to 3000 ms. The name changes at 2000 ms.
    await vi.advanceTimersByTimeAsync(2999)
    expect(saveStore).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(saveStore).toHaveBeenCalledTimes(2)
    expect(saveStore).toHaveBeenLastCalledWith({
      lastActive: ['s1'],
      names: { s1: 'beta' },
      priorities: {},
      started: [],
      watch: [],
      worktrees: [],
    })
  })

  test('stop clears every timer and ignores the results that come later', async () => {
    const registry = newRegistry()
    const apply = vi.spyOn(registry, 'applyAgents')
    const listActive = vi.fn(async () => resolveLater(3000, { entries: [bg()] }))
    const { service, updates } = startService(fakeDeps({ listActive }), registry)
    await vi.advanceTimersByTimeAsync(1000)
    const count = updates.length
    service.stop()
    await vi.advanceTimersByTimeAsync(60_000)
    expect(vi.getTimerCount()).toBe(0)
    expect(listActive).toHaveBeenCalledTimes(1)
    expect(apply).not.toHaveBeenCalled()
    expect(updates.length).toBe(count)
  })
})

describe('M4 registry service', () => {
  const ext = (): AgentEntry =>
    bg({ id: undefined, kind: 'interactive', name: '', pid: 931, sessionId: 'e1' })

  test('waitForRow resolves with the first matching row', async () => {
    const listActive = vi
      .fn<() => Promise<AgentList>>()
      .mockResolvedValueOnce({ entries: [] })
      .mockResolvedValue({ entries: [bg()] })
    const { service } = startService(fakeDeps({ listActive }))
    await vi.advanceTimersByTimeAsync(0)
    const wait = service.waitForRow(row => row.sessionId === 's1', 10_000)
    await vi.advanceTimersByTimeAsync(2000)
    expect((await wait).sessionId).toBe('s1')
  })

  test('waitForRow rejects with timeout', async () => {
    const { service } = startService(fakeDeps())
    const wait = service.waitForRow(() => false, 500)
    const caught = wait.catch((e: Error) => e.message)
    await vi.advanceTimersByTimeAsync(500)
    expect(await caught).toBe('timeout')
  })

  test('waitForRow rejects when the service stops', async () => {
    const { service } = startService(fakeDeps())
    const caught = service.waitForRow(() => false, 10_000).catch((e: Error) => e.message)
    service.stop()
    expect(await caught).toBe('stopped')
  })

  test('the service reads the process table one time for a new external PID', async () => {
    const readProcessTable = vi.fn(async () =>
      parseProcessTable('931 866 -zsh\n866 1 /Applications/Warp.app/Contents/MacOS/stable'),
    )
    const deps = fakeDeps({ listActive: async () => ({ entries: [ext()] }), readProcessTable })
    const { service } = startService(deps)
    await vi.advanceTimersByTimeAsync(5000)
    expect(readProcessTable).toHaveBeenCalledTimes(1)
    expect(service.rows()[0].terminalApp).toBe('Warp')
    expect(service.terminalOf('e1')?.bundle).toBe('/Applications/Warp.app')
  })

  test('forget, markStarted and markStopped save the store and send an update', async () => {
    const saveStore = vi.fn(async () => {})
    const { service, updates } = startService(
      fakeDeps({ listActive: async () => ({ entries: [bg()] }), saveStore }),
    )
    await vi.advanceTimersByTimeAsync(1000)
    saveStore.mockClear()
    service.markStarted('s1')
    await vi.advanceTimersByTimeAsync(300)
    expect(saveStore.mock.calls.at(-1)?.[0]).toMatchObject({ started: ['s1'] })
    service.markStopped('s1')
    await vi.advanceTimersByTimeAsync(300)
    expect(saveStore.mock.calls.at(-1)?.[0]).toMatchObject({ lastActive: [] })
    const count = updates.length
    service.forget('s1')
    await vi.advanceTimersByTimeAsync(300)
    expect(saveStore.mock.calls.at(-1)?.[0]).toMatchObject({ started: [] })
    expect(updates.length).toBeGreaterThan(count)
    expect(updates.at(-1)?.rows).toEqual([])
  })
})

describe('a session that is gone (Task 17 bug 3)', () => {
  // Another parked session, so that the --all list is not empty.
  const other = bg({ id: 'bb', pid: undefined, sessionId: 'o1', status: '' })
  // s9 is a started session that claude rm in a terminal removed.
  const withGone = () =>
    newRegistry({
      lastActive: [],
      names: { s9: 'nine' },
      priorities: {},
      started: ['s9'],
      watch: [],
    })
  const ids = (service: RegistryService) => service.rows().map(row => row.sessionId)
  const listAllOf = (...lists: (AgentList | Error)[]) => {
    const fn = vi.fn<() => Promise<AgentList>>()
    for (const list of lists) {
      if (list instanceof Error) fn.mockRejectedValueOnce(list)
      else fn.mockResolvedValueOnce(list)
    }
    return fn
  }

  test('a failed --all read between two good reads does not count', async () => {
    const failed = { entries: [], error: 'Command failed: claude agents --json --all' }
    const listAll = listAllOf({ entries: [other] }, failed, { entries: [other] })
    const saveStore = vi.fn(async (_store: RegistryStore) => {})
    const { service } = startService(fakeDeps({ listAll, saveStore }), withGone())
    await vi.advanceTimersByTimeAsync(0)
    expect(ids(service)).toContain('s9')
    await vi.advanceTimersByTimeAsync(SERVICE_TIMING.allMs)
    expect(listAll).toHaveBeenCalledTimes(2)
    expect(ids(service)).toContain('s9')
    await vi.advanceTimersByTimeAsync(SERVICE_TIMING.allMs)
    expect(listAll).toHaveBeenCalledTimes(3)
    expect(ids(service)).toEqual(['o1'])
    const saved = saveStore.mock.calls.at(-1)?.[0]
    expect(saved?.started).toEqual([])
    expect(saved?.names).not.toHaveProperty('s9')
  })

  test('failed and rejected --all reads never forget', async () => {
    const failed = { entries: [], error: 'boom' }
    const listAll = listAllOf(
      { entries: [other] },
      failed,
      new Error('spawn failed'),
      failed,
      new Error('spawn failed'),
    )
    const { service } = startService(fakeDeps({ listAll }), withGone())
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(4 * SERVICE_TIMING.allMs)
    expect(listAll).toHaveBeenCalledTimes(5)
    expect(ids(service)).toContain('s9')
  })

  test('a partial --all list never forgets', async () => {
    const partial: AgentList = { entries: [other], partial: true }
    const listAll = listAllOf({ entries: [other] }, partial, partial, partial)
    const { service } = startService(fakeDeps({ listAll }), withGone())
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(3 * SERVICE_TIMING.allMs)
    expect(listAll).toHaveBeenCalledTimes(4)
    expect(ids(service)).toContain('s9')
  })

  test('a --all list that comes after the stop does not forget', async () => {
    const late = vi.fn<() => Promise<AgentList>>()
    late.mockResolvedValueOnce({ entries: [other] })
    late.mockImplementationOnce(() => resolveLater(1000, { entries: [other] }))
    const { service } = startService(fakeDeps({ listAll: late }), withGone())
    await vi.advanceTimersByTimeAsync(0)
    await vi.advanceTimersByTimeAsync(SERVICE_TIMING.allMs)
    expect(late).toHaveBeenCalledTimes(2)
    service.stop()
    await vi.advanceTimersByTimeAsync(1000)
    expect(ids(service)).toContain('s9')
  })
})

describe('live lines (Task 4)', () => {
  const ready = async () => {
    const deps = fakeDeps({ listActive: async () => ({ entries: [bg()] }) })
    const started = startService(deps)
    // The first poll ends and the update gap ends.
    await vi.advanceTimersByTimeAsync(1000)
    return started
  }

  test('pushLive applies a state event and sends an update', async () => {
    const { service, updates } = await ready()
    expect(updates.at(-1)?.rows[0]).toMatchObject({ box: 'none' })
    const count = updates.length
    service.pushLive({ event: { at: Date.now(), name: 'Stop', sessionId: 's1' }, type: 'state' })
    expect(updates.length).toBe(count + 1)
    expect(updates.at(-1)?.rows[0]).toMatchObject({ box: 'yellow', flashing: true, live: true })
    expect(service.liveCount()).toBe(1)
  })

  test('pushLive applies a usage line', async () => {
    const { service, updates } = await ready()
    service.pushLive({ at: Date.now(), sessionId: 's1', type: 'usage', usage: { costUsd: 0.42 } })
    expect(updates.at(-1)?.rows[0]).toMatchObject({ costUsd: 0.42, live: true })
    expect(updates.at(-1)?.rows[0].lastActivity).toBe(1)
  })

  test('onEvents gets each live state event and no usage line', async () => {
    const { service } = await ready()
    const calls: unknown[] = []
    service.onEvents(events => calls.push(events))
    const stop = { at: Date.now(), name: 'Stop' as const, sessionId: 's1' }
    service.pushLive({ event: stop, type: 'state' })
    service.pushLive({ at: Date.now(), sessionId: 's1', type: 'usage', usage: { costUsd: 0.42 } })
    // A session that is not a row yet also gives its event.
    const other = { at: Date.now(), name: 'UserPromptSubmit' as const, sessionId: 'new' }
    service.pushLive({ event: other, type: 'state' })
    expect(calls).toEqual([[stop], [other]])
  })

  test('clearLive ends the live flags and sends an update', async () => {
    const { service, updates } = await ready()
    service.pushLive({ at: Date.now(), sessionId: 's1', type: 'usage', usage: { costUsd: 0.42 } })
    expect(service.liveCount()).toBe(1)
    const count = updates.length
    service.clearLive()
    expect(service.liveCount()).toBe(0)
    // The update limit of changed() applies. The next update has the change.
    await vi.advanceTimersByTimeAsync(SERVICE_TIMING.minUpdateGapMs)
    expect(updates.length).toBeGreaterThan(count)
    expect(updates.at(-1)?.rows[0]).not.toHaveProperty('live')
    expect(updates.at(-1)?.rows[0]).toMatchObject({ costUsd: 0.42 })
  })

  test('pushLive after stop changes nothing', async () => {
    const { service, updates } = await ready()
    const count = updates.length
    service.stop()
    service.pushLive({ at: Date.now(), sessionId: 's1', type: 'usage', usage: { costUsd: 0.42 } })
    expect(updates.length).toBe(count)
    expect(service.rows()[0]).not.toHaveProperty('costUsd')
  })

  test('the service has no event loop and no status loop', () => {
    expect(Object.keys(SERVICE_TIMING).sort()).toEqual([
      'activeMs',
      'allMs',
      'branchMs',
      'minUpdateGapMs',
      'tickMs',
    ])
  })
})

describe('the newest rate limits (M5b Task 1)', () => {
  const limits = { sevenDay: { resetsAt: 9_000_000, usedPercent: 15 } }
  const usageLine = (sessionId: string, at: number, usage: LiveUsage): LiveEvent => ({
    at,
    sessionId,
    type: 'usage',
    usage,
  })

  const ready = async () => {
    const deps = fakeDeps({ listActive: async () => ({ entries: [bg()] }) })
    const started = startService(deps)
    const usages: (UsageSnapshot | null)[] = []
    // The time of each onUsage call.
    const times: number[] = []
    started.service.onUsage(usage => {
      usages.push(usage)
      times.push(Date.now())
    })
    // The first poll ends and the update gap ends.
    await vi.advanceTimersByTimeAsync(1000)
    return { ...started, times, usages }
  }

  test('the service sends the usage when a line changes it', async () => {
    const { service, usages } = await ready()
    expect(service.usage()).toBeNull()
    service.pushLive(usageLine('s1', START, { rateLimits: limits }))
    expect(usages).toEqual([{ limits, name: 'alpha', sessionId: 's1', updatedAt: START }])
    expect(service.usage()).toEqual(usages[0])
    // The same line again changes nothing. A line without rate limits of another session also
    // changes nothing.
    service.pushLive(usageLine('s1', START, { rateLimits: limits }))
    service.pushLive(usageLine('s2', START + 10, { costUsd: 0.1 }))
    await vi.advanceTimersByTimeAsync(SERVICE_TIMING.minUpdateGapMs)
    expect(usages.length).toBe(1)
    // A newer line with the same limits changes the time.
    service.pushLive(usageLine('s1', START + 30_000, { rateLimits: limits }))
    expect(usages.length).toBe(2)
    expect(usages[1]).toMatchObject({ updatedAt: START + 30_000 })
  })

  test('the service sends the usage when it sends no rows', async () => {
    const { service, updates, usages } = await ready()
    const count = updates.length
    // A session that is not a row. Its line changes no row, so no update of the rows goes out.
    service.pushLive(usageLine('s2', Date.now(), { rateLimits: limits }))
    expect(updates.length).toBe(count)
    expect(usages).toEqual([{ limits, name: 's2', sessionId: 's2', updatedAt: Date.now() }])
  })

  test('forget sends null when it removes the newest rate limits', async () => {
    const { service, usages } = await ready()
    service.pushLive(usageLine('s1', START, { rateLimits: limits }))
    service.forget('s1')
    // The forget comes in the update gap. The end of the gap sends it.
    expect(usages.length).toBe(1)
    await vi.advanceTimersByTimeAsync(SERVICE_TIMING.minUpdateGapMs)
    expect(usages.at(-1)).toBeNull()
    expect(usages.length).toBe(2)
  })

  test('the service sends the usage at most 4 times each second, and the last value wins', async () => {
    const { service, times, usages } = await ready()
    const start = Date.now()
    // 20 lines in 1 s, each with a new value.
    for (let i = 0; i < 20; i++) {
      const sevenDay = { resetsAt: 9_000_000, usedPercent: i }
      service.pushLive(usageLine('s1', start + i * 50, { rateLimits: { sevenDay } }))
      await vi.advanceTimersByTimeAsync(50)
    }
    await vi.advanceTimersByTimeAsync(SERVICE_TIMING.minUpdateGapMs)
    expect(times.length).toBe(5)
    for (let k = 1; k < times.length; k++) {
      expect((times[k] ?? 0) - (times[k - 1] ?? 0)).toBeGreaterThanOrEqual(
        SERVICE_TIMING.minUpdateGapMs,
      )
    }
    expect(usages.at(-1)).toMatchObject({
      limits: { sevenDay: { usedPercent: 19 } },
      updatedAt: start + 19 * 50,
    })
  })

  test('the tick sends the usage when the row name changes it', async () => {
    let name = 'alpha'
    const deps = fakeDeps({ listActive: async () => ({ entries: [bg({ name })] }) })
    const { service } = startService(deps)
    const usages: (UsageSnapshot | null)[] = []
    service.onUsage(usage => usages.push(usage))
    await vi.advanceTimersByTimeAsync(1000)
    service.pushLive(usageLine('s1', START, { rateLimits: limits }))
    expect(usages.at(-1)).toMatchObject({ name: 'alpha' })
    name = 'beta'
    // The next active poll gives the new name. The tick after it sends the usage.
    await vi.advanceTimersByTimeAsync(SERVICE_TIMING.activeMs + SERVICE_TIMING.tickMs)
    expect(usages.at(-1)).toMatchObject({ name: 'beta' })
    expect(usages.length).toBe(2)
  })

  test('the service sends no usage after stop', async () => {
    const { service, usages } = await ready()
    service.pushLive(usageLine('s1', START, { rateLimits: limits }))
    expect(usages.length).toBe(1)
    service.stop()
    // forget removes the rate limits, but the service sends nothing after stop.
    service.forget('s1')
    service.pushLive(usageLine('s1', START + 1, { rateLimits: limits }))
    expect(usages.length).toBe(1)
  })
})
