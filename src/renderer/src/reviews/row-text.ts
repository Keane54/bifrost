// The texts of the rows of the Reviews panel.
import {
  type DraftAction,
  type MyPrRow,
  RECOMMENDATION_TEXT,
  type ReviewStatus,
  type ToReviewRow,
} from '../../../shared/reviews'
import { REVIEWS_ROWS } from '../settings/reviews-rows'

const MINUTE = 60_000
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR

// How long ago a time was. Under one minute gives "just now".
export function ageText(ms: number): string {
  if (ms < MINUTE) return 'just now'
  if (ms < HOUR) return `${Math.floor(ms / MINUTE)}m ago`
  if (ms < DAY) return `${Math.floor(ms / HOUR)}h ago`
  return `${Math.floor(ms / DAY)}d ago`
}

// The size of a PR. The minus sign is U+2212.
export function sizeText(add: number, del: number): string {
  return `+${add} −${del}`
}

// The states of a row that shows the CI text. A review session, a final state of the user and
// approved-by-others show their own status (user decision, 2026-11-13).
const CI_TEXT_STATES: readonly string[] = [
  'new',
  'waiting',
  'team',
  'failed',
  'reviewed',
  'draft-ready',
  'paused',
]

// The CI status of a To review row: it replaces the status of the row, but not the second line.
// Null when the row shows its own status.
export function ciText(row: ToReviewRow): 'CI failing' | 'CI running' | null {
  if (row.ci === null || !CI_TEXT_STATES.includes(row.state)) return null
  return row.ci === 'failing' ? 'CI failing' : 'CI running'
}

// True when the row shows a spinner beside the CI text: only for running CI.
export function showSpinner(row: ToReviewRow): boolean {
  return ciText(row) === 'CI running'
}

const CI_FAILING_TIP =
  "CI is failing on this pull request, so Bifrost won't review or approve it. " +
  'It can be reviewed again when CI passes.'
const CI_RUNNING_TIP =
  'CI is still running. Claude can review now, but you can approve only when it has passed.'
const APPROVE_WAIT_TIP = 'CI is still running. Approve when it has passed.'

// The tip of the CI status of a row. Null when the row shows no CI status.
export function ciTip(row: ToReviewRow): string | null {
  const text = ciText(row)
  if (text === null) return null
  return text === 'CI failing' ? CI_FAILING_TIP : CI_RUNNING_TIP
}

// The state at the right of a To review row. A new row shows its buttons instead, so it has no text.
export function toReviewText(row: ToReviewRow, now: number): string {
  switch (row.state) {
    case 'new':
      return ''
    case 'draft-ready':
      return 'Draft ready'
    case 'reviewed':
      return 'Looks good'
    case 'failed':
      return 'Review failed'
    case 'waiting':
      return 'Waiting for you'
    case 'trust-needed':
      return 'Trust needed'
    case 'reviewing':
      return 'Reviewing'
    case 'queued':
      return 'Queued'
    case 'paused': {
      const left = Math.max(1, Math.ceil(((row.pauseEndsAt ?? now) - now) / MINUTE))
      return `Paused ${left}m`
    }
    case 'approved-by-others':
      return 'Approved by others'
    case 'team':
      return 'Team request'
    case 'you-approved':
      return 'You approved'
    case 'you-reviewed':
      return 'Review sent'
  }
}

// The kind of result of a To review row (ruling B1): Claude recommends approval, Claude drafted a
// comment, Claude drafted a request for changes, the user deleted the draft to approve instead, or
// others approved the PR. Null for each other row.
export type RowResult = 'approve' | 'comment' | 'changes' | 'deleted' | 'others'

export function resultOf(row: ToReviewRow): RowResult | null {
  const { recommendation, state } = row
  if (state === 'approved-by-others') return 'others'
  if (state === 'reviewed' && row.draftDeleted) return 'deleted'
  const withMark = state === 'reviewed' || state === 'draft-ready'
  if (withMark && recommendation === 'approve') return 'approve'
  if (state !== 'draft-ready') return null
  if (recommendation === 'comment') return 'comment'
  return recommendation === 'request-changes' ? 'changes' : null
}

