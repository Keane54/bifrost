import { type RefObject, useCallback, useEffect, useRef, useState } from 'react'
import { cx } from '../lib/cx'
import { useLayouts, useWmControls } from './context'
import { MAX_LAYOUTS, MAX_NAME } from './layout'
import { useDismiss } from './popover'

const NAME_MESSAGE = `Use 1 to ${MAX_NAME} characters.`
const FULL_MESSAGE = `Delete a layout first. The limit is ${MAX_LAYOUTS}.`

const SMALL_BUTTON =
  'shrink-0 rounded border border-panel-edge px-2 py-0.5 text-text-dim hover:bg-panel hover:text-text'

function LayoutPopover(props: {
  button: RefObject<HTMLButtonElement | null>
  onClose(): void
}): React.JSX.Element {
  const { saveLayout, loadLayout, deleteLayout } = useWmControls()
  const names = useLayouts()
  const [name, setName] = useState('')
  const [message, setMessage] = useState<string | null>(null)
  const ref = useRef<HTMLDivElement>(null)
  const field = useRef<HTMLInputElement>(null)
  useDismiss(ref, props.button, props.onClose)

  useEffect(() => {
    field.current?.focus()
  }, [])

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
      className='absolute bottom-0 left-full z-10 ml-2 flex w-64 select-text flex-col gap-2 rounded-md border border-panel-edge bg-title p-3 text-text text-xs'
      ref={ref}
      role='dialog'
    >
      <form className='flex gap-2' onSubmit={onSubmit}>
        <input
          aria-label='Layout name'
          className='min-w-0 flex-1 rounded border border-panel-edge bg-bg px-2 py-1 text-text outline-none focus:border-accent'
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
export default function LayoutMenu(props: { className: string }): React.JSX.Element {
  const [open, setOpen] = useState(false)
  const button = useRef<HTMLButtonElement>(null)
  const close = useCallback(() => setOpen(false), [])

  return (
    <div className='relative mt-auto'>
      <button
        aria-expanded={open}
        aria-haspopup='dialog'
        aria-label='Layouts'
        className={cx(props.className, 'h-8')}
        onClick={() => setOpen(value => !value)}
        ref={button}
        title='Layouts'
        type='button'
      >
        L
      </button>
      {open && <LayoutPopover button={button} onClose={close} />}
    </div>
  )
}
