// The PR key of the Review panel. A store outside React, so a row and the panel share it. The
// panel resets it to null when it closes.
import { useSyncExternalStore } from 'react'

let current: string | null = null
const listeners = new Set<() => void>()

export function setDraftKey(key: string | null): void {
  if (key === current) return
  current = key
  for (const l of listeners) l()
}

export function useDraftKey(): string | null {
  return useSyncExternalStore(
    cb => {
      listeners.add(cb)
      return () => listeners.delete(cb)
    },
    () => current,
  )
}
