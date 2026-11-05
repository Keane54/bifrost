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

export const DEFAULT_WIDTHS: Record<ColumnId, number> = {
  activity: 84,
  branch: 110,
  context: 70,
  cost: 60,
  kind: 28,
  model: 90,
  name: 150,
  priority: 56,
  project: 130,
  state: 76,
}

export const MIN_WIDTH = 24
export const MAX_WIDTH = 600

// The first click on these columns sorts from the highest value (D5).
export const DESC_FIRST: ReadonlySet<ColumnId> = new Set<ColumnId>(['context', 'cost', 'activity'])

// Return true if the value is a column ID.
export function isColumnId(value: unknown): value is ColumnId {
  return COLUMN_IDS.some(id => id === value)
}
