// The order of the watchlist. These functions are pure.
import type { SessionRow } from '../../../shared/types'

// The watched rows in watch order.
export function watchedRows(rows: readonly SessionRow[]): SessionRow[] {
  return rows
    .filter(row => row.watch !== undefined)
    .sort((a, b) => (a.watch?.order ?? 0) - (b.watch?.order ?? 0))
}

// The session that the dragged row goes before. The pointer is over the row at overIndex.
// The upper half of a row puts the dragged row before it. The lower half puts it after it.
// Null means the end of the list. A drop on the dragged row gives the place that it has now.
export function dropTarget(
  order: readonly string[],
  draggedId: string,
  overIndex: number,
  upperHalf: boolean,
): string | null {
  if (order.length === 0) return null
  const over = Math.min(Math.max(overIndex, 0), order.length - 1)
  const onSelf = order[over] === draggedId
  const at = upperHalf && !onSelf ? over : over + 1
  const before = order[at] ?? null
  // Before the dragged row itself is the same place as before the row after it.
  return before === draggedId ? (order[at + 1] ?? null) : before
}

// True when a drop of the row before `before` changes the order. A drop at the place that the
// row has now, or a row that is not in the list, is not a move.
export function isMove(
  order: readonly string[],
  draggedId: string,
  before: string | null,
): boolean {
  const at = order.indexOf(draggedId)
  return at >= 0 && before !== (order[at + 1] ?? null)
}
