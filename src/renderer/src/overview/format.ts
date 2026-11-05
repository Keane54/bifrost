// Cell text and tones for the Overview.
import type { SessionRow, SessionState } from '../../../shared/types'

const WORKTREE_TAIL = /\/\.claude\/worktrees\/[^/]+$/

// Give the last two parts of the working directory. A Claude worktree path gives its repository.
export function projectLabel(cwd: string): string {
  const parts = cwd
    .replace(/\/+$/, '')
    .replace(WORKTREE_TAIL, '')
    .split('/')
    .filter(part => part !== '')
  if (parts.length === 0) return cwd === '' ? '' : '/'
  return parts.slice(-2).join('/')
}

export function formatCost(usd?: number): string {
  return usd === undefined ? '' : `$${usd.toFixed(2)}`
}

export function formatPercent(p?: number): string {
  return p === undefined ? '' : `${Math.round(p)}%`
}

// Both times are in milliseconds.
export function formatAge(since: number, now: number): string {
  const s = Math.max(0, Math.floor((now - since) / 1000))
  if (s < 60) return `${s} s`
  if (s < 3600) return `${Math.floor(s / 60)} min`
  if (s < 86400) return `${Math.floor(s / 3600)} h`
  return `${Math.floor(s / 86400)} d`
}

const STATE_LABELS: Record<SessionState, string> = {
  error: 'Error',
  idle: 'Idle',
  'needs-you': 'Needs you',
  parked: 'Parked',
  working: 'Working',
}

export function stateLabel(state: SessionState): string {
  return STATE_LABELS[state]
}

export type Tone = 'accent' | 'yellow' | 'red' | 'dim' | 'parked'

export function stateTone(row: Pick<SessionRow, 'state' | 'box'>): Tone {
  switch (row.state) {
    case 'error':
      return 'red'
    case 'needs-you':
      return row.box === 'yellow' ? 'yellow' : 'red'
    case 'working':
      return 'accent'
    case 'idle':
      return 'dim'
    case 'parked':
      return 'parked'
  }
}

// Give the first lines of the text that have content (spec 8.4 item 5).
export function previewLines(text: string | undefined, max = 3): string[] {
  if (!text) return []
  return text
    .split('\n')
    .map(line => line.trim())
    .filter(line => line !== '')
    .slice(0, max)
}
