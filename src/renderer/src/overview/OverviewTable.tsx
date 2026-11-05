// The header and the rows of the active Overview tab.
// TanStack Table keeps the column order, the visibility, the widths, the resize and the sort mark.
// viewRows filters and sorts the rows (D5). So the table has no sorted row model.
// A right-click on a row opens the row menu (spec 9.5). It does not change the selection (D6).
import { ContextMenu } from '@base-ui/react/context-menu'
import {
  type ColumnSizingState,
  columnOrderingFeature,
  columnResizingFeature,
  columnSizingFeature,
  columnVisibilityFeature,
  createColumnHelper,
  functionalUpdate,
  rowSortingFeature,
  tableFeatures,
  type Updater,
  useTable,
} from '@tanstack/react-table'
import { useEffect, useMemo, useRef, useState } from 'react'
import type { SessionRow } from '../../../shared/types'
import { rowMenu } from '../actions/action-model'
import { useActions } from '../actions/actions-context'
import RowMenu from '../actions/RowMenu'
import { openChatIds } from '../chat/views'
import { useRegistry } from '../data/registry'
import { cx } from '../lib/cx'
import { MENU_POPUP } from '../lib/menu'
import { useNow } from '../lib/use-now'
import { useWmState } from '../wm/context'
import { CellContent } from './cells'
import {
  COLUMN_IDS,
  COLUMN_LABELS,
  type ColumnId,
  DEFAULT_WIDTHS,
  isColumnId,
  MAX_WIDTH,
  MIN_WIDTH,
} from './columns'
import type { OverviewAction, OverviewTab } from './config'
import { viewRows } from './rows'
import { dropBefore, toTableState, widthsFromSizing } from './table-state'

const features = tableFeatures({
  columnOrderingFeature,
  columnResizingFeature,
  columnSizingFeature,
  columnVisibilityFeature,
  rowSortingFeature,
})

const helper = createColumnHelper<typeof features, SessionRow>()

// One display column for each column ID. The cells come from CellContent.
const columns = helper.columns(
  COLUMN_IDS.map(id =>
    helper.display({
      header: COLUMN_LABELS[id],
      id,
      maxSize: MAX_WIDTH,
      minSize: MIN_WIDTH,
      size: DEFAULT_WIDTHS[id],
    }),
  ),
)

const DRAG_TYPE = 'application/x-bifrost-column'
const STICKY = 'sticky top-0 z-10 bg-panel p-0'
const CELL = 'overflow-hidden text-clip whitespace-nowrap px-1 py-0'

function columnOf(id: string): ColumnId {
  return isColumnId(id) ? id : 'name'
}

