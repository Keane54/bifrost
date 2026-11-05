import { type Dispatch, type RefObject, useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import { useDismiss } from './popover'
import type { Frame, WmAction } from './state'

// The screen position of the menu button. The menu opens below the button, at its right edge.
export interface Anchor {
  bottom: number
  right: number
}

export interface PanelMenuProps {
  frame: Frame
  anchor: Anchor
  button: RefObject<HTMLButtonElement | null>
  dispatch: Dispatch<WmAction>
  onClose(): void
}

const GAP = 4

// The menu of one frame: an opacity slider and a Lock checkbox.
// The menu is in document.body. So the opacity and the clip of the frame do not apply to it.
export default function PanelMenu({
  frame,
  anchor,
  button,
  dispatch,
  onClose,
}: PanelMenuProps): React.JSX.Element {
  const ref = useRef<HTMLDivElement>(null)
  const slider = useRef<HTMLInputElement>(null)
  useDismiss(ref, button, onClose)

  useEffect(() => {
    slider.current?.focus()
  }, [])

  const percent = Math.round(frame.opacity * 100)

  return createPortal(
    <div
      aria-label='Panel menu'
      className='fixed z-10 flex w-52 select-none flex-col gap-3 rounded-md border border-panel-edge bg-title p-3 text-text text-xs'
      ref={ref}
      role='dialog'
      style={{
        right: Math.max(GAP, document.documentElement.clientWidth - anchor.right),
        top: anchor.bottom + GAP,
      }}
    >
      <label className='flex flex-col gap-1'>
        <span className='flex justify-between'>
          <span>Opacity</span>
          <span className='text-text-dim'>{percent}%</span>
        </span>
        <input
          className='accent-accent'
          max={100}
          min={30}
          onChange={e =>
            dispatch({ frameId: frame.id, opacity: Number(e.target.value) / 100, type: 'opacity' })
          }
          ref={slider}
          step={5}
          type='range'
          value={percent}
        />
      </label>
      <label className='flex items-center gap-2'>
        <input
          checked={frame.locked}
          className='accent-accent'
          onChange={e => dispatch({ frameId: frame.id, locked: e.target.checked, type: 'lock' })}
          type='checkbox'
        />
        Lock
      </label>
    </div>,
    document.body,
  )
}
