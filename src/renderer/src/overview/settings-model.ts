// The model of the Overview Settings panel (spec 8.3). Each function gives the next config of one
// Overview. A change that has no effect gives the same object.
// The column changes use the reducer of config.ts. So the panel, the tab menu and the header drag
// use the same rules.
import type { SessionKind, SessionState } from '../../../shared/types'
import type { Point, Rect } from '../wm/geometry'
import { COLUMN_LABELS, type ColumnId } from './columns'
import { KINDS, type OverviewConfig, overviewReducer, STATES } from './config'
import type { TabFilter } from './rows'

export interface ColumnRow {
  id: ColumnId
  label: string
  visible: boolean
  // True for the kind column. It is always first and always visible (D4).
  locked: boolean
}

// One row for each column, in the order of the tab. The top row is the leftmost column.
// An unknown tab gives no rows.
export function columnRows(config: OverviewConfig, tabId: string): ColumnRow[] {
  const tab = config.tabs.find(t => t.id === tabId)
  if (!tab) return []
  return tab.order.map(id => ({
    id,
    label: id === 'kind' ? 'Kind' : COLUMN_LABELS[id],
    locked: id === 'kind',
    visible: tab.columns.includes(id),
  }))
}

// Turn a column on or off. The kind column stays on.
export function toggleColumn(
  config: OverviewConfig,
  tabId: string,
  columnId: ColumnId,
): OverviewConfig {
  return overviewReducer(config, { column: columnId, tabId, type: 'toggleColumn' })
}

// Move a column before another column. Null moves it to the end. The kind column does not move.
export function moveColumn(
  config: OverviewConfig,
  tabId: string,
  columnId: ColumnId,
  beforeId: ColumnId | null,
): OverviewConfig {
  return overviewReducer(config, { before: beforeId, column: columnId, tabId, type: 'moveColumn' })
}

// Give the tab its default columns and its default filter.
export function resetTab(config: OverviewConfig, tabId: string): OverviewConfig {
  return overviewReducer(config, { tabId, type: 'resetTab' })
}

function withFilter(
  config: OverviewConfig,
  tabId: string,
  change: (filter: TabFilter) => TabFilter,
): OverviewConfig {
  const tab = config.tabs.find(t => t.id === tabId)
  if (!tab) return config
  return overviewReducer(config, { filter: change(tab.filter), tabId, type: 'setFilter' })
}

// Show or hide the rows of one state. The states stay in the order of STATES.
export function showState(
  config: OverviewConfig,
  tabId: string,
  state: SessionState,
  on: boolean,
): OverviewConfig {
  return withFilter(config, tabId, f => ({
    ...f,
    states: STATES.filter(s => (s === state ? on : f.states.includes(s))),
  }))
}

// Show or hide the rows of one kind. The kinds stay in the order of KINDS.
export function showKind(
  config: OverviewConfig,
  tabId: string,
  kind: SessionKind,
  on: boolean,
): OverviewConfig {
  return withFilter(config, tabId, f => ({
    ...f,
    kinds: KINDS.filter(k => (k === kind ? on : f.kinds.includes(k))),
  }))
}

// Show only the rows with a yellow or a red box, or all rows.
export function setBoxOnly(config: OverviewConfig, tabId: string, on: boolean): OverviewConfig {
  return withFilter(config, tabId, f => ({ ...f, boxOnly: on }))
}

// A release more than this distance outside the list does not move the row. So you can stop a
// drag with no change: move the pointer away from the list, and release it there.
export const DROP_MARGIN = 24

// True when p is on the list rect or not more than DROP_MARGIN px outside it.
export function inDropArea(list: Rect, p: Point): boolean {
  return (
    p.x >= list.x - DROP_MARGIN &&
    p.x <= list.x + list.w + DROP_MARGIN &&
    p.y >= list.y - DROP_MARGIN &&
    p.y <= list.y + list.h + DROP_MARGIN
  )
}

// The column that a dragged row goes before. The pointer is over the row at overIndex. The upper
// half of a row puts the dragged row before it. The lower half puts it after it. Null means the
// end of the list. A drop on the dragged row gives its old place, so the order does not change.
// The kind row is always first (order[0]). So a row never goes before it.
export function dropTarget(
  order: readonly ColumnId[],
  draggedId: ColumnId,
  overIndex: number,
  upperHalf: boolean,
): ColumnId | null {
  const over = Math.min(Math.max(overIndex, 0), order.length - 1)
  const onSelf = order[over] === draggedId
  const at = Math.max(1, upperHalf && !onSelf ? over : over + 1)
  const before = order[at] ?? null
  // Before the dragged row itself is the same place as before the row after it.
  return before === draggedId ? (order[at + 1] ?? null) : before
}
