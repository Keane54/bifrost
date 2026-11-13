import { describe, expect, it } from 'vitest'
import { freshMarks } from '../../src/shared/daily-schedule'
import {
  applyResult,
  type DailyAreaResult,
  type DailyState,
  EMPTY_DAILY_STATE,
  editDraft,
  FAILURE_CODES,
  failRun,
  failureText,
  keepMine,
  markSent,
  parseDailyState,
  redoArea,
  rollDay,
  setFirstShown,
  setSecondShown,
  setSkipped,
  undoSent,
  usePending,
} from '../../src/shared/daily-state'

const result = (id: string, draft: string, moved = true): DailyAreaResult => ({
  draft,
  id,
  items: [{ id: 'T-1', kind: 'ticket', title: 'One' }],
  moved,
})

describe('applyResult', () => {
  it('keeps a changed draft and offers the new one', () => {
    const s0 = applyResult(EMPTY_DAILY_STATE, [result('a', 'old')], [], 1)
    const s1 = editDraft(s0, 'a', 'mine')
    const s2 = applyResult(s1, [result('a', 'new')], [], 2)
    expect(s2.areas.a).toMatchObject({ draft: 'mine', edited: true, pending: 'new' })
  })

  it('replaces an unchanged draft and clears pending', () => {
    const s0 = applyResult(EMPTY_DAILY_STATE, [result('a', 'old')], [], 1)
    const s1 = applyResult(s0, [result('a', 'new')], [], 2)
    expect(s1.areas.a).toEqual({
      draft: 'new',
      edited: false,
      items: [{ id: 'T-1', kind: 'ticket', title: 'One' }],
      moved: true,
    })
    expect('pending' in s1.areas.a).toBe(false)
  })

  it('sets no pending when the new draft equals the changed one', () => {
    const s0 = editDraft(applyResult(EMPTY_DAILY_STATE, [result('a', 'old')], [], 1), 'a', 'same')
    const s1 = applyResult(s0, [result('a', 'same')], [], 2)
    expect(s1.areas.a.pending).toBeUndefined()
    expect(s1.areas.a.edited).toBe(true)
  })

  it('sets lastRun, replaces unplaced and keeps other areas', () => {
    const s0 = applyResult(EMPTY_DAILY_STATE, [result('a', 'x'), result('b', 'y')], [], 1)
    const un = [{ id: 'P-1', kind: 'pr' as const, title: 'Pr' }]
    const s1 = applyResult(s0, [result('a', 'z')], un, 5)
    expect(s1.areas.b.draft).toBe('y')
    expect(s1.unplaced).toEqual(un)
    expect(s1.lastRun).toEqual({ at: 5, ok: true })
  })

  it('keeps the start of the run with the view of each area', () => {
    const s0 = applyResult(EMPTY_DAILY_STATE, [result('a', 'x'), result('b', 'y')], [], 9, { a: 4 })
    expect(s0.areas.a.since).toBe(4)
    expect('since' in s0.areas.b).toBe(false)
    const s1 = applyResult(editDraft(s0, 'a', 'mine'), [result('a', 'z')], [], 10, { a: 7 })
    expect(s1.areas.a).toMatchObject({ draft: 'mine', edited: true, pending: 'z', since: 7 })
  })

  it('does not match an inherited key', () => {
    const s = applyResult(EMPTY_DAILY_STATE, [result('constructor', 'x')], [], 1)
    // A key in a variable uses the index type. s.areas.constructor has the type Function.
    const id: string = 'constructor'
    expect(Object.hasOwn(s.areas, id)).toBe(true)
    expect(s.areas[id]?.draft).toBe('x')
    expect(s.areas[id]?.edited).toBe(false)
  })
})

describe('redoArea', () => {
  it('replaces a changed draft and clears edited and pending', () => {
    let s = applyResult(EMPTY_DAILY_STATE, [result('a', 'old')], [], 1)
    s = editDraft(s, 'a', 'mine')
    s = applyResult(s, [result('a', 'new')], [], 2)
    s = redoArea(s, result('a', 'fresh'))
    expect(s.areas.a.draft).toBe('fresh')
    expect(s.areas.a.edited).toBe(false)
    expect('pending' in s.areas.a).toBe(false)
  })

  it('sets the start of the run of the new draft', () => {
    const s = applyResult(EMPTY_DAILY_STATE, [result('a', 'old')], [], 1, { a: 3 })
    expect(redoArea(s, result('a', 'fresh'), 8).areas.a.since).toBe(8)
  })
})

