// The pure helpers of the Daily update panel (Daily update design, section 6.2).
import { describe, expect, it } from 'vitest'
import {
  areaSince,
  areaView,
  COPIED_MS,
  clockText,
  dueText,
  failureLine,
  firstUnsentArea,
  itemChange,
  movedHeader,
  NEW_DRAFT,
  NO_DRAFT,
  NOT_SENT,
  NOTHING_DUE,
  NOTHING_MOVED,
  panelBody,
  REDO_CONFIRM,
  REFRESHING,
  redoNeedsConfirm,
  refreshText,
  SEND_TIP,
  SENT,
  SET_UP,
  SKIPPED,
  sendText,
  sentText,
  shownTab,
  skipButton,
  statusText,
  tabMarker,
  unplacedText,
} from '../../../src/renderer/src/daily-update/panel-model'
import { freshMarks } from '../../../src/shared/daily-schedule'
import {
  type AreaView,
  type DailySnapshot,
  type DailyState,
  EMPTY_DAILY_STATE,
  failureText,
} from '../../../src/shared/daily-state'
import type { WorkArea } from '../../../src/shared/daily-update'

// Wednesday 11 November 2026, local time.
const at = (h: number, m: number, day = 11): number => new Date(2026, 10, day, h, m).getTime()
const NOW = at(9, 41)
const TODAY = '2026-11-11'

const area = (id: string, name: string): WorkArea => ({
  channel: `#${id}`,
  description: '',
  id,
  name,
  on: true,
  takesRest: false,
})
const A = area('a', 'Platform')
const B = area('b', 'Billing')

function state(patch: Partial<DailyState> = {}): DailyState {
  return { ...EMPTY_DAILY_STATE, marks: freshMarks(TODAY), ...patch }
}

function snap(patch: Partial<DailySnapshot> = {}, s: Partial<DailyState> = {}): DailySnapshot {
  return {
    areas: [A, B],
    configured: true,
    deadline: '10:00',
    due: true,
    marker: true,
    running: false,
    since: { a: at(9, 0, 10), b: at(9, 0, 10) },
    state: state(s),
    ...patch,
  }
}

const sent = (ids: Record<string, number>, skipped = false): Partial<DailyState> => ({
  marks: { ...freshMarks(TODAY), sent: ids, skipped },
})

const view = (patch: Partial<AreaView> = {}): AreaView => ({
  draft: '**Daily update**',
  edited: false,
  items: [],
  moved: false,
  ...patch,
})

describe('statusText', () => {
  it('says not sent yet while an area is not sent', () => {
    expect(statusText(snap(), NOW)).toBe('Not sent yet')
    expect(statusText(snap({}, sent({ a: at(9, 30) })), NOW)).toBe(NOT_SENT)
  })

  it('says sent when each area is sent', () => {
    expect(statusText(snap({}, sent({ a: at(9, 30), b: at(9, 31) })), NOW)).toBe('Sent')
    expect(SENT).toBe('Sent')
  })

  it('says skipped today after a skip', () => {
    expect(statusText(snap({}, sent({}, true)), NOW)).toBe('Skipped today')
    expect(SKIPPED).toBe('Skipped today')
  })

  it('says nothing due today on a day that is not due', () => {
    expect(statusText(snap({ due: false }), NOW)).toBe('Nothing due today')
    expect(statusText(snap({ due: false }, sent({}, true)), NOW)).toBe(NOTHING_DUE)
  })

  it('ignores the marks of an earlier day', () => {
    const old = { marks: { ...freshMarks('2026-11-10'), skipped: true } }
    expect(statusText(snap({}, old), NOW)).toBe('Not sent yet')
  })
})

