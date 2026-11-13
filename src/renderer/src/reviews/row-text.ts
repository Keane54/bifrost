// The texts of the rows of the Reviews panel.
import {
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
  }
}

// The text at the right of a To review row. A draft or a reviewed row adds its recommendation.
export function rightText(row: ToReviewRow, now: number): string {
  const text = toReviewText(row, now)
  const withRecommendation = row.state === 'draft-ready' || row.state === 'reviewed'
  if (withRecommendation && row.recommendation !== null) {
    return `${text} · ${RECOMMENDATION_TEXT[row.recommendation]}`
  }
  return text
}

// The tip of the right text of a To review row. Null when the state has no tip.
export function rowTip(row: ToReviewRow): string | null {
  const why = row.why === null || row.why === '' ? '' : ` ${row.why}`
  switch (row.state) {
    case 'draft-ready':
      if (row.recommendation === null) return null
      return (
        `Claude suggests: ${RECOMMENDATION_TEXT[row.recommendation]}.${why} ` +
        'Check the draft on GitHub, then submit it.'
      )
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
    default:
      return null
  }
}

export type MenuItemId =
  | 'Open on GitHub'
  | 'Open session'
  | 'Review'
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
  if (hasReview(row)) items.push('Review')
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
