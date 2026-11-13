// The cells of the Overview rows, and the class lookups for the colour tokens.
import type { Priority, SessionRow } from '../../../shared/types'
import { ActivityAge } from './ActivityAge'
import type { ColumnId } from './columns'
import { formatCost, formatPercent, projectLabel, stateLabel, stateTone, type Tone } from './format'
import { SessionIcon } from './SessionIcon'

// Tailwind finds only full class names in the source. So these lookups hold full names.
// The index is the colour of the tab (0 to 11).
export const TAB_TEXT: string[] = [
  'text-tab-1',
  'text-tab-2',
  'text-tab-3',
  'text-tab-4',
  'text-tab-5',
  'text-tab-6',
  'text-tab-7',
  'text-tab-8',
  'text-tab-9',
  'text-tab-10',
  'text-tab-11',
  'text-tab-12',
]

// The swatch of a tab colour in Overview Settings.
export const TAB_SWATCH: string[] = [
  'bg-tab-1',
  'bg-tab-2',
  'bg-tab-3',
  'bg-tab-4',
  'bg-tab-5',
  'bg-tab-6',
  'bg-tab-7',
  'bg-tab-8',
  'bg-tab-9',
  'bg-tab-10',
  'bg-tab-11',
  'bg-tab-12',
]

// The names of the tab colours, in the order of the index.
export const TAB_COLOUR_NAMES: readonly string[] = [
  'Cyan',
  'Light blue',
  'Green',
  'Teal',
  'Blue',
  'Mint',
  'Red',
  'Amber',
  'Yellow',
  'Lime',
  'White',
  'Sky blue',
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

// The content of one cell. The Activity cell has its own clock.
export function CellContent({
  column,
  row,
}: {
  column: ColumnId
  row: SessionRow
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
      return <ActivityAge since={row.lastActivity} />
  }
}
