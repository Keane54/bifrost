import { X } from 'lucide-react'
import { Tip } from './menu'

// The close button of an error line. A press gives a short cyan tint. A hover stays neutral
// (spec 8.10).
const CLOSE =
  'flex size-4 shrink-0 items-center justify-center text-text-dim hover:bg-hover hover:text-text active:bg-accent/12'

// The text at the bottom of a panel that shows an error. A null message shows nothing.
// The text is not red, because red is only for the red box (spec 8.10).
// It shows the full friendly text, with no prefix. A long text wraps to more lines (Task 15).
// With onClose, the line has a close button. An error then stays until the user closes it
// (Task 18).
export function ErrorLine({
  message,
  onClose,
}: {
  message: string | null
  onClose?: () => void
}): React.JSX.Element | null {
  if (message === null) return null
  return (
    <div
      className='flex shrink-0 items-start gap-1 border-panel-edge border-t px-2 text-text text-xs'
      data-error-line={true}
    >
      <p className='wrap-break-word min-w-0 flex-1'>{message}</p>
      {onClose !== undefined && (
        <Tip label='Close'>
          <button aria-label='Close' className={CLOSE} onClick={onClose} type='button'>
            <X aria-hidden={true} size={12} />
          </button>
        </Tip>
      )}
    </div>
  )
}

// The text at the bottom of a panel that shows a notice of an action. A null message shows
// nothing. A long text wraps to more lines.
export function NoticeLine({ message }: { message: string | null }): React.JSX.Element | null {
  if (message === null) return null
  return (
    <p
      className='wrap-break-word shrink-0 border-panel-edge border-t px-2 text-text-dim text-xs'
      data-notice-line={true}
    >
      {message}
    </p>
  )
}
