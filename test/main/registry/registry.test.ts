import { describe, expect, test } from 'vitest'
import type { AgentEntry } from '../../../src/main/claude/agents'
import type { HookEvent, HookEventName } from '../../../src/main/registry/hook-event'
import {
  PENDING_EVENT_MS,
  type RegistryStore,
  SessionRegistry,
} from '../../../src/main/registry/registry'

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

const ev = (name: HookEventName, sessionId: string, at: number): HookEvent => ({
  at,
  name,
  sessionId,
})

const registry = (store: RegistryStore = { names: {}, priorities: {}, started: [] }) =>
  new SessionRegistry({ escalationMs: 600_000, store })

describe('brief', () => {
  test('a background entry is an owned row', () => {
    const r = new SessionRegistry({
      escalationMs: 600_000,
      store: { names: {}, priorities: {}, started: [] },
    })
    r.applyAgents([bg()], 100)
    expect(r.rows()[0]).toMatchObject({
      kind: 'owned',
      name: 'alpha',
      sessionId: 's1',
      shortId: 'aa',
      state: 'idle',
    })
  })

  test('an entry without pid stays as a row', () => {
    const r = registry()
    r.applyAgents([bg({ pid: undefined, status: '' })], 100)
    const rows = r.rows()
    expect(rows).toHaveLength(1)
    expect(rows[0].pid).toBeUndefined()
  })

  test('an external session that ends goes away', () => {
    const r = registry()
    r.applyAgents([bg({ id: undefined, kind: 'interactive' })], 100)
    expect(r.rows()).toHaveLength(1)
    r.applyAgents([], 200)
    expect(r.rows()).toEqual([])
  })

  test('an owned session in --all is parked and keeps its stored name', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.applyAgents([], 200)
    r.applyAllAgents([bg({ name: '', pid: undefined, status: '' })])
    expect(r.rows()).toHaveLength(1)
    expect(r.rows()[0]).toMatchObject({ box: 'none', name: 'alpha', state: 'parked' })
  })

  test('a started session that is not active and not in --all is parked', () => {
    const r = registry({ names: { s9: 'nine' }, priorities: {}, started: [] })
    r.markStarted('s9')
    r.applyAgents([], 100)
    r.applyAllAgents([])
    expect(r.rows()).toHaveLength(1)
    expect(r.rows()[0]).toMatchObject({
      box: 'none',
      kind: 'owned',
      name: 'nine',
      sessionId: 's9',
      state: 'parked',
    })
  })

  test('a name equal to the short id is not stored', () => {
    const r = registry()
    r.applyAgents([bg({ name: 'aa' })], 100)
    expect(r.store().names).not.toHaveProperty('s1')
  })

  test('an event before the session shows is applied later, or dropped after 60 s', () => {
    const r = registry()
    r.applyEvents([ev('Stop', 's1', 10)], 10)
    expect(r.rows()).toEqual([])
    r.applyAgents([bg()], 20)
    expect(r.rows()[0].box).toBe('yellow')

    const other = registry()
    other.applyEvents([ev('Stop', 's2', 10)], 10)
    other.tick(70_011)
    other.applyAgents([bg({ sessionId: 's2' })], 70_012)
    expect(other.rows()[0].box).toBe('none')
  })

  test('a new status from the poll sets lastActivity to the sample time', () => {
    const r = registry()
    r.applyAgents([bg({ status: 'idle' })], 100)
    expect(r.rows()[0].lastActivity).toBe(1)
    r.applyAgents([bg({ status: 'busy' })], 200)
    expect(r.rows()[0].lastActivity).toBe(200)
    r.applyAgents([bg({ status: 'busy' })], 300)
    expect(r.rows()[0].lastActivity).toBe(200)
    r.applyAgents([bg({ status: 'idle' })], 400)
    expect(r.rows()[0].lastActivity).toBe(400)
  })

  test('a later hook event or status file still wins over an older status change', () => {
    const r = registry()
    r.applyAgents([bg({ status: 'idle' })], 100)
    r.applyAgents([bg({ status: 'busy' })], 200)
    r.applyEvents([ev('Stop', 's1', 250)], 250)
    expect(r.rows()[0].lastActivity).toBe(250)
  })

  test('status data and the branch go on the row', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.applyEvents([ev('Stop', 's1', 300)], 300)
    r.applyStatusFiles(
      new Map([['s1', { contextPercent: 42, costUsd: 1.5, model: 'Opus', updatedAt: 500 }]]),
    )
    r.applyBranch('/p', 'main')
    expect(r.rows()[0]).toMatchObject({
      branch: 'main',
      contextPercent: 42,
      costUsd: 1.5,
      lastActivity: 500,
      model: 'Opus',
    })
    r.applyEvents([ev('UserPromptSubmit', 's1', 900)], 900)
    expect(r.rows()[0].lastActivity).toBe(900)
    r.applyBranch('/p', null)
    expect(r.rows()[0].branch).toBeUndefined()
  })

  test('tick escalates and acknowledge stops the flash', () => {
    const r = registry()
    r.applyAgents([bg()], 0)
    r.applyEvents([ev('Stop', 's1', 0)], 0)
    r.tick(600_000)
    expect(r.rows()[0]).toMatchObject({ box: 'red', flashing: true })
    r.acknowledge('s1')
    expect(r.rows()[0]).toMatchObject({ box: 'red', flashing: false })
  })
})

