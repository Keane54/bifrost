import type { SessionRow } from '../../../src/shared/types'

// Registry order A to G.
export function row(over: Partial<SessionRow> & { sessionId: string }): SessionRow {
  return {
    box: 'none',
    boxSince: null,
    claudeName: over.name ?? over.sessionId,
    cwd: '/Users/o/Developer/app',
    flashing: false,
    kind: 'owned',
    lastActivity: 0,
    name: over.sessionId,
    startedAt: 0,
    state: 'working',
    status: 'busy',
    ...over,
  }
}

export const A = row({ sessionId: 'A', state: 'working' })
export const B = row({ box: 'yellow', sessionId: 'B', state: 'needs-you' })
export const C = row({
  box: 'red',
  kind: 'external',
  sessionId: 'C',
  state: 'needs-you',
  status: 'waiting',
  waitingFor: 'input needed',
})
export const D = row({ box: 'red', sessionId: 'D', state: 'error' })
export const E = row({ sessionId: 'E', state: 'idle' })
export const F = row({ sessionId: 'F', state: 'parked' })
export const G = row({ sessionId: 'G', state: 'idle' })
export const ALL = [A, B, C, D, E, F, G]