describe('pending', () => {
  it('usePending takes the new draft and keepMine drops it', () => {
    let s = editDraft(applyResult(EMPTY_DAILY_STATE, [result('a', 'old')], [], 1), 'a', 'mine')
    s = applyResult(s, [result('a', 'new')], [], 2)
    const used = usePending(s, 'a')
    expect(used.areas.a).toMatchObject({ draft: 'new', edited: false })
    expect('pending' in used.areas.a).toBe(false)
    const kept = keepMine(s, 'a')
    expect(kept.areas.a).toMatchObject({ draft: 'mine', edited: true })
    expect('pending' in kept.areas.a).toBe(false)
  })
})

describe('sent marks', () => {
  it('markSent then undoSent gives back the earlier lastSent', () => {
    let s = markSent(EMPTY_DAILY_STATE, 'a', 10)
    s = markSent(s, 'a', 20)
    expect(s.lastSent.a).toBe(20)
    expect(s.marks.sent.a).toBe(20)
    s = undoSent(s, 'a')
    expect(s.lastSent.a).toBe(10)
    expect('a' in s.marks.sent).toBe(false)
  })

  it('undoSent with no earlier mark removes lastSent', () => {
    const s = undoSent(markSent(EMPTY_DAILY_STATE, 'a', 10), 'a')
    expect('a' in s.lastSent).toBe(false)
  })

  it('uses own keys only', () => {
    const s = undoSent(markSent(EMPTY_DAILY_STATE, 'constructor', 10), 'constructor')
    expect(Object.hasOwn(s.lastSent, 'constructor')).toBe(false)
  })
})

describe('day', () => {
  it('rollDay to a new date gives fresh marks and keeps the rest', () => {
    let s = applyResult(EMPTY_DAILY_STATE, [result('a', 'x')], [], 1)
    s = markSent(setFirstShown(setSkipped(s, true)), 'a', 5)
    const r = rollDay({ ...s, marks: { ...s.marks, date: '2026-11-10' } }, '2026-11-11')
    expect(r.marks).toEqual(freshMarks('2026-11-11'))
    expect(r.lastSent).toEqual({ a: 5 })
    expect(r.areas.a.draft).toBe('x')
  })

  it('rollDay to a new date clears edited and pending of each area', () => {
    let s = applyResult(EMPTY_DAILY_STATE, [result('a', 'old'), result('b', 'b')], [], 1)
    s = applyResult(editDraft(s, 'a', 'mine'), [result('a', 'new')], [], 2)
    const r = rollDay({ ...s, marks: freshMarks('2026-11-10') }, '2026-11-11')
    expect(r.areas.a).toMatchObject({ draft: 'mine', edited: false })
    expect('pending' in r.areas.a).toBe(false)
    expect(r.areas.b).toEqual(s.areas.b)
  })

  it('rollDay to the same date changes nothing', () => {
    const s: DailyState = { ...EMPTY_DAILY_STATE, marks: freshMarks('2026-11-11') }
    expect(rollDay(s, '2026-11-11')).toBe(s)
  })

  it('sets the flags', () => {
    expect(setSkipped(EMPTY_DAILY_STATE, true).marks.skipped).toBe(true)
    expect(setFirstShown(EMPTY_DAILY_STATE).marks.firstShown).toBe(true)
    expect(setSecondShown(EMPTY_DAILY_STATE).marks.secondShown).toBe(true)
  })
})

describe('failRun', () => {
  it('sets lastRun and changes nothing else', () => {
    const s = failRun(EMPTY_DAILY_STATE, 3, 'timeout', 'slow')
    expect(s.lastRun).toEqual({ at: 3, detail: 'slow', failure: 'timeout', ok: false })
    expect({ ...s, lastRun: null }).toEqual(EMPTY_DAILY_STATE)
    expect(failRun(EMPTY_DAILY_STATE, 3, 'timeout').lastRun).toEqual({
      at: 3,
      failure: 'timeout',
      ok: false,
    })
  })
})