const RESULT_TEXT: Record<RowResult, string> = {
  approve: 'Approval recommended',
  changes: 'Changes required',
  comment: 'Draft ready',
  deleted: 'Draft deleted',
  others: 'Approved by others',
}

// The text of an action of the Review panel that did not work.
const ISSUE_TEXT: Record<DraftAction, string> = {
  approve: "Couldn't approve",
  discard: "Couldn't discard",
  send: "Couldn't send",
}

// The text at the right of a To review row. A row with a result of Claude shows the text of the
// result. An Approve click or an action of the Review panel that did not work shows its own text
// until the next poll.
export function rightText(row: ToReviewRow, now: number): string {
  if (row.approveIssue !== null) {
    return row.approveIssue.unknown ? 'Approval not confirmed' : "Couldn't approve"
  }
  if (row.draftIssue !== null) {
    return row.draftIssue.unknown ? 'Not confirmed' : ISSUE_TEXT[row.draftIssue.action]
  }
  // CI that fails or runs replaces the status. The second line keeps the result of Claude.
  const ci = ciText(row)
  if (ci !== null) return ci
  const result = resultOf(row)
  return result === null ? toReviewText(row, now) : RESULT_TEXT[result]
}

// What Claude drafted, for the second line of a row.
function draftedText(drafted: ToReviewRow['drafted']): string {
  if (drafted === null) return 'Claude drafted a review.'
  const n = drafted.comments
  const comments = `${n} ${plural(n, 'comment', 'comments')}`
  if (drafted.summary && n > 0) return `Claude drafted a summary and ${comments}.`
  if (drafted.summary) return 'Claude drafted a summary.'
  return n > 0 ? `Claude drafted ${comments}.` : 'Claude found nothing to change.'
}

// The second line of a row with a result (ruling B1): what Claude did, or who approved. Null for
// each other row: it shows the author, the size and the age.
export function resultLine(row: ToReviewRow): string | null {
  const result = resultOf(row)
  if (result === null) return null
  if (result === 'deleted') return "You deleted Claude's draft. Approve when you're ready."
  if (result !== 'others') return draftedText(row.drafted)
  const n = row.approvals
  const who = n === 0 ? 'Others' : `${n} ${plural(n, 'person', 'people')}`
  return `${who} approved it, so you don't need to review it.`
}

// The buttons of a To review row, in order (ruling B1). Each result has one button. Remove shows
// only on an approved-by-others row.
export type RowButtonId =
  | 'Approve'
  | 'Comment'
  | 'Request changes'
  | 'Remove'
  | 'Review'
  | 'Try again'
  | 'Pause'

const REVIEW_BUTTON: readonly string[] = ['new', 'waiting', 'team', 'failed']

export function rowButtons(row: ToReviewRow): RowButtonId[] {
  const buttons: RowButtonId[] = []
  if (row.approve !== null) buttons.push('Approve')
  const result = resultOf(row)
  if (row.draft !== null && result === 'comment') buttons.push('Comment')
  if (row.draft !== null && result === 'changes') buttons.push('Request changes')
  if (row.state === 'approved-by-others') buttons.push('Remove')
  // A reviewed row whose Approve button is hidden gets Review back. A PR with failing CI gets no
  // review (user decision, 2026-11-13).
  const review =
    REVIEW_BUTTON.includes(row.state) || (row.state === 'reviewed' && row.approve === null)
  if (review && row.ci !== 'failing') buttons.push(row.state === 'failed' ? 'Try again' : 'Review')
  if (row.state === 'new') buttons.push('Pause')
  return buttons
}

const DRAFT_TIP = "Check Claude's draft, change it if you like, and send it."
const REMOVE_TIP =
  'Hide this pull request in Bifrost. Nothing changes on GitHub. ' +
  'It comes back if someone asks for your review again.'

