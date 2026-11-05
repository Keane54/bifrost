// The TanStack Table state of one Overview tab, and the widths back from the table.
import {
  COLUMN_IDS,
  type ColumnId,
  DEFAULT_WIDTHS,
  isColumnId,
  MAX_WIDTH,
  MIN_WIDTH,
} from './columns'
import type { OverviewTab } from './config'

export interface TableState {
  sorting: { id: ColumnId; desc: boolean }[]
  columnOrder: ColumnId[]
  columnVisibility: Record<ColumnId, boolean>
  columnSizing: Record<ColumnId, number>
}

// The visible columns come first in their tab order. The hidden columns follow in the default order.
export function toTableState(tab: OverviewTab): TableState {
  const hidden = COLUMN_IDS.filter(id => !tab.columns.includes(id))
  const columnVisibility = {} as Record<ColumnId, boolean>
  for (const id of COLUMN_IDS) columnVisibility[id] = tab.columns.includes(id)
  return {
    columnOrder: [...tab.columns, ...hidden],
    columnSizing: { ...DEFAULT_WIDTHS, ...tab.widths },
    columnVisibility,
    sorting: [{ desc: tab.sort.desc, id: tab.sort.column }],
  }
}

// The place of a header that the user drops on a different header. A drop on a header to the right
// puts the column after that header. A drop on a header to the left puts the column before it.
// The kind column does not move. Null means no move.
export function dropBefore(
  columns: ColumnId[],
  from: ColumnId,
  to: ColumnId,
): { before: ColumnId | null } | null {
  const fromIndex = columns.indexOf(from)
  const toIndex = columns.indexOf(to)
  if (from === 'kind' || from === to || fromIndex < 0 || toIndex < 0) return null
  if (fromIndex > toIndex) return { before: to }
  return { before: columns[toIndex + 1] ?? null }
}

// Keep the widths of known columns only. Each width is a whole number from MIN_WIDTH to MAX_WIDTH.
export function widthsFromSizing(
  sizing: Record<string, number>,
): Partial<Record<ColumnId, number>> {
  const widths: Partial<Record<ColumnId, number>> = {}
  for (const [key, value] of Object.entries(sizing)) {
    if (!isColumnId(key) || typeof value !== 'number' || !Number.isFinite(value)) continue
    widths[key] = Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, Math.round(value)))
  }
  return widths
}

// The resize handle is this wide (px) at the right edge of a header cell.
export const RESIZE_ZONE = 6

// True if the pointer is on the resize handle of a header that ends at `right`.
export function inResizeZone(clientX: number, right: number): boolean {
  return clientX >= right - RESIZE_ZONE && clientX <= right
}
