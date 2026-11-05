import type { Priority } from './types'

// The priorities that a session can have. 1 is the highest.
export const PRIORITIES: readonly Priority[] = [1, 2, 3, 4, 5]

// Return true if the value is a priority from 1 to 5.
export function isPriority(value: unknown): value is Priority {
  return PRIORITIES.some(priority => priority === value)
}
