// Tab filters and sort of the Overview rows.
import type { SessionRow, SessionState } from '../../../shared/types'
import type { ColumnId } from './columns'
import { projectLabel, stateTone, type Tone } from './format'

export interface TabFilter {
  states: SessionState[]
  boxOnly: boolean
}

export interface SortSpec {
  column: ColumnId
  desc: boolean
}

export function filterRows(rows: SessionRow[], filter: TabFilter): SessionRow[] {
  return rows.filter(
    row => filter.states.includes(row.state) && (!filter.boxOnly || row.box !== 'none'),
  )
}

const collator = new Intl.Collator('en', { numeric: true, sensitivity: 'base' })

const TONE_RANK: Record<Tone, number> = { accent: 2, dim: 3, parked: 4, red: 0, yellow: 1 }

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
      return TONE_RANK[stateTone(row)]
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
  return key === undefined || key === ''
}

function compare(a: Key, b: Key): number {
  if (typeof a === 'number' && typeof b === 'number') return a - b
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
