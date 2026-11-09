// The tab of the Reviews panel. A store outside React, so the route of a notification can select a tab.
import { useSyncExternalStore } from 'react'

export type ReviewsTab = 'to-review' | 'mine'

let current: ReviewsTab = 'to-review'
const listeners = new Set<() => void>()

export function setReviewsTab(tab: ReviewsTab): void {
  if (tab === current) return
  current = tab
  for (const l of listeners) l()
}

export function useReviewsTab(): ReviewsTab {
  return useSyncExternalStore(
    cb => {
      listeners.add(cb)
      return () => listeners.delete(cb)
    },
    () => current,
  )
}
