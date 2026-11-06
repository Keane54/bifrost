import { describe, expect, it } from 'vitest'
import {
  focusedOverview,
  type KeyContext,
  planHold,
  planKey,
  stepRow,
  stepStack,
  stepTab,
} from '../../../src/renderer/src/keys/commands'
import { defaultOverviewConfig } from '../../../src/renderer/src/overview/config'
import type { Frame } from '../../../src/renderer/src/wm/state'
import { slotById } from '../../../src/shared/keys'
import type { ProjectApp } from '../../../src/shared/types'
import { row } from '../overview/fixtures'

const S1 = 'S1'
const S2 = 'S2'
const S3 = 'S3'

const RECT = { h: 100, w: 100, x: 0, y: 0 }
const f1: Frame = {
  active: 'overview:1',
  id: 'f1',
  locked: false,
  minimised: false,
  panels: ['overview:1'],
  rect: RECT,
}
const f2: Frame = {
  active: `chat:${S1}`,
  id: 'f2',
  locked: false,
  minimised: false,
  panels: ['selected-item', `chat:${S1}`],
  rect: RECT,
}

const rows = [
  row({ sessionId: S1, state: 'idle' }),
  row({ sessionId: S2, state: 'idle' }),
  row({ sessionId: S3, state: 'parked' }),
]
const APPS: ProjectApp[] = [
  { id: 'finder', label: 'Finder' },
  { id: 'vscode', label: 'VS Code' },
]

function ctx(over: Partial<KeyContext> = {}): KeyContext {
  return {
    apps: APPS,
    frames: [f1, f2],
    overviews: {},
    projectApp: null,
    rows,
    selectedId: S2,
    zone: 'other',
    ...over,
  }
}

function plan(id: string, over: Partial<KeyContext> = {}) {
  const slot = slotById(id)
  if (!slot) throw new Error(`no slot ${id}`)
  return planKey(slot, ctx(over))
}

