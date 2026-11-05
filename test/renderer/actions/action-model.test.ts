import { describe, expect, it } from 'vitest'
import {
  ACTIONS,
  type ActionContext,
  type ActionId,
  actionStateFor,
  buttonTip,
  globalActionState,
  type MenuEntry,
  rowMenu,
} from '../../../src/renderer/src/actions/action-model'
import * as R from '../../../src/renderer/src/actions/reasons'
import { row } from '../overview/fixtures'

const ctx = (over: Partial<ActionContext> = {}): ActionContext => ({
  apps: [
    { id: 'finder', label: 'Finder' },
    { id: 'warp', label: 'Warp' },
  ],
  chatOpen: true,
  labels: 'plain',
  running: false,
  slashFavourites: [],
  slashRecent: [],
  ...over,
})
const owned = row({ sessionId: 'o', shortId: 'abcd1234', state: 'idle' })
const external = row({ kind: 'external', sessionId: 'e' })
const parked = row({ sessionId: 'p', state: 'parked' })
const labels = (m: MenuEntry[]) => m.map(e => (e.type === 'separator' ? '-' : e.label))
const find = (m: MenuEntry[], id: ActionId) =>
  m.find(e => e.type !== 'separator' && e.action === id)

describe('action model', () => {
  it('ACTIONS has the plain and space labels of spec 9.1', () => {
    expect([ACTIONS.open.plain, ACTIONS.open.space]).toEqual(['Open', 'Warp to'])
    expect([ACTIONS['take-control'].plain, ACTIONS['take-control'].space]).toEqual([
      'Take control',
      'Commandeer',
    ])
    expect(ACTIONS['set-priority'].space).toBe('Set threat level')
    expect(ACTIONS.delete.space).toBe('Self-destruct')
  })

  it('rowMenu gives the order of spec 9.5 for an owned row with an open chat window', () => {
    expect(labels(rowMenu(owned, ctx()))).toEqual([
      'Open',
      'Send message...',
      'Run slash command',
      'Interrupt',
      '-',
      'Set priority',
      'Rename...',
      'Show Info',
      'Copy session ID',
      'Open project',
      'Open in terminal',
      '-',
      'Close window',
      'Stop session...',
      'Delete session...',
    ])
  })

  it('rowMenu shows Take control only for an external row and Resume only for a parked row', () => {
    expect(find(rowMenu(external, ctx()), 'take-control')).toBeDefined()
    expect(find(rowMenu(external, ctx()), 'resume')).toBeUndefined()
    expect(find(rowMenu(parked, ctx()), 'resume')).toBeDefined()
    expect(find(rowMenu(parked, ctx()), 'take-control')).toBeUndefined()
    expect(find(rowMenu(owned, ctx()), 'take-control')).toBeUndefined()
    expect(find(rowMenu(owned, ctx()), 'resume')).toBeUndefined()
  })

  it('rowMenu shows Close window only when the chat window is open', () => {
    expect(find(rowMenu(owned, ctx({ chatOpen: false })), 'close-window')).toBeUndefined()
    expect(find(rowMenu(owned, ctx({ chatOpen: true })), 'close-window')).toBeDefined()
  })

  it('the M3 actions are enabled for an owned row', () => {
    for (const id of ['open', 'set-priority', 'copy-id', 'open-project', 'close-window'] as const) {
      expect(actionStateFor(id, owned, ctx())).toEqual({ enabled: true, reason: null })
    }
  })

  it('the M4 actions are enabled for an owned idle row', () => {
    const ids = [
      'send-message',
      'run-slash',
      'interrupt',
      'rename',
      'open-in-terminal',
      'stop',
      'delete',
    ] as const
    for (const id of ids) {
      expect(actionStateFor(id, owned, ctx())).toEqual({ enabled: true, reason: null })
    }
  })

  it('Show Info still shows Comes in M5', () => {
    expect(actionStateFor('show-info', owned, ctx())).toEqual({
      enabled: false,
      reason: 'Coming in M5',
    })
  })

  it('a red box blocks Send message, Run slash command and Rename, but not Interrupt', () => {
    const red = row({ box: 'red', sessionId: 'r', shortId: 'abcd1234', state: 'needs-you' })
    for (const id of ['send-message', 'run-slash', 'rename'] as const) {
      expect(actionStateFor(id, red, ctx()).reason).toBe(
        'Answer the prompt in the chat window first.',
      )
    }
    expect(actionStateFor('interrupt', red, ctx()).enabled).toBe(true)
  })

  it('actions that type need the short ID', () => {
    const noId = row({ sessionId: 'n', state: 'idle' })
    for (const id of ['send-message', 'run-slash', 'rename', 'interrupt', 'stop'] as const) {
      expect(actionStateFor(id, noId, ctx()).reason).toBe(R.REASON_WAIT_ID)
    }
    expect(actionStateFor('open-in-terminal', noId, ctx()).reason).toBe(R.REASON_WAIT_ID)
  })

  it('Take control is enabled for an idle external row and for a yellow box', () => {
    const ext = (over = {}) =>
      row({ kind: 'external', pid: 42, sessionId: 'e', state: 'idle', ...over })
    expect(actionStateFor('take-control', ext(), ctx())).toEqual({ enabled: true, reason: null })
    expect(
      actionStateFor('take-control', ext({ box: 'yellow', state: 'needs-you' }), ctx()).enabled,
    ).toBe(true)
  })

  it('Take control is blocked for a working row and for a red box with the spec 9.2 reasons', () => {
    const ext = (over = {}) =>
      row({ kind: 'external', pid: 42, sessionId: 'e', state: 'idle', ...over })
    expect(actionStateFor('take-control', ext({ state: 'working' }), ctx()).reason).toBe(
      R.REASON_TAKE_BUSY,
    )
    expect(
      actionStateFor('take-control', ext({ box: 'red', state: 'needs-you' }), ctx()).reason,
    ).toBe(R.REASON_TAKE_PROMPT)
    expect(actionStateFor('take-control', ext({ pid: undefined }), ctx()).reason).toBe(
      R.REASON_NO_PID,
    )
    expect(actionStateFor('take-control', ext({ cwd: '' }), ctx()).reason).toBe(R.REASON_NO_CWD)
  })

  it('the checks run in order', () => {
    const redNoId = row({ box: 'red', sessionId: 'r', state: 'needs-you' })
    expect(actionStateFor('send-message', redNoId, ctx()).reason).toBe(R.REASON_RED_BOX)
    const workingExt = row({ kind: 'external', pid: 42, sessionId: 'e', state: 'working' })
    expect(actionStateFor('take-control', workingExt, ctx({ running: true })).reason).toBe(
      R.REASON_RUNNING,
    )
    const redExtNoPid = row({ box: 'red', kind: 'external', sessionId: 'e', state: 'needs-you' })
    expect(actionStateFor('take-control', redExtNoPid, ctx()).reason).toBe(R.REASON_TAKE_PROMPT)
  })

  it('Stop on a parked row gives REASON_NO_PROCESS', () => {
    expect(actionStateFor('stop', parked, ctx()).reason).toBe(R.REASON_NO_PROCESS)
  })

  it('Delete is enabled for a parked row', () => {
    expect(actionStateFor('delete', parked, ctx()).enabled).toBe(true)
  })

  it('Resume needs a cwd', () => {
    expect(actionStateFor('resume', parked, ctx()).enabled).toBe(true)
    expect(
      actionStateFor('resume', row({ cwd: '', sessionId: 'p', state: 'parked' }), ctx()).reason,
    ).toBe(R.REASON_NO_CWD)
  })

  it('a running action disables Stop, Delete, Resume and Take control', () => {
    const c = ctx({ running: true })
    const ext = row({ kind: 'external', pid: 42, sessionId: 'e', state: 'idle' })
    expect(actionStateFor('stop', owned, c).reason).toBe(R.REASON_RUNNING)
    expect(actionStateFor('delete', owned, c).reason).toBe(R.REASON_RUNNING)
    expect(actionStateFor('resume', parked, c).reason).toBe(R.REASON_RUNNING)
    expect(actionStateFor('take-control', ext, c).reason).toBe(R.REASON_RUNNING)
  })

  it('Open in terminal needs a terminal app, and the terminal app of an external row', () => {
    expect(actionStateFor('open-in-terminal', owned, ctx({ apps: [] })).reason).toBe(
      R.REASON_NO_TERMINAL,
    )
    expect(
      actionStateFor('open-in-terminal', owned, ctx({ apps: [{ id: 'finder', label: 'Finder' }] }))
        .reason,
    ).toBe(R.REASON_NO_TERMINAL)
    expect(actionStateFor('open-in-terminal', external, ctx()).reason).toBe(
      R.REASON_TERMINAL_UNKNOWN,
    )
    const withApp = row({ kind: 'external', sessionId: 'e', terminalApp: 'Warp' })
    expect(actionStateFor('open-in-terminal', withApp, ctx()).enabled).toBe(true)
  })

  it('Resume all needs a resumable row and is blocked while it runs', () => {
    const g = { labels: 'plain', resumable: 2, resumeAllRunning: false } as const
    expect(globalActionState('resume-all', g).enabled).toBe(true)
    expect(globalActionState('resume-all', { ...g, resumable: 0 }).reason).toBe(
      R.REASON_NOTHING_TO_RESUME,
    )
    expect(globalActionState('resume-all', { ...g, resumeAllRunning: true }).reason).toBe(
      R.REASON_RESUME_ALL_RUNS,
    )
    expect(globalActionState('new-session', { ...g, resumable: 0 }).enabled).toBe(true)
  })

  it('the slash submenu gives the favourites, 5 recent commands and Other...', () => {
    const c = ctx({
      slashFavourites: ['/compact', '/clear', '/context'],
      slashRecent: ['/context', '/a', '/b', '/c', '/d', '/e', '/f'],
    })
    const s = find(rowMenu(owned, c), 'run-slash')
    const items = s?.type === 'submenu' ? s.items : []
    expect(items.map(i => i.label)).toEqual([
      '/compact',
      '/clear',
      '/context',
      '/a',
      '/b',
      '/c',
      '/d',
      '/e',
      'Other...',
    ])
    expect(items.filter(i => i.separatorBefore).map(i => i.label)).toEqual(['/a', 'Other...'])
    expect(items.at(-1)?.arg).toBe('/')
    expect(items.map(i => i.key)).toEqual([
      'fav:/compact',
      'fav:/clear',
      'fav:/context',
      'recent:/a',
      'recent:/b',
      'recent:/c',
      'recent:/d',
      'recent:/e',
      'other',
    ])
    expect(items.slice(0, -1).map(i => i.arg)).toEqual(items.slice(0, -1).map(i => i.label))
  })

  it('the availability reason comes before the milestone reason', () => {
    expect(actionStateFor('send-message', external, ctx()).reason).toBe(R.REASON_EXTERNAL)
    expect(actionStateFor('open', parked, ctx()).reason).toBe(R.REASON_PARKED)
    expect(actionStateFor('interrupt', external, ctx()).reason).toBe(R.REASON_EXTERNAL)
    expect(actionStateFor('take-control', owned, ctx()).reason).toBe(R.REASON_ONLY_EXTERNAL)
    expect(actionStateFor('resume', owned, ctx()).reason).toBe(R.REASON_ONLY_PARKED)
  })

  it('Open project is disabled without a cwd or without apps', () => {
    expect(actionStateFor('open-project', row({ cwd: '', sessionId: 'x' }), ctx()).reason).toBe(
      R.REASON_NO_CWD,
    )
    expect(actionStateFor('open-project', owned, ctx({ apps: [] })).reason).toBe(R.REASON_NO_APPS)
  })

  it('Close window is disabled without a chat window', () => {
    expect(actionStateFor('close-window', owned, ctx({ chatOpen: false })).reason).toBe(
      R.REASON_NO_WINDOW,
    )
  })

  it('actionStateFor gives REASON_GONE for a missing row', () => {
    expect(actionStateFor('open', undefined, ctx())).toEqual({
      enabled: false,
      reason: R.REASON_GONE,
    })
  })

  it('Set priority marks the current priority, or None', () => {
    const items = (r: typeof owned) => {
      const e = find(rowMenu(r, ctx()), 'set-priority')
      return e?.type === 'submenu' ? e.items : []
    }
    const withP = items(row({ priority: 2, sessionId: 'x' }))
    expect(withP.map(i => i.label)).toEqual(['1', '2', '3', '4', '5', 'None'])
    expect(withP.filter(i => i.checked).map(i => i.arg)).toEqual([2])
    expect(
      items(owned)
        .filter(i => i.checked)
        .map(i => i.arg),
    ).toEqual([null])
  })

  it('Open project lists the apps, and Run slash command has only Other... without commands', () => {
    const m = rowMenu(owned, ctx())
    const p = find(m, 'open-project')
    expect(p?.type === 'submenu' && p.items).toEqual([
      { arg: 'finder', key: 'finder', label: 'Finder' },
      { arg: 'warp', key: 'warp', label: 'Warp' },
    ])
    const s = find(m, 'run-slash')
    expect(s?.type === 'submenu' && s.items.map(i => i.label)).toEqual(['Other...'])
  })

  it('space labels change each label', () => {
    const m = labels(rowMenu(owned, ctx({ labels: 'space' })))
    expect(m).toContain('Warp to')
    expect(m).toContain('Hail...')
    expect(m).toContain('Power down...')
  })

  it('buttonTip gives the label, and the reason on a second line when disabled', () => {
    expect(buttonTip('open', actionStateFor('open', owned, ctx()), 'plain')).toBe('Open')
    expect(buttonTip('stop', actionStateFor('stop', owned, ctx()), 'plain')).toBe('Stop session')
    expect(buttonTip('stop', actionStateFor('stop', parked, ctx()), 'plain')).toBe(
      `Stop session\n${R.REASON_NO_PROCESS}`,
    )
    expect(buttonTip('open', actionStateFor('open', parked, ctx()), 'space')).toBe(
      `Warp to\n${R.REASON_PARKED}`,
    )
  })
})