describe('kind and leave rules', () => {
  test('all kinds other than background are external', () => {
    const r = registry()
    r.applyAgents(
      [bg({ kind: 'interactive' }), bg({ kind: '', sessionId: 's2' }), bg({ sessionId: 's3' })],
      100,
    )
    expect(r.rows().map(row => row.kind)).toEqual(['external', 'external', 'owned'])
  })

  test('an owned session that leaves the active list and is in --all is parked', () => {
    const r = registry()
    r.applyAllAgents([bg()])
    r.applyAgents([bg({ status: 'busy' })], 100)
    r.applyAgents([], 200)
    expect(r.rows()[0]).toMatchObject({ state: 'parked', status: '' })
    expect(r.rows()[0].pid).toBeUndefined()
  })

  test('an owned session that leaves the active list and is not in --all or started goes away', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    expect(r.rows()).toHaveLength(1)
    r.applyAgents([], 200)
    expect(r.rows()).toEqual([])
  })

  test('a parked session goes away when it leaves --all and Bifrost did not start it', () => {
    const r = registry()
    r.applyAllAgents([bg({ pid: undefined, status: '' })])
    expect(r.rows()).toHaveLength(1)
    r.applyAllAgents([])
    expect(r.rows()).toEqual([])
  })

  test('a parked session that shows in the active list again leaves the parked state', () => {
    // No hooks (Skip mode): only the session list can clear the parked state.
    const r = registry()
    r.markStarted('s1')
    r.applyAgents([], 100)
    expect(r.rows()[0].state).toBe('parked')
    r.applyAgents([bg({ status: 'busy' })], 200)
    expect(r.rows()[0]).toMatchObject({ pid: 5, state: 'working' })
  })

  test('a session that SessionEnd parked leaves the parked state in the next active list', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.applyEvents([ev('SessionEnd', 's1', 150)], 150)
    expect(r.rows()[0].state).toBe('parked')
    r.applyAgents([bg({ status: 'busy' })], 200)
    expect(r.rows()[0].state).toBe('working')
  })

  test('a parked session stays parked while its active entry has no pid', () => {
    // After a stop, the active list can show the entry without a pid for a short time.
    const r = registry()
    r.markStarted('s1')
    r.applyAgents([bg()], 100)
    r.applyEvents([ev('SessionEnd', 's1', 150)], 150)
    r.applyAgents([bg({ pid: undefined, status: '' })], 200)
    expect(r.rows()[0].state).toBe('parked')
    r.applyAgents([], 300)
    expect(r.rows()[0].state).toBe('parked')
    r.applyAgents([bg({ pid: undefined, status: '' })], 400)
    expect(r.rows()[0].state).toBe('parked')
    r.applyAgents([bg()], 500)
    expect(r.rows()[0]).toMatchObject({ pid: 5, state: 'idle' })
    r.applyAgents([bg({ status: 'busy' })], 600)
    expect(r.rows()[0].state).toBe('working')
  })

  test('a sample that started before a SessionEnd does not clear the parked state', () => {
    const r = registry()
    r.applyAgents([bg()], 1000)
    r.applyEvents([ev('SessionEnd', 's1', 2500)], 2500)
    r.applyAgents([bg()], 2000)
    expect(r.rows()[0].state).toBe('parked')
    r.applyAgents([bg()], 3000)
    expect(r.rows()[0].state).toBe('idle')
  })

  test('a sample that started before the list parked the session does not clear it', () => {
    const r = registry()
    r.markStarted('s1')
    r.applyAgents([], 2500)
    r.applyAgents([bg()], 2000)
    expect(r.rows()[0].state).toBe('parked')
    r.applyAgents([bg()], 3000)
    expect(r.rows()[0].state).toBe('idle')
  })

  test('an interactive entry in --all is not parked', () => {
    const ended = bg({
      id: undefined,
      kind: 'interactive',
      name: 'warp',
      pid: undefined,
      status: '',
    })
    const r = registry()
    r.applyAgents([{ ...ended, pid: 7, status: 'idle' }], 100)
    r.applyAgents([], 200)
    r.applyAllAgents([ended])
    expect(r.rows()).toEqual([])
  })
})

