// The header and the rows of the active Overview tab.
// TanStack Table keeps the column order, the visibility, the widths and the sort mark.
// The resize handle of each header has its own pointer handling. It changes only its own column.
// viewRows filters and sorts the rows (D5). So the table has no sorted row model.
// A right-click on a row opens the row menu (spec 9.5). It does not change the selection (D6).
import { ContextMenu } from '@base-ui/react/context-menu'
import {
  columnOrderingFeature,
  columnSizingFeature,
  columnVisibilityFeature,
  createColumnHelper,
  rowSortingFeature,
  tableFeatures,
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
import { WATCH_ROW_BG, WATCH_STRIPE } from '../watch/watch-colours'
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
import { dropBefore, inResizeZone, RESIZE_ZONE, toTableState } from './table-state'

const features = tableFeatures({
  columnOrderingFeature,
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
// A long text ends with an ellipsis, so it never touches the next column.
const CELL = 'truncate px-1 py-0'

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

  // The resize in progress: the column, the pointer start and the width at the start.
  const resizing = useRef<{ id: ColumnId; startX: number; startWidth: number } | null>(null)
  const [resizeId, setResizeId] = useState<ColumnId | null>(null)

  // The resize changes the width of its own column only. No other column changes.
  function resizeTo(clientX: number): void {
    const r = resizing.current
    if (r === null) return
    update({
      tabId: tab.id,
      type: 'setWidths',
      widths: { [r.id]: r.startWidth + clientX - r.startX },
    })
  }

  function endResize(e: React.PointerEvent<HTMLDivElement>): void {
    if (resizing.current === null) return
    resizing.current = null
    setResizeId(null)
    if (e.currentTarget.hasPointerCapture(e.pointerId)) {
      e.currentTarget.releasePointerCapture(e.pointerId)
    }
  }

  const table = useTable({
    columns,
    data,
    features,
    getRowId: row => row.sessionId,
    manualSorting: true,
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
                      className='flex h-[18px] w-full items-center gap-1 overflow-hidden whitespace-nowrap px-1 text-[11px] text-text-dim hover:text-text active:bg-accent/12'
                      draggable={id !== 'kind'}
                      onClick={() => update({ column: id, tabId: tab.id, type: 'sortBy' })}
                      onDragEnd={endDrag}
                      onDragStart={e => {
                        // A drag that starts in the resize zone never moves the column.
                        const right = e.currentTarget.getBoundingClientRect().right
                        if (inResizeZone(e.clientX, right)) {
                          e.preventDefault()
                          return
                        }
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
                    {/* Not in the button. It takes the pointer, so a drag on it only resizes. */}
                    <div
                      aria-hidden={true}
                      className={cx(
                        'absolute top-0 right-0 h-full cursor-col-resize touch-none hover:bg-text-strong/40',
                        resizeId === id && 'bg-text-strong/60',
                      )}
                      data-resize-handle={true}
                      // Without the capture, no pointer up comes to the handle. End the resize.
                      onLostPointerCapture={endResize}
                      onPointerCancel={endResize}
                      onPointerDown={e => {
                        if (e.button !== 0) return
                        e.preventDefault()
                        e.stopPropagation()
                        e.currentTarget.setPointerCapture(e.pointerId)
                        resizing.current = { id, startWidth: header.getSize(), startX: e.clientX }
                        setResizeId(id)
                      }}
                      onPointerMove={e => {
                        // No button is down. So Bifrost did not get the pointer up. End the resize.
                        if (e.buttons === 0) endResize(e)
                        else resizeTo(e.clientX)
                      }}
                      onPointerUp={endResize}
                      style={{ width: RESIZE_ZONE }}
                    />
                  </th>
                )
              })}
              <th className={STICKY} />
            </tr>
          </thead>
          <tbody className='text-xs'>
            {viewed.map(item => {
              const row = item.original
              const id = row.sessionId
              return (
                <tr
                  className={cx(
                    // The selected row is a light cyan. A hover stays neutral. A press gives a
                    // short cyan tint (spec 8.10).
                    'h-[22px] active:bg-accent/12',
                    row.watch
                      ? // A watched row has its watch colour as the row background. The selection
                        // and the hover are on the cells. So they show on top of the colour.
                        cx(
                          WATCH_ROW_BG[row.watch.colour],
                          WATCH_STRIPE[row.watch.colour],
                          id === selectedId
                            ? '*:bg-select'
                            : open.has(id)
                              ? '*:bg-hover'
                              : 'hover:*:bg-hover',
                        )
                      : id === selectedId
                        ? 'bg-select'
                        : open.has(id)
                          ? 'bg-hover'
                          : 'hover:bg-hover',
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
        {viewed.length === 0 && (
          <p className='px-2 py-0.5 text-text-dim text-xs'>
            {rows.length === 0 ? 'No sessions.' : 'No sessions match the filters of this tab.'}
          </p>
        )}
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