describe('the status line parts', () => {
  it('gives the deadline only on a due day', () => {
    expect(dueText(snap())).toBe('Due 10:00')
    expect(dueText(snap({ deadline: '09:45' }))).toBe('Due 09:45')
    expect(dueText(snap({ due: false }))).toBeNull()
  })

  it('gives the time of the last run, or Refreshing while a run runs', () => {
    const run = (ms: number, ok = true) => snap({}, { lastRun: { at: ms, ok } })
    expect(refreshText(snap(), NOW)).toBeNull()
    expect(refreshText(run(at(9, 31)), NOW)).toBe('Refreshed 09:31')
    expect(refreshText(run(at(9, 31), false), NOW)).toBe('Refreshed 09:31')
    expect(refreshText(snap({ running: true }), NOW)).toBe('Refreshing…')
    expect(REFRESHING).toBe('Refreshing…')
  })

  it('gives the day of a run that was not today, and the date of an older run', () => {
    const run = (ms: number) => snap({}, { lastRun: { at: ms, ok: true } })
    expect(refreshText(run(at(9, 31, 10)), NOW)).toBe('Refreshed Tue 09:31')
    expect(refreshText(run(at(9, 31, 5)), NOW)).toBe('Refreshed Thu 09:31')
    expect(refreshText(run(at(9, 31, 2)), NOW)).toBe('Refreshed Mon 2 Nov 09:31')
  })

  it('writes a time as HH:MM in 24 hours', () => {
    expect(clockText(at(9, 5))).toBe('09:05')
    expect(clockText(at(17, 45))).toBe('17:45')
  })

  it('offers Skip today on a due day, and Undo after a skip', () => {
    expect(skipButton(snap())).toBe('skip')
    expect(skipButton(snap({}, sent({}, true)))).toBe('undo')
    expect(skipButton(snap({ due: false }))).toBeNull()
  })
})

describe('unplacedText', () => {
  it('gives the singular and the plural text, and nothing for none', () => {
    expect(unplacedText(0)).toBeNull()
    expect(unplacedText(1)).toBe('1 ticket fits no area')
    expect(unplacedText(3)).toBe('3 tickets fit no area')
  })
})

describe('firstUnsentArea', () => {
  it('gives the first area in the order of the settings that is not sent', () => {
    expect(firstUnsentArea(snap())).toBe('a')
    expect(firstUnsentArea(snap({}, sent({ a: at(9, 30) })))).toBe('b')
    expect(firstUnsentArea(snap({ areas: [B, A] }))).toBe('b')
  })

  it('gives null when each area is sent', () => {
    expect(firstUnsentArea(snap({}, sent({ a: at(9, 30), b: at(9, 31) })))).toBeNull()
    expect(firstUnsentArea(snap({ areas: [] }))).toBeNull()
  })
})

describe('tabMarker', () => {
  it('marks a tab that is not sent on a due day', () => {
    const s = snap({}, sent({ a: at(9, 30) }))
    expect(tabMarker(s, 'a')).toBe(false)
    expect(tabMarker(s, 'b')).toBe(true)
  })

  it('marks no tab after a skip or on a day that is not due', () => {
    expect(tabMarker(snap({}, sent({}, true)), 'a')).toBe(false)
    expect(tabMarker(snap({ due: false }), 'a')).toBe(false)
  })
})

describe('shownTab', () => {
  it('keeps the chosen tab of an area that is on', () => {
    expect(shownTab(snap(), 'b')).toBe('b')
  })

  it('gives the first unsent area for no choice or an area that is gone', () => {
    expect(shownTab(snap({}, sent({ a: at(9, 30) })), null)).toBe('b')
    expect(shownTab(snap(), 'gone')).toBe('a')
  })

  it('gives the first area when each area is sent, and null with no area', () => {
    expect(shownTab(snap({}, sent({ a: at(9, 30), b: at(9, 31) })), null)).toBe('a')
    expect(shownTab(snap({ areas: [] }), null)).toBeNull()
  })
})

describe('movedHeader', () => {
  it('gives the day and the time of the start', () => {
    expect(movedHeader(at(9, 0, 10), NOW)).toBe('Moved since your last update (Tue 09:00)')
    expect(movedHeader(at(17, 45, 6), NOW)).toBe('Moved since your last update (Fri 17:45)')
    expect(movedHeader(at(9, 0, 5), NOW)).toBe('Moved since your last update (Thu 09:00)')
  })

  it('gives the date of a start more than 6 days ago', () => {
    expect(movedHeader(at(9, 0, 4), NOW)).toBe('Moved since your last update (Wed 4 Nov 09:00)')
    expect(movedHeader(at(9, 41, 2), NOW)).toBe('Moved since your last update (Mon 2 Nov 09:41)')
  })

  it('gives the header with no time when the start is not known', () => {
    expect(movedHeader(undefined, NOW)).toBe('Moved since your last update')
  })
})