describe('names', () => {
  test('the name comes from the status file, then the short id, then the session id', () => {
    const r = registry()
    r.applyAgents(
      [
        bg({ name: '' }),
        bg({ id: 'bb', name: 'bb', sessionId: 's2' }),
        bg({ id: undefined, name: '', sessionId: 'abcdefghijkl' }),
      ],
      100,
    )
    r.applyStatusFiles(new Map([['s1', { sessionName: 'from-status', updatedAt: 50 }]]))
    const names = Object.fromEntries(r.rows().map(row => [row.sessionId, row.name]))
    expect(names).toEqual({ abcdefghijkl: 'abcdefgh', s1: 'from-status', s2: 'bb' })
  })

  test('the stored name comes before the status file name', () => {
    const r = registry({ names: { s1: 'stored' }, priorities: {}, started: [] })
    r.applyAgents([bg({ name: '' })], 100)
    r.applyStatusFiles(new Map([['s1', { sessionName: 'from-status', updatedAt: 50 }]]))
    expect(r.rows()[0].name).toBe('stored')
  })

  test('a new entry name replaces the stored name', () => {
    const r = registry({ names: { s1: 'old' }, priorities: {}, started: [] })
    r.applyAgents([bg({ name: 'new' })], 100)
    expect(r.rows()[0].name).toBe('new')
    expect(r.store().names).toEqual({ s1: 'new' })
  })

  test('an empty name is not stored', () => {
    const r = registry()
    r.applyAgents([bg({ name: '' })], 100)
    expect(r.rows()[0].name).toBe('aa')
    expect(r.store().names).toEqual({})
  })
})