describe('planKey', () => {
  it('a session command acts on the selected row', () => {
    expect(plan('open:key')).toEqual({ action: 'open', kind: 'action', sessionId: S2 })
    expect(plan('stop:mod', { selectedId: S1 })).toEqual({
      action: 'stop',
      kind: 'action',
      sessionId: S1,
    })
  })

  it('a session key in a chat window acts on the selection, which the chat focus sets', () => {
    // focusChange selects the session of a focused chat window. So S1 is the selection here.
    for (const id of ['interrupt:mod', 'stop:mod', 'resume:mod', 'run-slash:mod']) {
      const slot = slotById(id)
      expect(plan(id, { selectedId: S1, zone: 'chat' })).toEqual({
        action: slot?.command,
        kind: 'action',
        sessionId: S1,
      })
    }
  })

  it('a session command without a selection gives none', () => {
    expect(plan('open:key', { selectedId: null })).toEqual({ kind: 'none' })
  })

  it('a selected ID that is not in the rows gives none', () => {
    expect(plan('open:key', { selectedId: 'gone' })).toEqual({ kind: 'none' })
  })

  it('set-priority gives the number and 0 gives null', () => {
    expect(plan('set-priority.3:mod')).toEqual({
      action: 'set-priority',
      arg: 3,
      kind: 'action',
      sessionId: S2,
    })
    expect(plan('set-priority.0:key')).toEqual({
      action: 'set-priority',
      arg: null,
      kind: 'action',
      sessionId: S2,
    })
  })

  it('open-project uses the default project app', () => {
    expect(plan('open-project:mod')).toEqual({
      action: 'open-project',
      arg: 'vscode',
      kind: 'action',
      sessionId: S2,
    })
    expect(plan('open-project:mod', { projectApp: 'finder' })).toMatchObject({ arg: 'vscode' })
    expect(plan('open-project:mod', { apps: [] })).toEqual({ kind: 'none' })
  })

  it('new-session and resume-all are global', () => {
    expect(plan('new-session:mod', { selectedId: null })).toEqual({
      action: 'new-session',
      kind: 'global',
    })
    expect(plan('resume-all:mod')).toEqual({ action: 'resume-all', kind: 'global' })
  })

  it('select-row selects the n-th row of the focused Overview', () => {
    expect(plan('select-row.2:mod')).toEqual({ kind: 'select', sessionId: S2 })
    expect(plan('select-row.3:mod')).toEqual({ kind: 'none' })
  })

  it('select-row uses the active tab of the focused Overview', () => {
    const config = { ...defaultOverviewConfig(), active: 't5' }
    expect(plan('select-row.1:mod', { overviews: { 'overview:1': config } })).toEqual({
      kind: 'select',
      sessionId: S3,
    })
  })

  it('select-next stops at the last row and starts at the first row without a selection', () => {
    expect(plan('select-next:key', { selectedId: null })).toEqual({
      kind: 'select',
      sessionId: S1,
    })
    expect(plan('select-next:key', { selectedId: S1 })).toEqual({ kind: 'select', sessionId: S2 })
    expect(plan('select-next:key', { selectedId: S2 })).toEqual({ kind: 'none' })
    expect(plan('select-prev:key', { selectedId: S1 })).toEqual({ kind: 'none' })
    expect(plan('select-prev:mod', { selectedId: null })).toEqual({
      kind: 'select',
      sessionId: S2,
    })
  })

  it('focus-overview gives the focused Overview, or null', () => {
    expect(plan('focus-overview:mod')).toEqual({ kind: 'focus-overview', panelId: 'overview:1' })
    expect(plan('focus-overview:mod', { frames: [f2] })).toEqual({
      kind: 'focus-overview',
      panelId: null,
    })
  })

  it('next-overview-tab wraps from the last tab to the first', () => {
    const config = { ...defaultOverviewConfig(), active: 't5' }
    expect(plan('next-overview-tab:key', { overviews: { 'overview:1': config } })).toEqual({
      kind: 'overview-tab',
      panelId: 'overview:1',
      tabId: 't1',
    })
    expect(plan('prev-overview-tab:key')).toEqual({
      kind: 'overview-tab',
      panelId: 'overview:1',
      tabId: 't5',
    })
    expect(plan('next-overview-tab:key', { frames: [f2] })).toEqual({ kind: 'none' })
  })

  it('next-stack-tab activates the next panel of the top frame and wraps', () => {
    expect(plan('next-stack-tab:mod')).toEqual({
      kind: 'activate-panel',
      panelId: 'selected-item',
    })
    expect(plan('prev-stack-tab:mod')).toEqual({
      kind: 'activate-panel',
      panelId: 'selected-item',
    })
    expect(plan('next-stack-tab:mod', { frames: [f1] })).toEqual({ kind: 'none' })
  })

  it('escape leaves the send box, or clears the selection', () => {
    expect(plan('escape:key', { zone: 'send-box' })).toEqual({ kind: 'leave-send-box' })
    expect(plan('escape:key', { selectedId: S1, zone: 'other' })).toEqual({
      kind: 'select',
      sessionId: null,
    })
    expect(plan('escape:key', { selectedId: S1, zone: 'control' })).toEqual({
      kind: 'select',
      sessionId: null,
    })
    expect(plan('escape:key', { selectedId: null, zone: 'other' })).toEqual({ kind: 'none' })
    expect(plan('escape:key', { selectedId: S1, zone: 'chat' })).toEqual({ kind: 'none' })
  })

  it('load-layout.3 gives index 2, and save-layout and the panels have their intent', () => {
    expect(plan('load-layout.3:mod')).toEqual({ index: 2, kind: 'load-layout' })
    expect(plan('save-layout:mod')).toEqual({ kind: 'save-layout' })
    expect(plan('event-log:mod')).toEqual({ kind: 'open-panel', panelId: 'event-log' })
    expect(plan('usage-hud:mod')).toEqual({ kind: 'open-panel', panelId: 'usage-hud' })
    expect(plan('settings:mod')).toEqual({ kind: 'open-panel', panelId: 'settings' })
  })

  it('the menu slots give none', () => {
    expect(plan('close-panel:mod')).toEqual({ kind: 'none' })
    expect(plan('toggle-fullscreen:mod')).toEqual({ kind: 'none' })
  })
})

describe('planHold', () => {
  it('planHold acts on the clicked row', () => {
    const slot = slotById('set-priority.4:hold')
    if (!slot) throw new Error('no slot')
    expect(planHold(slot, S2, { apps: APPS, projectApp: null })).toEqual({
      action: 'set-priority',
      arg: 4,
      kind: 'action',
      sessionId: S2,
    })
    const open = slotById('open:hold')
    if (!open) throw new Error('no slot')
    expect(planHold(open, S3, { apps: APPS, projectApp: null })).toEqual({
      action: 'open',
      kind: 'action',
      sessionId: S3,
    })
  })
})

describe('helpers', () => {
  it('the focused Overview is the highest frame that shows an Overview', () => {
    expect(focusedOverview([f1, f2])).toBe('overview:1')
    expect(focusedOverview([{ ...f1, minimised: true }, f2])).toBeNull()
    const f3: Frame = { ...f1, active: 'overview:2', id: 'f3', panels: ['overview:2'] }
    expect(focusedOverview([f1, f3, f2])).toBe('overview:2')
  })

  it('the focused Overview needs the Overview as the active panel', () => {
    const stack: Frame = { ...f1, active: 'watchlist', panels: ['overview:1', 'watchlist'] }
    expect(focusedOverview([stack])).toBeNull()
  })

  it('stepRow, stepTab and stepStack give null or wrap at the edges', () => {
    expect(stepRow([], S1, 1)).toBeNull()
    expect(stepRow(rows, 'gone', 1)).toBe(S1)
    expect(stepRow(rows, 'gone', -1)).toBe(S3)
    expect(stepTab(defaultOverviewConfig(), -1)).toBe('t5')
    expect(stepStack([f2], 1)).toBe('selected-item')
    expect(stepStack([f1], 1)).toBeNull()
    expect(stepStack([f2, { ...f1, minimised: true }], 1)).toBe('selected-item')
  })
})
