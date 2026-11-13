// One row of the Reviews panel: two lines, as in the design (section 8 and 9).
import { Button } from '@base-ui/react/button'
import { ContextMenu } from '@base-ui/react/context-menu'
import type { MyPrRow, ReviewStatus, ToReviewRow } from '../../../shared/reviews'
import { useActions } from '../actions/actions-context'
import { cx } from '../lib/cx'
import { MENU_ITEM, MENU_POPUP, Tip } from '../lib/menu'
import { useSettings } from '../settings/settings-context'
import { useWmControls } from '../wm/context'
import { setAnswerKey } from './answer-key'
import {
  ageText,
  claudeText,
  claudeTip,
  laterCopilotText,
  type MenuItemId,
  type MineMenuItemId,
  menuItems,
  mineMenuItems,
  olderText,
  rightText,
  rowTip,
  sizeText,
  statusText,
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
// with open questions opens the Answer panel (onOpenAnswer). Else a click on a row with a
// session opens its chat window.
function Shell({
  children,
  flash,
  menu,
  onAct,
  onOpenAnswer,
  prKey,
  sessionId,
}: {
  children: React.ReactNode
  flash: boolean
  menu: React.ReactNode
  onAct: OnAct
  onOpenAnswer?: () => void
  prKey: string
  sessionId: string | null
}): React.JSX.Element {
  const { run } = useActions()
  const { settings } = useSettings()
  return (
    <ContextMenu.Root>
      <ContextMenu.Trigger
        className='relative flex flex-col gap-0.5 border-t border-panel-edge px-1.5 py-1 text-xs first:border-t-0'
        data-review-row={prKey}
        onClick={e => {
          if (e.metaKey) onAct(() => window.bifrost.reviews.openPr(prKey))
          else if (onOpenAnswer !== undefined) onOpenAnswer()
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

const HAS_REVIEW_BUTTON: readonly string[] = [
  'new',
  'waiting',
  'approved-by-others',
  'team',
  'reviewed',
  'failed',
]

// The colour of the right text of a To review row.
function textColour(state: ToReviewRow['state']): string | undefined {
  if (state === 'failed') return 'text-box-red'
  if (state === 'draft-ready' || state === 'reviewed') return 'text-svc-ok'
  return undefined
}

// The action of one menu item of a To review row.
function selectItem(
  id: MenuItemId,
  row: ToReviewRow,
  onAct: OnAct,
  run: (action: 'open', sessionId: string) => void,
): void {
  const api = window.bifrost.reviews
  let job: (() => Promise<void>) | null = null
  switch (id) {
    case 'Cancel review':
      job = () => api.cancel(row.key)
      break
    case 'End pause now':
      job = () => api.endPause(row.key)
      break
    case 'Open on GitHub':
      job = () => api.openPr(row.key)
      break
    case 'Open session':
      if (row.sessionId !== null) run('open', row.sessionId)
      break
    case 'Pause':
      job = () => api.pause(row.key)
      break
    case 'Review':
      job = () => api.review(row.key)
      break
    case 'Stop session':
      job = () => api.stopSession(row.key)
      break
  }
  if (job !== null) onAct(job)
}

export function ToReviewItem({
  now,
  onAct,
  row,
}: Common & { now: number; row: ToReviewRow }): React.JSX.Element {
  const { run } = useActions()
  const text = rightText(row, now)
  const menu = (
    <>
      {menuItems(row).map(id => (
        <MenuItem key={id} label={id} onSelect={() => selectItem(id, row, onAct, run)} />
      ))}
    </>
  )
  return (
    <Shell flash={row.flash} menu={menu} onAct={onAct} prKey={row.key} sessionId={row.sessionId}>
      <Line1
        extra={
          row.team && (
            <span className='shrink-0 border border-panel-edge px-0.5 text-[10px] text-text-dim'>
              team
            </span>
          )
        }
        number={row.number}
        repo={row.repo}
        title={row.title}
      />
      {/* Line 2 cuts the author first, so the state on the right always shows. */}
      <div className='relative flex min-w-0 items-center gap-2.5 overflow-hidden whitespace-nowrap text-text-dim'>
        <span className='min-w-0 truncate'>{row.author}</span>
        <span className='shrink-0'>{sizeText(row.additions, row.deletions)}</span>
        <span className='shrink-0'>{ageText(now - row.requestedAt)}</span>
        <span className='ml-auto flex shrink-0 items-center gap-1.5 text-text'>
          {text !== '' && (
            <Tip label={rowTip(row)}>
              <span className={cx(textColour(row.state))}>{text}</span>
            </Tip>
          )}
          {HAS_REVIEW_BUTTON.includes(row.state) && (
            <RowButton
              label={row.state === 'failed' ? 'Try again' : 'Review'}
              onClick={() => onAct(() => window.bifrost.reviews.review(row.key))}
              strong={row.state === 'new'}
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

// The colour of the Claude state of a My PRs row.
function claudeColour(claude: MyPrRow['claude']): string {
  if (claude === 'needs-you' || claude === 'error') return 'text-box-red'
  return claude === 'fixing' ? 'text-text' : 'text-text-dim'
}

// The action of one menu item of a My PRs row.
function selectMine(
  id: MineMenuItemId,
  row: MyPrRow,
  onAct: OnAct,
  run: (action: 'open', sessionId: string) => void,
  openAnswer: () => void,
): void {
  const api = window.bifrost.reviews
  let job: (() => Promise<void>) | null = null
  switch (id) {
    case 'Answer Claude':
      openAnswer()
      break
    case 'Cancel':
      job = () => api.cancel(row.key)
      break
    case 'Handle Copilot comments':
      job = () => api.handle(row.key, 'copilot')
      break
    case 'Handle now':
      job = () => api.handle(row.key, 'all')
      break
    case 'Open on GitHub':
      job = () => api.openPr(row.key)
      break
    case 'Open session':
      if (row.sessionId !== null) run('open', row.sessionId)
      break
    case 'Stop session':
      job = () => api.stopSession(row.key)
      break
    case 'Try again':
      job = () => api.retry(row.key)
      break
  }
  if (job !== null) onAct(job)
}

export function MyPrItem({ onAct, row }: Common & { row: MyPrRow }): React.JSX.Element {
  const { run } = useActions()
  const { dispatch } = useWmControls()
  const later = laterCopilotText(row.laterCopilot)
  const older = olderText(row.olderOpen)
  const needsYou = row.claude === 'needs-you'
  const openAnswer = (): void => {
    setAnswerKey(row.key)
    dispatch({ panelId: 'answer', type: 'open' })
  }
  const menu = (
    <>
      {mineMenuItems(row).map(id => (
        <MenuItem
          key={id}
          label={id}
          onSelect={() => selectMine(id, row, onAct, run, openAnswer)}
        />
      ))}
    </>
  )
  return (
    <Shell
      flash={false}
      menu={menu}
      onAct={onAct}
      onOpenAnswer={row.questions.length > 0 ? openAnswer : undefined}
      prKey={row.key}
      sessionId={row.sessionId}
    >
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
      {/* Line 2 cuts the reviewers first, so the Claude state on the right always shows. */}
      <div className='relative flex min-w-0 items-center gap-2.5 overflow-hidden whitespace-nowrap text-text-dim'>
        <Tip label={truncatedText(row)}>
          <span
            className={cx('inline-flex shrink-0 items-center gap-1.5', STATUS_TEXT[row.status])}
          >
            <span aria-hidden={true} className='size-1.5 shrink-0 bg-current' />
            {statusText(row.status)}
          </span>
        </Tip>
        {row.reviewers.length > 0 && (
          <span className='min-w-0 truncate'>{row.reviewers.join(', ')}</span>
        )}
        {later !== null && <span className='shrink-0'>{later}</span>}
        {older !== null && <span className='shrink-0'>{older}</span>}
        <Tip label={claudeTip(row)}>
          <span
            className={cx(
              'ml-auto inline-flex shrink-0 items-center gap-1.5',
              claudeColour(row.claude),
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