describe('areaSince', () => {
  it('gives the start of the run that made the list of the area', () => {
    const a = view({ since: at(9, 0, 9) })
    const s = snap({ since: { a: at(9, 30), b: at(9, 0, 10) } }, { areas: { a, b: view() } })
    expect(areaSince(s, 'a')).toBe(at(9, 0, 9))
  })

  it('gives the start of the snapshot for a view with no start, or no view', () => {
    const s = snap({ since: { a: at(9, 30), b: at(9, 0, 10) } }, { areas: { b: view() } })
    expect(areaSince(s, 'a')).toBe(at(9, 30))
    expect(areaSince(s, 'b')).toBe(at(9, 0, 10))
    expect(areaSince(s, 'constructor')).toBeUndefined()
  })
})

describe('itemChange', () => {
  it('gives the change of state when the item has one', () => {
    const item = { id: 'PLAT-1', kind: 'ticket', title: 'Login' } as const
    expect(itemChange({ ...item, from: 'In progress', to: 'Done' })).toBe('In progress → Done')
    expect(itemChange({ ...item, to: 'Done' })).toBe('Done')
    expect(itemChange(item)).toBeNull()
  })
})

describe('the buttons of a tab', () => {
  it('Redo draft asks first only for a changed draft', () => {
    expect(redoNeedsConfirm(view({ edited: true }))).toBe(true)
    expect(redoNeedsConfirm(view())).toBe(false)
    expect(redoNeedsConfirm(undefined)).toBe(false)
  })

  it('Mark as sent gives the time of the send, and Undo removes it', () => {
    expect(sentText(snap(), 'a')).toBeNull()
    const s = snap({}, sent({ a: at(9, 44) }))
    expect(sentText(s, 'a')).toBe('Sent at 09:44')
    expect(sentText(s, 'b')).toBeNull()
  })

  it('names the channel on the Send button', () => {
    expect(sendText('#platform')).toBe('Send to #platform')
    expect(sendText('  ')).toBe('Send')
  })
})

describe('areaView', () => {
  it('gives the view of an area, and nothing for an inherited key', () => {
    const a = view({ draft: 'A' })
    expect(areaView(snap({}, { areas: { a } }), 'a')).toBe(a)
    expect(areaView(snap(), 'a')).toBeUndefined()
    expect(areaView(snap(), 'constructor')).toBeUndefined()
  })
})

describe('the texts of the panel', () => {
  it('are the texts of the design', () => {
    expect(NOTHING_MOVED).toBe('Nothing moved since your last update.')
    expect(NEW_DRAFT).toBe("There's a new draft.")
    expect(REDO_CONFIRM).toBe('Replace your changes with a new draft?')
    expect(SEND_TIP).toBe('Sending comes with the Slack app. For now, copy the draft.')
    expect(SET_UP).toBe('Set up your work areas to get a daily update.')
    expect(NO_DRAFT).toBe("This work area doesn't have a draft yet.")
    expect(COPIED_MS).toBe(2000)
  })
})

describe('panelBody', () => {
  it('waits for the first snapshot', () => {
    expect(panelBody(null)).toBe('loading')
  })

  it('shows the set-up text when no area is on', () => {
    expect(panelBody(snap({ areas: [], configured: false }))).toBe('empty')
  })

  it('shows the tabs when an area is on', () => {
    expect(panelBody(snap())).toBe('tabs')
  })
})

describe('failureLine', () => {
  it('gives the failure text of the last run, with the name of the server', () => {
    const s = snap(
      {},
      { lastRun: { at: 1, detail: 'needs-auth', failure: 'source-unavailable', ok: false } },
    )
    expect(failureLine(s, 'board')).toBe(failureText('source-unavailable', 'needs-auth', 'board'))
    expect(failureLine(s, 'board')).toContain('board (needs-auth)')
  })

  it('gives nothing after a good run, with no run, or with no failure code', () => {
    expect(failureLine(snap({}, { lastRun: { at: 1, ok: true } }), 'board')).toBeNull()
    expect(failureLine(snap(), 'board')).toBeNull()
    expect(failureLine(snap({}, { lastRun: { at: 1, ok: false } }), 'board')).toBeNull()
  })
})
