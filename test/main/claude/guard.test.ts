import { describe, expect, test } from 'vitest'
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

// The real ID of a session that is not a test session.
const REAL = 'bbbb2222'
// The background start that the harness sends.
const RUN = ['--bg', '--model', 'haiku', '--name', 'bifrost-test-x']
// The interactive start that the harness sends.
const EXT = ['--model', 'haiku', '--name', 'bifrost-test-ext']

describe('canOpenPty: attach', () => {
  test('allows an attach to a test session by name, id or sessionId', () => {
    expect(canOpenPty(ENTRIES, ['attach', 'bifrost-test-a'])).toBe(true)
    expect(canOpenPty(ENTRIES, ['attach', 'aaaa1111'])).toBe(true)
    expect(canOpenPty(ENTRIES, ['attach', 'sess-a'])).toBe(true)
  })
  test('refuses an attach to a real session', () => {
    expect(canOpenPty(ENTRIES, ['attach', 'herald-d8'])).toBe(false)
    expect(canOpenPty(ENTRIES, ['attach', REAL])).toBe(false)
  })
  test('refuses an attach to an unknown target', () => {
    expect(canOpenPty(ENTRIES, ['attach', 'nothing'])).toBe(false)
  })
  test('refuses an attach target that matches two entries', () => {
    expect(canOpenPty(ENTRIES, ['attach', 'cccc3333'])).toBe(false)
  })
  test('refuses an attach with extra arguments', () => {
    expect(canOpenPty(ENTRIES, ['attach', 'bifrost-test-a', '--x'])).toBe(false)
    expect(canOpenPty(ENTRIES, ['attach'])).toBe(false)
  })
  test('refuses an attach target that is not a string or is empty', () => {
    // An entry with no id field has the id undefined.
    const noIds = [entry({ pid: 9, name: 'bifrost-test-noid', sessionId: 'sess-n' })]
    expect(canOpenPty(noIds, ['attach', undefined as unknown as string])).toBe(false)
    const emptyName = [entry({ pid: 9, name: '', sessionId: 'sess-e' })]
    expect(canOpenPty(emptyName, ['attach', ''])).toBe(false)
  })
})

describe('canOpenPty: interactive start', () => {
  test('allows the external start of the harness', () => {
    expect(canOpenPty([], EXT)).toBe(true)
    expect(canOpenPty([], ['--name', 'bifrost-test-ext'])).toBe(true)
    expect(canOpenPty([], [...EXT, '--permission-mode', 'plan'])).toBe(true)
  })
  test('refuses attach in the wrong place', () => {
    expect(canOpenPty([], ['--name', 'bifrost-test-x', 'attach', REAL])).toBe(false)
    expect(canOpenPty(ENTRIES, ['--name', 'bifrost-test-x', 'attach', REAL])).toBe(false)
  })
  test('refuses a subcommand after the options', () => {
    for (const verb of ['stop', 'rm', 'kill', 'respawn', 'logs']) {
      expect(canOpenPty([], [...EXT, verb, REAL])).toBe(false)
      expect(canOpenPty([], [...EXT, verb])).toBe(false)
    }
  })
  test('refuses a prompt and --bg', () => {
    expect(canOpenPty([], [...EXT, 'say hello'])).toBe(false)
    expect(canOpenPty([], ['--bg', ...EXT])).toBe(false)
  })
  test('refuses resume, continue, session and fork flags', () => {
    expect(canOpenPty([], [...EXT, '--resume', 'x'])).toBe(false)
    expect(canOpenPty([], [...EXT, '-r'])).toBe(false)
    expect(canOpenPty([], [...EXT, `-r${REAL}`])).toBe(false)
    expect(canOpenPty([], [...EXT, '-c'])).toBe(false)
    expect(canOpenPty([], [...EXT, '-cr'])).toBe(false)
    expect(canOpenPty([], [...EXT, '--continue'])).toBe(false)
    expect(canOpenPty([], [...EXT, '--session-id', REAL])).toBe(false)
    expect(canOpenPty([], [...EXT, '--fork-session'])).toBe(false)
  })
  test('refuses a second name or a name that is not a test name', () => {
    expect(canOpenPty([], [...EXT, '--name', 'real'])).toBe(false)
    expect(canOpenPty([], [...EXT, '--name', 'bifrost-test-y'])).toBe(false)
    expect(canOpenPty([], [...EXT, '--name=real'])).toBe(false)
    expect(canOpenPty([], ['--name=bifrost-test-x'])).toBe(false)
    expect(canOpenPty([], ['--name', 'real'])).toBe(false)
    expect(canOpenPty([], ['--model', 'haiku'])).toBe(false)
    expect(canOpenPty([], [])).toBe(false)
  })
})

