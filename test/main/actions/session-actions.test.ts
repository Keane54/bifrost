import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import { trustMessage } from '../../../src/main/actions/claude-output'
import {
  createSessionActions,
  END_POLL_MS,
  END_WAIT_MS,
  newSessionArgs,
  RUN_TIMEOUT_MS,
  type SessionActionDeps,
  START_TIMEOUT_MS,
} from '../../../src/main/actions/session-actions'
import type { ExecResult } from '../../../src/main/claude/cli'
import {
  type DirInfo,
  type NewSessionSpec,
  REASON_PROMPT_IS_COMMAND,
} from '../../../src/shared/new-session'
import type { SessionRow } from '../../../src/shared/types'

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
  row({ kind: 'external', shortId: undefined, ...o })

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
      dirInfo: async dir => {
        this.add('dirInfo', dir)
        return this.dir
      },
      forget: id => this.add('forget', id),
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
      rows: () => this.rows,
      run: async () => {
        if (!this.claude) return null
        return async (args, opts) => {
          this.add('run', args, opts)
          return this.exec(args)
        }
      },
      signal: (pid, signal) => this.add('signal', pid, signal),
      waitForRow: (match, timeoutMs) => {
        this.add('waitForRow', timeoutMs)
        const found = this.appear.find(match)
        if (found) return Promise.resolve(found)
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
      `0 run ${JSON.stringify(['rm', SHORT])} ${JSON.stringify(RUN_OPTS)}`,
      `0 forget ${S}`,
    ])
  })

  test('remove of a parked row runs only claude rm', async () => {
    f.rows = [parked()]
    await actions.remove(S, true)
    expect(f.ops()).toEqual([
      `0 run ${JSON.stringify(['rm', SHORT])} ${JSON.stringify(RUN_OPTS)}`,
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
      `0 run ${JSON.stringify(['--bg', '--resume', S])} ${JSON.stringify(IN_P)}`,
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
    f.rows = [parked({ sessionId: 'abc' })]
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
      `0 run ${JSON.stringify(['--bg', '--resume', S])} ${JSON.stringify(IN_P)}`,
      `1000 end ${JSON.stringify(['--bg', '--resume', S])}`,
      '1000 dirInfo /q',
      `1000 run ${JSON.stringify(['--bg', '--resume', S4])} ${JSON.stringify({ cwd: '/q', timeoutMs: RUN_TIMEOUT_MS })}`,
      `2000 end ${JSON.stringify(['--bg', '--resume', S4])}`,
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
    f.exec = args => (args[2] === S2 ? { code: 1, stderr: TRUST, stdout: '' } : OK)
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
      JSON.stringify(['--bg', '--resume', S2]),
    ])
  })
})

describe('takeControl', () => {
  test('takeControl sends SIGTERM, waits for the end and resumes in the cwd', async () => {
    f.rows = [external()]
    f.alive = () => Date.now() - f.base < 300
    f.appear = [external({ pid: 5151 }), row({ pid: 5151 })]
    const done = actions.takeControl(S, true)
    await vi.advanceTimersByTimeAsync(300)
    await expect(done).resolves.toEqual({ sessionId: S })
    expect(f.ops()).toEqual([
      '0 dirInfo /p',
      '0 processName 4242',
      '0 signal 4242 SIGTERM',
      '0 isAlive 4242',
      '100 isAlive 4242',
      '200 isAlive 4242',
      '300 isAlive 4242',
      `300 markStarted ${S}`,
      `300 run ${JSON.stringify(['--bg', '--resume', S])} ${JSON.stringify(IN_P)}`,
      `300 waitForRow ${START_TIMEOUT_MS}`,
    ])
  })

  test('takeControl accepts a yellow box', async () => {
    f.rows = [external({ box: 'yellow', state: 'needs-you', status: 'waiting' })]
    f.appear = [row()]
    await expect(actions.takeControl(S, true)).resolves.toEqual({ sessionId: S })
    expect(f.ops('signal')).toEqual(['0 signal 4242 SIGTERM'])
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
    f.appear = [row()]
    await expect(actions.takeControl(S, true)).resolves.toEqual({ sessionId: S })
  })

  test('resume, Resume all and Take control pass no extra flags', async () => {
    // A resume with a new flag starts a copy with a new session ID (controller ruling).
    f.appear = [row()]
    f.rows = [parked({ resumable: true })]
    await actions.resume(S)
    await actions.resumeAll()
    f.rows = [external()]
    await actions.takeControl(S, true)
    const runs = f.ops('run').map(line => line.split(' ')[2])
    expect(runs).toEqual(Array(3).fill(JSON.stringify(['--bg', '--resume', S])))
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
