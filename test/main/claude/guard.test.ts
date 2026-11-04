import { expect, test } from 'vitest'
import type { AgentEntry } from '../../../src/main/claude/agents'
import { canSignal } from '../../../src/main/claude/guard'

function entry(over: Partial<AgentEntry>): AgentEntry {
  return {
    pid: 1,
    cwd: '/tmp',
    kind: 'background',
    startedAt: 0,
    sessionId: 's',
    name: 'x',
    status: 'idle',
    ...over
  }
}

test('canSignal allows a test session', () => {
  expect(canSignal([entry({ pid: 5, name: 'bifrost-test-ext' })], 5)).toBe(true)
})
test('canSignal refuses a real session', () => {
  expect(canSignal([entry({ pid: 5, name: 'herald-d8' })], 5)).toBe(false)
})
test('canSignal refuses a PID that is not in the list', () => {
  expect(canSignal([entry({ pid: 5, name: 'bifrost-test-ext' })], 6)).toBe(false)
})