describe('canRunClaude', () => {
  test('allows a background test start', () => {
    expect(canRunClaude(RUN)).toBe(true)
    expect(canRunClaude([...RUN, 'say hello in one word'])).toBe(true)
    expect(canRunClaude([...RUN, '--permission-mode', 'acceptEdits', 'list the files'])).toBe(true)
    expect(canRunClaude(['--bg', '--name', 'bifrost-test-x', '--model', 'haiku'])).toBe(true)
  })
  test('refuses stop, rm, kill and respawn after the options', () => {
    for (const verb of ['stop', 'rm', 'kill', 'respawn']) {
      expect(canRunClaude([...RUN, verb, REAL])).toBe(false)
    }
  })
  test('refuses a one-word prompt, because claude can read it as a subcommand', () => {
    for (const word of ['stop', 'update', 'doctor', 'hello', ' stop ']) {
      expect(canRunClaude([...RUN, word])).toBe(false)
    }
  })
  test('refuses a prompt that is not last, a second prompt and a prompt with a dash', () => {
    const early = ['--bg', 'say hello', '--model', 'haiku', '--name', 'bifrost-test-x']
    expect(canRunClaude(early)).toBe(false)
    expect(canRunClaude([...RUN, 'say hello', 'say more'])).toBe(false)
    expect(canRunClaude([...RUN, '-p hello there'])).toBe(false)
  })
  test('refuses attach in the wrong place', () => {
    expect(canRunClaude([...RUN, 'attach', REAL])).toBe(false)
  })
  test('refuses a start without --bg first', () => {
    expect(canRunClaude(['--name', 'bifrost-test-x'])).toBe(false)
    expect(canRunClaude(['--model', 'haiku', '--bg', '--name', 'bifrost-test-x'])).toBe(false)
    expect(canRunClaude(['stop', 'x'])).toBe(false)
    expect(canRunClaude(['rm', 'x'])).toBe(false)
    expect(canRunClaude([])).toBe(false)
  })
  test('refuses resume, continue, session and fork flags', () => {
    expect(canRunClaude([...RUN, '--resume', 'id'])).toBe(false)
    expect(canRunClaude([...RUN, '-r', REAL])).toBe(false)
    expect(canRunClaude([...RUN, `-r${REAL}`])).toBe(false)
    expect(canRunClaude([...RUN, '-c'])).toBe(false)
    expect(canRunClaude([...RUN, '-cr'])).toBe(false)
    expect(canRunClaude([...RUN, '--session-id', REAL])).toBe(false)
    expect(canRunClaude([...RUN, '--fork-session'])).toBe(false)
  })
  test('refuses a second name and a name that is not a test name', () => {
    expect(canRunClaude(['--bg', '--name', 'real'])).toBe(false)
    expect(canRunClaude([...RUN, '--name', 'real'])).toBe(false)
    expect(canRunClaude(['--bg', '--name=bifrost-test-x'])).toBe(false)
    expect(canRunClaude(['--bg', '--model', 'haiku'])).toBe(false)
  })
  test('refuses each flag that is not on the list', () => {
    expect(canRunClaude([...RUN, '-p'])).toBe(false)
    expect(canRunClaude([...RUN, '--print'])).toBe(false)
    expect(canRunClaude([...RUN, '--dangerously-skip-permissions'])).toBe(false)
    expect(canRunClaude([...RUN, '--settings', '{}'])).toBe(false)
    expect(canRunClaude([...RUN, '--model=opus'])).toBe(false)
    expect(canRunClaude([...RUN, '--'])).toBe(false)
  })
  test('refuses a flag value that is missing, is a flag or is a subcommand', () => {
    const named = ['--bg', '--name', 'bifrost-test-x']
    expect(canRunClaude([...named, '--model'])).toBe(false)
    expect(canRunClaude([...named, '--model', '-r'])).toBe(false)
    expect(canRunClaude([...named, '--model', 'stop'])).toBe(false)
    expect(canRunClaude([...named, '--permission-mode', 'rm'])).toBe(false)
    expect(canRunClaude([...RUN, '--model', 'opus'])).toBe(false)
  })
  test('refuses args that are not an array of strings', () => {
    expect(canRunClaude([...RUN, 5 as unknown as string])).toBe(false)
    expect(canRunClaude('--bg' as unknown as string[])).toBe(false)
  })
})
