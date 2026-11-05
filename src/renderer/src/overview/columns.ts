// The columns of an Overview. The order here is the default order (spec 8.3).
export type ColumnId =
  | 'kind'
  | 'name'
  | 'priority'
  | 'state'
  | 'project'
  | 'branch'
  | 'model'
  | 'context'
  | 'cost'
  | 'activity'

export const COLUMN_IDS: readonly ColumnId[] = [
  'kind',
  'name',
  'priority',
  'state',
  'project',
  'branch',
  'model',
  'context',
  'cost',
  'activity',
]

// The visible columns of a new tab (spec 8.3). You turn on the other columns in the Overview
// Settings panel.
export const DEFAULT_COLUMNS: readonly ColumnId[] = ['kind', 'name', 'state', 'project', 'activity']

export const COLUMN_LABELS: Record<ColumnId, string> = {
  activity: 'Last activity',
  branch: 'Branch',
  context: 'Context %',
  cost: 'Cost',
  kind: '',
  model: 'Model',
  name: 'Name',
  priority: 'Priority',
  project: 'Project',
  state: 'State',
}

// Geist Mono is 0.6 em wide: 7.2 px a character at 12 px. A width holds the normal content of its
// column (a name of 24 characters, a project of two path parts) and its header.
export const DEFAULT_WIDTHS: Record<ColumnId, number> = {
  activity: 112,
  branch: 130,
  context: 84,
  cost: 60,
  kind: 28,
  model: 90,
  name: 184,
  priority: 76,
  project: 200,
  state: 84,
}

export const MIN_WIDTH = 24
export const MAX_WIDTH = 600

// The first click on these columns sorts from the highest value (D5).
export const DESC_FIRST: ReadonlySet<ColumnId> = new Set<ColumnId>(['context', 'cost', 'activity'])

// Return true if the value is a column ID.
export function isColumnId(value: unknown): value is ColumnId {
  return COLUMN_IDS.some(id => id === value)
}
