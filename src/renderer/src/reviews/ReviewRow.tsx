// One row of the Reviews panel: two lines, as in the design (section 8 and 9).
import { Button } from '@base-ui/react/button'
import { ContextMenu } from '@base-ui/react/context-menu'
import { Fragment } from 'react'
import type {
  MyPrRow,
  Reviewer,
  ReviewerStance,
  ReviewStatus,
  ToReviewRow,
} from '../../../shared/reviews'
import { useActions } from '../actions/actions-context'
import { cx } from '../lib/cx'
import { MENU_ITEM, MENU_POPUP, Tip } from '../lib/menu'
import { useSettings } from '../settings/settings-context'
import { useWmControls } from '../wm/context'
import { setAnswerKey } from './answer-key'
import { setDraftKey } from './draft-key'
import {
  ageText,
  approveTip,
  buttonTip,
  claudeText,
  claudeTip,
  laterCopilotText,
  type MenuItemId,
  type MineMenuItemId,
  menuItems,
  mineMenuItems,
  olderText,
  type RowButtonId,
  type RowResult,
  resultLine,
  resultOf,
  rightText,
  rowButtons,
  rowTip,
  sizeText,
  statusText,
  truncatedText,
} from './row-text'

// The colour of the status text of a My PRs row. Red is for the flash, for Needs you, for a
// Changes required result of Claude on a To review row, and for a reviewer name with changes
// requested (user decision, 2026-11-13).
const STATUS_TEXT: Record<ReviewStatus, string> = {
  approved: 'text-svc-ok',
  'changes-requested': 'text-review-changes',
  comments: 'text-prio-3',
  pending: 'text-text-dim',
}

// The base of a small button, with no colour. Each button adds the colour of its tone.
const SMALL_BUTTON = cx(
  'border bg-black/35 px-1.5 leading-4 hover:text-text-strong',
  'not-data-disabled:active:bg-accent/12 data-disabled:opacity-40',
)

