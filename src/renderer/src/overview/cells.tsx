// The cells of the Overview rows, and the class lookups for the colour tokens.
import type { Priority, SessionRow } from '../../../shared/types'
import type { ColumnId } from './columns'
import {
  formatAge,
  formatCost,
  formatPercent,
  projectLabel,
  stateLabel,
  stateTone,
  type Tone,
} from './format'
import { SessionIcon } from './SessionIcon'

// Tailwind finds only full class names in the source. So these lookups hold full names.
// The index is the colour of the tab (0 to 5).
export const TAB_TEXT: string[] = [
  'text-tab-1',
  'text-tab-2',
  'text-tab-3',
  'text-tab-4',
  'text-tab-5',
  'text-tab-6',
]

export const PRIO_TEXT: Record<Priority, string> = {
  1: 'text-prio-1',
  2: 'text-prio-2',
  3: 'text-prio-3',
  4: 'text-prio-4',
  5: 'text-prio-5',
}

// The swatch of a priority in the Set priority menu.
export const PRIO_BG: Record<Priority, string> = {
  1: 'bg-prio-1',
  2: 'bg-prio-2',
  3: 'bg-prio-3',
  4: 'bg-prio-4',
  5: 'bg-prio-5',
}

export const TONE_TEXT: Record<Tone, string> = {
  active: 'text-text-strong',
  dim: 'text-text-dim',
  parked: 'text-parked',
  red: 'text-box-red',
  yellow: 'text-box-yellow',
}

// The content of one cell. The age in the Last activity column uses the time now.
export function CellContent({
  column,
  row,
  now,
}: {
  column: ColumnId
  row: SessionRow
  now: number
}): React.ReactNode {
  switch (column) {
    case 'kind':
      return <SessionIcon row={row} size={18} />
    case 'name':
      return row.name
    case 'priority':
      return row.priority ? <span className={PRIO_TEXT[row.priority]}>{row.priority}</span> : null
    case 'state':
      return <span className={TONE_TEXT[stateTone(row)]}>{stateLabel(row.state)}</span>
    case 'project':
      return projectLabel(row.cwd)
    case 'branch':
      return row.branch ?? ''
    case 'model':
      return row.model ?? ''
    case 'context':
      return formatPercent(row.contextPercent)
    case 'cost':
      return formatCost(row.costUsd)
    case 'activity':
      return formatAge(row.lastActivity, now)
  }
}
