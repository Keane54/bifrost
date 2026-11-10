// Settings > Updates: the switch for automatic checks, the version, the state of the updater and
// its buttons. The section shows the state that the main process pushes. It has no spinner of
// its own.
import { useState } from 'react'
import { DIALOG_BUTTON } from '../actions/ConfirmDialog'
import { ErrorLine } from '../lib/ErrorLine'
import { errorMessage } from '../lib/error-message'
import { useUpdates, useUpdatesLoaded } from '../updates/use-updates'
import { RowFilterContext } from './row-filter'
import { CheckRow } from './rows'
import { useSettings } from './settings-context'
import {
  lastCheckedLine,
  UPDATES_ACTION_LABELS,
  UPDATES_ROWS,
  type UpdatesActionId,
  updatesActionDisabled,
  updatesActions,
  updatesStateLine,
} from './updates-rows'

// only: during a search, the labels of the rows that show (spec 12).
export default function UpdatesSection({
  only = null,
}: {
  only?: ReadonlySet<string> | null
}): React.JSX.Element {
  const { settings, update } = useSettings()
  const snapshot = useUpdates()
  const loaded = useUpdatesLoaded()
  const [error, setError] = useState<string | null>(null)

  const onAction = (id: UpdatesActionId): void => {
    setError(null)
    const api = window.bifrost.updates
    const call = id === 'restart' ? api.restart() : id === 'show-log' ? api.showLog() : api.check()
    call.catch(err => setError(errorMessage(err)))
  }

  return (
    <RowFilterContext value={only}>
      <div className='flex flex-col text-xs'>
        <CheckRow
          checked={settings.autoUpdate}
          label={UPDATES_ROWS.auto}
          save={value => update({ autoUpdate: value })}
        />
        {only === null && loaded && (
          <div className='border-b border-panel-edge px-3 py-2'>
            <p className='text-text select-text'>Version {snapshot.version}</p>
            <p
              className='mt-1 text-text-strong select-text'
              data-updates-state={snapshot.state.kind}
            >
              {updatesStateLine(snapshot)}
            </p>
            {snapshot.lastCheckAt !== null && (
              <p className='mt-1 text-text-dim select-text'>
                {lastCheckedLine(snapshot.lastCheckAt, Date.now())}
              </p>
            )}
            {updatesActions(snapshot).length > 0 && (
              <div className='mt-2 flex items-center gap-2'>
                {updatesActions(snapshot).map(id => (
                  <button
                    className={DIALOG_BUTTON}
                    data-updates-action={id}
                    disabled={updatesActionDisabled(snapshot, id)}
                    key={id}
                    onClick={() => onAction(id)}
                    type='button'
                  >
                    {UPDATES_ACTION_LABELS[id]}
                  </button>
                ))}
              </div>
            )}
          </div>
        )}
        <ErrorLine message={error} onClose={() => setError(null)} />
      </div>
    </RowFilterContext>
  )
}
