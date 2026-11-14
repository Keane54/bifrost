// The module rows that the UI shows (plan Task 6, ruling P1). A packaged app treats a dev module
// as turned off and says so in its row.
import { describe, expect, it } from 'vitest'
import { DEV_OFF_REASON, modulesSnapshot } from '../../../src/main/modules/module-rows'
import { type ModulesState, parseModulesState } from '../../../src/main/modules/module-state'

const MANIFEST = {
  description: 'A test.',
  id: 'demo',
  minBifrost: '0.5.0',
  name: 'Demo',
  panels: [{ entry: 'panels/main.html', icon: 'chart-bar', id: 'main', title: 'Demo board' }],
  permissions: [
    { id: 'notify', reason: 'To tell you.' },
    { id: 'read-usage', reason: 'To show usage.' },
  ],
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

function state(modules: Record<string, Record<string, unknown>>): ModulesState {
  const parsed = parseModulesState({ modules })
  expect(Object.keys(parsed.modules)).toEqual(Object.keys(modules))
  return parsed
}

const TODAY = '2026-11-13'

describe('modulesSnapshot', () => {
  it('gives a row with the values of the entry', () => {
    const snap = modulesSnapshot(state({ demo: entry() }), { devAllowed: false, today: TODAY })
    expect(snap).toEqual({
      modules: [
        {
          dailyCap: 10,
          description: 'A test.',
          dev: false,
          enabled: true,
          granted: ['notify'],
          id: 'demo',
          jobsToday: 2,
          model: 'sonnet',
          name: 'Demo',
          offReason: null,
          panels: MANIFEST.panels,
          pendingUpdate: null,
          requested: MANIFEST.permissions,
          source: '/x/demo',
          sourceKind: 'folder',
          tier: 'standard',
          version: '1.0.0',
          waitingJobs: 0,
        },
      ],
    })
  })

  it('gives the count of the jobs that wait for Refresh', () => {
    const other = entry({ manifest: { ...MANIFEST, id: 'other', name: 'Other' } })
    const snap = modulesSnapshot(state({ demo: entry(), other }), {
      devAllowed: false,
      today: TODAY,
      waiting: id => (id === 'demo' ? 2 : 0),
    })
    expect(snap.modules.map(m => [m.id, m.waitingJobs])).toEqual([
      ['demo', 2],
      ['other', 0],
    ])
  })

  it('gives the source as text, with ~ for the home folder', () => {
    const rows = (over: Record<string, unknown>, home?: string) =>
      modulesSnapshot(state({ demo: entry(over) }), { devAllowed: true, home, today: TODAY })
        .modules[0]?.source
    expect(rows({}, '/x')).toBe('~/demo')
    expect(rows({}, '/x/')).toBe('~/demo')
    expect(rows({}, '/y')).toBe('/x/demo')
    expect(rows({ source: { kind: 'dev', path: '/x/dev' } }, '/x')).toBe('~/dev')
    expect(rows({ source: { kind: 'git', url: 'https://github.com/a/b' } }, '/x')).toBe(
      'https://github.com/a/b',
    )
    expect(rows({}, '/x/demo')).toBe('~')
    expect(rows({ source: { kind: 'folder', path: '/xy/demo' } }, '/x')).toBe('/xy/demo')
  })

  it('counts the jobs of today only', () => {
    const snap = modulesSnapshot(state({ demo: entry() }), {
      devAllowed: false,
      today: '2026-11-14',
    })
    expect(snap.modules[0]?.jobsToday).toBe(0)
  })

  it('gives a turned-off module with no reason', () => {
    const snap = modulesSnapshot(state({ demo: entry({ enabled: false }) }), {
      devAllowed: true,
      today: TODAY,
    })
    expect(snap.modules[0]?.enabled).toBe(false)
    expect(snap.modules[0]?.offReason).toBeNull()
  })

  it('treats a dev module as off in a packaged app, and says so', () => {
    const dev = entry({ source: { kind: 'dev', path: '/x/demo' } })
    const packaged = modulesSnapshot(state({ demo: dev }), { devAllowed: false, today: TODAY })
    expect(packaged.modules[0]).toMatchObject({
      dev: true,
      enabled: false,
      offReason: DEV_OFF_REASON,
      sourceKind: 'dev',
    })
    expect(DEV_OFF_REASON).toBe(
      'This developer module runs only in a development build of Bifrost.',
    )
    const devRun = modulesSnapshot(state({ demo: dev }), { devAllowed: true, today: TODAY })
    expect(devRun.modules[0]).toMatchObject({ dev: true, enabled: true, offReason: null })
  })

  it('gives the version and the new permissions of a waiting update', () => {
    const next = {
      ...MANIFEST,
      permissions: [
        ...MANIFEST.permissions,
        { id: 'read-sessions', reason: 'To list sessions.' },
        { id: 'discuss', reason: 'To talk.' },
      ],
      version: '1.3.0',
    }
    const snap = modulesSnapshot(
      state({ demo: entry({ pendingUpdate: { hash: 'b'.repeat(64), manifest: next } }) }),
      { devAllowed: false, today: TODAY },
    )
    expect(snap.modules[0]?.pendingUpdate).toEqual({
      added: [
        { id: 'read-sessions', reason: 'To list sessions.' },
        { id: 'discuss', reason: 'To talk.' },
      ],
      version: '1.3.0',
    })
  })

  it('sorts the rows by name, then by id', () => {
    const named = (id: string, name: string) => entry({ manifest: { ...MANIFEST, id, name } })
    const snap = modulesSnapshot(
      state({ aaa: named('aaa', 'Alpha'), abc: named('abc', 'Beta'), zed: named('zed', 'Alpha') }),
      { devAllowed: false, today: TODAY },
    )
    expect(snap.modules.map(m => m.id)).toEqual(['aaa', 'zed', 'abc'])
  })

  it('gives copies, so a change to a row does not change the state', () => {
    const s = state({ demo: entry() })
    const snap = modulesSnapshot(s, { devAllowed: false, today: TODAY })
    snap.modules[0]?.granted.push('discuss')
    snap.modules[0]?.panels.pop()
    expect(s.modules.demo?.granted).toEqual(['notify'])
    expect(s.modules.demo?.manifest.panels).toHaveLength(1)
  })
})
