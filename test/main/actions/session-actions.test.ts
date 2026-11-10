import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import { trustMessage } from '../../../src/main/actions/claude-output'
import {
  createSessionActions,
  DELETE_END_WAIT_MS,
  END_POLL_MS,
  END_WAIT_MS,
  handOverArgs,
  NO_STATUSLINE_SETTINGS,
  newSessionArgs,
  RESUME_SETTLE_MS,
  RM_GRACE_MS,
  RM_TIMEOUT_MS,
  RUN_TIMEOUT_MS,
  resumeArgs,
  type SessionActionDeps,
  START_TIMEOUT_MS,
  takeControlArgs,
} from '../../../src/main/actions/session-actions'
import type { ExecResult } from '../../../src/main/claude/cli'
import {
  type DirInfo,
  type NewSessionSpec,
  REASON_PROMPT_IS_COMMAND,
} from '../../../src/shared/new-session'
import type { SessionRow, WorktreeCheck } from '../../../src/shared/types'
import { worktreeOf } from '../../../src/shared/worktree'
import {
  CHANGES_SHORT_ID,
  CHANGES_STDOUT,
  CHANGES_WORKTREE,
  KEPT_DISCARD,
  KEPT_HEAD,
  KEPT_SHORT_ID,
  KEPT_STDOUT,
  KEPT_WORKTREE,
} from '../../fixtures/claude-rm'

const S = 'f3a9c2d1-4b5e-4c6d-8e7f-0a1b2c3d4e5f'
const S2 = '0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d'
const S3 = '1c2d3e4f-5061-4b7c-9d8e-0f1a2b3c4d5e'
const S4 = '2d3e4f50-6172-4c8d-ae9f-1a2b3c4d5e6f'
const SHORT = 'abcd1234'
const NEW_SHORT = '4cb23c30'
const OK: ExecResult = { code: 0, stderr: '', stdout: '' }
const STARTED: ExecResult = {
  code: 0,
  stderr: 'Starting background service…',
  stdout: `backgrounded · ${NEW_SHORT} · bifrost-test-n\n  hint line`,
}
const TRUST =
  'Workspace not trusted. Run `claude` in /p once and accept the trust prompt, then retry.'
const LOCKED = 'refused: an action on this session runs'
const NOT_ENDED =
  'The session process did not end in 5 seconds. Bifrost did not start a copy of the session.'
const NOT_RESUMED = 'The session did not start again in 30 seconds.'
const RUN_OPTS = { timeoutMs: RUN_TIMEOUT_MS }
// claude rm gets 10 minutes and SIGTERM (Task 17 bug 1).
const RM_OPTS = { killSignal: 'SIGTERM', timeoutMs: RM_TIMEOUT_MS }
// The statusline override of each new session, as one argument (controller ruling).
const SETTINGS = ['--settings', '{"statusLine":{"type":"command","command":"true"}}']
const IN_P = { cwd: '/p', timeoutMs: RUN_TIMEOUT_MS }

const row = (o: Partial<SessionRow> = {}): SessionRow => ({
  box: 'none',
  boxSince: null,
  cwd: '/p',
  flashing: false,
  kind: 'owned',
  lastActivity: 1,
  name: 'bifrost-test-s',
  pid: 4242,
  // The registry gives the resume ID of an owned row (spec 9.1). With no /clear, it is the row ID.
  resumeId: o.sessionId ?? S,
  sessionId: S,
  shortId: SHORT,
  startedAt: 1,
  state: 'idle',
  status: 'idle',
  ...o,
})

const parked = (o: Partial<SessionRow> = {}): SessionRow =>
  row({ pid: undefined, state: 'parked', status: '', ...o })

const external = (o: Partial<SessionRow> = {}): SessionRow =>
  row({ kind: 'external', resumeId: undefined, shortId: undefined, ...o })

const newSpec = (o: Partial<NewSessionSpec> = {}): NewSessionSpec => ({
  cwd: '/p',
  model: 'haiku',
  name: 'bifrost-test-n',
  permissionMode: '',
  prompt: '',
  worktree: false,
  ...o,
})

// Fake deps. Each call goes into the log with the fake time since base.
// waitForRow resolves with the first row of appear that matches, else it rejects at the timeout.
class Fake {
  log: string[] = []
  rows: SessionRow[] = []
  appear: SessionRow[] = []
  claude = true
  exec: (args: string[]) => ExecResult | Promise<ExecResult> = () => OK
  alive: (pid: number) => boolean = () => false
  name: string | null = '/Users/x/.local/bin/claude'
  dir: DirInfo = { git: true, kind: 'dir' }
  onProcessName: () => void = () => {}
  // Runs at each signal. A test can throw here.
  onSignal: () => void = () => {}
  // The result of hasMessages.
  messages = true
  // The result of the worktree check of a Delete, with the HEAD commit.
  check: (path: string) => (WorktreeCheck & { head: string }) | null = () => null
  // The count of the tracked changed files of a worktree before the stop. null is a git failure.
  tracked: (path: string) => number | null = () => 0
  base = Date.now()

