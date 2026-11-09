import { useEffect, useState } from 'react'
import { EMPTY_REVIEWS, type ReviewsSnapshot } from '../../../shared/reviews'

// The newest snapshot of the Reviews panel. Subscribe first, then load the value.
// An update that comes before the first answer wins.
export function useReviews(): ReviewsSnapshot {
  const [snapshot, setSnapshot] = useState<ReviewsSnapshot>(EMPTY_REVIEWS)
  useEffect(() => {
    let active = true
    let updated = false
    const off = window.bifrost.reviews.onUpdate(next => {
      updated = true
      if (active) setSnapshot(next)
    })
    window.bifrost.reviews.snapshot().then(
      first => {
        if (active && !updated) setSnapshot(first)
      },
      () => {},
    )
    return () => {
      active = false
      off()
    }
  }, [])
  return snapshot
}