// The tip of a button of a To review row. Null for a button with no tip.
export function buttonTip(id: RowButtonId, row: ToReviewRow): string | null {
  switch (id) {
    case 'Approve':
      return approveTip(row)
    case 'Comment':
    case 'Request changes':
      return row.draft === 'running' ? 'Working on the draft…' : DRAFT_TIP
    case 'Remove':
      return REMOVE_TIP
    default:
      return null
  }
}

// The tip of the right text of a To review row. Null when the state has no tip.
export function rowTip(row: ToReviewRow): string | null {
  if (row.approveIssue !== null) return row.approveIssue.message
  if (row.draftIssue !== null) return row.draftIssue.message
  // A failed row keeps its note, for example a review that CI stopped.
  if (row.state === 'failed' && row.error !== null) return row.error
  const ci = ciTip(row)
  if (ci !== null) return ci
  const why = row.why === null || row.why === '' ? '' : ` ${row.why}`
  if (resultOf(row) === 'deleted') {
    return "You deleted Claude's draft. Click Approve to approve this pull request."
  }
  switch (row.state) {
    case 'draft-ready': {
      if (row.recommendation === null) return null
      const text = RECOMMENDATION_TEXT[row.recommendation]
      const next =
        row.recommendation === 'approve'
          ? "Click Approve to submit Claude's draft as an approval."
          : `Click ${text} to check the draft and send it.`
      return `Claude suggests: ${text}.${why} ${next}`
    }
    case 'reviewed':
      return `Claude suggests: Approve.${why} Nothing was posted.`
    case 'failed':
      return row.error
    case 'trust-needed':
      return (
        'Bifrost needs you to trust this repository first. ' +
        'Click Trust at the top of the panel.'
      )
    case 'queued':
      return 'Waiting for a free review slot.'
    case 'reviewing':
      return 'Claude is reviewing this pull request.'
    case 'you-approved':
      return 'You approved this pull request on GitHub.'
    case 'you-reviewed':
      return 'You sent your review on GitHub.'
    default:
      return null
  }
}

// The tip of the Approve button of a To review row.
export function approveTip(row: ToReviewRow): string {
  if (row.approve === 'running') return 'Approving…'
  if (row.approve === 'ci-running') return APPROVE_WAIT_TIP
  return row.state === 'draft-ready'
    ? "Submit Claude's draft review on GitHub as an approval."
    : 'Approve this pull request on GitHub.'
}

export type MenuItemId =
  | 'Open on GitHub'
  | 'Open session'
  | 'Approve'
  | 'Comment'
  | 'Request changes'
  | 'Review'
  | 'Remove'
  | 'Cancel review'
  | 'Stop session'
  | 'Pause'
  | 'End pause now'

const NO_REVIEW_ITEM: readonly string[] = ['reviewing', 'queued', 'trust-needed']

// A draft-ready row with a mark shows the draft review of Bifrost (the snapshot gives the mark
// only for that draft). A new round would add each comment and the summary to it a second time,
// so the row has no Review. A pending review that the user made has no mark. Review then adds
// the comments of Bifrost to it.
const hasReview = (row: ToReviewRow): boolean =>
  !NO_REVIEW_ITEM.includes(row.state) &&
  !(row.state === 'draft-ready' && row.recommendation !== null)

// The menu items of a To review row, in order.
export function menuItems(row: ToReviewRow): MenuItemId[] {
  const items: MenuItemId[] = ['Open on GitHub']
  if (row.sessionId !== null) items.push('Open session')
  // The menu has Approve only while the row shows the Approve button and no write runs. The same
  // rule applies to the buttons of the Review panel.
  if (row.approve === 'ready') items.push('Approve')
  const result = resultOf(row)
  if (row.draft === 'ready' && result === 'comment') items.push('Comment')
  if (row.draft === 'ready' && result === 'changes') items.push('Request changes')
  if (hasReview(row) && row.ci !== 'failing') items.push('Review')
  if (row.state === 'approved-by-others') items.push('Remove')
  if (row.state === 'queued' || row.state === 'trust-needed') items.push('Cancel review')
  if (row.sessionId !== null) items.push('Stop session')
  if (row.state === 'new') items.push('Pause')
  if (row.state === 'paused') items.push('End pause now')
  return items
}

