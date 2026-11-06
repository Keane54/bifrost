import { describe, expect, test } from 'vitest'
import type { AgentEntry } from '../../../src/main/claude/agents'
import type { HookEvent, HookEventName } from '../../../src/main/registry/hook-event'
import {
  LAST_ACTIVE_GRACE_MS,
  LIVE_FRESH_MS,
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

// Another parked session. A --all list with it is not empty, so the list counts for a forget.
const another = bg({ id: 'cc', name: 'gamma', pid: undefined, sessionId: 'o2', status: '' })

const ev = (name: HookEventName, sessionId: string, at: number): HookEvent => ({
  at,
  name,
  sessionId,
})

const registry = (
  store: RegistryStore = { lastActive: [], names: {}, priorities: {}, started: [], watch: [] },
) => new SessionRegistry({ escalationMs: 600_000, store })

describe('brief', () => {
  test('a background entry is an owned row', () => {
    const r = new SessionRegistry({
      escalationMs: 600_000,
      store: { lastActive: [], names: {}, priorities: {}, started: [], watch: [] },
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
    r.applyAllAgents([bg({ name: '', pid: undefined, status: '' })], true)
    expect(r.rows()).toHaveLength(1)
    expect(r.rows()[0]).toMatchObject({ box: 'none', name: 'alpha', state: 'parked' })
  })

  test('a started session that is not active and not in --all is parked', () => {
    const r = registry({
      lastActive: [],
      names: { s9: 'nine' },
      priorities: {},
      started: [],
      watch: [],
    })
    r.markStarted('s9')
    r.applyAgents([], 100)
    r.applyAllAgents([], true)
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

  test('a later hook event still wins over an older status change', () => {
    const r = registry()
    r.applyAgents([bg({ status: 'idle' })], 100)
    r.applyAgents([bg({ status: 'busy' })], 200)
    r.applyEvents([ev('Stop', 's1', 250)], 250)
    expect(r.rows()[0].lastActivity).toBe(250)
  })

  // Changed for Task 4: the usage line gives the data, and a usage line is not activity (D8).
  test('usage data and the branch go on the row', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.applyEvents([ev('Stop', 's1', 300)], 300)
    r.applyUsage('s1', { contextPercent: 42, costUsd: 1.5, model: 'claude-opus-5-5' }, 500)
    r.applyBranch('/p', 'main')
    expect(r.rows()[0]).toMatchObject({
      branch: 'main',
      contextPercent: 42,
      costUsd: 1.5,
      lastActivity: 300,
      model: 'Opus 5.5',
    })
    r.applyEvents([ev('UserPromptSubmit', 's1', 900)], 900)
    expect(r.rows()[0].lastActivity).toBe(900)
    r.applyBranch('/p', null)
    expect(r.rows()[0].branch).toBeUndefined()
  })

  test('tick escalates and the box keeps flashing', () => {
    const r = registry()
    r.applyAgents([bg()], 0)
    r.applyEvents([ev('Stop', 's1', 0)], 0)
    r.tick(600_000)
    expect(r.rows()[0]).toMatchObject({ box: 'red', flashing: true })
    r.applyEvents([ev('UserPromptSubmit', 's1', 600_001)], 600_001)
    expect(r.rows()[0]).toMatchObject({ box: 'none', flashing: false })
  })
})

describe('the escalation setting (M5a)', () => {
  const T = 1000

  // A registry of 10 minutes with a yellow box since T.
  const yellowAtT = () => {
    const r = registry()
    r.applyAgents([bg()], T)
    r.applyEvents([ev('Stop', 's1', T)], T)
    expect(r.rows()[0]).toMatchObject({ box: 'yellow', boxSince: T })
    return r
  }

  test('setEscalationMs changes the time of an old yellow box at the next tick', () => {
    const r = yellowAtT()
    r.tick(T + 120_000)
    expect(r.rows()[0].box).toBe('yellow')
    r.setEscalationMs(60_000)
    r.tick(T + 120_000)
    expect(r.rows()[0]).toMatchObject({ box: 'red', boxReason: 'escalated' })
  })

  test('setEscalationMs 0 stops the escalation', () => {
    const r = yellowAtT()
    r.setEscalationMs(0)
    r.tick(T + 6_000_000)
    expect(r.rows()[0].box).toBe('yellow')
    // A later value starts the escalation again.
    r.setEscalationMs(600_000)
    r.tick(T + 6_000_000)
    expect(r.rows()[0].box).toBe('red')
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
    r.applyAllAgents([bg()], true)
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

  test('a parked session that Bifrost did not start goes away after two --all lists without it', () => {
    const r = registry()
    r.applyAllAgents([bg({ pid: undefined, status: '' })], true)
    expect(r.rows()).toHaveLength(1)
    r.applyAllAgents([another], true)
    expect(r.rows().map(row => row.sessionId)).toEqual(['o2', 's1'])
    r.applyAllAgents([another], true)
    expect(r.rows().map(row => row.sessionId)).toEqual(['o2'])
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
    r.applyAllAgents([ended], true)
    expect(r.rows()).toEqual([])
  })
})

describe('names', () => {
  // Changed for Task 4: the status file step of the name order is gone.
  test('the name comes from the entry, then the short id, then the session id', () => {
    const r = registry()
    r.applyAgents(
      [
        bg({ name: 'one' }),
        bg({ id: 'bb', name: 'bb', sessionId: 's2' }),
        bg({ id: undefined, name: '', sessionId: 'abcdefghijkl' }),
      ],
      100,
    )
    const names = Object.fromEntries(r.rows().map(row => [row.sessionId, row.name]))
    expect(names).toEqual({ abcdefghijkl: 'abcdefgh', s1: 'one', s2: 'bb' })
  })

  test('the stored name comes before the short id', () => {
    const r = registry({
      lastActive: [],
      names: { s1: 'stored' },
      priorities: {},
      started: [],
      watch: [],
    })
    r.applyAgents([bg({ name: '' })], 100)
    expect(r.rows()[0].name).toBe('stored')
  })

  test('a new entry name replaces the stored name', () => {
    const r = registry({
      lastActive: [],
      names: { s1: 'old' },
      priorities: {},
      started: [],
      watch: [],
    })
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
    expect(r.store()).toEqual({
      lastActive: ['s1'],
      names: { s1: 'alpha' },
      priorities: {},
      started: ['s1'],
      watch: [],
      worktrees: [],
    })
  })

  test('a name from --all goes into the store', () => {
    const r = registry()
    r.applyAllAgents([bg({ name: 'beta', pid: undefined, status: '' })], true)
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
    r.applyAllAgents([another], true)
    expect(r.store().names).toEqual({ o2: 'gamma', s1: 'warp' })
    r.storeChanged()
    r.applyAllAgents([another], true)
    expect(r.store().names).toEqual({ o2: 'gamma' })
    expect(r.storeChanged()).toBe(true)
  })

  test('applyAllAgents keeps the names of active, --all and started sessions', () => {
    const r = registry({
      lastActive: ['s1'],
      names: { s1: 'one', s2: 'two', s3: 'three' },
      priorities: {},
      started: ['s3'],
      watch: [],
    })
    r.applyAgents([bg({ name: 'one' })], 100)
    // The list has the active session s1, so it counts.
    r.applyAllAgents(
      [bg({ name: 'one' }), bg({ name: '', pid: undefined, sessionId: 's2', status: '' })],
      true,
    )
    expect(r.store().names).toEqual({ s1: 'one', s2: 'two', s3: 'three' })
    expect(r.storeChanged()).toBe(false)
  })

  test('applyAllAgents does not keep the name of an interactive entry', () => {
    const r = registry({
      lastActive: [],
      names: { s1: 'warp' },
      priorities: {},
      started: [],
      watch: [],
    })
    const ended = bg({ kind: 'interactive', name: 'warp', pid: undefined, status: '' })
    r.applyAllAgents([ended], true)
    expect(r.store().names).toEqual({ s1: 'warp' })
    r.applyAllAgents([ended], true)
    expect(r.store().names).toEqual({})
  })

  test('the caller cannot change the registry through the store or a row', () => {
    const input: RegistryStore = {
      lastActive: [],
      names: { s1: 'alpha' },
      priorities: {},
      started: [],
      watch: [],
    }
    const r = registry(input)
    input.names.s1 = 'changed'
    input.started.push('s7')
    const copy = r.store()
    copy.names.s1 = 'changed'
    copy.started.push('s8')
    expect(r.store()).toEqual({
      lastActive: [],
      names: { s1: 'alpha' },
      priorities: {},
      started: [],
      watch: [],
      worktrees: [],
    })

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
    r.applyAllAgents([bg({ pid: undefined, status: '' })], true)
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
    const r = registry({ lastActive: [], names: {}, priorities: { s1: 3 }, started: [] })
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
    r.applyAllAgents([bg()], true)
    r.applyAgents([], 200)
    expect(r.rows()[0]).toMatchObject({ priority: 4, state: 'parked' })
  })

  test('applyAllAgents removes the priority of a session that left all lists', () => {
    const r = registry()
    r.applyAgents([bg({ id: undefined, kind: 'interactive' })], 100)
    r.setPriority('s1', 1)
    r.applyAgents([], 200)
    r.storeChanged()
    r.applyAllAgents([another], true)
    expect(r.store().priorities).toEqual({ s1: 1 })
    r.applyAllAgents([another], true)
    expect(r.store().priorities).toEqual({})
    expect(r.storeChanged()).toBe(true)
  })
})

describe('forget, lastActive and terminals', () => {
  const ext = (o: Partial<AgentEntry> = {}) =>
    bg({ id: undefined, kind: 'interactive', name: '', pid: 931, sessionId: 'e1', ...o })
  const warp = { bundle: '/Applications/Warp.app', name: 'Warp' }

  test('forget removes the row and all stored values of the session', () => {
    const r = registry()
    r.markStarted('s1')
    r.applyAgents([bg()], 100)
    r.setPriority('s1', 2)
    r.storeChanged()
    r.forget('s1')
    expect(r.rows().map(row => row.sessionId)).toEqual([])
    const store = r.store()
    expect(store.started).toEqual([])
    expect(store.lastActive).toEqual([])
    expect(store.names).toEqual({})
    expect(store.priorities).toEqual({})
    expect(r.storeChanged()).toBe(true)
  })

  test('lastActive gets an owned session with a PID', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    expect(r.store().lastActive).toEqual(['s1'])
    expect(r.storeChanged()).toBe(true)
  })

  test('lastActive does not get an external session or an entry without a PID', () => {
    const r = registry()
    r.applyAgents([ext(), bg({ pid: undefined, sessionId: 's2', status: '' })], 100)
    expect(r.store().lastActive).toEqual([])
  })

  test('lastActive keeps a session that parked less than 60 s ago', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.applyAgents([], 1000)
    r.tick(1000 + LAST_ACTIVE_GRACE_MS - 1)
    expect(r.store().lastActive).toEqual(['s1'])
    r.tick(1000 + LAST_ACTIVE_GRACE_MS)
    expect(r.store().lastActive).toEqual([])
  })

  test('markStopped removes the session from lastActive at once', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.storeChanged()
    r.markStopped('s1')
    expect(r.store().lastActive).toEqual([])
    expect(r.storeChanged()).toBe(true)
  })

  test('the loaded lastActive gives the resumable rows', () => {
    const r = registry({ lastActive: ['s1'], names: {}, priorities: {}, started: [], watch: [] })
    r.applyAgents([], 1000)
    r.applyAllAgents([bg({ pid: undefined, status: '' })], true)
    expect(r.rows()[0]).toMatchObject({ resumable: true, state: 'parked' })
    r.tick(1000 + LAST_ACTIVE_GRACE_MS)
    expect(r.store().lastActive).toEqual([])
    expect(r.rows()[0].resumable).toBe(true)
  })

  test('a resumable session that runs again is no longer resumable', () => {
    const r = registry({ lastActive: ['s1'], names: {}, priorities: {}, started: [], watch: [] })
    r.applyAgents([bg()], 1000)
    r.applyAgents([], 2000)
    r.applyAllAgents([bg({ pid: undefined, status: '' })], true)
    expect(r.rows()[0].state).toBe('parked')
    expect(r.rows()[0].resumable).toBeUndefined()
  })

  test('a started external session parks when its process ends', () => {
    const r = registry()
    r.markStarted('e1')
    r.applyAgents([ext({ cwd: '/p' })], 100)
    r.applyAgents([], 200)
    expect(r.rows()[0]).toMatchObject({ cwd: '/p', kind: 'external', state: 'parked' })
  })

  test('an external session that Bifrost did not start goes away', () => {
    const r = registry()
    r.applyAgents([ext()], 100)
    r.applyAgents([], 200)
    r.applyAllAgents([], true)
    expect(r.rows()).toEqual([])
  })

  test('the row of an external session gets the terminal app name', () => {
    const r = registry()
    r.applyAgents([ext()], 100)
    r.applyTerminals(new Map([[931, warp]]))
    expect(r.rows()[0].terminalApp).toBe('Warp')
    expect(r.terminalOf('e1')).toEqual(warp)
  })

  test('pidsWithoutTerminal lists external PIDs without a cache entry', () => {
    const r = registry()
    r.applyAgents([ext(), bg()], 100)
    expect(r.pidsWithoutTerminal()).toEqual([931])
    r.applyTerminals(new Map([[931, null]]))
    expect(r.pidsWithoutTerminal()).toEqual([])
    expect(r.rows().find(row => row.sessionId === 'e1')?.terminalApp).toBeUndefined()
  })
})

describe('watchlist', () => {
  const two = () => {
    const r = registry()
    r.applyAgents([bg(), bg({ id: 'bb', name: 'beta', pid: 6, sessionId: 's2' })], 100)
    r.storeChanged()
    return r
  }
  const watchOf = (r: SessionRegistry) => r.store().watch

  test('watchAdd appends the session and changes the store', () => {
    const r = two()
    expect(r.watchAdd('s2', 'dark-blue')).toBe(true)
    expect(r.watchAdd('s1', 'red')).toBe(true)
    expect(watchOf(r)).toEqual([
      { colour: 'dark-blue', sessionId: 's2' },
      { colour: 'red', sessionId: 's1' },
    ])
    expect(r.storeChanged()).toBe(true)
  })

  test('watchAdd of a watched session changes only the colour', () => {
    const r = two()
    r.watchAdd('s1', 'dark-blue')
    r.watchAdd('s2', 'green')
    r.storeChanged()
    expect(r.watchAdd('s1', 'light-blue')).toBe(true)
    expect(watchOf(r)).toEqual([
      { colour: 'light-blue', sessionId: 's1' },
      { colour: 'green', sessionId: 's2' },
    ])
    expect(r.storeChanged()).toBe(true)
    r.watchAdd('s1', 'light-blue')
    expect(r.storeChanged()).toBe(false)
  })

  test('watchAdd refuses an unknown session', () => {
    const r = two()
    expect(r.watchAdd('nope', 'dark-blue')).toBe(false)
    expect(watchOf(r)).toEqual([])
    expect(r.storeChanged()).toBe(false)
  })

  test('watchRemove removes the session', () => {
    const r = two()
    r.watchAdd('s1', 'dark-blue')
    r.storeChanged()
    expect(r.watchRemove('s1')).toBe(true)
    expect(watchOf(r)).toEqual([])
    expect(r.storeChanged()).toBe(true)
    expect(r.watchRemove('s1')).toBe(true)
    expect(r.storeChanged()).toBe(false)
    expect(r.watchRemove('nope')).toBe(false)
  })

  test('watchColour changes the colour of a watched session only', () => {
    const r = two()
    r.watchAdd('s1', 'dark-blue')
    r.storeChanged()
    expect(r.watchColour('s1', 'green')).toBe(true)
    expect(watchOf(r)).toEqual([{ colour: 'green', sessionId: 's1' }])
    expect(r.storeChanged()).toBe(true)
    expect(r.watchColour('s2', 'green')).toBe(true)
    expect(watchOf(r)).toEqual([{ colour: 'green', sessionId: 's1' }])
    expect(r.storeChanged()).toBe(false)
    expect(r.watchColour('nope', 'green')).toBe(false)
  })

  test('watchMove puts the session before another one', () => {
    const r = two()
    r.watchAdd('s1', 'dark-blue')
    r.watchAdd('s2', 'green')
    r.storeChanged()
    expect(r.watchMove('s2', 's1')).toBe(true)
    expect(watchOf(r).map(w => w.sessionId)).toEqual(['s2', 's1'])
    expect(r.storeChanged()).toBe(true)
  })

  test('watchMove with null puts the session at the end', () => {
    const r = two()
    r.watchAdd('s1', 'dark-blue')
    r.watchAdd('s2', 'green')
    r.storeChanged()
    expect(r.watchMove('s1', null)).toBe(true)
    expect(watchOf(r).map(w => w.sessionId)).toEqual(['s2', 's1'])
    expect(r.storeChanged()).toBe(true)
  })

  test('watchMove of an unknown ID does nothing', () => {
    const r = two()
    r.watchAdd('s1', 'dark-blue')
    r.watchAdd('s2', 'green')
    r.storeChanged()
    expect(r.watchMove('nope', 's1')).toBe(false)
    expect(r.watchMove('s2', 'nope')).toBe(false)
    expect(r.watchMove('s1', 's1')).toBe(true)
    expect(watchOf(r).map(w => w.sessionId)).toEqual(['s1', 's2'])
    expect(r.storeChanged()).toBe(false)
  })

  test('rows carry the colour and the order', () => {
    const r = two()
    r.watchAdd('s2', 'dark-blue')
    r.watchAdd('s1', 'red')
    const rows = r.rows()
    expect(rows.find(x => x.sessionId === 's2')?.watch).toEqual({ colour: 'dark-blue', order: 0 })
    expect(rows.find(x => x.sessionId === 's1')?.watch).toEqual({ colour: 'red', order: 1 })
    r.watchRemove('s2')
    expect(r.rows().find(x => x.sessionId === 's2')).not.toHaveProperty('watch')
    expect(r.rows().find(x => x.sessionId === 's1')?.watch).toEqual({ colour: 'red', order: 0 })
  })

  test('a store without watch is valid', () => {
    const r = new SessionRegistry({
      escalationMs: 600_000,
      store: { lastActive: [], names: {}, started: [] },
    })
    expect(r.store().watch).toEqual([])
  })

  test('applyAllAgents removes a session that left all lists from the watchlist', () => {
    const r = registry()
    r.applyAgents([bg({ id: undefined, kind: 'interactive' })], 100)
    r.watchAdd('s1', 'dark-blue')
    r.storeChanged()
    r.applyAgents([], 200)
    r.applyAllAgents([another], true)
    expect(r.store().watch).toEqual([{ colour: 'dark-blue', sessionId: 's1' }])
    r.applyAllAgents([another], true)
    expect(r.store().watch).toEqual([])
    expect(r.storeChanged()).toBe(true)
  })

  test('forgetting a session removes it from the watchlist', () => {
    const r = two()
    r.watchAdd('s1', 'dark-blue')
    r.forget('s1')
    expect(r.store().watch).toEqual([])
  })
})

describe('worktrees', () => {
  const WT = '/r/.claude/worktrees/fix-a'
  // A worktree session that runs. Its cwd is a subfolder of the worktree.
  const inWorktree = (o: Partial<AgentEntry> = {}) => bg({ cwd: `${WT}/src`, ...o })
  // The --all entry of the same session after a stop. Its cwd is the start folder.
  const stopped = (o: Partial<AgentEntry> = {}) =>
    bg({ cwd: '/r', pid: undefined, status: '', ...o })

  test('the registry remembers the worktree of a session that runs', () => {
    const r = registry()
    r.applyAgents([inWorktree()], 100)
    expect(r.rows()[0].worktree).toBe(WT)
    expect(r.store().worktrees).toEqual([{ path: WT, sessionId: 's1' }])
    expect(r.storeChanged()).toBe(true)
    // The same worktree again does not change the store.
    r.applyAgents([inWorktree()], 200)
    expect(r.storeChanged()).toBe(false)
  })

  test('a row outside a worktree and a parked row store no worktree', () => {
    const r = registry()
    r.applyAgents([bg({ cwd: '/r' })], 100)
    expect(r.rows()[0].worktree).toBeUndefined()
    // An entry with a worktree cwd and no pid is parked.
    r.applyAllAgents([inWorktree({ pid: undefined, sessionId: 's2', status: '' })], true)
    expect(r.rows().find(row => row.sessionId === 's2')?.state).toBe('parked')
    expect(r.store().worktrees).toEqual([])
  })

  test('a parked session in the active list stores no worktree', () => {
    // A started session that is not active is parked. Its next active entry has no pid.
    const r = registry()
    r.markStarted('s1')
    r.applyAgents([], 100)
    r.applyAgents([inWorktree({ pid: undefined, status: '' })], 200)
    expect(r.rows()[0]).toMatchObject({ cwd: `${WT}/src`, state: 'parked' })
    expect(r.rows()[0].worktree).toBeUndefined()
    expect(r.store().worktrees).toEqual([])
  })

  test('rememberWorktree stores a worktree root for a known session only', () => {
    const r = registry()
    r.markStarted('s1')
    r.applyAllAgents([stopped()], true)
    r.storeChanged()
    // A path that is not a worktree root, and an unknown session, change nothing.
    for (const path of [`${WT}/src`, '/r', 'r/.claude/worktrees/a', `${WT}/`]) {
      expect(r.rememberWorktree('s1', path)).toBe(false)
    }
    expect(r.rememberWorktree('s9', WT)).toBe(false)
    expect(r.storeChanged()).toBe(false)
    expect(r.rememberWorktree('s1', WT)).toBe(true)
    expect(r.rows()[0]).toMatchObject({ cwd: '/r', worktree: WT })
    expect(r.store().worktrees).toEqual([{ path: WT, sessionId: 's1' }])
    expect(r.storeChanged()).toBe(true)
    expect(r.rememberWorktree('s1', WT)).toBe(true)
    expect(r.storeChanged()).toBe(false)
  })

  test('the worktree stays after the session parks with its start folder', () => {
    const r = registry()
    r.markStarted('s1')
    r.applyAgents([inWorktree()], 100)
    r.applyAgents([], 200)
    r.applyAllAgents([stopped()], true)
    const row = r.rows()[0]
    expect(row).toMatchObject({ cwd: '/r', state: 'parked', worktree: WT })
    expect(r.store().worktrees).toEqual([{ path: WT, sessionId: 's1' }])
  })

  test('the branch read uses the stored worktree when the cwd has no worktree', () => {
    const r = registry()
    r.applyAgents([inWorktree(), bg({ cwd: '/q', sessionId: 's2', startedAt: 2 })], 100)
    expect(r.cwds()).toEqual([`${WT}/src`, '/q'])
    r.applyAgents([bg({ cwd: '/q', sessionId: 's2', startedAt: 2 })], 200)
    r.applyAllAgents([stopped(), bg({ cwd: '/q', sessionId: 's2', startedAt: 2 })], true)
    expect(r.cwds()).toEqual([WT, '/q'])
    r.applyBranch(WT, 'worktree-fix-a')
    r.applyBranch('/r', 'main')
    expect(r.rows()[0]).toMatchObject({ branch: 'worktree-fix-a', cwd: '/r' })
  })

  test('applyAllAgents prunes the worktree of a session that left all lists', () => {
    const r = registry()
    r.applyAgents([inWorktree({ id: undefined, kind: 'interactive' })], 100)
    expect(r.store().worktrees).toHaveLength(1)
    r.storeChanged()
    r.applyAgents([], 200)
    r.applyAllAgents([another], true)
    expect(r.store().worktrees).toHaveLength(1)
    r.applyAllAgents([another], true)
    expect(r.store().worktrees).toEqual([])
    expect(r.storeChanged()).toBe(true)
  })

  test('forget removes the worktree', () => {
    const r = registry()
    r.applyAgents([inWorktree()], 100)
    r.storeChanged()
    r.forget('s1')
    expect(r.store().worktrees).toEqual([])
    expect(r.storeChanged()).toBe(true)
  })

  test('a loaded worktree goes on the row, and a store without worktrees is valid', () => {
    const r = registry({
      lastActive: [],
      names: {},
      priorities: {},
      started: ['s1'],
      watch: [],
      worktrees: [{ path: WT, sessionId: 's1' }],
    })
    r.applyAllAgents([stopped()], true)
    expect(r.rows()[0]).toMatchObject({ cwd: '/r', worktree: WT })
    const old = new SessionRegistry({
      escalationMs: 600_000,
      store: { lastActive: [], names: {}, started: [] },
    })
    expect(old.store().worktrees).toEqual([])
  })
})

describe('a session that is gone (Task 17 bug 3)', () => {
  const WT = '/r/.claude/worktrees/gone'
  // Another parked session, so that the --all list is not empty.
  const other = bg({ id: 'bb', name: 'beta', pid: undefined, sessionId: 'o1', status: '' })
  // A started session that claude rm in a terminal removed. The store has all its values.
  const withGone = () => {
    const r = registry({
      lastActive: ['s9'],
      names: { s9: 'nine' },
      priorities: { s9: 2 },
      started: ['s9'],
      watch: [{ colour: 'amber', sessionId: 's9' }],
      worktrees: [{ path: WT, sessionId: 's9' }],
    })
    r.applyAgents([], 100)
    return r
  }
  const ids = (r: SessionRegistry) => r.rows().map(row => row.sessionId)

  test('a started session that two --all lists in a row do not have is forgotten', () => {
    const r = withGone()
    expect(ids(r)).toEqual(['s9'])
    r.applyAllAgents([other], true)
    expect(ids(r)).toEqual(['s9', 'o1'])
    expect(r.store().started).toEqual(['s9'])
    r.storeChanged()
    r.applyAllAgents([other], true)
    expect(ids(r)).toEqual(['o1'])
    expect(r.store()).toEqual({
      lastActive: [],
      names: { o1: 'beta' },
      priorities: {},
      started: [],
      watch: [],
      worktrees: [],
    })
    expect(r.storeChanged()).toBe(true)
    // The next active list does not park it again.
    r.applyAgents([], 200)
    expect(ids(r)).toEqual(['o1'])
  })

  test('a session that comes back resets the count', () => {
    const r = withGone()
    const back = bg({ id: 'a9', pid: undefined, sessionId: 's9', status: '' })
    r.applyAllAgents([other], true)
    r.applyAllAgents([other, back], true)
    r.applyAllAgents([other], true)
    expect(ids(r)).toContain('s9')
    expect(r.store().started).toEqual(['s9'])
    r.applyAllAgents([other], true)
    expect(ids(r)).not.toContain('s9')
  })

  test('a session in the active list is not gone', () => {
    // A --all list that started before the session can miss it. The active list has it.
    const r = withGone()
    for (const at of [200, 300, 400]) {
      r.applyAgents([bg({ sessionId: 's9' })], at)
      r.applyAllAgents([other], true)
    }
    expect(ids(r)).toContain('s9')
    expect(r.store().started).toEqual(['s9'])
  })

  test('an entry of any kind in --all keeps the session', () => {
    // A failed Take control leaves a started session with an interactive entry (D6).
    const r = withGone()
    const ended = bg({
      id: undefined,
      kind: 'interactive',
      pid: undefined,
      sessionId: 's9',
      status: '',
    })
    for (let i = 0; i < 3; i++) r.applyAllAgents([other, ended], true)
    expect(ids(r)).toContain('s9')
    expect(r.store().watch).toEqual([{ colour: 'amber', sessionId: 's9' }])
  })

  test('an empty --all list and a list with a skipped entry do not count', () => {
    const r = withGone()
    r.applyAllAgents([other], true)
    r.applyAllAgents([], true)
    r.applyAllAgents([other], false)
    r.applyAllAgents([], false)
    expect(ids(r)).toContain('s9')
    expect(r.store().started).toEqual(['s9'])
    expect(r.store().worktrees).toEqual([{ path: WT, sessionId: 's9' }])
    // These lists do not stop the count either. The next good list is the second one in a row.
    r.applyAllAgents([other], true)
    expect(ids(r)).not.toContain('s9')
  })

  test('one --all list without the session does not forget it', () => {
    const r = withGone()
    r.applyAllAgents([other], true)
    r.applyAgents([], 200)
    r.tick(300)
    expect(r.rows().find(row => row.sessionId === 's9')).toMatchObject({
      name: 'nine',
      priority: 2,
      state: 'parked',
      watch: { colour: 'amber', order: 0 },
      worktree: WT,
    })
  })

  test('an --all list without a background session of the active list does not count', () => {
    // A list that misses a session that runs is not complete, or Claude Code filtered it.
    const r = withGone()
    const running = bg({ id: 'r1', name: 'run', sessionId: 'r1' })
    r.applyAgents([running], 200)
    for (let i = 0; i < 3; i++) r.applyAllAgents([other], true)
    expect(ids(r)).toContain('s9')
    expect(r.store().started).toEqual(['s9'])
    // An entry of any kind for the running session makes the list complete.
    r.applyAllAgents([other, running], true)
    expect(ids(r)).toContain('s9')
    r.applyAllAgents([other, { ...running, kind: 'interactive' }], true)
    expect(ids(r)).not.toContain('s9')
  })

  test('a list that does not count does not reset a count', () => {
    const r = withGone()
    const listed = bg({ id: 'a9', pid: undefined, sessionId: 's9', status: '' })
    r.applyAllAgents([other], true)
    // A partial list, and a list that misses a running session, have s9. They do not reset it.
    r.applyAllAgents([other, listed], false)
    r.applyAgents([bg({ id: 'r1', sessionId: 'r1' })], 200)
    r.applyAllAgents([other, listed], true)
    r.applyAgents([], 300)
    expect(ids(r)).toContain('s9')
    r.applyAllAgents([other], true)
    expect(ids(r)).not.toContain('s9')
  })

  test('an active list that has the session resets its count', () => {
    const r = withGone()
    r.applyAllAgents([other], true)
    // s9 runs for a short time between two --all lists.
    r.applyAgents([bg({ sessionId: 's9' })], 200)
    r.applyAgents([], 300)
    r.applyAllAgents([other], true)
    expect(ids(r)).toContain('s9')
    r.applyAllAgents([other], true)
    expect(ids(r)).not.toContain('s9')
  })

  test('a forget by Delete also clears the count', () => {
    const r = withGone()
    r.applyAllAgents([other], true)
    r.forget('s9')
    // The same ID again starts with no count.
    r.markStarted('s9')
    r.applyAgents([], 200)
    r.applyAllAgents([other], true)
    expect(ids(r)).toContain('s9')
  })
})

describe('one rule for all forgets (Task 18 fix round 1, M2)', () => {
  const WT = '/r/.claude/worktrees/kept'
  // An owned session that Bifrost did not start. It is parked, and it has all stored values.
  const withParked = () => {
    const r = registry()
    r.applyAllAgents([bg({ pid: undefined, status: '' })], true)
    r.setPriority('s1', 3)
    r.watchAdd('s1', 'green')
    r.rememberWorktree('s1', WT)
    return r
  }
  const kept = (r: SessionRegistry) => {
    expect(r.rows().find(row => row.sessionId === 's1')).toMatchObject({
      name: 'alpha',
      priority: 3,
      state: 'parked',
      watch: { colour: 'green', order: 0 },
      worktree: WT,
    })
    const store = r.store()
    expect(store.names.s1).toBe('alpha')
    expect(store.priorities.s1).toBe(3)
    expect(store.watch).toEqual([{ colour: 'green', sessionId: 's1' }])
    expect(store.worktrees).toEqual([{ path: WT, sessionId: 's1' }])
  }

  test('an empty --all list removes nothing', () => {
    const r = withParked()
    for (let i = 0; i < 3; i++) r.applyAllAgents([], true)
    kept(r)
  })

  test('a partial --all list removes nothing', () => {
    const r = withParked()
    for (let i = 0; i < 3; i++) r.applyAllAgents([another], false)
    kept(r)
    for (let i = 0; i < 3; i++) r.applyAllAgents([], false)
    kept(r)
  })

  test('an --all list that misses a running session removes nothing', () => {
    const r = withParked()
    r.applyAgents([bg({ id: 'r1', sessionId: 'r1' })], 100)
    for (let i = 0; i < 3; i++) r.applyAllAgents([another], true)
    kept(r)
  })

  test('one counted --all list without the session removes nothing', () => {
    const r = withParked()
    r.applyAllAgents([another], true)
    kept(r)
    r.applyAllAgents([another], true)
    expect(r.rows().map(row => row.sessionId)).toEqual(['o2'])
    expect(r.store()).toMatchObject({ priorities: {}, watch: [], worktrees: [] })
    expect(r.store().names).toEqual({ o2: 'gamma' })
  })

  test('a list that does not count does not make a stopped session go away', () => {
    // The session ran and was in the last counted list. Then a list that does not count came.
    const r = registry()
    r.applyAgents([bg()], 100)
    r.applyAllAgents([bg()], true)
    r.applyAllAgents([], true)
    r.applyAllAgents([another], false)
    r.applyAgents([], 200)
    expect(r.rows().find(row => row.sessionId === 's1')).toMatchObject({ state: 'parked' })
  })
})

describe('a list with no background entry (final review M1)', () => {
  // An interactive session in a terminal, for example in Warp. Its entry is in both lists.
  const warp = bg({ id: undefined, kind: 'interactive', name: 'warp', pid: 77, sessionId: 'w1' })
  const ids = (r: SessionRegistry) => r.rows().map(row => row.sessionId)

  test('a list with no background entry does not count while a parked owned row exists', () => {
    // For example after a restart of the computer: the background service starts slowly, and
    // the lists have only the interactive sessions.
    const r = registry()
    r.applyAllAgents([bg({ pid: undefined, status: '' })], true)
    r.setPriority('s1', 3)
    r.watchAdd('s1', 'green')
    r.applyAgents([warp], 100)
    for (let i = 0; i < 3; i++) r.applyAllAgents([warp], true)
    expect(r.rows().find(row => row.sessionId === 's1')).toMatchObject({
      name: 'alpha',
      priority: 3,
      state: 'parked',
      watch: { colour: 'green', order: 0 },
    })
    // A list with a background entry counts again.
    r.applyAllAgents([warp, another], true)
    r.applyAllAgents([warp, another], true)
    expect(ids(r)).toEqual(['o2', 'w1'])
  })

  test('a list with no background entry does not count while a session of the last run waits', () => {
    // Bifrost did not start s5, and no list showed it yet. lastActive of the store has it.
    const r = registry({
      lastActive: ['s5'],
      names: { s5: 'five' },
      priorities: { s5: 1 },
      started: [],
      watch: [{ colour: 'amber', sessionId: 's5' }],
    })
    r.applyAgents([warp], 100)
    for (let i = 0; i < 3; i++) r.applyAllAgents([warp], true)
    expect(r.store()).toMatchObject({
      lastActive: ['s5'],
      names: { s5: 'five', w1: 'warp' },
      priorities: { s5: 1 },
      watch: [{ colour: 'amber', sessionId: 's5' }],
    })
  })

  test('a list with no background entry counts when no owned session waits', () => {
    // Only the stored values of an interactive session that ended. Nothing owned is parked.
    const r = registry({
      lastActive: [],
      names: { e1: 'old' },
      priorities: { e1: 2 },
      started: [],
      watch: [],
    })
    r.applyAgents([warp], 100)
    r.applyAllAgents([warp], true)
    expect(r.store().priorities).toEqual({ e1: 2 })
    r.applyAllAgents([warp], true)
    expect(r.store().priorities).toEqual({})
    expect(r.store().names).toEqual({ w1: 'warp' })
  })
})

describe('the active list keeps a session from a forget (registry.ts forgetGone)', () => {
  test('two counted --all lists in a row do not forget a session of the active list', () => {
    // An interactive session in the active list. The --all set has only background IDs, and
    // the session is not started. So only the active list keeps it.
    const term = bg({ id: undefined, kind: 'interactive', name: 'term', pid: 77, sessionId: 'e1' })
    const r = registry()
    r.applyAgents([term], 100)
    expect(r.setPriority('e1', 2)).toBe(true)
    r.watchAdd('e1', 'light-blue')
    r.applyAllAgents([term, another], true)
    r.applyAllAgents([term, another], true)
    r.applyAllAgents([term, another], true)
    expect(r.rows().find(row => row.sessionId === 'e1')).toMatchObject({
      kind: 'external',
      priority: 2,
      watch: { colour: 'light-blue', order: 0 },
    })
  })
})

describe('live events and usage lines (Task 4)', () => {
  const seqEv = (name: HookEventName, at: number, seq: number): HookEvent => ({
    ...ev(name, 's1', at),
    seq,
  })
  // An interactive session with no stored name. Only its usage keeps its ID in the registry.
  const term = bg({ id: undefined, kind: 'interactive', name: '' })
  const rowOf = (r: SessionRegistry, id = 's1') => r.rows().find(row => row.sessionId === id)

  test('LIVE_FRESH_MS is 90 s', () => {
    expect(LIVE_FRESH_MS).toBe(90_000)
  })

  test('applyEvents drops a state event older than the newest applied event', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.applyEvents([ev('Stop', 's1', 300)], 300)
    r.applyEvents([ev('PostToolUse', 's1', 200)], 310)
    expect(rowOf(r)).toMatchObject({ box: 'yellow', boxSince: 300, lastActivity: 300 })
  })

  // D7, Review Focus 4: the mod sends session.start again at each reload.
  test('a mod SessionStart keeps the box and boxSince of a running row', () => {
    const r = registry()
    r.applyAgents([bg({ status: 'busy' })], 100)
    r.applyEvents([seqEv('Stop', 300, 1)], 300)
    const before = rowOf(r)
    expect(before).toMatchObject({ box: 'yellow', boxSince: 300 })
    r.applyEvents([seqEv('SessionStart', 400, 2)], 400)
    expect(rowOf(r)).toMatchObject({ box: 'yellow', boxSince: 300, state: before?.state })
  })

  test('applyEvents uses seq for two events with the same time', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.applyEvents([seqEv('Stop', 300, 5)], 300)
    r.applyEvents([seqEv('PostToolUse', 300, 4)], 300)
    expect(rowOf(r)).toMatchObject({ box: 'yellow', state: 'needs-you' })
    r.applyEvents([seqEv('PostToolUse', 300, 6)], 300)
    expect(rowOf(r)).toMatchObject({ box: 'none', state: 'working' })
  })

  test('two events with the same time and no seq both apply', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.applyEvents([ev('Stop', 's1', 300)], 300)
    r.applyEvents([seqEv('PostToolUse', 300, 1)], 300)
    expect(rowOf(r)?.state).toBe('working')
  })

  test('pending events follow the same order rule when they apply', () => {
    const r = registry()
    r.applyEvents([ev('Stop', 's1', 300), ev('PostToolUse', 's1', 200)], 300)
    r.applyAgents([bg()], 400)
    expect(rowOf(r)).toMatchObject({ box: 'yellow', boxSince: 300 })
  })

  test('applyUsage gives the model name, the context and the cost to the row', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.applyUsage('s1', { contextPercent: 6, costUsd: 0.01, model: 'claude-haiku-5-5' }, 200)
    expect(rowOf(r)).toMatchObject({ contextPercent: 6, costUsd: 0.01, model: 'Haiku 5.5' })
  })

  test('the newest usage line replaces the usage, and an older line changes nothing', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.applyUsage('s1', { costUsd: 0.5, model: 'claude-opus-5-5' }, 300)
    r.applyUsage('s1', { costUsd: 0.1, model: 'claude-haiku-5-5' }, 200)
    expect(rowOf(r)).toMatchObject({ costUsd: 0.5, model: 'Opus 5.5' })
    r.applyUsage('s1', { costUsd: 0.7 }, 400)
    expect(rowOf(r)?.costUsd).toBe(0.7)
    expect(rowOf(r)).not.toHaveProperty('model')
  })

  test('a usage line is not activity', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.applyEvents([ev('Stop', 's1', 300)], 300)
    r.applyUsage('s1', { costUsd: 0.2 }, 5000)
    expect(rowOf(r)?.lastActivity).toBe(300)
    // A usage line does not change the event time, so an older event still applies.
    r.applyEvents([ev('UserPromptSubmit', 's1', 400)], 5000)
    expect(rowOf(r)).toMatchObject({ lastActivity: 400, state: 'working' })
  })

  test('a usage line for an unknown session shows when the session comes', () => {
    const r = registry()
    r.applyUsage('s1', { contextPercent: 12, costUsd: 0.3, model: 'claude-sonnet-5' }, 100)
    expect(r.rows()).toEqual([])
    r.applyAgents([bg()], 200)
    expect(rowOf(r)).toMatchObject({ contextPercent: 12, costUsd: 0.3, model: 'Sonnet 5' })
  })

  test('a row is live for 90 s after its last line', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    expect(rowOf(r)).not.toHaveProperty('live')
    expect(r.liveCount()).toBe(0)
    r.applyUsage('s1', {}, 1000)
    r.tick(91_000)
    expect(rowOf(r)?.live).toBe(true)
    expect(r.liveCount()).toBe(1)
    r.tick(91_001)
    expect(rowOf(r)).not.toHaveProperty('live')
    expect(r.liveCount()).toBe(0)
  })

  test('a state event also makes the row live', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.applyEvents([ev('UserPromptSubmit', 's1', 200)], 200)
    expect(rowOf(r)?.live).toBe(true)
    r.applyAgents([bg({ status: 'busy' })], 200 + LIVE_FRESH_MS + 1)
    expect(rowOf(r)).not.toHaveProperty('live')
  })

  test('liveCount does not count a parked row', () => {
    const r = registry()
    r.markStarted('s1')
    r.applyAgents([bg()], 100)
    r.applyEvents([ev('SessionEnd', 's1', 200)], 200)
    expect(rowOf(r)?.state).toBe('parked')
    expect(r.liveCount()).toBe(0)
  })

  test('a poll-only session gets a yellow box at busy to idle', () => {
    const r = registry()
    r.applyAgents([bg({ status: 'busy' })], 1000)
    r.applyAgents([bg({ status: 'idle' })], 3000)
    expect(rowOf(r)).toMatchObject({
      box: 'yellow',
      boxSince: 3000,
      flashing: true,
      state: 'needs-you',
    })
    // A later busy sample clears it.
    r.applyAgents([bg({ status: 'busy' })], 5000)
    expect(rowOf(r)).toMatchObject({ box: 'none', state: 'working' })
  })

  test('a live session gets no poll yellow after a stopped turn', () => {
    const r = registry()
    r.applyAgents([bg({ status: 'busy' })], 1000)
    r.applyEvents([ev('UserPromptSubmit', 's1', 1500)], 1500)
    r.applyEvents([ev('TurnAborted', 's1', 2500)], 2500)
    r.applyAgents([bg({ status: 'idle' })], 3000)
    expect(rowOf(r)).toMatchObject({ box: 'none', state: 'idle' })
  })

  test('a session with only usage lines is live and gets no poll yellow', () => {
    const r = registry()
    r.applyAgents([bg({ status: 'busy' })], 1000)
    r.applyUsage('s1', { costUsd: 0.1 }, 2000)
    r.applyAgents([bg({ status: 'idle' })], 3000)
    expect(rowOf(r)).toMatchObject({ box: 'none', state: 'idle' })
  })

  test('clearLive ends the live flag of each row and keeps the usage', () => {
    const r = registry()
    r.applyAgents([bg({ status: 'busy' })], 1000)
    r.applyUsage('s1', { contextPercent: 5, costUsd: 0.1, model: 'claude-haiku-5-5' }, 1500)
    expect(r.liveCount()).toBe(1)
    r.clearLive()
    expect(r.liveCount()).toBe(0)
    expect(rowOf(r)).not.toHaveProperty('live')
    expect(rowOf(r)).toMatchObject({ contextPercent: 5, costUsd: 0.1, model: 'Haiku 5.5' })
    // The session is poll-only again. So the next busy to idle sample gives the yellow box.
    r.applyAgents([bg({ status: 'idle' })], 3000)
    expect(rowOf(r)).toMatchObject({ box: 'yellow', boxSince: 3000, state: 'needs-you' })
  })

  test('the first sample after the start gives no yellow box', () => {
    const r = registry()
    r.applyAgents([bg({ status: 'idle' })], 1000)
    expect(rowOf(r)).toMatchObject({ box: 'none', state: 'idle' })
    // A parked session that runs again has no status before the sample.
    const p = registry()
    p.markStarted('s1')
    p.applyAgents([], 1000)
    p.applyAgents([bg({ status: 'idle' })], 3000)
    expect(rowOf(p)).toMatchObject({ box: 'none', state: 'idle' })
  })

  test('applyAllAgents removes the usage of a session that left all lists', () => {
    const r = registry()
    r.applyAgents([term], 100)
    r.applyUsage('s1', { costUsd: 0.5 }, 150)
    r.applyAgents([], 200)
    // One counted --all list without the session keeps the usage.
    r.applyAllAgents([another], true)
    r.applyAgents([term], 300)
    expect(rowOf(r)?.costUsd).toBe(0.5)
    r.applyAgents([], 400)
    // GONE_LISTS counted lists in a row without the session remove the usage.
    r.applyAllAgents([another], true)
    r.applyAllAgents([another], true)
    r.applyAgents([term], 500)
    expect(rowOf(r)).not.toHaveProperty('costUsd')
    expect(rowOf(r)).not.toHaveProperty('live')
  })

  test('applyAllAgents removes the usage of a session that never showed', () => {
    const r = registry()
    r.applyUsage('s1', { costUsd: 0.5 }, 100)
    r.applyAllAgents([another], true)
    r.applyAllAgents([another], true)
    r.applyAgents([term], 200)
    expect(rowOf(r)).not.toHaveProperty('costUsd')
  })

  test('forget removes the usage of the session', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.applyUsage('s1', { costUsd: 0.5, model: 'claude-opus-5-5' }, 150)
    r.forget('s1')
    r.applyAgents([bg()], 200)
    expect(rowOf(r)).not.toHaveProperty('costUsd')
    expect(rowOf(r)).not.toHaveProperty('model')
    expect(rowOf(r)).not.toHaveProperty('live')
  })
})

