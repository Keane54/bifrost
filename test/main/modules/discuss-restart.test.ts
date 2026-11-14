// A session of Discuss with Claude after a restart of Bifrost (ruling P12, fix round 3 of Task 10).
// The modules state holds the saved id. The registry starts again, its first poll fails, and then
// a poll succeeds. The session must stay hidden from every module the whole time. The saved list
// drops an id only when the registry forgets that session for good. The glue is the same as the
// onForget wiring in ipc.ts (a source test checks that wiring).
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import type { AgentEntry, AgentList } from '../../../src/main/claude/agents'
import { createHeimdall } from '../../../src/main/modules/heimdall'
import { createModuleDataStore } from '../../../src/main/modules/module-data'
import {
  type ModuleEntry,
  type ModulesState,
  withoutDiscussSession,
} from '../../../src/main/modules/module-state'
import { SessionRegistry } from '../../../src/main/registry/registry'
import { RegistryService, SERVICE_TIMING } from '../../../src/main/registry/service'

const DISCUSS_ID = 'd1'

function moduleEntry(): ModuleEntry {
  return {
    dailyCap: 10,
    enabled: true,
    granted: ['read-sessions'],
    hash: 'a'.repeat(64),
    jobs: { count: 0, day: '' },
    manifest: {
      description: 'A test.',
      id: 'demo',
      minBifrost: '0.1.0',
      name: 'Demo',
      panels: [{ entry: 'panels/main.html', icon: 'bell', id: 'main', title: 'Main' }],
      permissions: [{ id: 'read-sessions', reason: 'For the test.' }],
      suggests: { dailyCap: null, model: null },
      version: '1.0.0',
    },
    model: 'sonnet',
    pendingUpdate: null,
    source: { kind: 'folder', path: '/src/demo' },
  }
}

const session = (o: Partial<AgentEntry> = {}): AgentEntry => ({
  cwd: '/p',
  id: 'aa',
  kind: 'background',
  name: 'From Discuss',
  pid: 5,
  sessionId: DISCUSS_ID,
  startedAt: 1,
  status: 'idle',
  ...o,
})

let service: RegistryService | undefined

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(1_000_000)
})

afterEach(() => {
  service?.stop()
  service = undefined
  vi.useRealTimers()
})

describe('a Discuss session after a restart', () => {
  test('stays hidden after a failed first poll and then a good poll', async () => {
    // The modules state after the restart: the saved id of the Discuss session.
    let state: ModulesState = { discussSessions: [DISCUSS_ID], modules: { demo: moduleEntry() } }
    const failed: AgentList = { entries: [], error: 'Command failed: claude agents --json' }
    const listActive = vi.fn<() => Promise<AgentList>>()
    listActive.mockResolvedValueOnce(failed)
    listActive.mockResolvedValue({
      entries: [session(), session({ id: 'bb', name: 'Other', sessionId: 'o1' })],
    })
    const registry = new SessionRegistry({
      escalationMs: 600_000,
      store: { lastActive: [], names: {}, priorities: {}, started: [DISCUSS_ID], watch: [] },
    })
    service = new RegistryService(registry, {
      listActive,
      listAll: vi.fn(async () => ({ entries: [session()] })),
      now: () => Date.now(),
      readBranch: vi.fn(async () => null),
      readProcessTable: vi.fn(async () => null),
      saveStore: vi.fn(async () => {}),
    })
    // The glue of ipc.ts: only a forget of the registry drops a saved id.
    service.onForget(id => {
      state = withoutDiscussSession(state, id)
    })
    const live = service
    const heimdall = createHeimdall({
      devAllowed: true,
      emit: () => {},
      notify: () => {},
      now: () => Date.now(),
      serviceStatus: () => [],
      sessions: { pr: async () => ({ kind: 'none' }), rows: () => live.rows() },
      state: () => state,
      store: createModuleDataStore('/home', {
        io: { read: async () => null, write: async () => {}, writeSync: () => {} },
      }),
      usage: () => ({ account: null, snapshot: null }),
    })
    const names = async (): Promise<string[]> =>
      ((await heimdall.call('demo', 'sessions.list', null)) as { name: string }[]).map(s => s.name)

    service.start()
    // The first poll fails.
    await vi.advanceTimersByTimeAsync(0)
    expect(listActive).toHaveBeenCalledTimes(1)
    expect(await names()).not.toContain('From Discuss')
    // The next polls succeed, and the session is in the list again.
    await vi.advanceTimersByTimeAsync(3 * SERVICE_TIMING.allMs)
    expect(listActive.mock.calls.length).toBeGreaterThan(1)
    expect(live.rows().map(row => row.sessionId)).toContain(DISCUSS_ID)
    expect(await names()).toEqual(['Other'])
    expect(state.discussSessions).toEqual([DISCUSS_ID])
  })
})