export function statusText(s: ReviewStatus): string {
  switch (s) {
    case 'changes-requested':
      return 'Changes requested'
    case 'comments':
      return 'Comments'
    case 'approved':
      return 'Approved'
    case 'pending':
      return 'Pending'
  }
}

export function claudeText(row: MyPrRow): string {
  switch (row.claude) {
    case 'needs-you':
      return 'Needs you'
    case 'fixing':
      return `Fixing ${row.fixing}`
    case 'queued':
      return 'Queued'
    case 'trust-needed':
      return 'Trust needed'
    case 'cloning':
      return 'Cloning'
    case 'waiting':
      return 'Waiting'
    case 'error':
      return 'Error'
    case 'fork':
      return 'Fork'
  }
}

// The tip of the status of a My PRs row that GitHub cut. Null for a row with all its items.
export function truncatedText(row: MyPrRow): string | null {
  return row.truncated ? 'Bifrost read only the newest items of this PR.' : null
}

const plural = (n: number, one: string, many: string): string => (n === 1 ? one : many)

// The count of older open comments on a My PRs row. Null for none.
export function olderText(n: number): string | null {
  if (n <= 0) return null
  return `${n} older ${plural(n, 'comment', 'comments')}`
}

// The tip of the Claude state of a My PRs row. Null for a waiting row.
export function claudeTip(row: MyPrRow): string | null {
  switch (row.claude) {
    case 'needs-you': {
      const n = row.questions.length
      return `Claude needs your answer on ${n} ${plural(n, 'comment', 'comments')}. Click to answer.`
    }
    case 'fixing':
      return `Claude is working on ${row.fixing} ${plural(row.fixing, 'comment', 'comments')}.`
    case 'queued':
      return 'Waiting for a free session slot.'
    case 'trust-needed':
      return (
        'Bifrost needs you to trust this repository first. ' +
        'Click Trust at the top of the panel.'
      )
    case 'cloning':
      return 'Bifrost is copying this repository.'
    case 'error':
    case 'fork':
      return row.error
    case 'waiting':
      return null
  }
}

export type MineMenuItemId =
  | 'Open on GitHub'
  | 'Open session'
  | 'Answer Claude'
  | 'Handle now'
  | 'Handle Copilot comments'
  | 'Try again'
  | 'Cancel'
  | 'Stop session'

const CAN_HANDLE: readonly string[] = ['waiting', 'needs-you', 'error']
const CAN_CANCEL: readonly string[] = ['queued', 'trust-needed', 'cloning']

// The hint of the My PRs tab while the automatic fixes wait for the confirm of the user
// (ruling S20).
export const AUTO_FIX_HINT =
  'Want Claude to fix and answer new review comments for you? ' +
  `Turn on ${REVIEWS_ROWS.autoFix} in Settings.`

// The menu items of a My PRs row, in order. A fork row has Open on GitHub only.
export function mineMenuItems(row: MyPrRow): MineMenuItemId[] {
  const items: MineMenuItemId[] = ['Open on GitHub']
  if (row.claude === 'fork') return items
  if (row.sessionId !== null) items.push('Open session')
  if (row.questions.length > 0) items.push('Answer Claude')
  const handle = CAN_HANDLE.includes(row.claude)
  if (handle && row.olderOpen > 0) items.push('Handle now')
  if (handle && row.laterCopilot > 0) items.push('Handle Copilot comments')
  if (row.claude === 'error') items.push('Try again')
  // On an error row, Cancel drops the posts that Bifrost did not send.
  if (CAN_CANCEL.includes(row.claude) || (row.claude === 'error' && row.unsent)) {
    items.push('Cancel')
  }
  if (row.sessionId !== null && row.claude === 'fixing') items.push('Stop session')
  return items
}

export function laterCopilotText(n: number): string | null {
  return n > 0 ? `Copilot: ${n} more` : null
}
