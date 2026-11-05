import { describe, expect, it } from 'vitest'
import { defaultOverviewConfig, type OverviewTab } from '../../../src/renderer/src/overview/config'
import { filterRows, sortRows, viewRows } from '../../../src/renderer/src/overview/rows'
import { ALL, row } from './fixtures'

const ids = (rows: { sessionId: string }[]) => rows.map(r => r.sessionId).join('')

describe('rows', () => {
  it('the default tabs filter the rows of spec 8.3', () => {
    const tabs = defaultOverviewConfig().tabs
    expect(tabs.map(t => ids(filterRows(ALL, t.filter)))).toEqual(['ABCDEG', 'BCD', 'A', 'EG', 'F'])
    expect(ids(viewRows(ALL, defaultOverviewConfig().tabs[0] as OverviewTab))).toBe('ABCDEG')
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

  it('sortRows by state gives red, yellow, working, idle, parked', () => {
    expect(ids(sortRows([...ALL].reverse(), { column: 'state', desc: false }))).toBe('DCBAGEF')
    expect(ids(sortRows(ALL, { column: 'kind', desc: false }))).toBe('ABDEFGC')
  })

  it('sortRows by project uses the project label', () => {
    const rows = [
      row({ cwd: '/z/b/.claude/worktrees/w', sessionId: 'a' }),
      row({ cwd: '/z/a', sessionId: 'b' }),
    ]
    expect(ids(sortRows(rows, { column: 'project', desc: false }))).toBe('ba')
  })
})