describe('session details and the newest rate limits (M5b Task 1)', () => {
  const rowOf = (r: SessionRegistry, id = 's1') => r.rows().find(row => row.sessionId === id)
  const limits = (usedPercent: number) => ({
    fiveHour: { resetsAt: 5_000_000, usedPercent },
    sevenDay: { resetsAt: 9_000_000, usedPercent: usedPercent + 1 },
  })

  test('a row gets the details of its usage line', () => {
    const r = registry()
    r.applyAgents([bg()], 100)
    r.applyUsage(
      's1',
      {
        contextWindow: 1000000,
        effort: 'xhigh',
        permissionMode: 'plan',
        rateLimits: limits(40),
        transcriptPath: '/h/.claude/projects/p/s1.jsonl',
        version: '2.1.318',
      },
      200,
    )
    expect(rowOf(r)).toMatchObject({
      claudeVersion: '2.1.318',
      contextWindowSize: 1000000,
      effort: 'xhigh',
      permissionMode: 'plan',
      rateLimits: limits(40),
      transcriptPath: '/h/.claude/projects/p/s1.jsonl',
    })
    // A line without the details leaves the fields out. The rate limits stay (ruling 4).
    r.applyUsage('s1', { costUsd: 0.1 }, 300)
    for (const field of [
      'claudeVersion',
      'contextWindowSize',
      'effort',
      'permissionMode',
      'transcriptPath',
    ]) {
      expect(rowOf(r)).not.toHaveProperty(field)
    }
    expect(rowOf(r)?.rateLimits).toEqual(limits(40))
  })

  test('a usage line without rate limits keeps the last rate limits of the session', () => {
    const r = registry()
    r.applyAgents(
      [
        bg({ id: 'aa', name: 'alpha', sessionId: 'a' }),
        bg({ id: 'cc', name: 'gamma', sessionId: 'c' }),
      ],
      100,
    )
    r.applyUsage('a', { rateLimits: limits(10) }, 1000)
    r.applyUsage('c', { rateLimits: limits(30) }, 1500)
    r.applyUsage('a', { costUsd: 0.2 }, 2000)
    expect(rowOf(r, 'a')).toMatchObject({ costUsd: 0.2, rateLimits: limits(10) })
    // The time of the kept limits is the time of the line that had them. So C stays the newest.
    expect(r.usage()).toEqual({
      limits: limits(30),
      name: 'gamma',
      sessionId: 'c',
      updatedAt: 1500,
    })
    // Only a line with rate limits replaces them.
    r.applyUsage('a', { rateLimits: limits(60) }, 2500)
    expect(rowOf(r, 'a')?.rateLimits).toEqual(limits(60))
    expect(r.usage()).toEqual({
      limits: limits(60),
      name: 'alpha',
      sessionId: 'a',
      updatedAt: 2500,
    })
  })

  test('usage gives the newest usage line with rate limits', () => {
    const r = registry()
    r.applyAgents(
      [
        bg({ id: 'aa', name: 'alpha', sessionId: 'a' }),
        bg({ id: 'bb', name: 'beta', sessionId: 'b' }),
        bg({ id: 'cc', name: 'gamma', sessionId: 'c' }),
      ],
      100,
    )
    r.applyUsage('a', { rateLimits: limits(10) }, 1000)
    r.applyUsage('b', { costUsd: 0.2 }, 2000)
    r.applyUsage('c', { rateLimits: limits(30) }, 1500)
    // A line that comes last but has an older time does not win.
    r.applyUsage('d', { rateLimits: limits(50) }, 1200)
    expect(r.usage()).toEqual({
      limits: limits(30),
      name: 'gamma',
      sessionId: 'c',
      updatedAt: 1500,
    })
  })

  test('usage uses the line of a session that is not a row', () => {
    const r = registry()
    const id = '73b5ca76-a4a8-4f97-9764-e41657296414'
    r.applyUsage(id, { rateLimits: limits(20) }, 1000)
    expect(r.rows()).toEqual([])
    expect(r.usage()).toEqual({
      limits: limits(20),
      name: '73b5ca76',
      sessionId: id,
      updatedAt: 1000,
    })
  })

  test('usage gives null without rate limits', () => {
    const r = registry()
    expect(r.usage()).toBeNull()
    r.applyAgents([bg()], 100)
    r.applyUsage('s1', { contextPercent: 5, costUsd: 0.1 }, 200)
    expect(r.usage()).toBeNull()
    // forget removes the kept rate limits.
    r.applyUsage('s1', { rateLimits: limits(10) }, 300)
    r.applyUsage('s1', { costUsd: 0.2 }, 400)
    expect(r.usage()).toMatchObject({ sessionId: 's1', updatedAt: 300 })
    r.forget('s1')
    expect(r.usage()).toBeNull()
  })
})
