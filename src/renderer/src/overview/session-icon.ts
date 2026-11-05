// The pure rules of the row icon: its kind and its project colour.
import type { SessionRow } from '../../../shared/types'
import { repoPath } from './format'

export type IconKind = 'owned' | 'external' | 'parked'

// The repository root of the working directory. A worktree gives its repository.
// This is the same rule as the Project column.
export function projectKey(cwd: string): string {
  return repoPath(cwd)
}

// A stable index from 1 to 8 for a project key. The hash is FNV-1a, 32 bit.
export function projectColourIndex(key: string): number {
  let hash = 0x811c9dc5
  for (const byte of new TextEncoder().encode(key)) {
    hash ^= byte
    hash = Math.imul(hash, 0x01000193) >>> 0
  }
  return (hash % 8) + 1
}

export function iconKind(row: Pick<SessionRow, 'kind' | 'state'>): IconKind {
  if (row.state === 'parked') return 'parked'
  return row.kind
}
