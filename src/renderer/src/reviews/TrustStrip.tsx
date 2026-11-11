// The Trust needed strip of the Reviews panel (design section 8).
import type { TrustNeed } from '../../../shared/reviews'
import { cx } from '../lib/cx'
import { Tip } from '../lib/menu'
import { useWmControls } from '../wm/context'
import { setTrustRepo } from './trust-repo'
import { waitingText } from './trust-text'

const TRUST_TIP =
  "Opens Claude Code in Bifrost's copy of this repository, so you can accept the trust prompt."

export function TrustStrip({ needs }: { needs: readonly TrustNeed[] }): React.JSX.Element | null {
  const { dispatch } = useWmControls()
  if (needs.length === 0) return null

  // The panel opens the session. The strip only sets the repository and shows the panel.
  const start = (repo: string): void => {
    setTrustRepo(repo)
    dispatch({ panelId: 'trust', type: 'open' })
  }

  return (
    <div className='shrink-0 border-b border-panel-edge px-3 py-1.5' data-trust-strip={true}>
      <p className='text-xs text-text-strong'>Trust needed</p>
      {needs.map(need => (
        <div className='flex items-center gap-2 py-0.5 text-xs' key={need.repo}>
          <span className='min-w-0 flex-1 truncate text-text'>{need.repo}</span>
          <span className='shrink-0 text-text-dim'>{waitingText(need.waiting)}</span>
          <Tip label={TRUST_TIP}>
            <button
              className={cx(
                'shrink-0 border border-panel-edge bg-black/35 px-1.5 leading-4 text-text',
                'hover:text-text-strong active:bg-accent/12',
              )}
              onClick={() => start(need.repo)}
              type='button'
            >
              Trust
            </button>
          </Tip>
        </div>
      ))}
    </div>
  )
}
