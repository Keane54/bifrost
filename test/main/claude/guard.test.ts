import { expect, test } from 'vitest'
import type { AgentEntry } from '../../../src/main/claude/agents'
import { canOpenPty, canRunClaude, canSignal } from '../../../src/main/claude/guard'

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

const ENTRIES = [
  entry({ pid: 5, name: 'bifrost-test-a', id: 'aaaa1111', sessionId: 'sess-a' }),
  entry({ pid: 6, name: 'herald-d8', id: 'bbbb2222', sessionId: 'sess-b' }),
  entry({ pid: 7, name: 'dup', id: 'cccc3333', sessionId: 'sess-c' }),
  entry({ pid: 8, name: 'bifrost-test-dup', id: 'cccc3333', sessionId: 'sess-d' })
]

test('canOpenPty allows an attach to a test session by name, id or sessionId', () => {
  expect(canOpenPty(ENTRIES, ['attach', 'bifrost-test-a'])).toBe(true)
  expect(canOpenPty(ENTRIES, ['attach', 'aaaa1111'])).toBe(true)
  expect(canOpenPty(ENTRIES, ['attach', 'sess-a'])).toBe(true)
})
test('canOpenPty refuses an attach to a real session', () => {
  expect(canOpenPty(ENTRIES, ['attach', 'herald-d8'])).toBe(false)
  expect(canOpenPty(ENTRIES, ['attach', 'bbbb2222'])).toBe(false)
})
test('canOpenPty refuses an attach to an unknown target', () => {
  expect(canOpenPty(ENTRIES, ['attach', 'nothing'])).toBe(false)
})
test('canOpenPty refuses an attach target that matches two entries', () => {
  expect(canOpenPty(ENTRIES, ['attach', 'cccc3333'])).toBe(false)
})
test('canOpenPty refuses an attach with extra arguments', () => {
  expect(canOpenPty(ENTRIES, ['attach', 'bifrost-test-a', '--x'])).toBe(false)
  expect(canOpenPty(ENTRIES, ['attach'])).toBe(false)
})
test('canOpenPty allows the external start of the harness', () => {
  expect(canOpenPty([], ['--model', 'haiku', '--name', 'bifrost-test-ext'])).toBe(true)
})
test('canOpenPty refuses a start with resume, continue or a second name', () => {
  const base = ['--name', 'bifrost-test-ext']
  expect(canOpenPty([], [...base, '--resume', 'x'])).toBe(false)
  expect(canOpenPty([], [...base, '-r'])).toBe(false)
  expect(canOpenPty([], [...base, '-c'])).toBe(false)
  expect(canOpenPty([], [...base, '--continue'])).toBe(false)
  expect(canOpenPty([], [...base, '--name', 'real'])).toBe(false)
  expect(canOpenPty([], [...base, '--name=real'])).toBe(false)
  expect(canOpenPty([], ['--name', 'real'])).toBe(false)
  expect(canOpenPty([], [])).toBe(false)
})
test('canRunClaude allows a background test start', () => {
  expect(canRunClaude(['--bg', '--model', 'haiku', '--name', 'bifrost-test-x', 'hello'])).toBe(true)
})
test('canRunClaude refuses stop, rm, resume and a second name', () => {
  expect(canRunClaude(['stop', 'x'])).toBe(false)
  expect(canRunClaude(['rm', 'x'])).toBe(false)
  expect(canRunClaude(['--bg', '--name', 'real'])).toBe(false)
  expect(canRunClaude(['--bg', '--name', 'bifrost-test-x', '--resume', 'id'])).toBe(false)
  expect(canRunClaude(['--bg', '--name', 'bifrost-test-x', '--name', 'real'])).toBe(false)
  expect(canRunClaude(['--name', 'bifrost-test-x'])).toBe(false)
})
