import { describe, expect, it } from 'vitest'
import { defaultOverviewConfig, type OverviewTab } from '../../../src/renderer/src/overview/config'
import { filterRows, sortRows, viewRows } from '../../../src/renderer/src/overview/rows'
import { ALL, row } from './fixtures'

const ids = (rows: { sessionId: string }[]) => rows.map(r => r.sessionId).join('')

describe('rows', () => {
  it('the default tabs filter the rows of spec 8.3', () => {
    const tabs = defaultOverviewConfig().tabs
    expect(tabs.map(t => ids(filterRows(ALL, t.filter)))).toEqual([
      'ABCDEG',
      'BCD',
      'A',
      'EG',
      'F',
      '',
    ])
    expect(ids(viewRows(ALL, defaultOverviewConfig().tabs[0] as OverviewTab))).toBe('ABCDEG')
  })

  it('the Watched tab comes after Needs you and shows the watched rows of every state', () => {
    const tabs = defaultOverviewConfig().tabs
    expect(tabs.map(t => t.name)).toEqual([
      'All',
      'Needs you',
      'Working',
      'Idle',
      'Parked',
      'Watched',
    ])
    const watched = tabs[5] as OverviewTab
    expect(watched.id).toBe('t6')
    expect(watched.filter.watchedOnly).toBe(true)
    const rows = [
      row({ sessionId: 'a' }),
      row({ sessionId: 'b', watch: { colour: 'lime', order: 0 } }),
      row({ sessionId: 'c', state: 'parked', watch: { colour: 'white', order: 1 } }),
    ]
    expect(ids(filterRows(rows, watched.filter))).toBe('bc')
  })

  it('watchedOnly false shows the rows that are not watched too', () => {
    const rows = [
      row({ sessionId: 'a' }),
      row({ sessionId: 'b', watch: { colour: 'lime', order: 0 } }),
    ]
    const base = { boxOnly: false, kinds: ['owned' as const], states: ['working' as const] }
    expect(ids(filterRows(rows, { ...base, watchedOnly: false }))).toBe('ab')
    expect(ids(filterRows(rows, { ...base, watchedOnly: true }))).toBe('b')
  })

  it('filterRows shows only the kinds of the filter', () => {
    const states = ['working', 'needs-you', 'error', 'idle'] as const
    const filter = (kinds: ('owned' | 'external')[]) => ({
      boxOnly: false,
      kinds,
      states: [...states],
      watchedOnly: false,
    })
    expect(ids(filterRows(ALL, filter(['owned'])))).toBe('ABDEG')
    expect(ids(filterRows(ALL, filter(['external'])))).toBe('C')
    expect(ids(filterRows(ALL, filter([])))).toBe('')
  })

  it('sortRows by name is numeric and ignores case', () => {
    const rows = [
      row({ name: 's10', sessionId: 'a' }),
      row({ name: 's2', sessionId: 'b' }),
      row({ name: 'Alpha', sessionId: 'c' }),
      row({ name: 'alpha', sessionId: 'd' }),
    ]
    expect(ids(sortRows(rows, { column: 'name', desc: false }))).toBe('cdba')
  })

  it('sortRows puts empty values last in both directions', () => {
    const rows = [
      row({ priority: 3, sessionId: 'a' }),
      row({ sessionId: 'b' }),
      row({ priority: 1, sessionId: 'c' }),
    ]
    expect(ids(sortRows(rows, { column: 'priority', desc: false }))).toBe('cab')
    expect(ids(sortRows(rows, { column: 'priority', desc: true }))).toBe('acb')
  })

  it('sortRows keeps the input order for equal values in both directions', () => {
    const rows = [
      row({ costUsd: 1, sessionId: 'a' }),
      row({ costUsd: 2, sessionId: 'b' }),
      row({ costUsd: 1, sessionId: 'c' }),
    ]
    expect(ids(sortRows(rows, { column: 'cost', desc: false }))).toBe('acb')
    expect(ids(sortRows(rows, { column: 'cost', desc: true }))).toBe('bac')
  })

  it('sortRows by state gives error, needs you, working, idle, parked', () => {
    expect(ids(sortRows([...ALL].reverse(), { column: 'state', desc: false }))).toBe('DCBAGEF')
    expect(ids(sortRows(ALL, { column: 'kind', desc: false }))).toBe('ABDEFGC')
  })

  // Spec 7 rule 6: Bifrost does not move a row because of a box.
  it('sortRows by state does not move a row when its yellow box changes to red', () => {
    const red = row({ box: 'red', sessionId: 'b', state: 'needs-you', status: 'idle' })
    const yellow = row({ box: 'yellow', sessionId: 'a', state: 'needs-you', status: 'idle' })
    const before = sortRows([yellow, red], { column: 'state', desc: false })
    const after = sortRows([{ ...yellow, box: 'red' }, red], { column: 'state', desc: false })
    expect(ids(before)).toBe('ab')
    expect(ids(after)).toBe('ab')
  })

  it('sortRows by project uses the project label', () => {
    const rows = [
      row({ cwd: '/z/b/.claude/worktrees/w', sessionId: 'a' }),
      row({ cwd: '/z/a', sessionId: 'b' }),
    ]
    expect(ids(sortRows(rows, { column: 'project', desc: false }))).toBe('ba')
  })
})
