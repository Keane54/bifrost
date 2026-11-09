// One row of the Reviews panel: two lines, as in the design (section 8 and 9).
import { Button } from '@base-ui/react/button'
import { ContextMenu } from '@base-ui/react/context-menu'
import type { MyPrRow, ReviewStatus, ToReviewRow } from '../../../shared/reviews'
import { useActions } from '../actions/actions-context'
import { cx } from '../lib/cx'
import { MENU_ITEM, MENU_POPUP, Tip } from '../lib/menu'
import { useSettings } from '../settings/settings-context'
import {
  ageText,
  claudeText,
  laterCopilotText,
  sizeText,
  statusText,
  toReviewText,
  truncatedText,
} from './row-text'

// The colour of the dot of a review status. Red is only for the flash and for Needs you.
const STATUS_TEXT: Record<ReviewStatus, string> = {
  approved: 'text-svc-ok',
  'changes-requested': 'text-watch-amber',
  comments: 'text-prio-3',
  pending: 'text-text-dim',
}

const SMALL_BUTTON =
  'border border-panel-edge bg-black/35 px-1.5 text-text leading-4 hover:text-text-strong not-data-disabled:active:bg-accent/12 data-disabled:opacity-40'

export type OnAct = (job: () => Promise<void>) => void

interface Common {
  onAct: OnAct
  selected?: boolean
}

// The flash overlay and the click rules. A Cmd+click opens the PR on GitHub. A click on a row
// with a session opens its chat window. A session exists from R2 on.
function Shell({
  children,
  flash,
  menu,
  onAct,
  prKey,
  sessionId,
}: {
  children: React.ReactNode
  flash: boolean
  menu: React.ReactNode
  onAct: OnAct
  prKey: string
  sessionId: string | null
}): React.JSX.Element {
  const { run } = useActions()
  const { settings } = useSettings()
  return (
    <ContextMenu.Root>
      <ContextMenu.Trigger
        className='relative flex flex-col gap-0.5 border-panel-edge border-t px-1.5 py-1 text-xs first:border-t-0'
        data-review-row={prKey}
        onClick={e => {
          if (e.metaKey) onAct(() => window.bifrost.reviews.openPr(prKey))
          else if (sessionId !== null) run('open', sessionId)
        }}
      >
        {flash && settings.rowFlash && (
          <span
            aria-hidden={true}
            className={cx('pointer-events-none absolute inset-0 animate-box-flash bg-box-red/35')}
            data-review-flash={true}
          />
        )}
        {children}
      </ContextMenu.Trigger>
      <ContextMenu.Portal>
        <ContextMenu.Positioner className='z-50 outline-none'>
          <ContextMenu.Popup className={MENU_POPUP}>{menu}</ContextMenu.Popup>
        </ContextMenu.Positioner>
      </ContextMenu.Portal>
    </ContextMenu.Root>
  )
}

function Line1({
  extra,
  number,
  repo,
  title,
}: {
  extra?: React.ReactNode
  number: number
  repo: string
  title: string
}): React.JSX.Element {
  return (
    <div className='relative flex items-baseline gap-1.5 overflow-hidden whitespace-nowrap'>
      <span className='shrink-0 text-text'>{repo}</span>
      <span className='shrink-0 text-text-dim'>#{number}</span>
      <span className='min-w-0 truncate text-text-strong'>{title}</span>
      {extra}
    </div>
  )
}

function MenuItem({ label, onSelect }: { label: string; onSelect: () => void }): React.JSX.Element {
  return (
    <ContextMenu.Item className={MENU_ITEM} onClick={onSelect}>
      {label}
    </ContextMenu.Item>
  )
}

function RowButton({
  disabled,
  label,
  onClick,
  strong,
  tip,
}: {
  disabled?: boolean
  label: string
  onClick?: () => void
  strong?: boolean
  tip?: string
}): React.JSX.Element {
  return (
    <Tip label={tip ?? null}>
      <Button
        className={cx(SMALL_BUTTON, strong && 'border-text-strong text-text-strong')}
        disabled={disabled}
        focusableWhenDisabled={true}
        onClick={e => {
          // The click does not reach the row.
          e.stopPropagation()
          if (!disabled) onClick?.()
        }}
      >
        {label}
      </Button>
    </Tip>
  )
}

