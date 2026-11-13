// The app-wide store of the Reviews snapshot. The Reviews panel and the side bar read it, so the
// app has one subscription. The side bar reads only the flash flag.
import { useSyncExternalStore } from 'react'
import { EMPTY_REVIEWS, type ReviewsSnapshot } from '../../../shared/reviews'
import { createSnapshotStore, type SnapshotApi, type SnapshotStore } from '../lib/snapshot-store'

export function createReviewsStore(
  api: () => SnapshotApi<ReviewsSnapshot>,
): SnapshotStore<ReviewsSnapshot> {
  return createSnapshotStore<ReviewsSnapshot>(api, EMPTY_REVIEWS)
}

const store = createReviewsStore(() => window.bifrost.reviews)

// The newest snapshot, for the panel.
export function useReviews(): ReviewsSnapshot {
  return useSyncExternalStore(store.subscribe, store.get)
}

// True when a To review row flashes.
export function reviewsAttention(s: ReviewsSnapshot): boolean {
  return s.toReview.some(r => r.flash)
}

// The flash flag only, for the side bar. A new snapshot with the same flag does not render it.
export function useReviewsAttention(): boolean {
  return useSyncExternalStore(store.subscribe, () => reviewsAttention(store.get()))
}