describe('store', () => {
  test('storeChanged is true one time after a change', () => {
    const r = registry()
    expect(r.storeChanged()).toBe(false)
    r.applyAgents([bg()], 100)
    expect(r.storeChanged()).toBe(true)
    expect(r.storeChanged()).toBe(false)
    r.applyAgents([bg()], 200)
    expect(r.storeChanged()).toBe(false)
    r.markStarted('s1')
    expect(r.storeChanged()).toBe(true)
    r.markStarted('s1')
    expect(r.storeChanged()).toBe(false)
    expect(r.store()).toEqual({ names: { s1: 'alpha' }, priorities: {}, started: ['s1'] })
  })

  test('a name from --all goes into the store', () => {
    const r = registry()
    r.applyAllAgents([bg({ name: 'beta', pid: undefined, status: '' })])
    expect(r.storeChanged()).toBe(true)
    expect(r.store().names).toEqual({ s1: 'beta' })
  })

  test('applyAllAgents removes the name of a session that ended', () => {
    const r = registry()
    r.applyAgents([bg({ id: undefined, kind: 'interactive', name: 'warp' })], 100)
    expect(r.store().names).toEqual({ s1: 'warp' })
    expect(r.storeChanged()).toBe(true)
    r.applyAgents([], 200)
    expect(r.storeChanged()).toBe(false)
    r.applyAllAgents([])
    expect(r.store().names).toEqual({})
    expect(r.storeChanged()).toBe(true)
  })

  test('applyAllAgents keeps the names of active, --all and started sessions', () => {
    const r = registry({
      names: { s1: 'one', s2: 'two', s3: 'three' },
      priorities: {},
      started: ['s3'],
    })
    r.applyAgents([bg({ name: 'one' })], 100)
    r.applyAllAgents([bg({ name: '', pid: undefined, sessionId: 's2', status: '' })])
    expect(r.store().names).toEqual({ s1: 'one', s2: 'two', s3: 'three' })
    expect(r.storeChanged()).toBe(false)
  })

  test('applyAllAgents does not keep the name of an interactive entry', () => {
    const r = registry({ names: { s1: 'warp' }, priorities: {}, started: [] })
    r.applyAllAgents([bg({ kind: 'interactive', name: 'warp', pid: undefined, status: '' })])
    expect(r.store().names).toEqual({})
  })

  test('the caller cannot change the registry through the store or a row', () => {
    const input: RegistryStore = { names: { s1: 'alpha' }, priorities: {}, started: [] }
    const r = registry(input)
    input.names.s1 = 'changed'
    input.started.push('s7')
    const copy = r.store()
    copy.names.s1 = 'changed'
    copy.started.push('s8')
    expect(r.store()).toEqual({ names: { s1: 'alpha' }, priorities: {}, started: [] })

    r.applyAgents([bg({ name: '' })], 100)
    const row = r.rows()[0]
    row.name = 'changed'
    row.state = 'error'
    expect(r.rows()[0]).toMatchObject({ name: 'alpha', state: 'idle' })
    expect(r.rows()[0]).not.toBe(r.rows()[0])
  })
})

describe('rows', () => {
  test('rows are sorted by startedAt, then sessionId', () => {
    const r = registry()
    r.applyAgents(
      [
        bg({ sessionId: 'c', startedAt: 5 }),
        bg({ sessionId: 'b', startedAt: 9 }),
        bg({ sessionId: 'a', startedAt: 5 }),
      ],
      100,
    )
    expect(r.rows().map(row => row.sessionId)).toEqual(['a', 'c', 'b'])
  })

  test('a row has the entry fields and the machine fields', () => {
    const r = registry()
    r.applyAgents([bg({ status: 'waiting', waitingFor: 'permission prompt' })], 100)
    expect(r.rows()[0]).toEqual({
      box: 'red',
      boxReason: 'prompt',
      boxSince: 100,
      cwd: '/p',
      flashing: true,
      kind: 'owned',
      lastActivity: 1,
      name: 'alpha',
      pid: 5,
      sessionId: 's1',
      shortId: 'aa',
      startedAt: 1,
      state: 'needs-you',
      status: 'waiting',
      waitingFor: 'permission prompt',
    })
  })

  test('a red row has the cause of its box, and other rows have none', () => {
    const r = registry()
    r.applyAgents(
      [bg(), bg({ sessionId: 's2', startedAt: 2 }), bg({ sessionId: 's3', startedAt: 3 })],
      0,
    )
    r.applyEvents([ev('Stop', 's1', 0), ev('PermissionRequest', 's2', 0)], 0)
    r.applyEvents([ev('StopFailure', 's3', 0)], 0)
    expect(r.rows().map(row => [row.box, row.boxReason])).toEqual([
      ['yellow', undefined],
      ['red', 'prompt'],
      ['red', 'error'],
    ])
    expect(Object.hasOwn(r.rows()[0], 'boxReason')).toBe(false)
    r.tick(600_000)
    expect(r.rows()[0]).toMatchObject({ box: 'red', boxReason: 'escalated' })
    r.applyEvents([ev('UserPromptSubmit', 's1', 700_000)], 700_000)
    expect(r.rows()[0].box).toBe('none')
    expect(Object.hasOwn(r.rows()[0], 'boxReason')).toBe(false)
  })

  test('the row keeps the last assistant message', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.applyEvents([{ ...ev('Stop', 's1', 200), lastAssistantMessage: 'Done.' }], 200)
    expect(r.rows()[0].lastMessage).toBe('Done.')
  })

  test('cwds gives each cwd one time and skips an empty cwd', () => {
    const r = registry()
    r.markStarted('s9')
    r.applyAgents(
      [bg(), bg({ sessionId: 's2' }), bg({ cwd: '/q', sessionId: 's3', startedAt: 2 })],
      100,
    )
    expect(r.cwds()).toEqual(['/p', '/q'])
  })

  test('the branch also goes on a row that shows later with the same cwd', () => {
    const r = registry()
    r.applyBranch('/p', 'HEAD')
    r.applyAgents([bg()], 100)
    expect(r.rows()[0].branch).toBe('HEAD')
  })
})

