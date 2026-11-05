import { type Dispatch, type RefObject, useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { MAX_SET_NAME } from '../overview/config'
import { useOverview } from '../overview/overviews-context'
import { useDismiss } from './popover'
import { type Frame, panelKind, type WmAction } from './state'

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

// The field shows the saved name again after each change of the name.
function NameField(props: { name: string; onSave(name: string): void }): React.JSX.Element {
  const [draft, setDraft] = useState(props.name)
  return (
    <label className='flex flex-col gap-1'>
      <span>Tab set name</span>
      <input
        className='rounded border border-panel-edge bg-bg px-2 py-1 text-text outline-none focus:border-text-strong/30'
        maxLength={MAX_SET_NAME}
        onChange={e => setDraft(e.target.value)}
        onKeyDown={e => {
          if (e.key !== 'Enter') return
          e.preventDefault()
          props.onSave(draft)
          // The reducer refuses an empty name. Then the field shows the saved name.
          setDraft(props.name)
        }}
        type='text'
        value={draft}
      />
    </label>
  )
}

// Enter saves the name of the tab set of an Overview.
function SetNameField({ panelId }: { panelId: string }): React.JSX.Element {
  const { config, update } = useOverview(panelId)
  return (
    <NameField
      key={config.name}
      name={config.name}
      onSave={name => update({ name, type: 'rename' })}
    />
  )
}

// The menu of one frame: a Lock checkbox. A frame has no opacity control (spec 8.1).
// For an Overview, the menu also has the name of the tab set.
// The menu is in document.body. So the clip of the frame does not apply to it.
export default function PanelMenu({
  frame,
  anchor,
  button,
  dispatch,
  onClose,
}: PanelMenuProps): React.JSX.Element {
  const ref = useRef<HTMLDivElement>(null)
  const lock = useRef<HTMLInputElement>(null)
  useDismiss(ref, button, onClose)

  useEffect(() => {
    lock.current?.focus()
  }, [])

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
      <label className='flex items-center gap-2'>
        <input
          checked={frame.locked}
          onChange={e => dispatch({ frameId: frame.id, locked: e.target.checked, type: 'lock' })}
          ref={lock}
          type='checkbox'
        />
        Lock
      </label>
      {panelKind(frame.active) === 'overview' && <SetNameField panelId={frame.active} />}
    </div>,
    document.body,
  )
}
