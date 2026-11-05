// The Watchlist panel (spec 8.3): the watched sessions in watch order.
// A click selects a row. A double-click opens the chat window. A right-click opens the row menu.
// A drag of a row up or down changes the order.
import { ContextMenu } from '@base-ui/react/context-menu'
import { useEffect, useMemo, useRef, useState } from 'react'
import { rowMenu } from '../actions/action-model'
import { useActions } from '../actions/actions-context'
import { friendlyError } from '../actions/errors'
import RowMenu from '../actions/RowMenu'
import { useRegistry } from '../data/registry'
import { cx } from '../lib/cx'
import { ErrorLine } from '../lib/ErrorLine'
import { errorMessage } from '../lib/error-message'
import { MENU_POPUP } from '../lib/menu'
import { TONE_TEXT } from '../overview/cells'
import { stateLabel, stateTone } from '../overview/format'
import { SessionIcon } from '../overview/SessionIcon'
import { movedToStack } from '../wm/hit'
import { WATCH_ROW_BG, WATCH_SWATCH } from './watch-colours'
import { dropTarget, isDragCancel, isMove, shouldMove, watchedRows } from './watch-order'

const EMPTY_TEXT =
  'Nothing on your watchlist yet. Right-click a session and choose Add to watchlist.'

// The row under the pointer, with the half of that row. A pointer above the list is on the upper
// half of the first row. A pointer below the list is on the lower half of the last row.
function placeAt(
  list: HTMLElement | null,
  y: number,
): { order: string[]; overIndex: number; upperHalf: boolean } {
  const items = Array.from(list?.querySelectorAll<HTMLElement>('[data-session-id]') ?? [])
  const order: string[] = []
  let overIndex = 0
  let upperHalf = true
  for (const item of items) {
    const id = item.dataset.sessionId
    if (id === undefined) continue
    const box = item.getBoundingClientRect()
    if (y >= box.top) {
      overIndex = order.length
      upperHalf = y < box.top + box.height / 2
    }
    order.push(id)
  }
  return { order, overIndex, upperHalf }
}

// The dragged row and the session that it goes before. Null means the end of the list.
interface DropMark {
  id: string
  before: string | null
}

