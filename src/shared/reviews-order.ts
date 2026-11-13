import type { MyPrRow, ReviewStatus, ToReviewRow, ToReviewState } from './reviews'

// The order of the groups on the To review tab (design 8.2).
export const TO_REVIEW_ORDER: readonly ToReviewState[] = [
  'new',
  'draft-ready',
  'reviewed',
  'failed',
  'waiting',
  'trust-needed',
  'reviewing',
  'queued',
  'paused',
  'you-approved',
  'you-reviewed',
  'approved-by-others',
  'team',
]

// The order of the groups on the My PRs tab (design 9.4). A row that needs you comes first.
export const MINE_ORDER: readonly ReviewStatus[] = [
  'changes-requested',
  'comments',
  'pending',
  'approved',
]

// Inside a group, the oldest request is first. A paused row sorts by the end of its pause.
export function sortToReview(rows: ToReviewRow[]): ToReviewRow[] {
  return [...rows].sort((a, b) => {
    const group = TO_REVIEW_ORDER.indexOf(a.state) - TO_REVIEW_ORDER.indexOf(b.state)
    if (group !== 0) return group
    if (a.state === 'paused') {
      const byPause =
        (a.pauseEndsAt ?? Number.POSITIVE_INFINITY) - (b.pauseEndsAt ?? Number.POSITIVE_INFINITY)
      if (byPause !== 0 && !Number.isNaN(byPause)) return byPause
    }
    return a.requestedAt - b.requestedAt || a.key.localeCompare(b.key)
  })
}

// Inside a group, the newest update is first.
export function sortMine(rows: MyPrRow[]): MyPrRow[] {
  const rank = (row: MyPrRow): number =>
    row.claude === 'needs-you' ? -1 : MINE_ORDER.indexOf(row.status)
  return [...rows].sort(
    (a, b) => rank(a) - rank(b) || b.updatedAt - a.updatedAt || a.key.localeCompare(b.key),
  )
}
