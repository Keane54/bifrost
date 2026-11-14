// The request that Heimdall's panel shows (plan Task 9). A store outside React, so Settings and the
// panel share it, as answer-key.ts does for the Answer panel. The panel resets it to null when it
// closes. Only Bifrost's own UI sets it, from an answer of the main process.
import { useSyncExternalStore } from 'react'
import type { ModuleApproval, ModuleDiscuss } from '../../../shared/modules'

// The approval of an install or an update, or the request of a module for Discuss with Claude
// (plan Task 10).
export type HeimdallRequest =
  | { kind: 'approval'; approval: ModuleApproval }
  | { kind: 'discuss'; discuss: ModuleDiscuss }

let current: HeimdallRequest | null = null
const listeners = new Set<() => void>()

export function setHeimdallRequest(request: HeimdallRequest | null): void {
  if (request === current) return
  current = request
  for (const l of [...listeners]) l()
}

export function getHeimdallRequest(): HeimdallRequest | null {
  return current
}

export function useHeimdallRequest(): HeimdallRequest | null {
  return useSyncExternalStore(
    cb => {
      listeners.add(cb)
      return () => listeners.delete(cb)
    },
    getHeimdallRequest,
    getHeimdallRequest,
  )
}
