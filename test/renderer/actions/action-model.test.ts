import { describe, expect, it } from 'vitest'
import {
  ACTIONS,
  type ActionContext,
  type ActionId,
  actionStateFor,
  buttonTip,
  checkedKey,
  globalActionState,
  HAND_OVER_WARN_PERCENT,
  handOverWarning,
  type MenuEntry,
  rowMenu,
  SELECTED_ITEM_ACTIONS,
} from '../../../src/renderer/src/actions/action-model'
import { friendlyError } from '../../../src/renderer/src/actions/errors'
import * as R from '../../../src/renderer/src/actions/reasons'
import type { SessionRow } from '../../../src/shared/types'
import { row } from '../overview/fixtures'

const ctx = (over: Partial<ActionContext> = {}): ActionContext => ({
  apps: [
    { id: 'finder', label: 'Finder' },
    { id: 'warp', label: 'Warp' },
  ],
  chatOpen: true,
  folderShared: false,
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
      'Compact',
      'Hand over',
      'Interrupt',
      '-',
      'Set priority',
      'Add to watchlist',
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

  it('the watch labels: plain and space', () => {
    expect([ACTIONS['watch-add'].plain, ACTIONS['watch-add'].space]).toEqual([
      'Add to watchlist',
      'Track',
    ])
    expect([ACTIONS['watch-remove'].plain, ACTIONS['watch-remove'].space]).toEqual([
      'Remove from watchlist',
      'Stop tracking',
    ])
    expect(ACTIONS['watch-colour'].plain).toBe('Change colour')
  })

  it('rowMenu gives Add to watchlist with the 8 colours for an unwatched row', () => {
    const menu = rowMenu(owned, ctx())
    const add = find(menu, 'watch-add')
    expect(add).toMatchObject({ label: 'Add to watchlist', type: 'submenu' })
    expect(find(menu, 'watch-colour')).toBeUndefined()
    expect(find(menu, 'watch-remove')).toBeUndefined()
    if (add?.type !== 'submenu') throw new Error('not a submenu')
    expect(add.items.map(i => [i.label, i.arg])).toEqual([
      ['Dark red', 'dark-red'],
      ['Red', 'red'],
      ['Amber', 'amber'],
      ['Yellow', 'yellow'],
      ['Green', 'green'],
      ['Light blue', 'light-blue'],
      ['Dark blue', 'dark-blue'],
      ['White', 'white'],
    ])
    expect(add.state).toEqual({ enabled: true, reason: null })
  })

  it('rowMenu gives Change colour and Remove for a watched row, with a check on its colour', () => {
    const watched = row({ sessionId: 'w', watch: { colour: 'green', order: 0 } })
    const menu = rowMenu(watched, ctx())
    expect(find(menu, 'watch-add')).toBeUndefined()
    expect(find(menu, 'watch-remove')).toMatchObject({
      label: 'Remove from watchlist',
      type: 'item',
    })
    const change = find(menu, 'watch-colour')
    if (change?.type !== 'submenu') throw new Error('not a submenu')
    expect(change.label).toBe('Change colour')
    expect(change.items.filter(i => i.checked).map(i => i.arg)).toEqual(['green'])
  })

  it('the watch actions use the space labels', () => {
    const menu = rowMenu(owned, ctx({ labels: 'space' }))
    expect(find(menu, 'watch-add')).toMatchObject({ label: 'Track' })
    const watched = row({ sessionId: 'w', watch: { colour: 'green', order: 0 } })
    expect(find(rowMenu(watched, ctx({ labels: 'space' })), 'watch-remove')).toMatchObject({
      label: 'Stop tracking',
    })
  })

  it('the watch actions work for every row class', () => {
    for (const r of [owned, external, parked]) {
      expect(actionStateFor('watch-add', r, ctx()).enabled).toBe(true)
    }
    const watched = row({ kind: 'external', sessionId: 'w', watch: { colour: 'red', order: 0 } })
    expect(actionStateFor('watch-remove', watched, ctx()).enabled).toBe(true)
    expect(actionStateFor('watch-colour', watched, ctx()).enabled).toBe(true)
  })

  it('a watch action that does not fit the row is off with a reason', () => {
    const watched = row({ sessionId: 'w', watch: { colour: 'red', order: 0 } })
    expect(actionStateFor('watch-add', watched, ctx())).toEqual({
      enabled: false,
      reason: 'This session is already on the watchlist.',
    })
    for (const id of ['watch-colour', 'watch-remove'] as const) {
      expect(actionStateFor(id, owned, ctx())).toEqual({
        enabled: false,
        reason: "This session isn't on the watchlist.",
      })
    }
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

  it('Show Info is enabled for owned, external and parked rows', () => {
    for (const r of [owned, external, parked]) {
      expect(actionStateFor('show-info', r, ctx())).toEqual({ enabled: true, reason: null })
    }
  })

  it('a red box blocks Send message and Run slash command, but not Interrupt or Rename', () => {
    const red = row({ box: 'red', sessionId: 'r', shortId: 'abcd1234', state: 'needs-you' })
    for (const id of ['send-message', 'run-slash'] as const) {
      expect(actionStateFor(id, red, ctx()).reason).toBe(
        'Answer the prompt in the chat window first.',
      )
    }
    expect(actionStateFor('interrupt', red, ctx()).enabled).toBe(true)
    expect(actionStateFor('rename', red, ctx()).enabled).toBe(true)
  })

  it('Rename is enabled for owned, external and parked rows, also without a short ID', () => {
    for (const r of [owned, external, parked, row({ sessionId: 'n', state: 'idle' })]) {
      expect(actionStateFor('rename', r, ctx())).toEqual({ enabled: true, reason: null })
    }
  })

  // Spec 8.4: an escalated yellow box and an error box show no prompt, so they do not block.
  const redBox = (over: Partial<SessionRow> = {}) =>
    row({ box: 'red', sessionId: 'r', shortId: 'abcd1234', state: 'needs-you', ...over })
  const TYPED = ['send-message', 'run-slash'] as const

  it('an escalated box and an error box do not block Send message and Run slash command', () => {
    for (const red of [redBox({ boxReason: 'escalated' }), redBox({ boxReason: 'error' })]) {
      for (const id of TYPED) {
        expect(actionStateFor(id, red, ctx())).toEqual({ enabled: true, reason: null })
      }
    }
  })

  it('a prompt box and a red box with no reason block Send message and Run slash command', () => {
    for (const red of [redBox({ boxReason: 'prompt' }), redBox()]) {
      for (const id of TYPED) {
        expect(actionStateFor(id, red, ctx()).reason).toBe(R.REASON_RED_BOX)
      }
    }
  })

  it('Take control stays blocked for an escalated box and an error box (spec 9.2)', () => {
    for (const boxReason of ['escalated', 'error'] as const) {
      const red = redBox({ boxReason, kind: 'external', pid: 42, sessionId: 'e' })
      expect(actionStateFor('take-control', red, ctx()).reason).toBe(R.REASON_TAKE_PROMPT)
    }
  })

  it('actions that type need the short ID', () => {
    const noId = row({ sessionId: 'n', state: 'idle' })
    for (const id of ['send-message', 'run-slash', 'interrupt', 'stop'] as const) {
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

  it('each action gives the reason of its row class', () => {
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

  // User decision (2026-11-10): Compact sends /compact with one click.
  describe('Compact', () => {
    const idle = (over: Partial<SessionRow> = {}) =>
      row({ sessionId: 'c', shortId: 'abcd1234', state: 'idle', ...over })

    it('has the plain label Compact and the space label Compress cargo, for owned rows only', () => {
      expect([ACTIONS.compact.plain, ACTIONS.compact.space]).toEqual(['Compact', 'Compress cargo'])
      expect(ACTIONS.compact.for).toEqual(['owned'])
    })

    it('is enabled for an owned row that is idle, has finished or has an error', () => {
      const rows = [
        idle(),
        idle({ box: 'yellow', state: 'needs-you' }),
        idle({ box: 'red', boxReason: 'escalated', state: 'needs-you' }),
        idle({ box: 'red', boxReason: 'error', state: 'error' }),
      ]
      for (const r of rows) {
        expect(actionStateFor('compact', r, ctx())).toEqual({ enabled: true, reason: null })
      }
    })

    it('gives the reason of the row class for an external row and a parked row', () => {
      expect(actionStateFor('compact', external, ctx()).reason).toBe(R.REASON_EXTERNAL)
      expect(actionStateFor('compact', parked, ctx()).reason).toBe(R.REASON_PARKED)
    })

    it('is blocked by a prompt box and by a red box with no reason', () => {
      for (const red of [redBox({ boxReason: 'prompt' }), redBox()]) {
        expect(actionStateFor('compact', red, ctx()).reason).toBe(R.REASON_RED_BOX)
      }
    })

    it('needs the short ID', () => {
      expect(actionStateFor('compact', idle({ shortId: undefined }), ctx()).reason).toBe(
        R.REASON_WAIT_ID,
      )
    })

    it('is disabled while the session is working, with the reason in the tooltip', () => {
      const state = actionStateFor('compact', idle({ state: 'working' }), ctx())
      expect(state).toEqual({ enabled: false, reason: 'Wait until the session is idle.' })
      expect(R.REASON_WAIT_IDLE).toBe('Wait until the session is idle.')
      expect(buttonTip('compact', state, 'plain')).toBe('Compact\nWait until the session is idle.')
      expect(buttonTip('compact', state, 'space')).toBe(
        'Compress cargo\nWait until the session is idle.',
      )
    })

    it('checks the row class, the red box and the short ID before the working state', () => {
      const working = row({ sessionId: 'w', state: 'working' })
      expect(actionStateFor('compact', { ...working, kind: 'external' }, ctx()).reason).toBe(
        R.REASON_EXTERNAL,
      )
      expect(actionStateFor('compact', working, ctx()).reason).toBe(R.REASON_WAIT_ID)
    })

    it('another action that runs on the session does not block it', () => {
      expect(actionStateFor('compact', idle(), ctx({ running: true })).enabled).toBe(true)
    })

    it('is a plain menu entry after Run slash command, with no three full stops', () => {
      const menu = rowMenu(owned, ctx())
      expect(find(menu, 'compact')).toMatchObject({ label: 'Compact', type: 'item' })
      const ids = menu.map(e => (e.type === 'separator' ? '-' : e.action))
      expect(ids.indexOf('compact')).toBe(ids.indexOf('run-slash') + 1)
      expect(find(rowMenu(owned, ctx({ labels: 'space' })), 'compact')).toMatchObject({
        label: 'Compress cargo',
      })
    })

    it('the menu entry shows for each row class, disabled with the reason where it does not apply', () => {
      expect(find(rowMenu(external, ctx()), 'compact')).toMatchObject({
        state: { enabled: false, reason: R.REASON_EXTERNAL },
      })
      expect(find(rowMenu(parked, ctx()), 'compact')).toMatchObject({
        state: { enabled: false, reason: R.REASON_PARKED },
      })
    })

    it('is a Selected Item button after Run slash command', () => {
      expect(SELECTED_ITEM_ACTIONS).toEqual([
        'open',
        'send-message',
        'run-slash',
        'compact',
        'hand-over',
        'interrupt',
        'show-info',
        'open-in-terminal',
        'stop',
      ])
    })
  })

  describe('Hand over', () => {
    const idle = (over: Partial<SessionRow> = {}) =>
      row({ sessionId: 'h', shortId: 'abcd1234', state: 'idle', ...over })

    it('has the labels Hand over and Transfer command, for owned rows only', () => {
      expect([ACTIONS['hand-over'].plain, ACTIONS['hand-over'].space]).toEqual([
        'Hand over',
        'Transfer command',
      ])
      expect(ACTIONS['hand-over'].for).toEqual(['owned'])
    })

    it('is enabled for an owned row that waits, also with a yellow box', () => {
      for (const r of [idle(), idle({ box: 'yellow', state: 'needs-you' })]) {
        expect(actionStateFor('hand-over', r, ctx())).toEqual({ enabled: true, reason: null })
      }
    })

    it('gives the reason of the row class for an external row and a parked row', () => {
      expect(actionStateFor('hand-over', external, ctx()).reason).toBe(R.REASON_EXTERNAL)
      expect(actionStateFor('hand-over', parked, ctx()).reason).toBe(R.REASON_PARKED)
    })

    it('is blocked by a red box, by a missing short ID and by a working row', () => {
      expect(actionStateFor('hand-over', redBox(), ctx()).reason).toBe(R.REASON_RED_BOX)
      expect(actionStateFor('hand-over', idle({ shortId: undefined }), ctx()).reason).toBe(
        R.REASON_WAIT_ID,
      )
      expect(actionStateFor('hand-over', idle({ state: 'working' }), ctx()).reason).toBe(
        R.REASON_WAIT_IDLE,
      )
    })

    it('is disabled for a review session of a PR, with a reason', () => {
      const state = actionStateFor('hand-over', idle({ prSession: true }), ctx())
      expect(state).toEqual({ enabled: false, reason: R.REASON_PR_SESSION })
      expect(actionStateFor('hand-over', idle(), ctx()).enabled).toBe(true)
    })

    it('is blocked while another action runs on the session', () => {
      expect(actionStateFor('hand-over', idle(), ctx({ running: true })).reason).toBe(
        R.REASON_RUNNING,
      )
    })

    it('is a menu entry after Compact and a Selected Item button', () => {
      const ids = rowMenu(owned, ctx()).map(e => (e.type === 'separator' ? '-' : e.action))
      expect(ids.indexOf('hand-over')).toBe(ids.indexOf('compact') + 1)
      expect(find(rowMenu(owned, ctx({ labels: 'space' })), 'hand-over')).toMatchObject({
        label: 'Transfer command',
      })
    })

    it('handOverWarning is true from 80 percent, after rounding', () => {
      expect(HAND_OVER_WARN_PERCENT).toBe(80)
      expect(handOverWarning({ contextPercent: undefined })).toBe(false)
      expect(handOverWarning({ contextPercent: 79.4 })).toBe(false)
      expect(handOverWarning({ contextPercent: 79.5 })).toBe(true)
      expect(handOverWarning({ contextPercent: 80 })).toBe(true)
    })
  })

  describe('Delete and a shared folder (spec 8 of the skills design)', () => {
    it('Delete is enabled for a parked row whose folder a running row uses', () => {
      const state = actionStateFor('delete', parked, ctx({ folderShared: true }))
      expect(state).toEqual({ enabled: true, reason: null })
      expect(Object.keys(R)).not.toContain('REASON_FOLDER_IN_USE')
    })

    it('stays enabled when no session uses the folder', () => {
      expect(actionStateFor('delete', parked, ctx()).enabled).toBe(true)
    })

    it('gives REASON_RUNNING while an action runs', () => {
      const c = ctx({ folderShared: true, running: true })
      expect(actionStateFor('delete', parked, c).reason).toBe(R.REASON_RUNNING)
    })
  })

  // Bug 4: the colour items use the same check mark rule as Set priority.
  it('checkedKey gives the key of the checked item, or undefined', () => {
    expect(
      checkedKey([
        { arg: 1, key: '1', label: 'One' },
        { arg: 2, checked: true, key: '2', label: 'Two' },
      ]),
    ).toBe('2')
    expect(checkedKey([{ arg: 1, checked: false, key: '1', label: 'One' }])).toBeUndefined()
    const watched = row({ sessionId: 'w', watch: { colour: 'light-blue', order: 0 } })
    const change = find(rowMenu(watched, ctx()), 'watch-colour')
    if (change?.type !== 'submenu') throw new Error('not a submenu')
    expect(checkedKey(change.items)).toBe('light-blue')
    // A row that is not watched has no colour to mark.
    const add = find(rowMenu(owned, ctx()), 'watch-add')
    if (add?.type !== 'submenu') throw new Error('not a submenu')
    expect(checkedKey(add.items)).toBeUndefined()
  })
})

describe('Resume of a review session', () => {
  it('is disabled for a review session of a PR, with a reason', () => {
    const parkedPr = row({ prSession: true, sessionId: 'p', state: 'parked' })
    expect(actionStateFor('resume', parkedPr, ctx())).toEqual({
      enabled: false,
      reason: R.REASON_PR_RESUME,
    })
    expect(actionStateFor('resume', parked, ctx()).enabled).toBe(true)
    expect(friendlyError('refused: a review session cannot be resumed')).toBe(R.REASON_PR_RESUME)
  })
})
