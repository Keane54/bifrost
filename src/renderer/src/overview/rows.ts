// Tab filters and sort of the Overview rows.
import type { SessionKind, SessionRow, SessionState } from '../../../shared/types'
import type { ColumnId } from './columns'
import { projectLabel } from './format'

export interface TabFilter {
  states: SessionState[]
  kinds: SessionKind[]
  boxOnly: boolean
}

export interface SortSpec {
  column: ColumnId
  desc: boolean
}

export function filterRows(rows: SessionRow[], filter: TabFilter): SessionRow[] {
  return rows.filter(
    row =>
      filter.states.includes(row.state) &&
      filter.kinds.includes(row.kind) &&
      (!filter.boxOnly || row.box !== 'none'),
  )
}

const collator = new Intl.Collator('en', { numeric: true, sensitivity: 'base' })

// The State column sorts by the state only, not by the box.
// So a yellow box that changes to red does not move the row (spec 7 rule 6).
const STATE_RANK: Record<SessionState, number> = {
  error: 0,
  idle: 3,
  'needs-you': 1,
  parked: 4,
  working: 2,
}

type Key = number | string | undefined

function keyOf(row: SessionRow, column: ColumnId): Key {
  switch (column) {
    case 'kind':
      return row.kind === 'owned' ? 0 : 1
    case 'name':
      return row.name
    case 'priority':
      return row.priority
    case 'state':
      return STATE_RANK[row.state]
    case 'project':
      return projectLabel(row.cwd)
    case 'branch':
      return row.branch
    case 'model':
      return row.model
    case 'context':
      return row.contextPercent
    case 'cost':
      return row.costUsd
    case 'activity':
      return row.lastActivity
  }
}

function isEmpty(key: Key): key is undefined | '' {
  return key === undefined || key === '' || (typeof key === 'number' && Number.isNaN(key))
}

function compare(a: Key, b: Key): number {
  if (typeof a === 'number' && typeof b === 'number') return a < b ? -1 : a > b ? 1 : 0
  return collator.compare(String(a), String(b))
}

// Empty values go last in both directions. Equal values keep the input order (D5).
export function sortRows(rows: SessionRow[], sort: SortSpec): SessionRow[] {
  const keyed = rows.map(row => ({ key: keyOf(row, sort.column), row }))
  keyed.sort((x, y) => {
    const xe = isEmpty(x.key)
    const ye = isEmpty(y.key)
    if (xe || ye) return xe === ye ? 0 : xe ? 1 : -1
    const result = compare(x.key, y.key)
    return sort.desc ? -result : result
  })
  return keyed.map(item => item.row)
}

export function viewRows(
  rows: SessionRow[],
  tab: { filter: TabFilter; sort: SortSpec },
): SessionRow[] {
  return sortRows(filterRows(rows, tab.filter), tab.sort)
}
