import { type Dispatch, memo } from 'react'
import { cx } from '../lib/cx'
import { PanelContent, panelTitle } from '../panels/panels'
import { type Edge, TITLE_H } from './geometry'
import type { Frame, WmAction } from './state'

// A drag moves the frame, or it resizes the frame at one edge or corner.
export type DragMode = 'move' | Edge

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

function FrameView({ frame, z, top, dispatch, onDrag }: FrameProps): React.JSX.Element {
  const { id, rect } = frame

  function onTitleDown(e: React.PointerEvent<HTMLElement>): void {
    // A pointer down on a button is a click, not a move.
    if (e.button !== 0 || (e.target as Element).closest('button')) return
    onDrag(e, id, 'move')
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
        <div className='flex min-w-0 flex-1 items-center'>
          {frame.panels.map(panelId => (
            <div
              className={cx(
                'truncate px-2 text-xs',
                panelId === frame.active ? 'text-text' : 'text-text-dim',
              )}
              data-panel-id={panelId}
              key={panelId}
            >
              {panelTitle(panelId)}
            </div>
          ))}
        </div>
        {/* Task 6 adds the opacity and lock controls to this menu. */}
        <button
          aria-label='Panel menu'
          className={BUTTON}
          disabled={true}
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
      <div className='relative min-h-0 flex-1'>
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
    </div>
  )
}

// A drag changes only the dragged frame. The other frames keep their props and do not render.
export default memo(FrameView)
