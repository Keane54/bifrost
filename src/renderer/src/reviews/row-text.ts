// The texts of the rows of the Reviews panel.
import type { MyPrRow, ReviewStatus, ToReviewRow } from '../../../shared/reviews'

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
  }
}

// The tip of the status of a My PRs row that GitHub cut. Null for a row with all its items.
export function truncatedText(row: MyPrRow): string | null {
  return row.truncated ? 'Bifrost read only the newest items of this PR.' : null
}

export function laterCopilotText(n: number): string | null {
  return n > 0 ? `Copilot: ${n} more` : null
}
