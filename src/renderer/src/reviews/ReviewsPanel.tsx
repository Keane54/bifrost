// The Reviews panel: the To review tab and the My PRs tab (design section 8 and 9).
import { RefreshCw } from 'lucide-react'
import { useCallback, useState } from 'react'
import type { ReviewsSnapshot } from '../../../shared/reviews'
import { friendlyError } from '../actions/errors'
import { cx } from '../lib/cx'
import { ErrorLine } from '../lib/ErrorLine'
import { errorMessage } from '../lib/error-message'
import { Tip } from '../lib/menu'
import { useNow } from '../lib/use-now'
import { useSettingsNav } from '../settings/settings-nav'
import { panelBody } from './panel-body'
import { MyPrItem, ToReviewItem } from './ReviewRow'
import { type ReviewsTab, setReviewsTab, useReviewsTab } from './reviews-tab'
import { AUTO_FIX_HINT } from './row-text'
import { TrustStrip } from './TrustStrip'
import { useReviews } from './use-reviews'

const TABS: { id: ReviewsTab; label: string }[] = [
  { id: 'to-review', label: 'To review' },
  { id: 'mine', label: 'My PRs' },
]

// The count of a tab is red while one of its rows needs you.
export function hotTab(s: ReviewsSnapshot, tab: ReviewsTab): boolean {
  return tab === 'to-review'
    ? s.toReview.some(r => r.flash)
    : s.mine.some(r => r.claude === 'needs-you')
}

function Notice({ children }: { children: React.ReactNode }): React.JSX.Element {
  return <p className='px-3 py-2 text-xs text-text-dim'>{children}</p>
}

export default function ReviewsPanel(): React.JSX.Element {
  const snapshot = useReviews()
  const tab = useReviewsTab()
  const settingsNav = useSettingsNav()
  const now = useNow(30_000)
  const [error, setError] = useState<string | null>(null)

  const onAct = useCallback((job: () => Promise<void>) => {
    setError(null)
    job().catch((err: unknown) => setError(friendlyError(errorMessage(err))))
  }, [])

  const { availability } = snapshot
  const rows = tab === 'to-review' ? snapshot.toReview : snapshot.mine
  const counts: Record<ReviewsTab, number> = {
    mine: snapshot.mine.length,
    'to-review': snapshot.toReview.length,
  }

  const kind = panelBody(snapshot, rows.length)
  let body: React.ReactNode
  if (kind === 'off') {
    body = (
      <div className='flex flex-col items-start gap-2 px-3 py-2'>
        <p className='text-xs text-text-dim'>
          Reviews is off. Turn on Watch GitHub in Settings to see your pull requests.
        </p>
        <button
          className='border border-panel-edge bg-black/35 px-1.5 text-xs leading-4 text-text hover:text-text-strong active:bg-accent/12'
          onClick={() => settingsNav.open('reviews')}
          type='button'
        >
          Open Settings
        </button>
      </div>
    )
  } else if (kind === 'starting') {
    body = <Notice>Checking GitHub…</Notice>
  } else if (kind === 'notice') {
    body = <Notice>{snapshot.message}</Notice>
  } else if (kind === 'error') {
    // The error line under the body shows the message.
    body = null
  } else if (kind === 'empty') {
    body = <Notice>Nothing needs you here.</Notice>
  } else if (tab === 'to-review') {
    body = snapshot.toReview.map(row => (
      <ToReviewItem key={row.key} now={now} onAct={onAct} row={row} />
    ))
  } else {
    body = snapshot.mine.map(row => <MyPrItem key={row.key} onAct={onAct} row={row} />)
  }

  const showTabs = availability !== 'off' && availability !== 'starting'
  // Ruling S20: the automatic fixes wait for the confirm of the user in Settings.
  const showHint =
    tab === 'mine' && snapshot.autoFixConfirm && (kind === 'rows' || kind === 'empty')
  return (
    <div className='flex h-full min-h-0 flex-col'>
      {showTabs && (
        <div
          className='flex h-[22px] shrink-0 items-stretch border-b border-panel-edge'
          role='tablist'
        >
          {TABS.map(t => (
            <button
              aria-selected={t.id === tab}
              className={cx(
                'truncate border-b-2 px-2 text-xs active:bg-accent/12',
                t.id === tab
                  ? 'border-text-strong text-text-strong'
                  : 'border-transparent text-text-dim hover:text-text',
              )}
              data-reviews-tab={t.id}
              key={t.id}
              onClick={() => setReviewsTab(t.id)}
              role='tab'
              type='button'
            >
              {t.label}{' '}
              <span
                className={hotTab(snapshot, t.id) ? 'text-box-red' : undefined}
                data-reviews-count={t.id}
              >
                {counts[t.id]}
              </span>
            </button>
          ))}
          <div className='ml-auto flex items-center pr-1'>
            <Tip label='Refresh'>
              <button
                aria-label='Refresh'
                className='flex size-4 items-center justify-center text-text-dim hover:bg-hover hover:text-text active:bg-accent/12'
                onClick={() => onAct(() => window.bifrost.reviews.refresh())}
                type='button'
              >
                <RefreshCw aria-hidden={true} size={12} />
              </button>
            </Tip>
          </div>
        </div>
      )}
      <TrustStrip needs={snapshot.trust} />
      {showHint && (
        <div className='flex shrink-0 items-start gap-2 border-b border-panel-edge px-3 py-2'>
          <p className='min-w-0 flex-1 text-xs text-text-dim'>{AUTO_FIX_HINT}</p>
          <button
            className='shrink-0 border border-panel-edge bg-black/35 px-1.5 text-xs leading-4 text-text hover:text-text-strong active:bg-accent/12'
            onClick={() => settingsNav.open('reviews')}
            type='button'
          >
            Open Settings
          </button>
        </div>
      )}
      <div className='min-h-0 flex-1 overflow-auto select-none'>{body}</div>
      {availability === 'error' && snapshot.message !== null && (
        <ErrorLine message={snapshot.message} />
      )}
      <ErrorLine message={error} onClose={() => setError(null)} />
    </div>
  )
}