export default function WatchlistPanel(): React.JSX.Element {
  const { rows, selectedId, select } = useRegistry()
  const { contextFor, run } = useActions()
  const watched = useMemo(() => watchedRows(rows), [rows])
  const list = useRef<HTMLUListElement>(null)
  // The current order, for a drag that is still on when a row changes.
  const orderRef = useRef<string[]>([])
  // Removes the window listeners of the current drag.
  const stop = useRef<(() => void) | null>(null)
  // True from the release of a drag until the click of that release has gone.
  const noClick = useRef(false)
  const [mark, setMark] = useState<DropMark | null>(null)
  const [error, setError] = useState<string | null>(null)
  // The session of the row menu. A right-click on a row sets it before the menu opens.
  const [menuId, setMenuId] = useState<string | null>(null)
  const [menuOpen, setMenuOpen] = useState(false)
  const menuRow = menuId === null ? undefined : rows.find(r => r.sessionId === menuId)

  useEffect(() => {
    orderRef.current = watched.map(r => r.sessionId)
  }, [watched])
  useEffect(() => () => stop.current?.(), [])
  // When the row goes away, the menu closes.
  useEffect(() => {
    if (menuOpen && !menuRow) setMenuOpen(false)
  }, [menuOpen, menuRow])

  function startDrag(e: React.PointerEvent<HTMLElement>, id: string): void {
    if (e.button !== 0) return
    stop.current?.()
    const { pointerId } = e
    const start = { x: e.clientX, y: e.clientY }
    let started = false
    // True after Esc. The release then makes no move.
    let cancelled = false
    let before: string | null = null
    const targetAt = (y: number): string | null => {
      const { order, overIndex, upperHalf } = placeAt(list.current, y)
      return dropTarget(order, id, overIndex, upperHalf)
    }
    const onMove = (ev: PointerEvent): void => {
      if (ev.pointerId !== pointerId) return
      if (!started) {
        if (!movedToStack(start, { x: ev.clientX, y: ev.clientY })) return
        started = true
      }
      before = targetAt(ev.clientY)
      setMark(prev => (prev?.id === id && prev.before === before ? prev : { before, id }))
    }
    const onUp = (ev: PointerEvent): void => {
      if (ev.pointerId !== pointerId) return
      end()
      if (!started) return
      noClick.current = true
      window.setTimeout(() => {
        noClick.current = false
      }, 0)
      const target = targetAt(ev.clientY)
      // A drop at the place that the row has now is not a move. The ref has the current order.
      if (!shouldMove(orderRef.current, id, target, cancelled)) return
      setError(null)
      window.bifrost.registry.watch
        .move(id, target)
        .catch(err => setError(friendlyError(errorMessage(err))))
    }
    const onCancel = (ev: PointerEvent): void => {
      if (ev.pointerId === pointerId) end()
    }
    // Esc ends the drag at once. The row and the line go back. The release does nothing.
    const onKey = (ev: KeyboardEvent): void => {
      if (!isDragCancel(ev.key)) return
      cancelled = true
      end()
      if (!started) return
      // The release still comes. Its click must not select the row, as for a drop.
      // A pointer cancel ends the wait too. Both paths remove both listeners.
      const clear = (): void => {
        window.removeEventListener('pointerup', onRelease)
        window.removeEventListener('pointercancel', clear)
        if (stop.current === clear) stop.current = null
      }
      const onRelease = (): void => {
        clear()
        noClick.current = true
        window.setTimeout(() => {
          noClick.current = false
        }, 0)
      }
      window.addEventListener('pointerup', onRelease)
      window.addEventListener('pointercancel', clear)
      stop.current = clear
    }
    const end = (): void => {
      window.removeEventListener('pointermove', onMove)
      window.removeEventListener('pointerup', onUp)
      window.removeEventListener('pointercancel', onCancel)
      window.removeEventListener('keydown', onKey)
      stop.current = null
      setMark(null)
    }
    window.addEventListener('pointermove', onMove)
    window.addEventListener('pointerup', onUp)
    window.addEventListener('pointercancel', onCancel)
    window.addEventListener('keydown', onKey)
    stop.current = end
  }

  // A drop that keeps the place shows no line.
  const order = watched.map(r => r.sessionId)
  const moves = mark !== null && isMove(order, mark.id, mark.before)
  const last = order.at(-1)

  return (
    <div className='flex min-h-full min-w-0 flex-col' data-watchlist={true}>
      <ContextMenu.Root onOpenChange={setMenuOpen} open={menuOpen && menuRow !== undefined}>
        <ContextMenu.Trigger className='min-h-0 flex-1 select-none'>
          {watched.length === 0 ? (
            <p className='p-3 text-[13px] text-text-dim'>{EMPTY_TEXT}</p>
          ) : (
            <ul
              aria-label='Watchlist'
              onClickCapture={e => {
                if (!noClick.current) return
                e.preventDefault()
                e.stopPropagation()
              }}
              ref={list}
            >
              {watched.map(row => {
                const id = row.sessionId
                const lineAbove = moves && mark?.before === id
                const lineBelow = moves && mark?.before === null && id === last
                return (
                  <li
                    className={cx(
                      'relative flex h-[26px] items-center gap-2 px-2 text-xs',
                      row.watch && WATCH_ROW_BG[row.watch.colour],
                      mark?.id === id && 'opacity-40',
                      row.state === 'parked' && 'text-parked',
                    )}
                    data-session-id={id}
                    data-watch-colour={row.watch?.colour}
                    key={id}
                    onClick={() => select(id)}
                    onContextMenu={() => setMenuId(id)}
                    onDoubleClick={() => {
                      select(id)
                      run('open', id)
                    }}
                    onPointerDown={e => startDrag(e, id)}
                  >
                    {/* The selection is a layer on top of the watch colour. */}
                    {id === selectedId && (
                      <span
                        aria-hidden={true}
                        className='pointer-events-none absolute inset-0 bg-select'
                      />
                    )}
                    {/* The stripe in the full watch colour. It is above the selection layer. */}
                    {row.watch && (
                      <span
                        aria-hidden={true}
                        className={cx(
                          'pointer-events-none absolute inset-y-0 left-0 w-[3px]',
                          WATCH_SWATCH[row.watch.colour],
                        )}
                      />
                    )}
                    <SessionIcon row={row} size={16} />
                    <span className='min-w-0 flex-1 truncate'>{row.name}</span>
                    <span className={cx('shrink-0', TONE_TEXT[stateTone(row)])}>
                      {stateLabel(row.state)}
                    </span>
                    {(lineAbove || lineBelow) && (
                      <span
                        aria-hidden={true}
                        className={cx(
                          'pointer-events-none absolute inset-x-1 h-px bg-text-strong',
                          lineAbove ? 'top-0' : 'bottom-0',
                        )}
                      />
                    )}
                  </li>
                )
              })}
            </ul>
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
      <ErrorLine message={error} />
    </div>
  )
}
