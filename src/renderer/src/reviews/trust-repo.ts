// The repository of the trust terminal. A store outside React, so the strip and the panel share it.
import { useSyncExternalStore } from 'react'

let current: string | null = null
const listeners = new Set<() => void>()

export function setTrustRepo(repo: string | null): void {
  if (repo === current) return
  current = repo
  for (const l of listeners) l()
}

export function useTrustRepo(): string | null {
  return useSyncExternalStore(
    cb => {
      listeners.add(cb)
      return () => listeners.delete(cb)
    },
    () => current,
  )
}
