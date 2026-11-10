import { LayoutGrid } from 'lucide-react'
import { type RefObject, useCallback, useEffect, useRef, useState } from 'react'
import { cx } from '../lib/cx'
import { Tip } from '../lib/menu'
import { useLayoutMenu, useLayouts, useWmControls } from './context'
import { MAX_LAYOUTS, MAX_NAME } from './layout'
import { useDismiss } from './popover'

const NAME_MESSAGE = `Use 1 to ${MAX_NAME} characters.`
const FULL_MESSAGE = `Delete a layout first. The limit is ${MAX_LAYOUTS}.`

// A press gives a short cyan tint. A hover stays neutral (spec 8.10).
const SMALL_BUTTON =
  'shrink-0 border border-panel-edge px-2 py-0.5 text-text-dim hover:bg-panel hover:text-text active:bg-accent/12'

function LayoutPopover(props: {
  button: RefObject<HTMLButtonElement | null>
  focusRequest: number
  onClose(): void
}): React.JSX.Element {
  const { saveLayout, loadLayout, deleteLayout } = useWmControls()
  const names = useLayouts()
  const [name, setName] = useState('')
  const [message, setMessage] = useState<string | null>(null)
  const ref = useRef<HTMLDivElement>(null)
  const field = useRef<HTMLInputElement>(null)
  useDismiss(ref, props.button, props.onClose)

  // The field takes the focus when the popover opens, and again at each Cmd+Option+S.
  // biome-ignore lint/correctness/useExhaustiveDependencies: each new request focuses the field again.
  useEffect(() => {
    field.current?.focus()
  }, [props.focusRequest])

  // Enter in the name field also sends this form.
  function onSubmit(e: React.FormEvent<HTMLFormElement>): void {
    e.preventDefault()
    const result = saveLayout(name)
    if (result === 'saved') {
      setName('')
      setMessage(null)
    } else {
      setMessage(result === 'name' ? NAME_MESSAGE : FULL_MESSAGE)
    }
  }

  return (
    <div
      aria-label='Layouts'
      className='absolute bottom-0 left-full z-10 ml-2 flex w-64 flex-col gap-2 border border-panel-edge bg-title p-3 text-xs text-text select-text'
      ref={ref}
      role='dialog'
    >
      <form className='flex gap-2' onSubmit={onSubmit}>
        <input
          aria-label='Layout name'
          className='min-w-0 flex-1 border border-panel-edge bg-bg px-2 py-1 text-text focus:border-text-strong/30'
          onChange={e => {
            setName(e.target.value)
            setMessage(null)
          }}
          placeholder='Layout name'
          ref={field}
          type='text'
          value={name}
        />
        <button className={SMALL_BUTTON} type='submit'>
          Save
        </button>
      </form>
      {message && <p role='status'>{message}</p>}
      {names.length === 0 ? (
        <p className='text-text-dim'>No saved layouts.</p>
      ) : (
        <ul aria-label='Saved layouts' className='flex max-h-64 flex-col gap-1 overflow-y-auto'>
          {names.map(item => (
            <li className='flex items-center gap-2' key={item}>
              <span className='min-w-0 flex-1 truncate' title={item}>
                {item}
              </span>
              <button
                aria-label={`Load ${item}`}
                className={SMALL_BUTTON}
                onClick={() => loadLayout(item)}
                type='button'
              >
                Load
              </button>
              <button
                aria-label={`Delete ${item}`}
                className={SMALL_BUTTON}
                onClick={() => deleteLayout(item)}
                type='button'
              >
                Delete
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

// The Layouts button at the bottom of the side bar, and its popover.
// The window manager keeps the open state, so Cmd+Option+S can open the popover.
export default function LayoutMenu(props: { className: string }): React.JSX.Element {
  const { focusRequest, open, setOpen } = useLayoutMenu()
  const button = useRef<HTMLButtonElement>(null)
  const close = useCallback(() => setOpen(false), [setOpen])

  return (
    <div className='relative mt-auto'>
      <Tip label='Layouts' side='right'>
        <button
          aria-expanded={open}
          aria-haspopup='dialog'
          aria-label='Layouts'
          className={cx(props.className, 'h-8')}
          onClick={() => setOpen(!open)}
          ref={button}
          type='button'
        >
          <LayoutGrid aria-hidden={true} size={16} />
        </button>
      </Tip>
      {open && <LayoutPopover button={button} focusRequest={focusRequest} onClose={close} />}
    </div>
  )
}