describe('pending events', () => {
  test('an event at exactly PENDING_EVENT_MS is kept', () => {
    const r = registry()
    r.applyEvents([ev('Stop', 's1', 10)], 10)
    r.tick(10 + PENDING_EVENT_MS)
    r.applyAgents([bg()], 10 + PENDING_EVENT_MS)
    expect(r.rows()[0].box).toBe('yellow')
  })

  test('applyEvents also drops old pending events', () => {
    const r = registry()
    r.applyEvents([ev('Stop', 's1', 10)], 10)
    r.applyEvents([], 10 + PENDING_EVENT_MS + 1)
    r.applyAgents([bg()], 10 + PENDING_EVENT_MS + 2)
    expect(r.rows()[0].box).toBe('none')
  })

  test('a pending event goes to a session that shows in --all, before it is parked', () => {
    const r = registry()
    r.applyEvents([ev('SessionStart', 's1', 10), ev('Stop', 's1', 20)], 20)
    r.applyAllAgents([bg({ pid: undefined, status: '' })])
    expect(r.rows()[0]).toMatchObject({ box: 'none', lastActivity: 20, state: 'parked' })
  })

  test('PENDING_EVENT_MS is 60 s', () => {
    expect(PENDING_EVENT_MS).toBe(60_000)
  })
})

describe('priority', () => {
  test('setPriority puts the priority in the row and in the store', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.storeChanged()
    expect(r.setPriority('s1', 2)).toBe(true)
    expect(r.rows()[0].priority).toBe(2)
    expect(r.store().priorities).toEqual({ s1: 2 })
    expect(r.storeChanged()).toBe(true)
  })

  test('setPriority null removes the priority from the row and the store', () => {
    const r = registry({ names: {}, priorities: { s1: 3 }, started: [] })
    r.applyAgents([bg()], 100)
    expect(r.rows()[0].priority).toBe(3)
    r.storeChanged()
    expect(r.setPriority('s1', null)).toBe(true)
    expect(r.rows()[0]).not.toHaveProperty('priority')
    expect(r.store().priorities).toEqual({})
    expect(r.storeChanged()).toBe(true)
  })

  test('setPriority of the same value does not change the store', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.setPriority('s1', 2)
    r.storeChanged()
    expect(r.setPriority('s1', 2)).toBe(true)
    expect(r.storeChanged()).toBe(false)
    r.setPriority('s1', null)
    r.storeChanged()
    expect(r.setPriority('s1', null)).toBe(true)
    expect(r.storeChanged()).toBe(false)
  })

  test('setPriority refuses an unknown session', () => {
    const r = registry()
    expect(r.setPriority('nope', 1)).toBe(false)
    expect(r.store().priorities).toEqual({})
    expect(r.storeChanged()).toBe(false)
  })

  test('a priority stays when the session parks', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.setPriority('s1', 4)
    r.applyAllAgents([bg()])
    r.applyAgents([], 200)
    expect(r.rows()[0]).toMatchObject({ priority: 4, state: 'parked' })
  })

  test('applyAllAgents removes the priority of a session that left all lists', () => {
    const r = registry()
    r.applyAgents([bg({ id: undefined, kind: 'interactive' })], 100)
    r.setPriority('s1', 1)
    r.applyAgents([], 200)
    r.storeChanged()
    r.applyAllAgents([])
    expect(r.store().priorities).toEqual({})
    expect(r.storeChanged()).toBe(true)
  })
})
