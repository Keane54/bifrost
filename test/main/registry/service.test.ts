import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import type { AgentEntry, AgentList } from '../../../src/main/claude/agents'
import { type RegistryStore, SessionRegistry } from '../../../src/main/registry/registry'
import {
  RegistryService,
  SERVICE_TIMING,
  type ServiceDeps,
} from '../../../src/main/registry/service'
import type { StatusData } from '../../../src/main/registry/status-file'
import type { SessionRow } from '../../../src/shared/types'

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
    drainEvents: vi.fn(async () => ({ errors: 0, events: [] })),
    listActive: vi.fn(async () => empty()),
    listAll: vi.fn(async () => empty()),
    now: () => Date.now(),
    readBranch: vi.fn(async () => 'main'),
    readStatus: vi.fn(async () => new Map<string, StatusData>()),
    saveStore: vi.fn(async () => {}),
    ...o,
  }
}

const newRegistry = (store: RegistryStore = { names: {}, started: [] }) =>
  new SessionRegistry({ escalationMs: 600_000, store })

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

  test('updates are at most 4 each second', async () => {
    let cost = 0
    const deps = fakeDeps({
      listActive: async () => ({ entries: [bg()] }),
      readStatus: async () => new Map([['s1', { costUsd: cost, updatedAt: 1 }]]),
    })
    const { updates } = startService(deps, newRegistry(), { ...SERVICE_TIMING, statusMs: 100 })
    // The first rows go out. The data does not change for 1000 ms, so the gap ends.
    await vi.advanceTimersByTimeAsync(1000)
    updates.length = 0
    // 10 data changes in 1000 ms.
    for (let i = 1; i <= 10; i++) {
      cost = i
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
    // The first update opens a gap. The error goes out at the end of the gap.
    await vi.advanceTimersByTimeAsync(SERVICE_TIMING.minUpdateGapMs)
    expect(updates.at(-1)?.error).toBe('spawn failed')
    await vi.advanceTimersByTimeAsync(SERVICE_TIMING.activeMs)
    expect(listActive).toHaveBeenCalledTimes(2)
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

  test('hook events and the status files change the rows', async () => {
    const deps = fakeDeps({
      drainEvents: vi
        .fn<ServiceDeps['drainEvents']>()
        .mockResolvedValueOnce({ errors: 0, events: [] })
        .mockResolvedValueOnce({
          errors: 0,
          events: [{ at: START + 400, name: 'UserPromptSubmit', sessionId: 's1' }],
        })
        .mockResolvedValue({ errors: 0, events: [] }),
      listActive: async () => ({ entries: [bg({ status: 'busy' })] }),
      readStatus: async () => new Map([['s1', { model: 'Opus', updatedAt: 1 }]]),
    })
    const { updates } = startService(deps)
    await vi.advanceTimersByTimeAsync(1000)
    expect(updates.at(-1)?.rows[0]).toMatchObject({ model: 'Opus', state: 'working' })
    expect(updates.at(-1)?.rows[0].lastActivity).toBe(START + 400)
  })

  test('acknowledge stops the flash and sends an update', async () => {
    const deps = fakeDeps({
      drainEvents: vi
        .fn<ServiceDeps['drainEvents']>()
        .mockResolvedValueOnce({
          errors: 0,
          events: [{ at: START, name: 'Stop', sessionId: 's1' }],
        })
        .mockResolvedValue({ errors: 0, events: [] }),
      listActive: async () => ({ entries: [bg()] }),
    })
    const { service, updates } = startService(deps)
    await vi.advanceTimersByTimeAsync(1000)
    expect(updates.at(-1)?.rows[0]).toMatchObject({ box: 'yellow', flashing: true })
    service.acknowledge('s1')
    expect(updates.at(-1)?.rows[0]).toMatchObject({ box: 'yellow', flashing: false })
  })

  test('the service saves the store after a change to the store', async () => {
    const saveStore = vi.fn(async () => {})
    startService(fakeDeps({ listActive: async () => ({ entries: [bg()] }), saveStore }))
    await vi.advanceTimersByTimeAsync(0)
    expect(saveStore).toHaveBeenCalledTimes(1)
    expect(saveStore).toHaveBeenCalledWith({ names: { s1: 'alpha' }, started: [] })
    await vi.advanceTimersByTimeAsync(10_000)
    expect(saveStore).toHaveBeenCalledTimes(1)
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
