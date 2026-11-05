import { type Dispatch, memo, useCallback, useRef, useState } from 'react'
import { cx } from '../lib/cx'
import { PanelContent, PanelTitle, panelScrolls } from '../panels/panels'
import { type Edge, TITLE_H } from './geometry'
import PanelMenu, { type Anchor } from './PanelMenu'
import type { Frame, WmAction } from './state'

// A drag moves the frame, or it resizes the frame at one edge or corner.
// A drag that starts on a tab of a stack can tear that tab out of the stack.
export type DragMode = 'move' | Edge | { tab: string }

export interface FrameProps {
  frame: Frame
  // The place of the frame in the z-order. A higher value is on top.
  z: number
  top: boolean
  dispatch: Dispatch<WmAction>
  onDrag(e: React.PointerEvent<HTMLElement>, frameId: string, mode: DragMode): void
}

// The resize handles. The edges are 6 pixels thick. The corners are 12 by 12 pixels.
const HANDLES: Record<Edge, string> = {
  e: 'inset-y-3 right-0 w-1.5 cursor-ew-resize',
  n: 'inset-x-3 top-0 h-1.5 cursor-ns-resize',
  ne: 'top-0 right-0 size-3 cursor-nesw-resize',
  nw: 'top-0 left-0 size-3 cursor-nwse-resize',
  s: 'inset-x-3 bottom-0 h-1.5 cursor-ns-resize',
  se: 'right-0 bottom-0 size-3 cursor-nwse-resize',
  sw: 'bottom-0 left-0 size-3 cursor-nesw-resize',
  w: 'inset-y-3 left-0 w-1.5 cursor-ew-resize',
}
const EDGES = Object.keys(HANDLES) as Edge[]

// The content keeps its props during a drag, so it does not render again.
const Content = memo(PanelContent)

// The buttons are above the resize handles, so a click near a corner hits the button.
const BUTTON =
  'relative z-10 flex size-6 shrink-0 items-center justify-center rounded text-text-dim hover:bg-panel hover:text-text disabled:opacity-40 disabled:hover:bg-transparent'

function LockGlyph(): React.JSX.Element {
  return (
    <svg
      className='size-3 shrink-0 text-text-dim'
      fill='none'
      role='img'
      stroke='currentColor'
      strokeWidth={1.5}
      viewBox='0 0 12 12'
    >
      <title>Locked</title>
      <rect height={5} rx={1} width={8} x={2} y={5.5} />
      <path d='M4 5.5V4a2 2 0 0 1 4 0v1.5' />
    </svg>
  )
}

function FrameView({ frame, z, top, dispatch, onDrag }: FrameProps): React.JSX.Element {
  const { id, rect } = frame
  const menuButton = useRef<HTMLButtonElement>(null)
  const [menu, setMenu] = useState<Anchor | null>(null)
  const closeMenu = useCallback(() => setMenu(null), [])
  const stacked = frame.panels.length > 1

  function onTitleDown(e: React.PointerEvent<HTMLElement>): void {
    if (e.button !== 0) return
    const target = e.target as Element
    // A pointer down on a tab of a stack can start a tear-out. A click on the tab activates it.
    const panelId = target.closest('[role="tab"]')?.getAttribute('data-panel-id')
    if (panelId) {
      onDrag(e, id, { tab: panelId })
      return
    }
    // A pointer down on a button is a click, not a move.
    if (target.closest('button')) return
    onDrag(e, id, 'move')
  }

  function toggleMenu(): void {
    const box = menuButton.current?.getBoundingClientRect()
    setMenu(open => (open || !box ? null : { bottom: box.bottom, right: box.right }))
  }

  return (
    <div
      className={cx(
        'absolute flex-col overflow-hidden rounded-md border bg-panel backdrop-blur-md',
        frame.minimised ? 'hidden' : 'flex',
        top ? 'border-accent' : 'border-panel-edge',
      )}
      data-frame-id={id}
      onPointerDownCapture={() => dispatch({ frameId: id, type: 'focus' })}
      style={{
        height: rect.h,
        left: rect.x,
        opacity: frame.opacity,
        top: rect.y,
        width: rect.w,
        zIndex: z,
      }}
    >
      <div
        className='flex shrink-0 touch-none select-none items-center gap-1 bg-title pr-3 pl-1'
        data-title-bar={true}
        onPointerDown={onTitleDown}
        style={{ height: TITLE_H }}
      >
        {stacked ? (
          <div className='flex min-w-0 flex-1 items-stretch self-stretch' role='tablist'>
            {frame.panels.map(panelId => {
              const active = panelId === frame.active
              return (
                <button
                  aria-selected={active}
                  className={cx(
                    'min-w-0 truncate border-b-2 px-2 text-xs',
                    active
                      ? 'border-accent text-text'
                      : 'border-transparent text-text-dim hover:text-text',
                  )}
                  data-panel-id={panelId}
                  key={panelId}
                  onClick={() => dispatch({ panelId, type: 'activate' })}
                  role='tab'
                  type='button'
                >
                  <PanelTitle panelId={panelId} />
                </button>
              )
            })}
          </div>
        ) : (
          <div className='flex min-w-0 flex-1 items-center'>
            <div className='truncate px-2 text-text text-xs' data-panel-id={frame.active}>
              <PanelTitle panelId={frame.active} />
            </div>
          </div>
        )}
        {frame.locked && <LockGlyph />}
        <button
          aria-expanded={menu !== null}
          aria-haspopup='dialog'
          aria-label='Panel menu'
          className={BUTTON}
          onClick={toggleMenu}
          ref={menuButton}
          title='Panel menu'
          type='button'
        >
          ⋯
        </button>
        <button
          aria-label='Minimise'
          className={BUTTON}
          onClick={() => dispatch({ frameId: id, type: 'minimise' })}
          title='Minimise'
          type='button'
        >
          −
        </button>
        <button
          aria-label='Close'
          className={BUTTON}
          onClick={() => dispatch({ panelId: frame.active, type: 'close' })}
          title='Close'
          type='button'
        >
          ×
        </button>
      </div>
      {/* The content scrolls in both directions when it is larger than the frame.
        A chat panel does not scroll. Its terminal fills the area. */}
      <div
        className={cx(
          'relative min-h-0 flex-1',
          panelScrolls(frame.active) ? 'overflow-auto' : 'overflow-hidden',
        )}
        data-frame-content={true}
      >
        <Content panelId={frame.active} />
      </div>
      {!frame.locked &&
        EDGES.map(edge => (
          <div
            className={cx('absolute touch-none select-none', HANDLES[edge])}
            data-edge={edge}
            key={edge}
            onPointerDown={e => {
              if (e.button === 0) onDrag(e, id, edge)
            }}
          />
        ))}
      {/* Not in the title bar: a pointer down in the menu must not start a move. */}
      {menu && !frame.minimised && (
        <PanelMenu
          anchor={menu}
          button={menuButton}
          dispatch={dispatch}
          frame={frame}
          onClose={closeMenu}
        />
      )}
    </div>
  )
}

// A drag changes only the dragged frame. The other frames keep their props and do not render.
export default memo(FrameView)
