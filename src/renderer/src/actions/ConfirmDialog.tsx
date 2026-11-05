// The confirmation dialog of Stop, Delete and Take control (spec 9.1, 9.2).
// One dialog serves the app. useConfirm shows it and resolves true only after a confirm click.
import { AlertDialog } from '@base-ui/react/alert-dialog'
import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react'
import { cx } from '../lib/cx'
import type { ConfirmText } from './confirm'
import { type ConfirmState, confirmLabel, confirmStep } from './confirm-step'

// The style of the menu popup of M3, with 13 px text and a maximum width of 420 px.
export const DIALOG_POPUP =
  'fixed top-1/2 left-1/2 z-50 flex w-[calc(100vw-32px)] max-w-[420px] -translate-x-1/2 -translate-y-1/2 flex-col gap-3 border border-panel-edge bg-title p-4 text-[13px] text-text outline-none backdrop-blur-md'
export const DIALOG_BACKDROP = 'fixed inset-0 z-50 bg-bg/40'
// A press gives a short cyan tint. A hover stays neutral (spec 8.10).
export const DIALOG_BUTTON =
  'shrink-0 border border-panel-edge px-2 py-0.5 text-text hover:bg-panel enabled:active:bg-accent/12 disabled:opacity-40'

export interface ConfirmOptions {
  // The click on Open worktree. The dialog stays open.
  onOpenFolder?(): void
}

export type Confirm = (text: ConfirmText, opts?: ConfirmOptions) => Promise<boolean>

interface Request {
  text: ConfirmText
  opts: ConfirmOptions
  resolve(ok: boolean): void
}

const ConfirmContext = createContext<Confirm | null>(null)

export function ConfirmProvider({ children }: { children: React.ReactNode }): React.JSX.Element {
  const [request, setRequest] = useState<Request | null>(null)
  // The dialog keeps the last text while it closes.
  const [shown, setShown] = useState<Request | null>(null)
  const [step, setStep] = useState<ConfirmState>('first')
  const pending = useRef<Request | null>(null)
  const cancelRef = useRef<HTMLButtonElement>(null)

  // Resolve the open request one time and close the dialog.
  const finish = useCallback((ok: boolean) => {
    const current = pending.current
    if (!current) return
    pending.current = null
    setRequest(null)
    current.resolve(ok)
  }, [])

  // One dialog at a time. A second request while a dialog shows gives false at once.
  const confirm = useCallback<Confirm>(
    (text, opts = {}) =>
      new Promise<boolean>(resolve => {
        if (pending.current) {
          resolve(false)
          return
        }
        const next: Request = { opts, resolve, text }
        pending.current = next
        setStep('first')
        setShown(next)
        setRequest(next)
      }),
    [],
  )

  // When the provider goes away, an open request gives false.
  useEffect(() => () => finish(false), [finish])

  function onConfirm(e: React.MouseEvent<HTMLButtonElement>): void {
    const current = pending.current
    if (!current) return
    // The second click must be its own click. The second half of a double click does not count.
    if (step === 'again' && e.detail > 1) return
    const result = confirmStep(step, current.text)
    if (result.resolve) finish(true)
    else setStep('again')
  }

  const text = shown?.text
  const openFolder = shown?.opts.onOpenFolder
  return (
    <ConfirmContext value={confirm}>
      {children}
      {/* Esc and Cancel give false. A click outside the dialog does nothing. */}
      <AlertDialog.Root
        onOpenChange={open => {
          if (!open) finish(false)
        }}
        open={request !== null}
      >
        <AlertDialog.Portal>
          <AlertDialog.Backdrop className={DIALOG_BACKDROP} />
          <AlertDialog.Popup
            className={DIALOG_POPUP}
            data-confirm-dialog={true}
            initialFocus={cancelRef}
          >
            <AlertDialog.Title className='font-semibold text-text-strong'>
              {text?.title}
            </AlertDialog.Title>
            <AlertDialog.Description className='select-text whitespace-pre-line'>
              {text?.body}
            </AlertDialog.Description>
            <div className='flex items-center gap-2'>
              {text?.openFolder !== undefined && openFolder && (
                <button
                  className={DIALOG_BUTTON}
                  data-confirm-open-folder={true}
                  onClick={() => openFolder()}
                  type='button'
                >
                  Open worktree
                </button>
              )}
              <span className='flex-1' />
              <AlertDialog.Close
                className={DIALOG_BUTTON}
                data-confirm-cancel={true}
                ref={cancelRef}
              >
                Cancel
              </AlertDialog.Close>
              <button
                className={cx(DIALOG_BUTTON, step === 'again' && 'text-text-strong')}
                data-confirm-ok={step}
                onClick={onConfirm}
                type='button'
              >
                {text ? confirmLabel(step, text) : ''}
              </button>
            </div>
          </AlertDialog.Popup>
        </AlertDialog.Portal>
      </AlertDialog.Root>
    </ConfirmContext>
  )
}

export function useConfirm(): Confirm {
  const value = useContext(ConfirmContext)
  if (!value) throw new Error('useConfirm needs a ConfirmProvider.')
  return value
}
