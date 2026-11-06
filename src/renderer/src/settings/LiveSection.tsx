// Settings > Live details (spec 11.2, 12, D11): the state, the buttons, the notes and the
// version of Claude Code.
import { useEffect, useState } from 'react'
import { DIALOG_BUTTON, useConfirm } from '../actions/ConfirmDialog'
import { ErrorLine } from '../lib/ErrorLine'
import { errorMessage } from '../lib/error-message'
import LiveSteps from './LiveSteps'
import { useLive } from './live-context'
import {
  claudeVersionLine,
  claudeVersionNotice,
  type LiveActionId,
  liveActions,
  liveStateLine,
  liveVersionNote,
  oldInstallNote,
  RELOAD_NOTE,
  REMOVE_CONFIRM,
  WITHOUT_LIVE,
} from './live-notice'

const LABELS: Record<LiveActionId, string> = {
  disable: 'Turn off',
  enable: 'Turn on',
  install: 'Install',
  remove: 'Remove',
  retry: 'Try again',
}

function Note({ text, name }: { text: string | null; name: string }): React.JSX.Element | null {
  if (text === null) return null
  return (
    <p className='mt-2 text-text' data-live-note={name}>
      {text}
    </p>
  )
}

export default function LiveSection(): React.JSX.Element {
  const live = useLive()
  const { busy, changed, notice, refresh, status, version, versionFailed } = live
  const confirm = useConfirm()
  const [error, setError] = useState<string | null>(null)
  // True after the first Install click. The steps then show with Install and Cancel.
  const [showSteps, setShowSteps] = useState(false)

  // Read the status again each time the section opens. So the state line is current.
  useEffect(() => {
    void refresh()
  }, [refresh])

  // Run a call. A failure shows its message until the user closes it. The result is true when
  // the call worked.
  const run = async (fn: () => Promise<void>): Promise<boolean> => {
    setError(null)
    try {
      await fn()
      return true
    } catch (err) {
      setError(errorMessage(err))
      return false
    }
  }

  const onAction = (id: LiveActionId): void => {
    switch (id) {
      case 'install':
        setError(null)
        setShowSteps(true)
        return
      case 'enable':
        void run(live.enable)
        return
      case 'disable':
        void run(live.disable)
        return
      case 'retry':
        void run(refresh)
        return
      case 'remove':
        void confirm(REMOVE_CONFIRM).then(ok => {
          if (ok) void run(live.uninstall)
        })
        return
    }
  }

  // The status for the steps of Install, or null when the steps do not show.
  const stepsOf = showSteps && notice.kind === 'not-installed' ? status : null
  const claudeLine = claudeVersionLine(version, versionFailed)

  return (
    <div className='flex flex-col text-xs'>
      <div className='border-panel-edge border-b px-3 py-2'>
        <p className='select-text text-text-strong' data-live-state={notice.kind}>
          {liveStateLine(notice)}
        </p>
        {notice.kind === 'not-installed' && (
          <p className='mt-1 select-text text-text-dim'>{WITHOUT_LIVE}</p>
        )}
        {stepsOf ? (
          <div className='mt-2 text-text'>
            <p className='mb-1'>Install makes these changes:</p>
            <LiveSteps status={stepsOf} />
            <div className='mt-2 flex items-center gap-2'>
              <button
                className={DIALOG_BUTTON}
                data-live-action='install-confirm'
                disabled={busy}
                onClick={() => {
                  void run(live.install).then(ok => {
                    if (ok) setShowSteps(false)
                  })
                }}
                type='button'
              >
                Install
              </button>
              <button
                className={DIALOG_BUTTON}
                data-live-action='install-cancel'
                disabled={busy}
                onClick={() => setShowSteps(false)}
                type='button'
              >
                Cancel
              </button>
            </div>
          </div>
        ) : (
          liveActions(status).length > 0 && (
            <div className='mt-2 flex items-center gap-2'>
              {liveActions(status).map(id => (
                <button
                  className={DIALOG_BUTTON}
                  data-live-action={id}
                  disabled={busy}
                  key={id}
                  onClick={() => onAction(id)}
                  type='button'
                >
                  {LABELS[id]}
                </button>
              ))}
            </div>
          )
        )}
        <Note name='old-install' text={oldInstallNote(status)} />
        <Note name='live-version' text={liveVersionNote(status)} />
        <Note name='reload' text={changed ? RELOAD_NOTE : null} />
      </div>
      <ErrorLine message={error} onClose={() => setError(null)} />
      <div className='px-3 py-2 text-text' data-live-claude={true}>
        {claudeLine !== null && <p className='select-text'>{claudeLine}</p>}
        <Note name='version' text={claudeVersionNotice(version, versionFailed)} />
      </div>
    </div>
  )
}
