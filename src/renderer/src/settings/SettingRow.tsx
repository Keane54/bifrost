// One row of the Settings panel: the label on the left, the control on the right (spec 12).
// An optional hint shows under the row. An optional error shows under the hint.
// During a search, a row that does not match shows nothing.
import { useCallback, useState } from 'react'
import { friendlyError } from '../actions/errors'
import { cx } from '../lib/cx'
import { ErrorLine } from '../lib/ErrorLine'
import { errorMessage } from '../lib/error-message'
import { useRowShown } from './row-filter'
import { useSaveTracker } from './save-context'

// The field style of the dialogs, in a smaller size for a row.
export const ROW_FIELD =
  'h-5 min-w-0 border border-panel-edge bg-bg px-1.5 text-text text-xs focus:border-text-strong/30 disabled:opacity-40'

export function SettingRow({
  label,
  hint,
  error,
  onCloseError,
  children,
}: {
  label: string
  hint?: string
  error?: string | null
  onCloseError?: () => void
  children: React.ReactNode
}): React.JSX.Element | null {
  if (!useRowShown(label)) return null
  return (
    <div className='border-panel-edge border-b' data-setting-row={label}>
      <div className='flex min-h-7 items-center justify-between gap-3 px-3'>
        <span className='shrink-0 text-text text-xs'>{label}</span>
        <div className={cx('flex min-w-0 items-center justify-end gap-2 text-text text-xs')}>
          {children}
        </div>
      </div>
      {hint !== undefined && <p className='px-3 pb-1 text-text-dim text-xs'>{hint}</p>}
      <ErrorLine message={error ?? null} onClose={onCloseError} />
    </div>
  )
}

export interface RowSave {
  error: string | null
  closeError(): void
  // Run a save. The result is true when it worked. A failure shows its reason in the row.
  save(run: () => Promise<void>): Promise<boolean>
}

// The error state of one row. The error stays until the user closes it or the next save works.
// In the Settings panel, the Save button waits for each save of a row (spec 12).
export function useRowSave(): RowSave {
  const tracker = useSaveTracker()
  const [error, setError] = useState<string | null>(null)
  const closeError = useCallback(() => setError(null), [])
  const save = useCallback(
    (run: () => Promise<void>): Promise<boolean> => {
      const result = (async (): Promise<boolean> => {
        try {
          await run()
          setError(null)
          return true
        } catch (err) {
          setError(friendlyError(errorMessage(err)))
          return false
        }
      })()
      tracker?.track(result)
      return result
    },
    [tracker],
  )
  return { closeError, error, save }
}
