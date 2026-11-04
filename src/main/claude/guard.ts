import type { AgentEntry } from './agents'

// Every test session has a name that starts with this prefix.
export const TEST_PREFIX = 'bifrost-test-'

// Return true only if exactly one entry has this PID
// and the name of that entry starts with TEST_PREFIX.
export function canSignal(entries: AgentEntry[], pid: number): boolean {
  const matches = entries.filter((e) => e.pid === pid)
  return matches.length === 1 && matches[0].name.startsWith(TEST_PREFIX)
}
