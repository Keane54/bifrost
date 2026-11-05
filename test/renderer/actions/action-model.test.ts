import { describe, expect, it } from 'vitest'
import {
  ACTIONS,
  type ActionContext,
  type ActionId,
  actionStateFor,
  type MenuEntry,
  rowMenu,
} from '../../../src/renderer/src/actions/action-model'
import * as R from '../../../src/renderer/src/actions/reasons'
import { row } from '../overview/fixtures'

const ctx = (over: Partial<ActionContext> = {}): ActionContext => ({
  apps: [{ id: 'finder', label: 'Finder' }],
  chatOpen: true,
  labels: 'plain',
  ...over,
})
const owned = row({ sessionId: 'o' })
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

  it('the M4 actions of an owned row are disabled with the reason Comes in M4', () => {
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
      expect(actionStateFor(id, owned, ctx())).toEqual({ enabled: false, reason: 'Comes in M4' })
    }
  })

  it('Show Info is disabled with the reason Comes in M5', () => {
    expect(actionStateFor('show-info', owned, ctx())).toEqual({
      enabled: false,
      reason: 'Comes in M5',
    })
  })

  it('the availability reason comes before the milestone reason', () => {
    expect(actionStateFor('send-message', external, ctx()).reason).toBe(R.REASON_EXTERNAL)
    expect(actionStateFor('open', parked, ctx()).reason).toBe(R.REASON_PARKED)
    expect(actionStateFor('take-control', external, ctx()).reason).toBe('Comes in M4')
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

  it('Open project lists the apps, and Run slash command has no items in M3', () => {
    const m = rowMenu(owned, ctx())
    const p = find(m, 'open-project')
    expect(p?.type === 'submenu' && p.items).toEqual([
      { arg: 'finder', key: 'finder', label: 'Finder' },
    ])
    const s = find(m, 'run-slash')
    expect(s?.type === 'submenu' && s.items).toEqual([])
  })

  it('space labels change each label', () => {
    const m = labels(rowMenu(owned, ctx({ labels: 'space' })))
    expect(m).toContain('Warp to')
    expect(m).toContain('Hail...')
    expect(m).toContain('Power down...')
  })
})