  private add(op: string, ...args: unknown[]): void {
    const text = args.map(a => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ')
    this.log.push(`${Date.now() - this.base} ${op}${text === '' ? '' : ` ${text}`}`)
  }

  // A claude run that ends after ms.
  slow(ms: number, result: ExecResult = OK): (args: string[]) => Promise<ExecResult> {
    return args =>
      new Promise(resolve =>
        setTimeout(() => {
          this.add('end', args)
          resolve(result)
        }, ms),
      )
  }

  ops(...names: string[]): string[] {
    return this.log.filter(line => names.length === 0 || names.includes(line.split(' ')[1]))
  }

  deps(): SessionActionDeps {
    return {
      checkWorktree: async path => {
        this.add('checkWorktree', path)
        return this.check(path)
      },
      dirInfo: async dir => {
        this.add('dirInfo', dir)
        return this.dir
      },
      forget: id => this.add('forget', id),
      hasMessages: async id => {
        this.add('hasMessages', id)
        return this.messages
      },
      isAlive: pid => {
        this.add('isAlive', pid)
        return this.alive(pid)
      },
      markStarted: id => this.add('markStarted', id),
      markStopped: id => this.add('markStopped', id),
      processName: async pid => {
        this.add('processName', pid)
        this.onProcessName()
        return this.name
      },
      rememberWorktree: (id, path) => this.add('rememberWorktree', id, path),
      rows: () => this.rows,
      run: async () => {
        if (!this.claude) return null
        return async (args, opts) => {
          this.add('run', args, opts)
          return this.exec(args)
        }
      },
      signal: (pid, signal) => {
        this.add('signal', pid, signal)
        this.onSignal()
      },
      trackedChanges: async path => {
        this.add('trackedChanges', path)
        return this.tracked(path)
      },
      waitForRow: (match, timeoutMs) => {
        this.add('waitForRow', timeoutMs)
        const found = this.appear.find(match)
        if (found) {
          // The registry now has the row that matched.
          this.rows = [...this.rows.filter(r => r.sessionId !== found.sessionId), found]
          return Promise.resolve(found)
        }
        return new Promise((_resolve, reject) => {
          setTimeout(() => reject(new Error('timeout')), timeoutMs)
        })
      },
    }
  }
}

let f: Fake
let actions: ReturnType<typeof createSessionActions>

beforeEach(() => {
  vi.useFakeTimers()
  f = new Fake()
  actions = createSessionActions(f.deps())
})

afterEach(() => {
  vi.useRealTimers()
})

// The literal argument lists, so the tests do not repeat the code under test.
const expectedResume = (id: string): string[] => ['--bg', '--resume', id]
const expectedTakeControl = (id: string): string[] => [
  '--bg',
  '--settings',
  '{"statusLine":{"type":"command","command":"true"}}',
  '--resume',
  id,
]

describe('resumeArgs and takeControlArgs', () => {
  test('Resume and Resume all add no flag, because a flag on a background session starts a copy', () => {
    expect(resumeArgs({ kind: 'owned', resumeId: 'S1', sessionId: 'S1' })).toEqual(
      expectedResume('S1'),
    )
  })

  test('Resume of a parked foreground session turns the statusline off, as Take control does', () => {
    // A failed Take control parks a session whose last entry was in the foreground. It has no
    // saved options, so the flag keeps the same session ID (test of 2026-11-06).
    expect(resumeArgs({ kind: 'external', sessionId: 'S1' })).toEqual(expectedTakeControl('S1'))
  })

  test('Take control turns the statusline off, because the session was in the foreground', () => {
    expect(takeControlArgs('S1')).toEqual(expectedTakeControl('S1'))
    expect(expectedTakeControl('S1')[2]).toBe(NO_STATUSLINE_SETTINGS)
  })
})

describe('newSessionArgs', () => {
  test('newSessionArgs puts the flags before the name and the prompt last', () => {
    expect(
      newSessionArgs(
        newSpec({
          model: 'haiku',
          name: 'n1',
          permissionMode: 'plan',
          prompt: 'Reply',
          worktree: true,
        }),
      ),
    ).toEqual([
      '--bg',
      ...SETTINGS,
      '--worktree',
      'n1',
      '--model',
      'haiku',
      '--permission-mode',
      'plan',
      '--name',
      'n1',
      'Reply',
    ])
    expect(newSessionArgs(newSpec({ model: '', name: 'n1' }))).toEqual([
      '--bg',
      ...SETTINGS,
      '--name',
      'n1',
    ])
    expect(newSessionArgs(newSpec({ model: '', name: 'My Name', worktree: true }))).toEqual([
      '--bg',
      ...SETTINGS,
      '--worktree',
      'my-name',
      '--name',
      'My Name',
    ])
  })

  test('newSessionArgs never passes a permission mode outside the list', () => {
    expect(() => newSessionArgs(newSpec({ permissionMode: 'bypassPermissions' }))).toThrow(
      'refused: unknown permission mode',
    )
  })

  test('newSessionArgs gives the statusline override as one argument', () => {
    const args = newSessionArgs(newSpec({ name: 'n1', prompt: 'Reply' }))
    const at = args.indexOf('--settings')
    expect(at).toBeGreaterThan(0)
    expect(JSON.parse(args[at + 1])).toEqual({ statusLine: { command: 'true', type: 'command' } })
    expect(args.filter(arg => arg === '--settings')).toHaveLength(1)
  })

  test('newSessionArgs always turns the statusline off for a new session', () => {
    const args = newSessionArgs(newSpec({ model: '', name: 'n1', prompt: 'Reply' }))
    expect(args.slice(0, 3)).toEqual(['--bg', '--settings', NO_STATUSLINE_SETTINGS])
  })

  test('newSessionArgs never passes a command name or a flag as the prompt', () => {
    for (const prompt of ['update', ' help ', 'stop', 'migrate-installer']) {
      expect(() => newSessionArgs(newSpec({ prompt })), prompt).toThrow(REASON_PROMPT_IS_COMMAND)
    }
    expect(() => newSessionArgs(newSpec({ prompt: '-p' }))).toThrow(
      'The first prompt cannot start with "-".',
    )
    expect(newSessionArgs(newSpec({ name: 'n1', prompt: 'update the docs' })).at(-1)).toBe(
      'update the docs',
    )
  })
})

describe('handOverArgs', () => {
  const opts = {
    model: 'claude-opus-5-5',
    name: 'fix login (2)',
    permissionMode: null,
    prompt: 'Go',
  }

  test('handOverArgs gives the model, the name and the prompt last', () => {
    expect(handOverArgs(opts)).toEqual([
      '--bg',
      ...SETTINGS,
      '--model',
      'claude-opus-5-5',
      '--name',
      'fix login (2)',
      'Go',
    ])
  })

  test('a permission mode in the list gives the flag', () => {
    expect(handOverArgs({ ...opts, model: 'opus[1m]', permissionMode: 'plan' })).toEqual([
      '--bg',
      ...SETTINGS,
      '--model',
      'opus[1m]',
      '--permission-mode',
      'plan',
      '--name',
      'fix login (2)',
      'Go',
    ])
  })

  test('a permission mode outside the list gives no flag', () => {
    for (const permissionMode of ['default', 'bypassPermissions', '', '--x', null]) {
      expect(handOverArgs({ ...opts, permissionMode }), String(permissionMode)).not.toContain(
        '--permission-mode',
      )
    }
  })

  test('a bad model is refused', () => {
    for (const model of ['', '-p', '--model', 'a b', 'a\nb', 'opus;x', 'x'.repeat(101)]) {
      expect(() => handOverArgs({ ...opts, model }), model).toThrow('refused: unknown model')
    }
    expect(handOverArgs({ ...opts, model: 'x'.repeat(100) })).toContain('x'.repeat(100))
  })

  test('a bad name is refused', () => {
    for (const name of ['', '  ', 'x'.repeat(65), 'a\nb', 'a\rb', '-x', ' -x']) {
      expect(() => handOverArgs({ ...opts, name }), name).toThrow('refused: bad name')
    }
    expect(handOverArgs({ ...opts, name: 'x'.repeat(64) })).toContain('x'.repeat(64))
  })

  test('the prompt rules of newSessionArgs apply', () => {
    expect(() => handOverArgs({ ...opts, prompt: 'update' })).toThrow(REASON_PROMPT_IS_COMMAND)
    expect(() => handOverArgs({ ...opts, prompt: ' -p x' })).toThrow(
      'The first prompt cannot start with "-".',
    )
  })

  test('a hand-over never adds a plugin folder, a worktree or a resume', () => {
    const args = handOverArgs({ ...opts, permissionMode: 'acceptEdits' })
    for (const flag of ['--plugin-dir', '--worktree', '--resume']) {
      expect(args).not.toContain(flag)
    }
  })
})

describe('create', () => {
  test('create runs claude --bg in the directory, waits for the entry and marks the session as started', async () => {
    f.exec = () => STARTED
    // Only an owned entry with a PID that is not parked is the new session.
    f.appear = [
      row({ kind: 'external', sessionId: S2, shortId: NEW_SHORT }),
      parked({ sessionId: S2, shortId: NEW_SHORT }),
      row({ pid: undefined, sessionId: S2, shortId: NEW_SHORT }),
      row({ sessionId: S3 }),
      row({ sessionId: S, shortId: NEW_SHORT }),
    ]
    await expect(
      actions.create({ ...newSpec({ cwd: '/p/', permissionMode: 'plan', prompt: 'Reply' }) }),
    ).resolves.toEqual({ sessionId: S })
    expect(f.ops()).toEqual([
      '0 dirInfo /p',
      `0 run ${JSON.stringify([
        '--bg',
        ...SETTINGS,
        '--model',
        'haiku',
        '--permission-mode',
        'plan',
        '--name',
        'bifrost-test-n',
        'Reply',
      ])} ${JSON.stringify(IN_P)}`,
      `0 waitForRow ${START_TIMEOUT_MS}`,
      `0 markStarted ${S}`,
    ])
  })

  test('create always passes the statusline override', async () => {
    f.log = []
    f.exec = () => STARTED
    f.appear = [row({ shortId: NEW_SHORT })]
    await expect(actions.create(newSpec())).resolves.toEqual({ sessionId: S })
    const runs = f.ops('run')
    expect(runs).toHaveLength(1)
    expect(JSON.parse(runs[0].split(' ')[2])).toEqual([
      '--bg',
      ...SETTINGS,
      '--model',
      'haiku',
      '--name',
      'bifrost-test-n',
    ])
  })

  test('create shows the trust error with the instruction', async () => {
    f.exec = () => ({ code: 1, stderr: TRUST, stdout: '' })
    await expect(actions.create(newSpec())).rejects.toThrow(trustMessage('/p'))
    f.exec = () => ({ code: 0, stderr: '', stdout: TRUST })
    await expect(actions.create(newSpec())).rejects.toThrow(trustMessage('/p'))
    expect(f.ops('waitForRow', 'markStarted')).toEqual([])
  })

  test('create does not take exit code 0 as proof', async () => {
    f.exec = () => STARTED
    let settled = false
    const done = actions.create(newSpec()).finally(() => {
      settled = true
    })
    const check = expect(done).rejects.toThrow(
      `The session ${NEW_SHORT} did not start in 30 seconds. Run claude logs ${NEW_SHORT} to see the cause.`,
    )
    await vi.advanceTimersByTimeAsync(START_TIMEOUT_MS - 1)
    expect(settled).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    await check
    expect(f.ops('markStarted')).toEqual([])
  })

  test('create refuses a missing directory and a worktree outside a git repository', async () => {
    f.dir = { git: false, kind: 'missing' }
    await expect(actions.create(newSpec())).rejects.toThrow("This folder doesn't exist.")
    f.dir = { git: false, kind: 'other' }
    await expect(actions.create(newSpec())).rejects.toThrow("This folder doesn't exist.")
    f.dir = { git: false, kind: 'dir' }
    await expect(actions.create(newSpec({ worktree: true }))).rejects.toThrow(
      "This folder isn't in a git repository, so it can't use a worktree.",
    )
    expect(f.ops('run')).toEqual([])
    // Without the worktree option, a directory outside git is correct.
    f.exec = () => STARTED
    f.appear = [row({ shortId: NEW_SHORT })]
    await expect(actions.create(newSpec())).resolves.toEqual({ sessionId: S })
  })

  test('create refuses bad values before it reads the directory', async () => {
    await expect(actions.create(newSpec({ name: '-x' }))).rejects.toThrow(
      'The name cannot start with "-".',
    )
    await expect(
      actions.create({ ...newSpec(), permissionMode: 'bypassPermissions' }),
    ).rejects.toThrow('refused: unknown permission mode')
    await expect(actions.create(null)).rejects.toThrow('refused: bad new session data')
    await expect(actions.create(newSpec({ prompt: 'update' }))).rejects.toThrow(
      REASON_PROMPT_IS_COMMAND,
    )
    expect(f.log).toEqual([])
  })

  test('only one New session starts at a time', async () => {
    f.exec = f.slow(1000, STARTED)
    f.appear = [row({ shortId: NEW_SHORT })]
    const first = actions.create(newSpec())
    await expect(actions.create(newSpec())).rejects.toThrow(
      'A new session is already starting. Please wait.',
    )
    await vi.advanceTimersByTimeAsync(1000)
    await expect(first).resolves.toEqual({ sessionId: S })
    // A failed start also frees the lock.
    f.exec = () => ({ code: 1, stderr: 'boom', stdout: '' })
    await expect(actions.create(newSpec())).rejects.toThrow('boom')
    f.exec = () => STARTED
    await expect(actions.create(newSpec())).resolves.toEqual({ sessionId: S })
    expect(f.ops('run')).toHaveLength(3)
  })

  test('create gives the claude failure, a missing short ID and a missing claude', async () => {
    f.exec = () => ({ code: 2, stderr: ' unknown option \n', stdout: '' })
    await expect(actions.create(newSpec())).rejects.toThrow('unknown option')
    f.exec = () => ({ code: 3, stderr: '', stdout: '' })
    await expect(actions.create(newSpec())).rejects.toThrow('claude --bg failed with code 3')
    f.exec = () => ({ code: 0, stderr: '', stdout: 'done' })
    await expect(actions.create(newSpec())).rejects.toThrow(
      'claude --bg did not give a session ID.',
    )
    expect(f.ops('waitForRow')).toEqual([])
    f.claude = false
    await expect(actions.create(newSpec())).rejects.toThrow('claude not found')
  })
})

describe('stop', () => {
  test('stop runs claude stop with the short ID and marks the session as stopped', async () => {
    f.rows = [row({ state: 'working' })]
    await actions.stop(S)
    expect(f.ops()).toEqual([
      `0 run ${JSON.stringify(['stop', SHORT])} ${JSON.stringify(RUN_OPTS)}`,
      `0 markStopped ${S}`,
    ])
  })

  test('stop refuses an external and a parked row', async () => {
    f.rows = [external()]
    await expect(actions.stop(S)).rejects.toThrow('refused: only an owned session that runs')
    f.rows = [parked()]
    await expect(actions.stop(S)).rejects.toThrow('refused: only an owned session that runs')
    expect(f.log).toEqual([])
  })

  test('stop refuses an unknown session and a bad short ID', async () => {
    f.rows = [row()]
    await expect(actions.stop(S2)).rejects.toThrow('refused: unknown session')
    await expect(actions.stop(7)).rejects.toThrow('refused: unknown session')
    for (const shortId of [undefined, 'ABCD1234', '-abcd123', 'abcd12345']) {
      f.rows = [row({ shortId })]
      await expect(actions.stop(S)).rejects.toThrow('refused: bad session ID')
    }
    expect(f.log).toEqual([])
  })

  test('a failed claude command gives the lead sentence before the raw text (final review M5)', async () => {
    f.rows = [row()]
    f.exec = () => ({ code: 1, stderr: 'no such job\n', stdout: '' })
    const stopped = await actions.stop(S).catch((e: Error) => e.message)
    expect(stopped).toBe('Claude Code reported a problem: no such job')
    f.rows = [parked()]
    f.exec = () => ({ code: 1, stderr: '', stdout: 'rm failed' })
    const removed = await actions.remove(S, true).catch((e: Error) => e.message)
    expect(removed).toBe('Claude Code reported a problem: rm failed')
    f.exec = () => ({ code: 1, stderr: 'resume failed', stdout: '' })
    const resumed = await actions.resume(S).catch((e: Error) => e.message)
    expect(resumed).toBe('Claude Code reported a problem: resume failed')
  })

  test('stop does not mark the session after a failed claude stop', async () => {
    f.rows = [row()]
    f.exec = () => ({ code: 1, stderr: 'no such job', stdout: '' })
    await expect(actions.stop(S)).rejects.toThrow('no such job')
    expect(f.ops('markStopped')).toEqual([])
  })
})

describe('remove', () => {
  test('remove stops a running session, runs claude rm and forgets it', async () => {
    f.rows = [row()]
    await actions.remove(S, true)
    expect(f.ops()).toEqual([
      `0 run ${JSON.stringify(['stop', SHORT])} ${JSON.stringify(RUN_OPTS)}`,
      '0 isAlive 4242',
      `0 run ${JSON.stringify(['rm', SHORT])} ${JSON.stringify(RM_OPTS)}`,
      `0 forget ${S}`,
    ])
  })

  test('remove of a parked row runs only claude rm', async () => {
    f.rows = [parked()]
    await actions.remove(S, true)
    expect(f.ops()).toEqual([
      `0 run ${JSON.stringify(['rm', SHORT])} ${JSON.stringify(RM_OPTS)}`,
      `0 forget ${S}`,
    ])
  })

  test('remove of a row without a short ID only forgets', async () => {
    f.rows = [parked({ shortId: undefined })]
    f.claude = false
    await actions.remove(S, true)
    expect(f.ops()).toEqual([`0 forget ${S}`])
  })

  test('remove refuses a session that runs and has no short ID', async () => {
    // Bifrost cannot stop it. A forget alone gives the row again at the next sample.
    f.rows = [row({ shortId: undefined })]
    await expect(actions.remove(S, true)).rejects.toThrow(
      'refused: the session runs and has no short ID',
    )
    expect(f.log).toEqual([])
  })

  test('remove does not forget after a failed claude rm', async () => {
    f.rows = [parked()]
    f.exec = () => ({ code: 1, stderr: 'rm failed', stdout: '' })
    await expect(actions.remove(S, true)).rejects.toThrow('rm failed')
    expect(f.ops('forget')).toEqual([])
  })

  test('claude rm has 10 minutes, and the other commands keep the old limit', () => {
    expect(RM_TIMEOUT_MS).toBe(600_000)
    expect(RUN_TIMEOUT_MS).toBe(60_000)
  })

  test('remove gives the slow text when claude rm reaches its time limit, and does not forget', async () => {
    // Node gives this text when the kill signal ended the program (Task 17 bug 1).
    const slow: ExecResult = {
      code: 1,
      stderr: 'Command failed: /Users/x/.local/bin/claude rm abcd1234',
      stdout: '',
      timedOut: true,
    }
    f.rows = [parked()]
    f.exec = () => slow
    await expect(actions.remove(S, true)).rejects.toThrow('refused: claude rm took too long')
    expect(f.ops('forget')).toEqual([])
    // A program that exits with a code after the SIGTERM also reached the limit.
    f.exec = () => ({ code: 143, stderr: '', stdout: 'removing', timedOut: true })
    await expect(actions.remove(S, true)).rejects.toThrow('refused: claude rm took too long')
    expect(f.ops('forget')).toEqual([])
  })

  test('remove releases the lock 30 s after the SIGTERM of a claude rm that does not end', async () => {
    // Node sends SIGTERM at RM_TIMEOUT_MS. Bifrost waits 30 s more and sends no SIGKILL.
    const GRACE = 30_000
    f.rows = [parked()]
    let finish: (result: ExecResult) => void = () => {}
    f.exec = () =>
      new Promise<ExecResult>(resolve => {
        finish = resolve
      })
    let outcome: string | null = null
    actions.remove(S, true).then(
      () => {
        outcome = 'resolved'
      },
      (error: Error) => {
        outcome = error.message
      },
    )
    await vi.advanceTimersByTimeAsync(RM_TIMEOUT_MS + GRACE - 1)
    expect(outcome).toBeNull()
    await expect(actions.remove(S, true)).rejects.toThrow(LOCKED)
    await vi.advanceTimersByTimeAsync(1)
    expect(outcome).toBe('refused: claude rm took too long')
    expect(RM_GRACE_MS).toBe(GRACE)
    // A late end of that claude rm changes nothing. The next poll shows the result.
    finish(OK)
    await vi.advanceTimersByTimeAsync(0)
    expect(f.ops('forget')).toEqual([])
    // The lock is free again.
    f.exec = () => OK
    await actions.remove(S, true)
    expect(f.ops('forget')).toEqual([`${RM_TIMEOUT_MS + GRACE} forget ${S}`])
  })

  test('remove does not run claude rm after a failed claude stop', async () => {
    f.rows = [row()]
    f.exec = args => (args[0] === 'stop' ? { code: 1, stderr: '', stdout: '' } : OK)
    await expect(actions.remove(S, true)).rejects.toThrow('claude stop failed with code 1')
    expect(f.ops()).toEqual([
      `0 run ${JSON.stringify(['stop', SHORT])} ${JSON.stringify(RUN_OPTS)}`,
    ])
  })

  test('remove refuses an external session that runs and a delete without the confirmation', async () => {
    f.rows = [external()]
    await expect(actions.remove(S, true)).rejects.toThrow(
      'refused: Bifrost does not delete an external session',
    )
    f.rows = [row()]
    for (const confirmed of [undefined, false, 'true', 1]) {
      await expect(actions.remove(S, confirmed)).rejects.toThrow(
        'refused: Delete needs a confirmation',
      )
    }
    f.rows = [parked({ shortId: 'xyz' })]
    await expect(actions.remove(S, true)).rejects.toThrow('refused: bad session ID')
    expect(f.log).toEqual([])
  })
})

describe('remove of a worktree that claude rm keeps', () => {
  // The rows of this group have the short ID and the worktree of the real kept text.
  const ID = KEPT_SHORT_ID
  const WT = KEPT_WORKTREE
  const KEPT: ExecResult = { code: 1, stderr: '', stdout: KEPT_STDOUT }
  const RM = ['rm', ID]
  const DISCARD = ['rm', ID, '--discard-unpushed', KEPT_DISCARD]
  const CHANGED = 'refused: the worktree changed after the check'
  const KEPT_REFUSAL = 'refused: claude rm kept the worktree'
  const runLine = (args: string[]) =>
    `0 run ${JSON.stringify(args)} ${JSON.stringify(args[0] === 'rm' ? RM_OPTS : RUN_OPTS)}`
  // The check that the dialog showed, with the worktree of that check (final review M2).
  const counts = (unmergedCommits: number, changedFiles: number, worktree = WT) => ({
    changedFiles,
    unmergedCommits,
    worktree,
  })
  const found = (
    unmergedCommits: number,
    changedFiles: number,
    head = KEPT_HEAD,
  ): WorktreeCheck & { head: string } => ({
    branch: 'worktree-bifrost-test-rmx',
    changedFiles,
    head,
    unmergedCommits,
    worktree: WT,
  })
  // claude rm keeps the worktree. claude rm with the discard value removes it.
  const keeps = (args: string[]) => (args.length === 2 && args[0] === 'rm' ? KEPT : OK)
  // A stopped worktree session reports its start folder. The row keeps the worktree.
  const stoppedRow = (o: Partial<SessionRow> = {}) =>
    parked({ cwd: '/r', shortId: ID, worktree: WT, ...o })
  // The kept text with another worktree path.
  const keptAt = (path: string): ExecResult => ({
    code: 1,
    stderr: '',
    stdout: KEPT_STDOUT.replace(WT, path),
  })

  test('remove discards after a refusal when seen is 0 and 0', async () => {
    f.rows = [stoppedRow()]
    f.exec = keeps
    f.check = () => found(0, 0)
    await actions.remove(S, true, counts(0, 0))
    expect(f.ops()).toEqual([
      runLine(RM),
      `0 checkWorktree ${WT}`,
      runLine(DISCARD),
      `0 forget ${S}`,
    ])
  })

  test('remove discards when the new check after the stop equals seen', async () => {
    f.rows = [row({ cwd: `${WT}/src`, shortId: ID })]
    f.exec = keeps
    f.check = () => found(2, 1)
    await actions.remove(S, true, counts(2, 1))
    expect(f.ops()).toEqual([
      `0 trackedChanges ${WT}`,
      runLine(['stop', ID]),
      '0 isAlive 4242',
      runLine(RM),
      `0 checkWorktree ${WT}`,
      runLine(DISCARD),
      `0 forget ${S}`,
    ])
    // Less work than the dialog showed also discards.
    f.log = []
    f.rows = [stoppedRow()]
    f.check = () => found(1, 0)
    await actions.remove(S, true, counts(2, 1))
    expect(f.ops('run', 'forget')).toEqual([runLine(RM), runLine(DISCARD), `0 forget ${S}`])
  })

  test('remove does not discard when the new check has more commits or more changed files', async () => {
    f.exec = keeps
    for (const now of [found(3, 1), found(2, 2), found(9, 9)]) {
      f.log = []
      f.rows = [stoppedRow()]
      f.check = () => now
      await expect(actions.remove(S, true, counts(2, 1))).rejects.toThrow(CHANGED)
      expect(f.ops()).toEqual([runLine(RM), `0 checkWorktree ${WT}`])
    }
  })

  test('remove does not discard when the new check fails or finds no worktree', async () => {
    f.exec = keeps
    const none = {
      branch: null,
      changedFiles: 0,
      head: KEPT_HEAD,
      unmergedCommits: 0,
      worktree: null,
    }
    for (const now of [null, none]) {
      f.log = []
      f.rows = [stoppedRow()]
      f.check = () => now
      await expect(actions.remove(S, true, counts(0, 0))).rejects.toThrow(CHANGED)
      expect(f.ops()).toEqual([runLine(RM), `0 checkWorktree ${WT}`])
    }
  })

  test('remove does not discard when seen is null', async () => {
    f.exec = keeps
    f.check = () => found(0, 0)
    for (const seen of [null, undefined]) {
      f.log = []
      f.rows = [stoppedRow()]
      await expect(actions.remove(S, true, seen)).rejects.toThrow(KEPT_REFUSAL)
      expect(f.ops()).toEqual([runLine(RM)])
    }
  })

  test('remove does not discard when Bifrost knows no worktree of the row, and remembers it', async () => {
    // The next Delete then checks the worktree of the kept text and offers Open worktree.
    f.exec = keeps
    f.check = () => found(0, 0)
    // The check of a row with no worktree finds no worktree. So the dialog sends no counts.
    for (const seen of [null, undefined]) {
      f.log = []
      f.rows = [parked({ cwd: '/r', shortId: ID })]
      await expect(actions.remove(S, true, seen)).rejects.toThrow(KEPT_REFUSAL)
      expect(f.ops()).toEqual([runLine(RM), `0 rememberWorktree ${S} ${WT}`])
    }
    // One trailing "/" goes away.
    f.log = []
    f.exec = args => (args[0] === 'rm' ? keptAt(`${WT}/`) : OK)
    await expect(actions.remove(S, true, null)).rejects.toThrow(KEPT_REFUSAL)
    expect(f.ops('rememberWorktree')).toEqual([`0 rememberWorktree ${S} ${WT}`])
  })

  test('remove does not remember a kept worktree of another session or a path that is not a root', async () => {
    const cases: [SessionRow, ExecResult][] = [
      [parked({ cwd: '/r', shortId: SHORT }), KEPT],
      [parked({ cwd: '/r', shortId: ID }), keptAt(`${WT}/src`)],
      [parked({ cwd: '/r', shortId: ID }), keptAt('/r/src')],
      [parked({ cwd: '/r', shortId: ID }), keptAt('r/.claude/worktrees/a')],
      [parked({ cwd: '/r', shortId: ID }), keptAt(`${WT}//`)],
    ]
    for (const [current, result] of cases) {
      f.log = []
      f.rows = [current]
      f.exec = args => (args[0] === 'rm' ? result : OK)
      await expect(actions.remove(S, true, null)).rejects.toThrow(KEPT_REFUSAL)
      expect(f.ops('run', 'rememberWorktree', 'checkWorktree')).toHaveLength(1)
    }
  })

  test('remove does not discard when the kept text names another short ID', async () => {
    f.rows = [stoppedRow({ shortId: SHORT })]
    f.exec = args => (args.length === 2 && args[0] === 'rm' ? KEPT : OK)
    f.check = () => found(0, 0)
    await expect(actions.remove(S, true, counts(0, 0))).rejects.toThrow(CHANGED)
    expect(f.ops('run')).toEqual([runLine(['rm', SHORT])])
  })

  test('remove does not discard when the kept text names another worktree', async () => {
    f.check = () => found(0, 0)
    // A cwd in a worktree inside a worktree gives the outer root. claude rm keeps the inner one.
    const inner = `${WT}/.claude/worktrees/inner`
    const cases: [SessionRow, ExecResult][] = [
      [stoppedRow({ worktree: '/r/.claude/worktrees/other' }), KEPT],
      [stoppedRow(), keptAt(`${WT}//`)],
      [stoppedRow(), keptAt(`${WT}-2`)],
      [row({ cwd: inner, shortId: ID }), keptAt(inner)],
    ]
    for (const [current, result] of cases) {
      f.log = []
      f.rows = [current]
      f.exec = args => (args.length === 2 && args[0] === 'rm' ? result : OK)
      // The dialog checked the worktree of the row. Only the kept text names another worktree.
      const seen = counts(0, 0, worktreeOf(current) ?? WT)
      await expect(actions.remove(S, true, seen)).rejects.toThrow(CHANGED)
      expect(f.ops('run')).toContainEqual(runLine(RM))
      expect(f.ops('run').map(line => line.split(' ')[2])).not.toContain(JSON.stringify(DISCARD))
      expect(f.ops('forget')).toEqual([])
    }
  })

  test('remove does not discard when the HEAD of the worktree is not the commit of the value', async () => {
    f.rows = [stoppedRow()]
    f.exec = keeps
    f.check = () => found(0, 0, '0'.repeat(40))
    await expect(actions.remove(S, true, counts(0, 0))).rejects.toThrow(CHANGED)
    expect(f.ops()).toEqual([runLine(RM), `0 checkWorktree ${WT}`])
  })

  test('remove compares the kept worktree after one trailing slash goes away', async () => {
    f.rows = [stoppedRow()]
    f.exec = args => (args.length === 2 && args[0] === 'rm' ? keptAt(`${WT}/`) : OK)
    f.check = () => found(0, 0)
    await actions.remove(S, true, counts(0, 0))
    expect(f.ops('run', 'forget')).toEqual([runLine(RM), runLine(DISCARD), `0 forget ${S}`])
  })

  test('remove never passes a value that parseKept did not give', async () => {
    f.check = () => found(0, 0)
    const cases: [ExecResult, string][] = [
      [{ code: 1, stderr: 'rm failed', stdout: '' }, 'rm failed'],
      [{ code: 1, stderr: KEPT_STDOUT, stdout: '' }, 'kept abd71478'],
      [{ code: 1, stderr: '', stdout: KEPT_STDOUT.replace('kept ', 'held ') }, 'held abd71478'],
      [
        { code: 1, stderr: '', stdout: KEPT_STDOUT.replace(KEPT_DISCARD, `${KEPT_DISCARD};id`) },
        'kept',
      ],
      [
        {
          code: 1,
          stderr: '',
          stdout: KEPT_STDOUT.replace(KEPT_DISCARD, KEPT_DISCARD.toUpperCase()),
        },
        'kept',
      ],
      [{ code: 1, stderr: '', stdout: KEPT_STDOUT.replace(KEPT_DISCARD, '--all') }, 'kept'],
      [{ code: 2, stderr: '', stdout: '' }, 'claude rm failed with code 2'],
    ]
    for (const [result, error] of cases) {
      f.log = []
      f.rows = [stoppedRow()]
      f.exec = args => (args[0] === 'rm' ? result : OK)
      await expect(actions.remove(S, true, counts(0, 0))).rejects.toThrow(error)
      expect(f.ops()).toEqual([runLine(RM)])
    }
  })

  test('remove gives the changed text when claude rm keeps the worktree again', async () => {
    // The second refusal ends the delete. Bifrost tries the discard one time only.
    f.rows = [stoppedRow()]
    f.exec = args => (args[0] === 'rm' ? KEPT : OK)
    f.check = () => found(0, 0)
    await expect(actions.remove(S, true, counts(0, 0))).rejects.toThrow(CHANGED)
    expect(f.ops()).toEqual([runLine(RM), `0 checkWorktree ${WT}`, runLine(DISCARD)])
  })

  test('remove gives the slow text when the discard reaches its time limit, and does not forget', async () => {
    f.rows = [stoppedRow()]
    f.exec = args =>
      args.length === 2 ? KEPT : { code: 1, stderr: 'Command failed', stdout: '', timedOut: true }
    f.check = () => found(0, 0)
    await expect(actions.remove(S, true, counts(0, 0))).rejects.toThrow(
      'refused: claude rm took too long',
    )
    expect(f.ops()).toEqual([runLine(RM), `0 checkWorktree ${WT}`, runLine(DISCARD)])
  })

  test('remove releases the lock 30 s after the SIGTERM of a discard that does not end', async () => {
    f.rows = [stoppedRow()]
    f.exec = args => (args.length === 2 ? KEPT : new Promise<ExecResult>(() => {}))
    f.check = () => found(0, 0)
    let outcome: string | null = null
    actions.remove(S, true, counts(0, 0)).catch((error: Error) => {
      outcome = error.message
    })
    await vi.advanceTimersByTimeAsync(RM_TIMEOUT_MS + 30_000)
    expect(outcome).toBe('refused: claude rm took too long')
    expect(f.ops('forget')).toEqual([])
  })

  test('remove refuses a worktree with uncommitted changes and tries no discard', async () => {
    const UNCOMMITTED = 'refused: the worktree has uncommitted changes'
    const CHANGES: ExecResult = { code: 1, stderr: '', stdout: CHANGES_STDOUT }
    const rm = ['rm', CHANGES_SHORT_ID]
    f.exec = args => (args[0] === 'rm' ? CHANGES : OK)
    f.check = () => found(1, 75)
    // Bifrost knows the worktree. It runs no check and no other command.
    for (const seen of [counts(1, 75, CHANGES_WORKTREE), null]) {
      f.log = []
      f.rows = [parked({ cwd: '/r', shortId: CHANGES_SHORT_ID, worktree: CHANGES_WORKTREE })]
      await expect(actions.remove(S, true, seen)).rejects.toThrow(UNCOMMITTED)
      expect(f.ops()).toEqual([runLine(rm)])
    }
    // Bifrost knows no worktree. It remembers the worktree as for Task 15.
    f.log = []
    f.rows = [parked({ cwd: '/r', shortId: CHANGES_SHORT_ID })]
    await expect(actions.remove(S, true, null)).rejects.toThrow(UNCOMMITTED)
    expect(f.ops()).toEqual([runLine(rm), `0 rememberWorktree ${S} ${CHANGES_WORKTREE}`])
    // A kept line of another session gives no remembered worktree.
    f.log = []
    f.rows = [parked({ cwd: '/r', shortId: SHORT })]
    await expect(actions.remove(S, true, null)).rejects.toThrow(UNCOMMITTED)
    expect(f.ops()).toEqual([runLine(['rm', SHORT])])
  })

  test('remove tries no discard when the changes text comes with a discard value', async () => {
    const both = `${CHANGES_STDOUT}  claude rm ${CHANGES_SHORT_ID} --discard-unpushed ${KEPT_DISCARD}\n`
    f.rows = [parked({ cwd: '/r', shortId: CHANGES_SHORT_ID, worktree: CHANGES_WORKTREE })]
    f.exec = args => (args[0] === 'rm' ? { code: 1, stderr: '', stdout: both } : OK)
    f.check = () => found(0, 0)
    await expect(actions.remove(S, true, counts(0, 0, CHANGES_WORKTREE))).rejects.toThrow(
      'refused: the worktree has uncommitted changes',
    )
    expect(f.ops('run')).toEqual([runLine(['rm', CHANGES_SHORT_ID])])
  })

  test('remove gives the changes text when the discard refuses for uncommitted changes', async () => {
    const changesAt = CHANGES_STDOUT.replaceAll(CHANGES_SHORT_ID, ID).replace(CHANGES_WORKTREE, WT)
    f.rows = [stoppedRow()]
    f.exec = args => (args.length === 2 ? KEPT : { code: 1, stderr: '', stdout: changesAt })
    f.check = () => found(0, 0)
    await expect(actions.remove(S, true, counts(0, 0))).rejects.toThrow(
      'refused: the worktree has uncommitted changes',
    )
    expect(f.ops('run', 'forget')).toEqual([runLine(RM), runLine(DISCARD)])
  })

  test('remove refuses check counts that are not counts', async () => {
    f.rows = [stoppedRow()]
    for (const seen of [
      {},
      { changedFiles: 0 },
      { changedFiles: -1, unmergedCommits: 0 },
      { changedFiles: 0.5, unmergedCommits: 0 },
      { changedFiles: '0', unmergedCommits: 0 },
      { changedFiles: 0, unmergedCommits: Number.NaN },
      // The worktree of the check must be a string (final review M2).
      { changedFiles: 0, unmergedCommits: 0 },
      { changedFiles: 0, unmergedCommits: 0, worktree: null },
      { changedFiles: 0, unmergedCommits: 0, worktree: 7 },
      0,
      'x',
      [],
    ]) {
      await expect(actions.remove(S, true, seen)).rejects.toThrow('refused: bad input')
    }
    expect(f.log).toEqual([])
  })

  test('remove refuses before any command when the checked worktree is not the worktree of the row', async () => {
    // The row moved to another worktree after the dialog check (final review M2). Without this
    // check, the kept text and the new check name the worktree of the row, and the discard runs.
    f.exec = keeps
    f.check = () => found(0, 0)
    const other = '/r/.claude/worktrees/other'
    for (const current of [stoppedRow(), row({ cwd: `${WT}/src`, shortId: ID })]) {
      f.log = []
      f.rows = [current]
      await expect(actions.remove(S, true, counts(0, 0, other))).rejects.toThrow(CHANGED)
      expect(f.log).toEqual([])
    }
    // The row has no worktree now.
    f.rows = [parked({ cwd: '/r', shortId: ID })]
    await expect(actions.remove(S, true, counts(0, 0))).rejects.toThrow(CHANGED)
    // A path with a "/" at the end is not the same text.
    f.rows = [stoppedRow()]
    await expect(actions.remove(S, true, counts(0, 0, `${WT}/`))).rejects.toThrow(CHANGED)
    expect(f.log).toEqual([])
    // The worktree of the row discards as before.
    await actions.remove(S, true, counts(0, 0))
    expect(f.ops('run', 'forget')).toEqual([runLine(RM), runLine(DISCARD), `0 forget ${S}`])
  })
})

describe('remove of a running worktree session with changes (final review M3)', () => {
  const ID = KEPT_SHORT_ID
  const WT = KEPT_WORKTREE
  const UNCOMMITTED = 'refused: the worktree has uncommitted changes'
  const runLine = (args: string[]) =>
    `0 run ${JSON.stringify(args)} ${JSON.stringify(args[0] === 'rm' ? RM_OPTS : RUN_OPTS)}`
  const running = () => row({ cwd: `${WT}/src`, shortId: ID })
  const seen = (changedFiles: number) => ({ changedFiles, unmergedCommits: 0, worktree: WT })

  test('remove refuses before the stop when the worktree has tracked changes', async () => {
    // claude rm refuses such a worktree. A stop first would end the turn of the session for
    // no result.
    for (const counts of [seen(2), null]) {
      f.log = []
      f.rows = [running()]
      f.tracked = () => 2
      await expect(actions.remove(S, true, counts)).rejects.toThrow(UNCOMMITTED)
      expect(f.ops()).toEqual([`0 trackedChanges ${WT}`])
    }
    // One tracked change is enough.
    f.log = []
    f.tracked = () => 1
    await expect(actions.remove(S, true, seen(1))).rejects.toThrow(UNCOMMITTED)
    expect(f.ops('run', 'forget', 'markStopped')).toEqual([])
  })

  test('untracked files alone do not block the stop, so claude rm decides', async () => {
    f.rows = [running()]
    // The dialog counted three untracked files. git tracks none of them.
    f.tracked = () => 0
    await actions.remove(S, true, seen(3))
    expect(f.ops()).toEqual([
      `0 trackedChanges ${WT}`,
      runLine(['stop', ID]),
      '0 isAlive 4242',
      runLine(['rm', ID]),
      `0 forget ${S}`,
    ])
  })

  test('a failed check does not block the stop, so claude rm decides', async () => {
    f.rows = [running()]
    f.tracked = () => null
    await actions.remove(S, true, seen(0))
    expect(f.ops('trackedChanges', 'run')).toEqual([
      `0 trackedChanges ${WT}`,
      runLine(['stop', ID]),
      runLine(['rm', ID]),
    ])
  })

  test('a parked row and a row outside a worktree get no check before the stop', async () => {
    f.tracked = () => 5
    // A parked row gets no stop. claude rm decides.
    f.rows = [parked({ cwd: '/r', shortId: ID, worktree: WT })]
    await actions.remove(S, true, seen(5))
    f.rows = [row()]
    await actions.remove(S, true)
    expect(f.ops('trackedChanges')).toEqual([])
  })
})

describe('remove waits for the end of the session process (Task 19 bugs 1 and 2)', () => {
  const stopLine = `0 run ${JSON.stringify(['stop', SHORT])} ${JSON.stringify(RUN_OPTS)}`
  const NOT_STOPPED = 'refused: the session did not stop'

  test('claude rm runs only after isAlive gives false', async () => {
    f.rows = [row()]
    let alive = true
    f.alive = () => alive
    let settled = false
    const done = actions.remove(S, true).finally(() => {
      settled = true
    })
    await vi.advanceTimersByTimeAsync(2000)
    expect(settled).toBe(false)
    expect(f.ops('run')).toEqual([stopLine])
    expect(f.ops('isAlive').length).toBeGreaterThan(10)
    alive = false
    await vi.advanceTimersByTimeAsync(END_POLL_MS)
    await done
    expect(f.ops('run', 'forget').map(l => l.split(' ').slice(1, 3).join(' '))).toEqual([
      `run ${JSON.stringify(['stop', SHORT])}`,
      `run ${JSON.stringify(['rm', SHORT])}`,
      `forget ${S}`,
    ])
  })

  test('the wait is at least 15 seconds', () => {
    expect(DELETE_END_WAIT_MS).toBeGreaterThanOrEqual(15_000)
  })

  test('a process that stays alive past the wait gives no claude rm, and releases the lock', async () => {
    f.rows = [row()]
    f.alive = () => true
    let settled = false
    const done = actions.remove(S, true).finally(() => {
      settled = true
    })
    const check = expect(done).rejects.toThrow(NOT_STOPPED)
    await vi.advanceTimersByTimeAsync(DELETE_END_WAIT_MS - 1)
    expect(settled).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    await check
    expect(f.ops('run')).toEqual([stopLine])
    expect(f.ops('forget')).toEqual([])
    // The lock is free. A second Delete starts and runs claude stop again.
    f.alive = () => false
    await actions.remove(S, true)
    expect(f.ops('run')).toHaveLength(3)
  })

  test('a session with no PID still deletes and checks no process', async () => {
    f.rows = [row({ pid: undefined })]
    await actions.remove(S, true)
    expect(f.ops('isAlive')).toEqual([])
    expect(f.ops('run', 'forget')).toHaveLength(3)
  })

  test('the worktree discard still works after the wait', async () => {
    const WT = KEPT_WORKTREE
    f.rows = [row({ cwd: `${WT}/src`, shortId: KEPT_SHORT_ID })]
    let alive = true
    f.alive = () => alive
    f.exec = args =>
      args.length === 2 && args[0] === 'rm' ? { code: 1, stderr: '', stdout: KEPT_STDOUT } : OK
    f.check = () => ({
      branch: 'worktree-bifrost-test-rmx',
      changedFiles: 0,
      head: KEPT_HEAD,
      unmergedCommits: 1,
      worktree: WT,
    })
    const done = actions.remove(S, true, { changedFiles: 0, unmergedCommits: 1, worktree: WT })
    await vi.advanceTimersByTimeAsync(1000)
    // The re-check of the worktree waits for the end of the process.
    expect(f.ops('checkWorktree')).toEqual([])
    alive = false
    await vi.advanceTimersByTimeAsync(END_POLL_MS)
    await done
    expect(f.ops('checkWorktree')).toHaveLength(1)
    const runs = f.ops('run').map(l => JSON.parse(l.split(' ')[2]) as string[])
    expect(runs).toEqual([
      ['stop', KEPT_SHORT_ID],
      ['rm', KEPT_SHORT_ID],
      ['rm', KEPT_SHORT_ID, '--discard-unpushed', KEPT_DISCARD],
    ])
    expect(f.ops('forget')).toEqual([`${Date.now() - f.base} forget ${S}`])
  })
})

describe('resume', () => {
  test('resume runs claude --bg --resume with the session ID in the cwd and waits for the entry', async () => {
    f.rows = [parked()]
    f.exec = () => ({ code: 0, stderr: '', stdout: `backgrounded · ${SHORT}` })
    f.appear = [
      parked(),
      row({ kind: 'external' }),
      row({ pid: undefined }),
      row({ sessionId: S2 }),
      row({ pid: 5151 }),
    ]
    await actions.resume(S)
    expect(f.ops()).toEqual([
      '0 dirInfo /p',
      `0 run ${JSON.stringify(expectedResume(S))} ${JSON.stringify(IN_P)}`,
      `0 waitForRow ${START_TIMEOUT_MS}`,
      `0 markStarted ${S}`,
    ])
  })

  test('resume refuses a row that is not parked', async () => {
    for (const r of [row(), row({ state: 'working' }), external()]) {
      f.rows = [r]
      await expect(actions.resume(S)).rejects.toThrow('refused: the session is not parked')
    }
    expect(f.ops('run')).toEqual([])
  })

  test('resume refuses a missing directory and a bad session ID', async () => {
    f.rows = [parked({ cwd: '' })]
    await expect(actions.resume(S)).rejects.toThrow(
      "Bifrost doesn't know the project folder of this session.",
    )
    f.rows = [parked()]
    f.dir = { git: false, kind: 'missing' }
    await expect(actions.resume(S)).rejects.toThrow("The folder /p doesn't exist.")
    f.dir = { git: false, kind: 'dir' }
    f.rows = [parked({ resumeId: 'abc', sessionId: 'abc' })]
    await expect(actions.resume('abc')).rejects.toThrow('refused: bad session ID')
    expect(f.ops('run')).toEqual([])
  })

  test('resume shows the trust error and the timeout, and does not mark the session', async () => {
    f.rows = [parked()]
    f.exec = () => ({ code: 1, stderr: TRUST, stdout: '' })
    await expect(actions.resume(S)).rejects.toThrow(trustMessage('/p'))
    f.exec = () => OK
    const done = actions.resume(S)
    const check = expect(done).rejects.toThrow(NOT_RESUMED)
    await vi.advanceTimersByTimeAsync(START_TIMEOUT_MS)
    await check
    expect(f.ops('markStarted')).toEqual([])
  })
})

describe('resumeAll', () => {
  test('resumeAll resumes only the resumable parked rows, one after the other', async () => {
    f.rows = [
      parked({ name: 'a1', resumable: true }),
      parked({ name: 'b', sessionId: S2 }),
      row({ name: 'c', resumable: true, sessionId: S3 }),
      parked({ cwd: '/q', name: 'a2', resumable: true, sessionId: S4 }),
    ]
    f.exec = f.slow(1000)
    f.appear = [row(), row({ cwd: '/q', sessionId: S4 })]
    const done = actions.resumeAll()
    await vi.advanceTimersByTimeAsync(2000)
    await expect(done).resolves.toEqual({ failed: [], resumed: 2 })
    expect(f.ops()).toEqual([
      '0 dirInfo /p',
      `0 run ${JSON.stringify(expectedResume(S))} ${JSON.stringify(IN_P)}`,
      `1000 end ${JSON.stringify(expectedResume(S))}`,
      '1000 dirInfo /q',
      `1000 run ${JSON.stringify(expectedResume(S4))} ${JSON.stringify({ cwd: '/q', timeoutMs: RUN_TIMEOUT_MS })}`,
      `2000 end ${JSON.stringify(expectedResume(S4))}`,
      `2000 waitForRow ${START_TIMEOUT_MS}`,
      `2000 waitForRow ${START_TIMEOUT_MS}`,
      `2000 markStarted ${S}`,
      `2000 markStarted ${S4}`,
    ])
  })

  test('resumeAll gives each failure with the row name', async () => {
    f.rows = [
      parked({ cwd: '/gone', name: 'a1', resumable: true }),
      parked({ name: 'a2', resumable: true, sessionId: S2 }),
      parked({ name: 'a3', resumable: true, sessionId: S3 }),
      parked({ name: 'a4', resumable: true, sessionId: S4 }),
    ]
    const deps = f.deps()
    actions = createSessionActions({
      ...deps,
      dirInfo: async dir => (dir === '/gone' ? { git: false, kind: 'missing' } : f.dir),
    })
    f.exec = args => (args.at(-1) === S2 ? { code: 1, stderr: TRUST, stdout: '' } : OK)
    f.appear = [row({ sessionId: S4 })]
    const done = actions.resumeAll()
    await vi.advanceTimersByTimeAsync(START_TIMEOUT_MS)
    await expect(done).resolves.toEqual({
      failed: [
        { error: "The folder /gone doesn't exist.", name: 'a1' },
        { error: trustMessage('/p'), name: 'a2' },
        { error: NOT_RESUMED, name: 'a3' },
      ],
      resumed: 1,
    })
    // Each session is marked when its entry shows, not after the last wait.
    expect(f.ops('markStarted')).toEqual([`0 markStarted ${S4}`])
  })

  test('resumeAll does not resume a candidate that runs again during an earlier resume', async () => {
    f.rows = [
      parked({ name: 'a1', resumable: true }),
      parked({ name: 'a2', resumable: true, sessionId: S2 }),
    ]
    // During the first resume, the registry shows that a2 runs again.
    f.exec = () => {
      f.rows = [parked({ name: 'a1', resumable: true }), row({ name: 'a2', sessionId: S2 })]
      return OK
    }
    f.appear = [row()]
    await expect(actions.resumeAll()).resolves.toEqual({
      failed: [{ error: 'refused: the session is not parked', name: 'a2' }],
      resumed: 1,
    })
    expect(f.ops('run')).toHaveLength(1)
  })

  test('resumeAll with no candidate does nothing', async () => {
    f.rows = [parked(), row({ resumable: true, sessionId: S2 })]
    await expect(actions.resumeAll()).resolves.toEqual({ failed: [], resumed: 0 })
    expect(f.log).toEqual([])
  })

  test('one Resume all runs at a time, and it holds the lock of each session', async () => {
    f.rows = [
      parked({ name: 'a1', resumable: true }),
      parked({ name: 'a2', resumable: true, sessionId: S2 }),
    ]
    f.exec = f.slow(1000)
    f.appear = [row(), row({ sessionId: S2 })]
    const done = actions.resumeAll()
    await vi.advanceTimersByTimeAsync(0)
    await expect(actions.resumeAll()).rejects.toThrow('refused: Resume all runs')
    await expect(actions.resume(S)).rejects.toThrow(LOCKED)
    await expect(actions.remove(S, true)).rejects.toThrow(LOCKED)
    await vi.advanceTimersByTimeAsync(2000)
    await expect(done).resolves.toEqual({ failed: [], resumed: 2 })
    // After the end, the locks are free again.
    f.rows = [row()]
    f.exec = () => OK
    await expect(actions.stop(S)).resolves.toBeUndefined()
  })

  test('resumeAll skips a session that has a running action', async () => {
    f.rows = [
      parked({ name: 'a1', resumable: true }),
      parked({ name: 'a2', resumable: true, sessionId: S2 }),
    ]
    f.exec = args => (args[0] === 'rm' ? f.slow(1000)(args) : OK)
    f.appear = [row({ sessionId: S2 })]
    const removing = actions.remove(S, true)
    await expect(actions.resumeAll()).resolves.toEqual({
      failed: [{ error: LOCKED, name: 'a1' }],
      resumed: 1,
    })
    await vi.advanceTimersByTimeAsync(1000)
    await removing
    expect(f.ops('run').map(line => line.split(' ')[2])).toEqual([
      JSON.stringify(['rm', SHORT]),
      JSON.stringify(expectedResume(S2)),
    ])
  })
})

describe('takeControl', () => {
  test('a failed SIGTERM gives a friendly text without the Node error (final review M5)', async () => {
    f.rows = [external()]
    f.onSignal = () => {
      throw new Error('kill EPERM')
    }
    const error = await actions.takeControl(S, true).catch((e: Error) => e)
    expect((error as Error).message).toBe("Bifrost couldn't stop the terminal session. Try again.")
    expect(f.ops('markStarted', 'run')).toEqual([])
  })

  test('takeControl sends SIGTERM, waits for the end, resumes in the cwd and checks the new process', async () => {
    f.rows = [external()]
    f.alive = pid => pid === 5151 || Date.now() - f.base < 300
    f.appear = [external({ pid: 5151 }), row({ pid: 5151 })]
    let settled = false
    const done = actions.takeControl(S, true).finally(() => {
      settled = true
    })
    await vi.advanceTimersByTimeAsync(300 + RESUME_SETTLE_MS - 1)
    expect(settled).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    await expect(done).resolves.toEqual({ sessionId: S })
    expect(f.ops()).toEqual([
      '0 dirInfo /p',
      `0 hasMessages ${S}`,
      '0 processName 4242',
      '0 signal 4242 SIGTERM',
      '0 isAlive 4242',
      '100 isAlive 4242',
      '200 isAlive 4242',
      '300 isAlive 4242',
      `300 markStarted ${S}`,
      `300 run ${JSON.stringify(expectedTakeControl(S))} ${JSON.stringify(IN_P)}`,
      `300 waitForRow ${START_TIMEOUT_MS}`,
      `${300 + RESUME_SETTLE_MS} isAlive 5151`,
    ])
  })

  test('takeControl accepts a yellow box', async () => {
    f.rows = [external({ box: 'yellow', state: 'needs-you', status: 'waiting' })]
    f.appear = [row({ pid: 5151 })]
    f.alive = pid => pid === 5151
    const done = actions.takeControl(S, true)
    await vi.advanceTimersByTimeAsync(RESUME_SETTLE_MS)
    await expect(done).resolves.toEqual({ sessionId: S })
    expect(f.ops('signal')).toEqual(['0 signal 4242 SIGTERM'])
  })

  test('takeControl refuses a session with no messages and sends no signal', async () => {
    // Claude Code cannot resume a session without a user message (Task 10 bug 3).
    f.rows = [external()]
    f.messages = false
    await expect(actions.takeControl(S, true)).rejects.toThrow(
      'refused: the session has no messages yet',
    )
    expect(f.ops('hasMessages')).toEqual([`0 hasMessages ${S}`])
    expect(f.ops('signal', 'processName', 'markStarted', 'run')).toEqual([])
  })

  test('takeControl rejects when the resumed session parks before it runs', async () => {
    // The resumed job gets a process, and then it ends at once (Task 10 bug 3).
    f.rows = [external()]
    f.appear = [row({ pid: 5151 })]
    f.alive = pid => pid === 5151
    const done = actions.takeControl(S, true)
    const check = expect(done).rejects.toThrow(
      `Claude Code could not resume this session. Run claude logs ${SHORT} to see the cause.`,
    )
    await vi.advanceTimersByTimeAsync(1000)
    f.rows = [parked()]
    await vi.advanceTimersByTimeAsync(RESUME_SETTLE_MS - 1000)
    await check
    expect(f.ops('signal', 'markStarted')).toEqual(['0 signal 4242 SIGTERM', `0 markStarted ${S}`])
  })

  test('takeControl rejects when the process of the resumed session ends', async () => {
    f.rows = [external()]
    f.appear = [row({ pid: 5151 })]
    f.alive = () => false
    const done = actions.takeControl(S, true)
    const check = expect(done).rejects.toThrow('Claude Code could not resume this session.')
    await vi.advanceTimersByTimeAsync(RESUME_SETTLE_MS)
    await check
    expect(f.ops('isAlive').at(-1)).toBe(`${RESUME_SETTLE_MS} isAlive 5151`)
    // A row without a short ID gives no claude logs hint.
    f.log = []
    f.rows = [external()]
    f.appear = [row({ pid: 5151, shortId: undefined })]
    const next = actions.takeControl(S, true)
    const nextCheck = expect(next).rejects.toThrow(/^Claude Code could not resume this session\.$/)
    await vi.advanceTimersByTimeAsync(RESUME_SETTLE_MS)
    await nextCheck
  })

  test('takeControl starts no copy when the process does not end in 5 seconds', async () => {
    f.rows = [external()]
    f.alive = () => true
    let settled = false
    const done = actions.takeControl(S, true).finally(() => {
      settled = true
    })
    const check = expect(done).rejects.toThrow(NOT_ENDED)
    await vi.advanceTimersByTimeAsync(END_WAIT_MS - 1)
    expect(settled).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    await check
    expect(f.ops('signal')).toEqual(['0 signal 4242 SIGTERM'])
    expect(f.ops('isAlive')).toHaveLength(END_WAIT_MS / END_POLL_MS + 1)
    expect(f.ops('run', 'markStarted', 'waitForRow')).toEqual([])
  })

  test('takeControl refuses a working row, a red box, an owned row and a process that is not claude', async () => {
    const cases: [SessionRow[], string][] = [
      [[external({ state: 'working', status: 'busy' })], 'refused: the session is working'],
      [
        [external({ box: 'red', boxReason: 'prompt', state: 'needs-you', status: 'waiting' })],
        'refused: the session has an open prompt',
      ],
      [[external({ box: 'none', state: 'needs-you' })], 'refused: the session is not idle'],
      [[external({ state: 'error' })], 'refused: the session is not idle'],
      [[row()], 'refused: only an external session'],
      [[external({ state: 'parked' })], 'refused: only an external session'],
      [[external({ pid: undefined })], 'refused: the session has no process ID'],
      [[external({ sessionId: 'abc' })], 'refused: bad session ID'],
      [[external({ cwd: 'p' })], "The folder p doesn't exist."],
      [[external({ cwd: '' })], "Bifrost doesn't know the project folder of this session."],
      // 0 and -1 signal a process group or all processes of the user. 1 is launchd.
      [[external({ pid: 0 })], 'refused: bad process ID'],
      [[external({ pid: -1 })], 'refused: bad process ID'],
      [[external({ pid: 1 })], 'refused: bad process ID'],
      [[external({ pid: 1.5 })], 'refused: bad process ID'],
    ]
    for (const [rows, reason] of cases) {
      f.rows = rows
      await expect(actions.takeControl(rows[0].sessionId, true)).rejects.toThrow(reason)
    }
    f.rows = [external()]
    await expect(actions.takeControl(S2, true)).rejects.toThrow('refused: unknown session')
    await expect(actions.takeControl(null, true)).rejects.toThrow('refused: unknown session')
    for (const name of ['/usr/bin/node', 'claude-helper', '/x/claude/node', '', null]) {
      f.name = name
      await expect(actions.takeControl(S, true)).rejects.toThrow(
        'refused: process 4242 is not a claude process',
      )
    }
    f.name = 'claude'
    f.dir = { git: false, kind: 'missing' }
    await expect(actions.takeControl(S, true)).rejects.toThrow("The folder /p doesn't exist.")
    f.dir = { git: false, kind: 'dir' }
    f.claude = false
    await expect(actions.takeControl(S, true)).rejects.toThrow('claude not found')
    expect(f.ops('signal', 'markStarted', 'run')).toEqual([])
  })

  test('takeControl sends no signal when the PID changes or another row has the PID', async () => {
    f.rows = [external()]
    // The registry gives a new PID during the name read.
    f.onProcessName = () => {
      f.rows = [external({ pid: 5151 })]
    }
    await expect(actions.takeControl(S, true)).rejects.toThrow(
      'refused: the session process changed',
    )
    // An owned row has the same PID.
    f.onProcessName = () => {}
    f.rows = [external(), row({ sessionId: S2 })]
    await expect(actions.takeControl(S, true)).rejects.toThrow(
      'refused: the session process changed',
    )
    // The session starts to work during the name read.
    f.rows = [external()]
    f.onProcessName = () => {
      f.rows = [external({ state: 'working', status: 'busy' })]
    }
    await expect(actions.takeControl(S, true)).rejects.toThrow('refused: the session is working')
    // The row goes away during the name read.
    f.rows = [external()]
    f.onProcessName = () => {
      f.rows = []
    }
    await expect(actions.takeControl(S, true)).rejects.toThrow(
      'refused: the session process changed',
    )
    expect(f.ops('signal')).toEqual([])
  })

  test('takeControl marks the session as started when the resume fails', async () => {
    f.rows = [external()]
    f.exec = () => ({ code: 1, stderr: 'resume failed', stdout: '' })
    await expect(actions.takeControl(S, true)).rejects.toThrow('resume failed')
    expect(f.ops('signal', 'markStarted')).toEqual(['0 signal 4242 SIGTERM', `0 markStarted ${S}`])
  })

  test('takeControl needs the confirmation', async () => {
    f.rows = [external()]
    for (const confirmed of [undefined, false, 'true', 1]) {
      await expect(actions.takeControl(S, confirmed)).rejects.toThrow(
        'refused: Take control needs a confirmation',
      )
    }
    expect(f.log).toEqual([])
    // A refused call does not hold the lock.
    f.appear = [row({ pid: 5151 })]
    f.alive = pid => pid === 5151
    const done = actions.takeControl(S, true)
    await vi.advanceTimersByTimeAsync(RESUME_SETTLE_MS)
    await expect(done).resolves.toEqual({ sessionId: S })
  })

  test('Resume and Resume all pass no extra flag, Take control passes the statusline override', async () => {
    // A resume with a new flag on a background session starts a copy with a new session ID.
    // Take control starts from a foreground session, so the override keeps the same ID (D13).
    f.appear = [row()]
    f.rows = [parked({ resumable: true })]
    await actions.resume(S)
    // The resumed row runs now. Resume all needs it parked again.
    f.rows = [parked({ resumable: true })]
    await actions.resumeAll()
    f.rows = [external()]
    f.appear = [row({ pid: 5151 })]
    f.alive = pid => pid === 5151
    const done = actions.takeControl(S, true)
    await vi.advanceTimersByTimeAsync(RESUME_SETTLE_MS)
    await done
    const runs = f.ops('run').map(line => line.split(' ')[2])
    expect(runs).toEqual([
      JSON.stringify(expectedResume(S)),
      JSON.stringify(expectedResume(S)),
      JSON.stringify(expectedTakeControl(S)),
    ])
  })
})

describe('locks and dirInfo', () => {
  test('one action at a time runs for each session', async () => {
    f.rows = [row(), row({ sessionId: S2, shortId: '1234abcd' })]
    f.exec = f.slow(1000)
    const first = actions.stop(S)
    await expect(actions.stop(S)).rejects.toThrow(LOCKED)
    await expect(actions.remove(S, true)).rejects.toThrow(LOCKED)
    // Another session is free.
    const other = actions.stop(S2)
    await vi.advanceTimersByTimeAsync(1000)
    await first
    await other
    // After the end, the lock is free again.
    const again = actions.stop(S)
    await vi.advanceTimersByTimeAsync(1000)
    await expect(again).resolves.toBeUndefined()
    expect(f.ops('markStopped')).toEqual([
      `1000 markStopped ${S}`,
      `1000 markStopped ${S2}`,
      `2000 markStopped ${S}`,
    ])
  })

  test('a failed action frees the lock', async () => {
    f.rows = [external()]
    await expect(actions.stop(S)).rejects.toThrow('refused: only an owned session that runs')
    f.rows = [row()]
    await expect(actions.stop(S)).resolves.toBeUndefined()
  })

  test('dirInfo reads only an absolute path', async () => {
    await expect(actions.dirInfo(7)).resolves.toEqual({ git: false, kind: 'missing' })
    await expect(actions.dirInfo('p')).resolves.toEqual({ git: false, kind: 'missing' })
    expect(f.log).toEqual([])
    await expect(actions.dirInfo('/p')).resolves.toEqual({ git: true, kind: 'dir' })
    expect(f.ops()).toEqual(['0 dirInfo /p'])
  })
})

describe('the ID of each command after a /clear (2026-11-06)', () => {
  // The row ID is S. A /clear made S2 the current ID. S3 is the original ID of the job, which
  // starts with its short ID.
  test('Resume passes the resume ID of an owned row, not the row ID or the current ID', () => {
    expect(resumeArgs({ currentId: S2, kind: 'owned', resumeId: S3, sessionId: S })).toEqual(
      expectedResume(S3),
    )
  })

  test('Resume of a parked external row passes the current ID with the Take control flags', () => {
    expect(resumeArgs({ currentId: S2, kind: 'external', sessionId: S })).toEqual(
      expectedTakeControl(S2),
    )
  })

  test('Resume refuses an owned row whose resume ID Bifrost does not know yet', async () => {
    expect(() => resumeArgs({ currentId: S2, kind: 'owned', sessionId: S })).toThrow(
      'refused: the ID that resumes this session is not known yet',
    )
    f.rows = [parked({ currentId: S2, resumeId: undefined })]
    await expect(actions.resume(S)).rejects.toThrow(
      'refused: the ID that resumes this session is not known yet',
    )
    expect(f.ops('run')).toEqual([])
  })

  test('Resume after /clear and stop passes the original ID and waits for the row ID', async () => {
    f.rows = [parked({ currentId: S2, resumeId: S3 })]
    f.appear = [row({ currentId: S2, pid: 5151, resumeId: S3 })]
    await actions.resume(S)
    expect(f.ops('run', 'markStarted')).toEqual([
      `0 run ${JSON.stringify(expectedResume(S3))} ${JSON.stringify(IN_P)}`,
      `0 markStarted ${S}`,
    ])
  })

  test('Resume all passes the original ID of each job', async () => {
    f.rows = [parked({ currentId: S2, resumable: true, resumeId: S3 })]
    f.appear = [row({ currentId: S2, pid: 5151, resumeId: S3 })]
    await expect(actions.resumeAll()).resolves.toEqual({ failed: [], resumed: 1 })
    expect(f.ops('run')).toEqual([
      `0 run ${JSON.stringify(expectedResume(S3))} ${JSON.stringify(IN_P)}`,
    ])
  })

  test('Resume refuses a resume ID that is not a UUID', async () => {
    f.rows = [parked({ resumeId: 'abc' })]
    await expect(actions.resume(S)).rejects.toThrow('refused: bad session ID')
    expect(f.ops('run')).toEqual([])
  })

  test('Take control after an interactive /clear resumes the current ID', async () => {
    f.rows = [external({ currentId: S2 })]
    f.alive = pid => pid === 5151
    f.appear = [row({ currentId: S2, pid: 5151 })]
    const done = actions.takeControl(S, true)
    await vi.advanceTimersByTimeAsync(RESUME_SETTLE_MS)
    await expect(done).resolves.toEqual({ sessionId: S })
    expect(f.ops('hasMessages', 'markStarted', 'run')).toEqual([
      `0 hasMessages ${S2}`,
      `0 markStarted ${S}`,
      `0 run ${JSON.stringify(expectedTakeControl(S2))} ${JSON.stringify(IN_P)}`,
    ])
  })

  test('Take control refuses when a /clear changes the current ID during the checks', async () => {
    f.rows = [external()]
    f.onProcessName = () => {
      f.rows = [external({ currentId: S2 })]
    }
    await expect(actions.takeControl(S, true)).rejects.toThrow(
      'refused: the session process changed',
    )
    expect(f.ops('signal', 'run')).toEqual([])
  })

  test('Take control refuses a current ID that is not a UUID', async () => {
    f.rows = [external({ currentId: 'abc' })]
    await expect(actions.takeControl(S, true)).rejects.toThrow('refused: bad session ID')
    expect(f.ops('hasMessages', 'signal')).toEqual([])
  })

  test('Stop and Delete use the short ID, which a /clear does not change', async () => {
    f.rows = [row({ currentId: S2, resumeId: S3 })]
    await actions.stop(S)
    f.rows = [parked({ currentId: S2, resumeId: S3 })]
    await actions.remove(S, true, null)
    expect(f.ops('run', 'forget')).toEqual([
      `0 run ${JSON.stringify(['stop', SHORT])} ${JSON.stringify(RUN_OPTS)}`,
      `0 run ${JSON.stringify(['rm', SHORT])} ${JSON.stringify(RM_OPTS)}`,
      `0 forget ${S}`,
    ])
  })
})