export default function OverviewTable({
  tab,
  update,
}: {
  tab: OverviewTab
  update(action: OverviewAction): void
}): React.JSX.Element {
  const { rows, selectedId, select } = useRegistry()
  const { frames } = useWmState()
  const { contextFor, run } = useActions()
  const now = useNow()
  const data = useMemo(() => viewRows(rows, tab), [rows, tab])
  const state = useMemo(() => toTableState(tab), [tab])
  const open = useMemo(() => new Set(openChatIds(frames)), [frames])
  // The header that a drag started on, and the header under the pointer.
  const dragged = useRef<ColumnId | null>(null)
  const [dropTarget, setDropTarget] = useState<ColumnId | null>(null)
  // The session of the row menu. A right-click on a row sets it before the menu opens.
  const [menuId, setMenuId] = useState<string | null>(null)
  const [menuOpen, setMenuOpen] = useState(false)
  // The row of the current right-click. Null when the right-click is not on a row.
  const clickedRow = useRef<string | null>(null)
  // The menu shows the current row. The row can change while the menu is open.
  const menuRow = menuId === null ? undefined : rows.find(r => r.sessionId === menuId)

  // When the row goes away, the menu closes.
  useEffect(() => {
    if (menuOpen && !menuRow) setMenuOpen(false)
  }, [menuOpen, menuRow])

  // A resize step gives an updater. Keep only the widths that changed and save them in the tab.
  function onColumnSizingChange(updater: Updater<ColumnSizingState>): void {
    const current: ColumnSizingState = state.columnSizing
    const next = functionalUpdate(updater, current)
    const changed: ColumnSizingState = {}
    for (const [id, width] of Object.entries(next)) {
      if (width !== current[id]) changed[id] = width
    }
    update({ tabId: tab.id, type: 'setWidths', widths: widthsFromSizing(changed) })
  }

  const table = useTable({
    columnResizeMode: 'onChange',
    columns,
    data,
    features,
    getRowId: row => row.sessionId,
    manualSorting: true,
    onColumnSizingChange,
    state,
  })

  function endDrag(): void {
    dragged.current = null
    setDropTarget(null)
  }

  function drop(target: ColumnId): void {
    const from = dragged.current
    endDrag()
    if (from === null) return
    const move = dropBefore(tab.columns, from, target)
    if (move) update({ before: move.before, column: from, tabId: tab.id, type: 'moveColumn' })
  }

  const headers = table.getHeaderGroups()[0]?.headers ?? []
  const viewed = table.getRowModel().rows

  return (
    <ContextMenu.Root onOpenChange={setMenuOpen} open={menuOpen && menuRow !== undefined}>
      <ContextMenu.Trigger
        className='min-h-0 flex-1 select-none overflow-auto'
        data-rows-area={true}
        onContextMenu={e => {
          // The row handler runs first. A right-click outside a row opens no menu.
          const id = clickedRow.current
          clickedRow.current = null
          if (id === null) e.preventBaseUIHandler()
        }}
      >
        {/* The last column has no width. It takes the free space, so the rows fill the panel. */}
        <table className='table-fixed' style={{ minWidth: '100%', width: table.getTotalSize() }}>
          <thead>
            <tr className='h-[18px]'>
              {headers.map(header => {
                const id = columnOf(header.column.id)
                const sorted = header.column.getIsSorted()
                const resize = header.getResizeHandler()
                return (
                  <th
                    aria-sort={
                      sorted === 'asc' ? 'ascending' : sorted === 'desc' ? 'descending' : undefined
                    }
                    className={cx(
                      STICKY,
                      'text-left font-normal',
                      dropTarget === id && 'outline-1 outline-text-strong -outline-offset-1',
                    )}
                    data-column-id={id}
                    key={header.id}
                    onDragLeave={() => setDropTarget(prev => (prev === id ? null : prev))}
                    onDragOver={e => {
                      const from = dragged.current
                      if (from === null || from === id) return
                      e.preventDefault()
                      e.dataTransfer.dropEffect = 'move'
                      setDropTarget(id)
                    }}
                    onDrop={e => {
                      e.preventDefault()
                      drop(id)
                    }}
                    style={{ width: header.getSize() }}
                  >
                    <button
                      aria-label={COLUMN_LABELS[id] || 'Kind'}
                      className='flex h-[18px] w-full items-center gap-1 overflow-hidden whitespace-nowrap px-1 text-[11px] text-text-dim hover:text-text'
                      draggable={id !== 'kind'}
                      onClick={() => update({ column: id, tabId: tab.id, type: 'sortBy' })}
                      onDragEnd={endDrag}
                      onDragStart={e => {
                        dragged.current = id
                        e.dataTransfer.effectAllowed = 'move'
                        // Not text/plain, so a drop on a text field does not insert the label.
                        e.dataTransfer.setData(DRAG_TYPE, id)
                      }}
                      type='button'
                    >
                      {COLUMN_LABELS[id]}
                      {sorted && (
                        <span className='text-[8px]'>{sorted === 'desc' ? '▼' : '▲'}</span>
                      )}
                    </button>
                    {/* Not in the button, so a drag on it resizes and does not move the column. */}
                    <div
                      aria-hidden={true}
                      className={cx(
                        'absolute top-0 right-0 h-full w-1 cursor-col-resize touch-none hover:bg-text-strong/40',
                        header.column.getIsResizing() && 'bg-text-strong/60',
                      )}
                      data-resize-handle={true}
                      onMouseDown={resize}
                      onTouchStart={resize}
                    />
                  </th>
                )
              })}
              <th className={STICKY} />
            </tr>
          </thead>
          <tbody className='font-narrow text-xs'>
            {viewed.map(item => {
              const row = item.original
              const id = row.sessionId
              return (
                <tr
                  className={cx(
                    'h-[22px]',
                    id === selectedId ? 'bg-select' : open.has(id) ? 'bg-hover' : 'hover:bg-hover',
                    row.state === 'parked' && 'text-parked',
                  )}
                  data-session-id={id}
                  key={item.id}
                  onClick={() => select(id)}
                  onContextMenu={() => {
                    clickedRow.current = id
                    setMenuId(id)
                  }}
                  onDoubleClick={() => {
                    select(id)
                    run('open', id)
                  }}
                >
                  {item.getVisibleCells().map(cell => {
                    const column = columnOf(cell.column.id)
                    return (
                      <td
                        className={CELL}
                        key={cell.id}
                        title={column === 'project' ? row.cwd : undefined}
                      >
                        <CellContent column={column} now={now} row={row} />
                      </td>
                    )
                  })}
                  <td />
                </tr>
              )
            })}
          </tbody>
        </table>
        {viewed.length === 0 && <p className='px-2 py-0.5 text-text-dim text-xs'>No sessions.</p>}
      </ContextMenu.Trigger>
      <ContextMenu.Portal>
        <ContextMenu.Positioner className='z-50 outline-none'>
          <ContextMenu.Popup className={MENU_POPUP} data-row-menu={menuId ?? ''}>
            {menuRow && (
              <RowMenu
                entries={rowMenu(menuRow, contextFor(menuRow.sessionId))}
                onRun={(action, arg) => run(action, menuRow.sessionId, arg)}
              />
            )}
          </ContextMenu.Popup>
        </ContextMenu.Positioner>
      </ContextMenu.Portal>
    </ContextMenu.Root>
  )
}