const HAS_REVIEW_BUTTON: readonly string[] = ['new', 'waiting', 'approved-by-others', 'team']

export function ToReviewItem({
  now,
  onAct,
  row,
}: Common & { now: number; row: ToReviewRow }): React.JSX.Element {
  const text = toReviewText(row, now)
  const menu = (
    <>
      <MenuItem
        label='Open on GitHub'
        onSelect={() => onAct(() => window.bifrost.reviews.openPr(row.key))}
      />
      {row.state === 'new' && (
        <MenuItem
          label='Pause'
          onSelect={() => onAct(() => window.bifrost.reviews.pause(row.key))}
        />
      )}
      {row.state === 'paused' && (
        <MenuItem
          label='End pause now'
          onSelect={() => onAct(() => window.bifrost.reviews.endPause(row.key))}
        />
      )}
    </>
  )
  return (
    <Shell flash={row.flash} menu={menu} onAct={onAct} prKey={row.key} sessionId={row.sessionId}>
      <Line1
        extra={
          row.state === 'team' && (
            <span className='shrink-0 border border-panel-edge px-0.5 text-[10px] text-text-dim'>
              team
            </span>
          )
        }
        number={row.number}
        repo={row.repo}
        title={row.title}
      />
      <div className='relative flex items-center gap-2.5 whitespace-nowrap text-text-dim'>
        <span>{row.author}</span>
        <span>{sizeText(row.additions, row.deletions)}</span>
        <span>{ageText(now - row.requestedAt)}</span>
        <span className='ml-auto flex items-center gap-1.5 text-text'>
          {text !== '' && (
            <span className={row.state === 'draft-ready' ? 'text-svc-ok' : undefined}>{text}</span>
          )}
          {HAS_REVIEW_BUTTON.includes(row.state) && (
            <RowButton
              disabled={true}
              label='Review'
              strong={row.state === 'new'}
              tip='Coming soon'
            />
          )}
          {row.state === 'new' && (
            <RowButton
              label='Pause'
              onClick={() => onAct(() => window.bifrost.reviews.pause(row.key))}
            />
          )}
        </span>
      </div>
    </Shell>
  )
}

export function MyPrItem({ onAct, row }: Common & { row: MyPrRow }): React.JSX.Element {
  const later = laterCopilotText(row.laterCopilot)
  const needsYou = row.claude === 'needs-you'
  const menu = (
    <MenuItem
      label='Open on GitHub'
      onSelect={() => onAct(() => window.bifrost.reviews.openPr(row.key))}
    />
  )
  return (
    <Shell flash={false} menu={menu} onAct={onAct} prKey={row.key} sessionId={row.sessionId}>
      <Line1
        extra={
          row.failedChecks > 0 && (
            <Tip
              label={`${row.failedChecks} ${row.failedChecks === 1 ? 'check' : 'checks'} failed`}
            >
              <span className='shrink-0 text-box-red'>{'✕'}</span>
            </Tip>
          )
        }
        number={row.number}
        repo={row.repo}
        title={row.title}
      />
      <div className='relative flex items-center gap-2.5 whitespace-nowrap text-text-dim'>
        <Tip label={truncatedText(row)}>
          <span className={cx('inline-flex items-center gap-1.5', STATUS_TEXT[row.status])}>
            <span aria-hidden={true} className='size-1.5 shrink-0 bg-current' />
            {statusText(row.status)}
          </span>
        </Tip>
        {row.reviewers.length > 0 && <span>{row.reviewers.join(', ')}</span>}
        {later !== null && <span>{later}</span>}
        <Tip label={row.error}>
          <span
            className={cx(
              'ml-auto inline-flex items-center gap-1.5',
              needsYou ? 'text-box-red' : row.claude === 'fixing' ? 'text-text' : 'text-text-dim',
            )}
          >
            {needsYou && (
              <span
                aria-hidden={true}
                className='size-2.5 shrink-0 animate-box-flash border border-box-red'
              />
            )}
            {claudeText(row)}
          </span>
        </Tip>
      </div>
    </Shell>
  )
}