describe('parseDailyState', () => {
  it('gives EMPTY_DAILY_STATE for a bad file', () => {
    expect(parseDailyState(null)).toEqual(EMPTY_DAILY_STATE)
    expect(parseDailyState('x')).toEqual(EMPTY_DAILY_STATE)
    expect(parseDailyState({ version: 2 })).toEqual(EMPTY_DAILY_STATE)
  })

  it('drops bad items and bad areas and keeps good ones', () => {
    const s = parseDailyState({
      areas: {
        a: {
          draft: 'd',
          edited: false,
          items: [
            { id: 'T-1', kind: 'ticket', title: 'ok', url: 'u' },
            { id: 1, kind: 'ticket', title: 'bad' },
            { id: 'X', kind: 'other', title: 'bad' },
          ],
          moved: true,
        },
        b: 5,
      },
      lastRun: { at: 1, failure: 'nope', ok: false },
      lastSent: { a: 3, b: 'x' },
      marks: {
        date: '2026-11-11',
        firstShown: true,
        secondShown: false,
        sent: { a: 2 },
        skipped: false,
      },
      prevSent: {},
      unplaced: [{ id: 'P', kind: 'pr', title: 't' }, 7],
      version: 1,
    })
    expect(s.areas.a.items).toEqual([{ id: 'T-1', kind: 'ticket', title: 'ok', url: 'u' }])
    expect('b' in s.areas).toBe(false)
    expect(s.lastSent).toEqual({ a: 3 })
    expect(s.unplaced).toHaveLength(1)
    expect(s.marks.firstShown).toBe(true)
    expect(s.lastRun?.failure).toBeUndefined()
  })

  it('keeps the start of an area only when it is a finite number', () => {
    const area = (since: unknown) => ({ draft: 'd', edited: false, items: [], moved: false, since })
    const s = parseDailyState({
      areas: { a: area(5), b: area('5'), c: area(null), d: { draft: 'd' } },
      version: 1,
    })
    expect(s.areas.a.since).toBe(5)
    for (const id of ['b', 'c', 'd']) expect('since' in s.areas[id]).toBe(false)
  })
})

describe('failureText', () => {
  it('gives the friendly text of each failure', () => {
    expect(failureText('nothing-to-read')).toBe(
      'Choose a ticket source or turn on merged PRs in Settings > Daily update.',
    )
    expect(failureText('source-unavailable', 'needs-auth', 'board')).toBe(
      "Bifrost couldn't reach board (needs-auth). Check it in Claude Code with /mcp.",
    )
    expect(failureText('no-user')).toBe(
      "Claude couldn't find you on the board. Add your name, email or ID in Settings > " +
        'Daily update.',
    )
    expect(failureText('tool-denied')).toBe(
      "The run needed a tool that it isn't allowed to use. Check the tools in Settings > " +
        'Daily update.',
    )
    expect(failureText('bad-result')).toBe(
      "Claude's answer didn't have the right shape, so Bifrost didn't use it. Try Refresh.",
    )
    expect(failureText('timeout')).toBe('The run took more than 5 minutes, so Bifrost stopped it.')
    expect(failureText('claude-failed', 'claude -p failed with code 1')).toBe(
      "Claude Code couldn't run the daily update. claude -p failed with code 1",
    )
  })

  it('works with no detail and no server', () => {
    expect(failureText('claude-failed')).toBe("Claude Code couldn't run the daily update.")
    expect(failureText('source-unavailable')).toBe(
      "Bifrost couldn't reach the ticket source. Check it in Claude Code with /mcp.",
    )
    expect(failureText('source-unavailable', undefined, null)).toBe(
      "Bifrost couldn't reach the ticket source. Check it in Claude Code with /mcp.",
    )
  })

  it('has a text for each code', () => {
    for (const code of FAILURE_CODES) expect(failureText(code).length).toBeGreaterThan(10)
  })
})
