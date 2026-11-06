// The save tracker of the Settings panel for its rows (spec 12).
import { createContext, useContext } from 'react'
import type { SaveTracker } from './save-tracker'

// Outside the Settings panel the value is null. A save then has no tracker.
export const SaveTrackerContext = createContext<SaveTracker | null>(null)

export function useSaveTracker(): SaveTracker | null {
  return useContext(SaveTrackerContext)
}
