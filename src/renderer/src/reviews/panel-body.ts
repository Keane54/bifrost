// The body of the Reviews panel for a snapshot (design sections 8 and 9).
import type { ReviewsSnapshot } from '../../../shared/reviews'

export type PanelBody = 'off' | 'starting' | 'notice' | 'error' | 'empty' | 'rows'

// What the body of the panel shows. rows is the count of rows of the open tab.
// A failed first poll has no rows. The panel then shows only the error line, not the empty text
// (final review M9). A failed later poll keeps the rows of the last good poll.
export function panelBody(s: ReviewsSnapshot, rows: number): PanelBody {
  if (s.availability === 'off') return 'off'
  if (s.availability === 'starting') return 'starting'
  if (s.availability === 'no-gh' || s.availability === 'logged-out') return 'notice'
  if (s.polledAt === null) return 'error'
  return rows === 0 ? 'empty' : 'rows'
}