// The colours of a small button. Each result of Claude has its own colour (ruling B1).
const TONES = {
  approve: 'border-review-approve text-review-approve',
  changes: 'border-review-changes text-review-changes',
  comment: 'border-review-comment text-review-comment',
  dim: 'border-panel-edge text-text-dim',
  plain: 'border-panel-edge text-text',
  strong: 'border-text-strong text-text-strong',
} as const
type Tone = keyof typeof TONES

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
  dot,
  extra,
  number,
  repo,
  title,
}: {
  // The colour class of the dot before the repository, or no dot.
  dot?: string | null
  extra?: React.ReactNode
  number: number
  repo: string
  title: string
}): React.JSX.Element {
  return (
    <div className='relative flex items-baseline gap-1.5 overflow-hidden whitespace-nowrap'>
      {dot != null && (
        <span
          aria-hidden={true}
          className={cx('size-1.5 shrink-0 self-center', dot)}
          data-review-dot={true}
        />
      )}
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
  tip,
  tone = 'plain',
}: {
  disabled?: boolean
  label: string
  onClick?: () => void
  tip?: string | null
  tone?: Tone
}): React.JSX.Element {
  return (
    <Tip label={tip ?? null}>
      <Button
        className={cx(SMALL_BUTTON, TONES[tone])}
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

// The colour of the dot of each result of Claude, as in the approved mock (user decision,
// 2026-11-13).
const RESULT_DOT: Record<RowResult, string> = {
  approve: 'bg-review-approve',
  changes: 'bg-review-changes',
  comment: 'bg-review-comment',
  deleted: 'bg-text-dim',
  others: 'bg-text-dim',
}

// The colour of the right text of each result of Claude.
const RESULT_COLOUR: Record<RowResult, string> = {
  approve: 'text-review-approve',
  changes: 'text-review-changes',
  comment: 'text-review-comment',
  deleted: 'text-text-dim',
  others: 'text-text-dim',
}

// The colour of the right text of a To review row. An Approve click or an action of the Review
// panel that did not work is red.
function textColour(row: ToReviewRow): string | undefined {
  if (row.approveIssue !== null || row.draftIssue !== null) return 'text-box-red'
  if (row.state === 'failed') return 'text-box-red'
  const result = resultOf(row)
  if (result !== null) return RESULT_COLOUR[result]
  if (row.state === 'you-approved') return 'text-review-approve'
  return undefined
}

// The tone of each button of a To review row.
function buttonTone(id: RowButtonId, row: ToReviewRow): Tone {
  switch (id) {
    case 'Approve':
      return 'approve'
    case 'Comment':
      return 'comment'
    case 'Request changes':
      return 'changes'
    case 'Remove':
      return 'dim'
    case 'Review':
      return row.state === 'new' ? 'strong' : 'plain'
    default:
      return 'plain'
  }
}

// Open the Review panel for the draft of a row.
function useOpenDraft(): (key: string) => void {
  const { dispatch } = useWmControls()
  return key => {
    setDraftKey(key)
    dispatch({ panelId: 'review-draft', type: 'open' })
  }
}

// The action of one button of a To review row.
function pressButton(
  id: RowButtonId,
  row: ToReviewRow,
  onAct: OnAct,
  openDraft: (key: string) => void,
): void {
  const api = window.bifrost.reviews
  switch (id) {
    case 'Approve':
      onAct(() => api.approve(row.key))
      break
    case 'Comment':
    case 'Request changes':
      openDraft(row.key)
      break
    case 'Remove':
      onAct(() => api.remove(row.key))
      break
    case 'Review':
    case 'Try again':
      onAct(() => api.review(row.key))
      break
    case 'Pause':
      onAct(() => api.pause(row.key))
      break
  }
}

// A button is disabled while its write runs.
function buttonDisabled(id: RowButtonId, row: ToReviewRow): boolean {
  if (id === 'Approve') return row.approve === 'running'
  if (id === 'Comment' || id === 'Request changes') return row.draft === 'running'
  return false
}

// The action of one menu item of a To review row.
function selectItem(
  id: MenuItemId,
  row: ToReviewRow,
  onAct: OnAct,
  run: (action: 'open', sessionId: string) => void,
  openDraft: (key: string) => void,
): void {
  const api = window.bifrost.reviews
  let job: (() => Promise<void>) | null = null
  switch (id) {
    case 'Approve':
      job = () => api.approve(row.key)
      break
    case 'Cancel review':
      job = () => api.cancel(row.key)
      break
    case 'Comment':
    case 'Request changes':
      openDraft(row.key)
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
    case 'Remove':
      job = () => api.remove(row.key)
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
  const openDraft = useOpenDraft()
  const text = rightText(row, now)
  const line = resultLine(row)
  const result = resultOf(row)
  const menu = (
    <>
      {menuItems(row).map(id => (
        <MenuItem key={id} label={id} onSelect={() => selectItem(id, row, onAct, run, openDraft)} />
      ))}
    </>
  )
  return (
    <Shell flash={row.flash} menu={menu} onAct={onAct} prKey={row.key} sessionId={row.sessionId}>
      <Line1
        dot={result === null ? null : RESULT_DOT[result]}
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
      {/* Line 2 cuts the author or the result line first, so the state on the right always
          shows. A row with a result of Claude says what Claude did (ruling B1). */}
      <div className='relative flex min-w-0 items-center gap-2.5 overflow-hidden whitespace-nowrap text-text-dim'>
        {line === null ? (
          <>
            <span className='min-w-0 truncate'>{row.author}</span>
            <span className='shrink-0'>{sizeText(row.additions, row.deletions)}</span>
            <span className='shrink-0'>{ageText(now - row.requestedAt)}</span>
          </>
        ) : (
          <span className='min-w-0 truncate'>{line}</span>
        )}
        {/* The state text and the buttons are centred on one line (ruling B2). */}
        <span className='ml-auto flex shrink-0 items-center gap-1.5 text-text'>
          {text !== '' && (
            <Tip label={rowTip(row)}>
              <span className={cx('leading-4', textColour(row))}>{text}</span>
            </Tip>
          )}
          {rowButtons(row).map(id => (
            <RowButton
              disabled={buttonDisabled(id, row)}
              key={id}
              label={id}
              onClick={() => pressButton(id, row, onAct, openDraft)}
              tip={id === 'Approve' ? approveTip(row) : buttonTip(id, row)}
              tone={buttonTone(id, row)}
            />
          ))}
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

// The colour of a reviewer name by stance. It matches the status colours (user decision,
// 2026-11-13).
const STANCE_TEXT: Record<ReviewerStance, string> = {
  approved: 'text-svc-ok',
  changes: 'text-review-changes',
  commented: 'text-review-comment',
  none: 'text-text-dim',
}

// The reviewer names of line 2. The separator stays dim.
export function ReviewerNames({ reviewers }: { reviewers: Reviewer[] }): React.JSX.Element | null {
  if (reviewers.length === 0) return null
  return (
    <span className='min-w-0 truncate'>
      {reviewers.map((r, i) => (
        <Fragment key={r.name}>
          {i > 0 && <span className='text-text-dim'>{', '}</span>}
          <span className={cx(STANCE_TEXT[r.stance])}>{r.name}</span>
        </Fragment>
      ))}
    </span>
  )
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
        <ReviewerNames reviewers={row.reviewers} />
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
