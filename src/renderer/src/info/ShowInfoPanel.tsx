// The Show Info panel (spec 8.6): all known values of one session, with the PR from gh.
import { Copy } from 'lucide-react'
import { useEffect, useState } from 'react'
import type { PrInfo } from '../../../shared/types'
import { useActions } from '../actions/actions-context'
import { REASON_GONE } from '../actions/reasons'
import { useRegistry } from '../data/registry'
import { cx } from '../lib/cx'
import { ErrorLine } from '../lib/ErrorLine'
import { errorMessage } from '../lib/error-message'
import { Tip } from '../lib/menu'
import { useNow } from '../lib/use-now'
import { type InfoItem, infoSections, prFailure, showInfoSessionId } from './show-info'

const LIVE_HINT = 'Turn on Live details in Settings to see the model, effort, cost and limits.'
const WAITING = 'Waiting for the session list...'

const COPY_BUTTON =
  'ml-1 inline-flex size-4 shrink-0 items-center justify-center align-middle text-text-dim hover:bg-hover hover:text-text active:bg-accent/12'

// The PR of the branch. It is null until the call ends. A new call starts when the folder or
// the branch changes.
function usePr(sessionId: string | null, cwd: string | undefined, branch: string | undefined) {
  const [pr, setPr] = useState<PrInfo | null>(null)
  // biome-ignore lint/correctness/useExhaustiveDependencies: a new folder or branch needs a new call.
  useEffect(() => {
    if (sessionId === null || cwd === undefined) return
    let active = true
    setPr(null)
    window.bifrost.info.pr(sessionId).then(
      value => {
        if (active) setPr(value)
      },
      err => {
        if (active) setPr(prFailure(errorMessage(err)))
      },
    )
    return () => {
      active = false
    }
  }, [sessionId, cwd, branch])
  return pr
}

function Value({
  item,
  pr,
  sessionId,
}: {
  item: InfoItem
  pr: PrInfo | null
  sessionId: string
}): React.JSX.Element {
  const { run } = useActions()
  if (item.label === 'PR' && pr?.kind === 'pr') {
    return (
      <button
        className='min-w-0 cursor-pointer text-left break-all text-text-strong underline'
        onClick={() => {
          window.bifrost.info
            .openPr(sessionId)
            .catch(err => console.error('Bifrost cannot open the PR.', err))
        }}
        type='button'
      >
        {item.value}
      </button>
    )
  }
  return (
    <span className={cx('min-w-0 break-all select-text', item.mono && 'font-mono')}>
      {item.value}
      {item.label === 'Session ID' && (
        <Tip label='Copy session ID'>
          <button
            aria-label='Copy session ID'
            className={COPY_BUTTON}
            onClick={() => run('copy-id', sessionId)}
            type='button'
          >
            <Copy size={13} />
          </button>
        </Tip>
      )}
    </span>
  )
}

export default function ShowInfoPanel({ panelId }: { panelId: string }): React.JSX.Element {
  const { loaded, rows } = useRegistry()
  const { closeError, error } = useActions()
  const now = useNow(1000)
  const sessionId = showInfoSessionId(panelId)
  const row = rows.find(r => r.sessionId === sessionId)
  const pr = usePr(sessionId, row?.cwd, row?.branch)
  if (!row || sessionId === null) {
    return <div className='p-3 text-[13px] text-text-dim'>{loaded ? REASON_GONE : WAITING}</div>
  }
  return (
    <div className='flex min-h-full min-w-0 flex-col text-xs'>
      <div className='flex flex-1 flex-col gap-3 p-3'>
        {infoSections(row, now, pr).map(section => (
          <section key={section.title}>
            <h3 className='mb-1 text-[11px] text-text-dim'>{section.title}</h3>
            <dl className='grid min-w-0 grid-cols-[120px_1fr] gap-x-3 gap-y-0.5'>
              {section.items.map(item => (
                <div className='contents' key={item.label}>
                  <dt className='text-[11px] text-text-dim'>{item.label}</dt>
                  <dd className='min-w-0 text-xs'>
                    <Value item={item} pr={pr} sessionId={sessionId} />
                  </dd>
                </div>
              ))}
            </dl>
          </section>
        ))}
        {row.live === undefined && row.model === undefined && (
          <p className='text-[11px] text-text-dim'>{LIVE_HINT}</p>
        )}
      </div>
      <ErrorLine message={error} onClose={closeError} />
    </div>
  )
}
