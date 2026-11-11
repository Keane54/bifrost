// One trust session of the panel. This module is pure: the panel gives it the API and the size.
// The order matters. Subscribe first, so no text is lost. Then ask main to open the session.
// Main drops a resize while the PTY loads. So the size goes again after the open resolves.
import type { BifrostApi } from '../../../shared/api'

const MIN_SIDE = 2
const MAX_SIDE = 500

export function clampSide(n: number): number {
  if (!Number.isFinite(n)) return MIN_SIDE
  return Math.min(MAX_SIDE, Math.max(MIN_SIDE, Math.floor(n)))
}

export type TrustApi = Pick<
  BifrostApi['reviews'],
  'onTrustData' | 'onTrustEnd' | 'trust' | 'trustClose' | 'trustResize'
>

export interface TrustSessionDeps {
  api: TrustApi
  repo: string
  getSize(): { cols: number; rows: number }
  onData(chunk: string): void
  // trusted is true when Claude Code now trusts the repository.
  onEnd(trusted: boolean): void
  onError(err: unknown): void
}

// The returned function closes only this session.
export function startTrustSession(deps: TrustSessionDeps): () => void {
  const { api, repo } = deps
  let closed = false
  const offData = api.onTrustData(chunk => {
    if (!closed) deps.onData(chunk)
  })
  const offEnd = api.onTrustEnd(end => {
    if (!closed && end.repo === repo) deps.onEnd(end.trusted)
  })
  api.trust(repo).then(
    () => {
      if (closed) return
      const { cols, rows } = deps.getSize()
      api.trustResize(clampSide(cols), clampSide(rows)).catch(deps.onError)
    },
    err => {
      if (!closed) deps.onError(err)
    },
  )
  return () => {
    if (closed) return
    closed = true
    offData()
    offEnd()
    api.trustClose().catch(() => {})
  }
}
