// The module jobs of the modules (plan Task 7, Modules design 8.5). A fake runner takes the place
// of claude. The state store is real and writes to a temporary folder.
import { lstat, mkdir, mkdtemp, readdir, rm, stat, symlink, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ExecResult } from '../../../src/main/claude/cli'
import type { JobRunOptions, RunClaudeJob } from '../../../src/main/claude/job-runner'
import { createHeimdall } from '../../../src/main/modules/heimdall'
import {
  createJobs,
  JOB_HEADER,
  JOB_INPUT_MAX,
  JOB_PROMPT_MAX,
  JOB_TIMEOUT_MS,
  JOB_WAIT_MS,
  JOBS_AT_ONCE,
  type JobsDeps,
  jobArgs,
  moduleJobsRoot,
  watchLocalDay,
} from '../../../src/main/modules/jobs'
import { createModuleDataStore } from '../../../src/main/modules/module-data'
import {
  type ModuleEntry,
  type ModulesState,
  type ModulesStateStore,
  openModulesStateStore,
} from '../../../src/main/modules/module-state'
import { createBridge } from '../../../src/renderer/src/modules/bridge'
import type { PermissionId } from '../../../src/shared/module-manifest'
import type { ModelChoice } from '../../../src/shared/new-session'

const CAP = 'refused: daily job cap reached'
const CANCELLED = 'refused: job cancelled'
const TOO_LONG = 'refused: the job took too long'
const FAILED = 'refused: the job failed'
const NOT_JSON = 'refused: the job result is not JSON'
const BAD = 'refused: bad module input'
const OFF = 'refused: module off'
const NOT_ALLOWED = 'refused: not allowed for this module'

// A fake token. The test builds it from parts.
const TOKEN = `ghp_${'A1b2C3d4E5f6G7h8I9j0'}`

// The argument list of Spike B (findings-job.md), with --no-session-persistence,
// --disable-slash-commands and the settings of ruling S-A10, and the model haiku.
const SPIKE_ARGS = [
  '-p',
  '--no-session-persistence',
  '--disable-slash-commands',
  '--output-format',
  'json',
  '--tools',
  '',
  '--strict-mcp-config',
  '--mcp-config',
  '{"mcpServers":{}}',
  '--setting-sources',
  '',
  '--settings',
  '{"disableAllHooks":true,"autoMemoryEnabled":false,"disableSkillShellExecution":true}',
  '--permission-mode',
  'dontAsk',
  '--model',
  'haiku',
]

const JOBS: PermissionId[] = ['claude-jobs']
const AUTO: PermissionId[] = ['claude-jobs', 'claude-jobs-auto']

// 2026-11-13 at 10:00 and 2026-11-14 just after midnight, in local time.
const DAY_ONE = new Date(2026, 10, 13, 10, 0).getTime()
const DAY_TWO = new Date(2026, 10, 14, 0, 0, 1).getTime()

function entry(id: string, granted: PermissionId[], extra: Partial<ModuleEntry> = {}): ModuleEntry {
  return {
    dailyCap: 10,
    enabled: true,
    granted,
    hash: 'a'.repeat(64),
    jobs: { count: 0, day: '' },
    manifest: {
      description: 'A test.',
      id,
      minBifrost: '0.1.0',
      name: `Module ${id}`,
      panels: [{ entry: 'panels/main.html', icon: 'bell', id: 'main', title: 'Main' }],
      permissions: AUTO.map(p => ({ id: p, reason: 'For the test.' })),
      suggests: { dailyCap: null, model: null },
      version: '1.0.0',
    },
    model: 'haiku',
    pendingUpdate: null,
    source: { kind: 'folder', path: `/src/${id}` },
    ...extra,
  }
}

// The stdout of a good claude -p run with --output-format json.
function claudeOutput(result: string): ExecResult {
  return {
    code: 0,
    stderr: '',
    stdout: JSON.stringify({ is_error: false, result, subtype: 'success', type: 'result' }),
  }
}

interface RunnerCall {
  args: string[]
  opts: JobRunOptions
  // The stdin text after the Bifrost line and the blank line.
  body: string
  // The files in the job folder when the run starts.
  files: string[]
  finish(result: ExecResult): void
}

// A fake runner. By default each run ends at once with the answer. After hold(), each run waits
// for finish(). An abort ends a run as execFile does. Each run writes a file in its folder, as
// claude can.
function fakeRunner() {
  const calls: RunnerCall[] = []
  let answer: ExecResult | null = claudeOutput('done')
  const run: RunClaudeJob = async (args, opts) => {
    const files = await readdir(opts.cwd)
    await writeFile(join(opts.cwd, 'left.txt'), 'x')
    return new Promise<ExecResult>(resolve => {
      const head = `${JOB_HEADER}\n\n`
      const body = opts.input.startsWith(head) ? opts.input.slice(head.length) : '(no Bifrost line)'
      calls.push({ args, body, files, finish: resolve, opts })
      opts.signal.addEventListener('abort', () =>
        resolve({ aborted: true, code: 1, stderr: '', stdout: '' }),
      )
      if (answer !== null) resolve(answer)
    })
  }
  return {
    answer: (next: ExecResult) => {
      answer = next
    },
    calls,
    hold: () => {
      answer = null
    },
    run,
  }
}

// Wait until the condition holds. Each step lets the file system and the promises run.
async function until(condition: () => boolean): Promise<void> {
  for (let i = 0; i < 5000; i += 1) {
    if (condition()) return
    await new Promise(resolve => setImmediate(resolve))
  }
  throw new Error('The condition did not hold.')
}

let root = ''
// The stop of each jobs service of a test. Each test ends with no job left.
const stops: (() => void)[] = []

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'bifrost-jobs-test-'))
})

afterEach(async () => {
  for (const stop of stops.splice(0)) stop()
  vi.useRealTimers()
  // stop() aborts a running job, and that job empties its own folder later. So this remove can
  // meet a folder that is not empty yet (ENOTEMPTY). rm tries again for that error.
  await rm(root, { force: true, maxRetries: 10, recursive: true, retryDelay: 20 })
})

async function setup(
  modules: Record<string, ModuleEntry>,
  over: Partial<JobsDeps> = {},
  wrap: (store: ModulesStateStore) => JobsDeps['store'] = store => store,
) {
  const store: ModulesStateStore = await openModulesStateStore(join(root, 'modules', 'state.json'))
  await store.change(() => ({ modules }))
  // The jobs make this folder, in the system temp folder of the test.
  const jobRoot = moduleJobsRoot(join(root, 'temp'))
  let now = DAY_ONE
  let changes = 0
  const runner = fakeRunner()
  const events: unknown[] = []
  const logs: string[] = []
  const deps: JobsDeps = {
    changed: () => {
      changes += 1
    },
    devAllowed: true,
    emit: (moduleId, event, data) => events.push({ data, event, moduleId }),
    jobsRoot: jobRoot,
    log: message => logs.push(message),
    now: () => now,
    runner: async () => runner.run,
    store: wrap(store),
    ...over,
  }
  const jobs = createJobs(deps)
  stops.push(() => jobs.stop())
  return {
    changes: () => changes,
    events,
    jobRoot,
    jobs,
    logs,
    runner,
    setNow: (time: number) => {
      now = time
    },
    store,
  }
}

describe('jobArgs', () => {
  it('gives the argument list of Spike B: no tools, no MCP servers, no hooks', () => {
    expect(jobArgs('haiku')).toEqual(SPIKE_ARGS)
    expect(jobArgs('opus').slice(-2)).toEqual(['--model', 'opus'])
  })

  it('refuses a model that is not a model choice', () => {
    for (const bad of ['--tools', 'opus --x', 'gpt', ' haiku', 'HAIKU']) {
      expect(() => jobArgs(bad as ModelChoice), bad).toThrow()
    }
  })

  it('puts the job folders in the system temp folder', () => {
    expect(moduleJobsRoot('/tmp/T')).toBe('/tmp/T/bifrost-module-jobs')
  })

  it('gives no model flag for the default model of Claude Code', () => {
    expect(jobArgs('')).toEqual(SPIKE_ARGS.slice(0, -2))
  })
})

describe('the run mode', () => {
  it('runs a job at once with claude-jobs-auto', async () => {
    const t = await setup({ demo: entry('demo', AUTO) })
    await expect(t.jobs.run('demo', { prompt: 'Say hi' })).resolves.toEqual({ text: 'done' })
    expect(t.runner.calls).toHaveLength(1)
    expect(t.jobs.waiting('demo')).toBe(0)
  })

  it('keeps a job waiting without claude-jobs-auto, and runs it on refresh', async () => {
    const t = await setup({ demo: entry('demo', JOBS) })
    let settled = false
    const job = t.jobs.run('demo', { prompt: 'Say hi' }).finally(() => {
      settled = true
    })
    await until(() => t.jobs.waiting('demo') === 1)
    // Let the file system and the promises run. The job still waits.
    for (let i = 0; i < 50; i += 1) await new Promise(resolve => setImmediate(resolve))
    expect(t.runner.calls).toHaveLength(0)
    expect(settled).toBe(false)
    expect(t.changes()).toBe(1)
    t.jobs.refresh('demo')
    expect(t.jobs.waiting('demo')).toBe(0)
    expect(t.changes()).toBe(2)
    await expect(job).resolves.toEqual({ text: 'done' })
    expect(t.runner.calls).toHaveLength(1)
  })

  it('sends the refresh event on refresh, in both modes', async () => {
    const t = await setup({ auto: entry('auto', AUTO), demo: entry('demo', JOBS) })
    t.jobs.refresh('demo')
    t.jobs.refresh('auto')
    expect(t.events).toEqual([
      { data: null, event: 'refresh', moduleId: 'demo' },
      { data: null, event: 'refresh', moduleId: 'auto' },
    ])
  })

  it('runs on refresh only the waiting jobs of that module', async () => {
    const t = await setup({ demo: entry('demo', JOBS), other: entry('other', JOBS) })
    const job = t.jobs.run('demo', { prompt: 'Demo' })
    void t.jobs.run('other', { prompt: 'Other' }).catch(() => {})
    await until(() => t.jobs.waiting('demo') === 1 && t.jobs.waiting('other') === 1)
    t.jobs.refresh('demo')
    await expect(job).resolves.toEqual({ text: 'done' })
    expect(t.runner.calls.map(c => c.body)).toEqual(['Demo'])
    expect(t.jobs.waiting('other')).toBe(1)
  })

  it('does nothing on refresh of a module that is off or gone', async () => {
    const t = await setup({ off: entry('off', JOBS, { enabled: false }) })
    t.jobs.refresh('off')
    t.jobs.refresh('gone')
    t.jobs.refresh('__proto__')
    expect(t.events).toEqual([])
  })

  it('ends a waiting job after 10 minutes', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] })
    const t = await setup({ demo: entry('demo', JOBS) })
    const job = t.jobs.run('demo', { prompt: 'Say hi' })
    const done = expect(job).rejects.toThrow(CANCELLED)
    await until(() => t.jobs.waiting('demo') === 1)
    vi.advanceTimersByTime(JOB_WAIT_MS - 1)
    expect(t.jobs.waiting('demo')).toBe(1)
    vi.advanceTimersByTime(1)
    await done
    expect(t.jobs.waiting('demo')).toBe(0)
    expect(t.changes()).toBe(2)
    expect(t.runner.calls).toHaveLength(0)
  })
})

describe('the daily cap', () => {
  it('refuses a job over the cap, and counts again on the next day', async () => {
    const t = await setup({
      demo: entry('demo', AUTO, { dailyCap: 2, jobs: { count: 1, day: '2026-11-13' } }),
    })
    await expect(t.jobs.run('demo', { prompt: 'One' })).resolves.toEqual({ text: 'done' })
    expect(t.store.get().modules.demo?.jobs).toEqual({ count: 2, day: '2026-11-13' })
    await expect(t.jobs.run('demo', { prompt: 'Two' })).rejects.toThrow(CAP)
    expect(t.runner.calls).toHaveLength(1)
    t.setNow(DAY_TWO)
    await expect(t.jobs.run('demo', { prompt: 'Three' })).resolves.toEqual({ text: 'done' })
    expect(t.store.get().modules.demo?.jobs).toEqual({ count: 1, day: '2026-11-14' })
  })

  it('counts the jobs that wait against the cap', async () => {
    const t = await setup({ demo: entry('demo', JOBS, { dailyCap: 1 }) })
    const first = t.jobs.run('demo', { prompt: 'One' })
    await expect(t.jobs.run('demo', { prompt: 'Two' })).rejects.toThrow(CAP)
    t.jobs.refresh('demo')
    await expect(first).resolves.toEqual({ text: 'done' })
    expect(t.store.get().modules.demo?.jobs).toEqual({ count: 1, day: '2026-11-13' })
  })

  it('checks the cap again when a job starts', async () => {
    const t = await setup({ demo: entry('demo', JOBS, { dailyCap: 2 }) })
    const first = t.jobs.run('demo', { prompt: 'One' })
    const second = t.jobs.run('demo', { prompt: 'Two' })
    await until(() => t.jobs.waiting('demo') === 2)
    // The user lowers the cap while the jobs wait.
    await t.store.change(s => ({
      modules: { demo: { ...(s.modules.demo as ModuleEntry), dailyCap: 1 } },
    }))
    t.jobs.refresh('demo')
    await expect(first).resolves.toEqual({ text: 'done' })
    await expect(second).rejects.toThrow(CAP)
    expect(t.runner.calls).toHaveLength(1)
  })
})

describe('the run', () => {
  it('gives the model of the module to claude, with the argument list of Spike B', async () => {
    const t = await setup({
      demo: entry('demo', AUTO, { model: 'opus' }),
      haiku: entry('haiku', AUTO),
    })
    await t.jobs.run('haiku', { prompt: 'Hi' })
    await t.jobs.run('demo', { prompt: 'Hi' })
    expect(t.runner.calls[0]?.args).toEqual(SPIKE_ARGS)
    expect(t.runner.calls[1]?.args).toEqual(jobArgs('opus'))
  })

  it('reads the model of the module when the job starts', async () => {
    const t = await setup({ demo: entry('demo', JOBS) })
    const job = t.jobs.run('demo', { prompt: 'Hi' })
    await until(() => t.jobs.waiting('demo') === 1)
    await t.store.change(s => ({
      modules: { demo: { ...(s.modules.demo as ModuleEntry), model: 'sonnet' } },
    }))
    t.jobs.refresh('demo')
    await job
    expect(t.runner.calls[0]?.args).toEqual(jobArgs('sonnet'))
  })

  it('gives the text on stdin, in the empty fixed folder of the module', async () => {
    const t = await setup({ demo: entry('demo', AUTO) })
    // A file that an earlier run left.
    await mkdir(join(t.jobRoot, 'demo'), { recursive: true })
    await writeFile(join(t.jobRoot, 'demo', 'old.txt'), 'x')
    await t.jobs.run('demo', { input: 'one\ntwo', prompt: 'Sum it' })
    const call = t.runner.calls[0] as RunnerCall
    expect(call.body).toBe('Sum it\n\n<input>\none\ntwo\n</input>')
    expect(call.opts.timeoutMs).toBe(JOB_TIMEOUT_MS)
    expect(JOB_TIMEOUT_MS).toBe(120_000)
    expect(call.opts.cwd).toBe(join(t.jobRoot, 'demo'))
    expect(call.files).toEqual([])
    // The job empties the folder after the run, and keeps it.
    expect(await readdir(t.jobRoot)).toEqual(['demo'])
    expect(await readdir(join(t.jobRoot, 'demo'))).toEqual([])
    expect((await stat(t.jobRoot)).mode & 0o777).toBe(0o700)
    expect((await stat(join(t.jobRoot, 'demo'))).mode & 0o777).toBe(0o700)
  })

  it('uses one fixed folder for each module, also for its next job', async () => {
    const t = await setup({ 'mod-a': entry('mod-a', AUTO), 'mod-b': entry('mod-b', AUTO) })
    t.runner.hold()
    const a1 = t.jobs.run('mod-a', { prompt: 'A1' })
    const b1 = t.jobs.run('mod-b', { prompt: 'B1' })
    const a2 = t.jobs.run('mod-a', { prompt: 'A2' })
    await until(() => t.runner.calls.length === 2)
    expect(t.runner.calls.map(c => c.opts.cwd).sort()).toEqual([
      join(t.jobRoot, 'mod-a'),
      join(t.jobRoot, 'mod-b'),
    ])
    t.runner.calls[0]?.finish(claudeOutput('a1'))
    t.runner.calls[1]?.finish(claudeOutput('b1'))
    await until(() => t.runner.calls.length === 3)
    expect(t.runner.calls[2]?.opts.cwd).toBe(join(t.jobRoot, 'mod-a'))
    expect(t.runner.calls[2]?.files).toEqual([])
    t.runner.calls[2]?.finish(claudeOutput('a2'))
    await Promise.all([a1, b1, a2])
    expect((await readdir(t.jobRoot)).sort()).toEqual(['mod-a', 'mod-b'])
  })

  it('removes a link in place of the folder of a module, not its target', async () => {
    const t = await setup({ demo: entry('demo', AUTO) })
    const outside = join(root, 'outside')
    await mkdir(outside)
    await writeFile(join(outside, 'keep.txt'), 'x')
    await mkdir(t.jobRoot, { recursive: true })
    await symlink(outside, join(t.jobRoot, 'demo'))
    await t.jobs.run('demo', { prompt: 'Hi' })
    expect(await readdir(outside)).toEqual(['keep.txt'])
    const info = await lstat(join(t.jobRoot, 'demo'))
    expect(info.isDirectory() && !info.isSymbolicLink()).toBe(true)
  })

  it('refuses a job when the jobs folder is a link, or the id is no folder name', async () => {
    const t = await setup({ demo: entry('demo', AUTO) })
    await mkdir(join(root, 'elsewhere'))
    await mkdir(dirname(t.jobRoot), { recursive: true })
    await symlink(join(root, 'elsewhere'), t.jobRoot)
    await expect(t.jobs.run('demo', { prompt: 'Hi' })).rejects.toThrow(FAILED)
    expect(t.runner.calls).toHaveLength(0)
    expect(await readdir(join(root, 'elsewhere'))).toEqual([])
    const u = await setup({ '../evil': entry('../evil', AUTO) }, { jobsRoot: join(root, 'other') })
    await expect(u.jobs.run('../evil', { prompt: 'Hi' })).rejects.toThrow(FAILED)
    expect(u.runner.calls).toHaveLength(0)
    expect(await readdir(root)).not.toContain('evil')
  })

  it('starts the stdin with the Bifrost line, so the text of a module is never first', async () => {
    const t = await setup({ demo: entry('demo', AUTO) })
    const prompts = ['/x args', '!cmd', '#note']
    for (const prompt of prompts) await t.jobs.run('demo', { prompt })
    expect(t.runner.calls.map(c => c.opts.input)).toEqual(
      prompts.map(prompt => `${JOB_HEADER}\n\n${prompt}`),
    )
    expect(JOB_HEADER).toBe('This is a Bifrost module job.')
  })

  it('refuses a job when the saved model is not a model choice, with no count', async () => {
    const bad = '--allowedTools' as ModelChoice
    const t = await setup({ demo: entry('demo', AUTO, { model: bad }) })
    await expect(t.jobs.run('demo', { prompt: 'Hi' })).rejects.toThrow(FAILED)
    expect(t.runner.calls).toHaveLength(0)
    expect(t.store.get().modules.demo?.jobs).toEqual({ count: 0, day: '' })
  })

  it('makes the jobs folder again when the system removes it', async () => {
    const t = await setup({ demo: entry('demo', AUTO) })
    await t.jobs.run('demo', { prompt: 'One' })
    await rm(t.jobRoot, { force: true, recursive: true })
    await expect(t.jobs.run('demo', { prompt: 'Two' })).resolves.toEqual({ text: 'done' })
    expect(t.runner.calls[1]?.files).toEqual([])
    expect((await stat(t.jobRoot)).mode & 0o777).toBe(0o700)
  })

  it('masks a token in the prompt and the input before the run', async () => {
    const t = await setup({ demo: entry('demo', AUTO) })
    await t.jobs.run('demo', { input: `key ${TOKEN}`, prompt: `Use ${TOKEN}` })
    const input = t.runner.calls[0]?.body ?? ''
    expect(input).not.toContain(TOKEN)
    expect(input).toBe('Use ***\n\n<input>\nkey ***\n</input>')
  })

  it('masks a token in the result', async () => {
    const t = await setup({ demo: entry('demo', AUTO) })
    t.runner.answer(claudeOutput(`The token is ${TOKEN}.`))
    await expect(t.jobs.run('demo', { prompt: 'Hi' })).resolves.toEqual({
      text: 'The token is ***.',
    })
  })

  it('gives a JSON result as data, with each text masked', async () => {
    const t = await setup({ demo: entry('demo', AUTO) })
    t.runner.answer(claudeOutput(`\`\`\`json\n{"note":"${TOKEN}","items":[1,2]}\n\`\`\``))
    await expect(t.jobs.run('demo', { json: true, prompt: 'List it' })).resolves.toEqual({
      json: { items: [1, 2], note: '***' },
    })
    // The job asks Claude for JSON only, after the text of the module.
    expect(t.runner.calls[0]?.body).toBe(
      'List it\n\nAnswer with only one JSON value and no other text.',
    )
    t.runner.answer(claudeOutput('[true, null]'))
    await expect(t.jobs.run('demo', { json: true, prompt: 'List it' })).resolves.toEqual({
      json: [true, null],
    })
  })

  it('refuses a JSON job whose result is not JSON', async () => {
    const t = await setup({ demo: entry('demo', AUTO) })
    t.runner.answer(claudeOutput('Here you go: {"a": 1}'))
    await expect(t.jobs.run('demo', { json: true, prompt: 'Hi' })).rejects.toThrow(NOT_JSON)
  })

  it('gives a text that looks like a tool call as plain text', async () => {
    const t = await setup({ demo: entry('demo', AUTO) })
    const fake = '<tool_use name="Bash">{"command":"cat /etc/hosts"}</tool_use>'
    t.runner.answer(claudeOutput(fake))
    await expect(t.jobs.run('demo', { prompt: 'Hi' })).resolves.toEqual({ text: fake })
    expect(t.runner.calls).toHaveLength(1)
  })

  it('refuses a job that took too long', async () => {
    const t = await setup({ demo: entry('demo', AUTO) })
    t.runner.answer({ code: 1, stderr: '', stdout: '', timedOut: true })
    await expect(t.jobs.run('demo', { prompt: 'Hi' })).rejects.toThrow(TOO_LONG)
    expect(await readdir(join(t.jobRoot, 'demo'))).toEqual([])
  })

  it('refuses a job when claude fails or gives no good result', async () => {
    const t = await setup({ demo: entry('demo', AUTO, { dailyCap: 100 }) })
    const bad: ExecResult[] = [
      { code: 1, stderr: `failed with ${TOKEN}`, stdout: '' },
      { code: 0, stderr: '', stdout: 'not json' },
      { code: 0, stderr: '', stdout: JSON.stringify({ is_error: true, result: 'error' }) },
      { code: 0, stderr: '', stdout: JSON.stringify({ is_error: false, result: 7 }) },
      { code: 1, overflow: true, stderr: '', stdout: '' },
      { code: 1, signal: 'SIGSEGV', stderr: '', stdout: '' },
    ]
    for (const result of bad) {
      t.runner.answer(result)
      await expect(t.jobs.run('demo', { prompt: 'Hi' }), JSON.stringify(result)).rejects.toThrow(
        FAILED,
      )
    }
    expect(t.logs).toHaveLength(bad.length)
    expect(t.logs.join('\n')).not.toContain(TOKEN)
  })

  it('refuses a job when Bifrost cannot find claude, and does not count it', async () => {
    const t = await setup({ demo: entry('demo', AUTO) }, { runner: async () => null })
    await expect(t.jobs.run('demo', { prompt: 'Hi' })).rejects.toThrow(FAILED)
    expect(t.store.get().modules.demo?.jobs).toEqual({ count: 0, day: '' })
    expect(t.logs).toHaveLength(1)
  })
})

describe('the input check', () => {
  it('refuses a request that does not have the right form', async () => {
    const t = await setup({ demo: entry('demo', AUTO) })
    const bad: unknown[] = [
      null,
      'Hi',
      [],
      {},
      { prompt: '' },
      { prompt: '  \n ' },
      { prompt: 5 },
      { prompt: 'x'.repeat(JOB_PROMPT_MAX + 1) },
      { input: 'x'.repeat(JOB_INPUT_MAX + 1), prompt: 'Hi' },
      { input: 5, prompt: 'Hi' },
      { json: 'yes', prompt: 'Hi' },
      { model: 'opus', prompt: 'Hi' },
    ]
    for (const req of bad) {
      await expect(t.jobs.run('demo', req), JSON.stringify(req)?.slice(0, 40)).rejects.toThrow(BAD)
    }
    expect(t.runner.calls).toHaveLength(0)
  })

  it('accepts a prompt and an input at the limits', async () => {
    const t = await setup({ demo: entry('demo', AUTO) })
    const req = {
      input: 'y'.repeat(JOB_INPUT_MAX),
      json: false,
      prompt: 'x'.repeat(JOB_PROMPT_MAX),
    }
    await expect(t.jobs.run('demo', req)).resolves.toEqual({ text: 'done' })
    expect(JOB_PROMPT_MAX).toBe(20_000)
    expect(JOB_INPUT_MAX).toBe(200_000)
  })

  it('refuses a module that is off or gone, or that has no claude-jobs permission', async () => {
    const t = await setup(
      {
        dev: entry('dev', AUTO, { source: { kind: 'dev', path: '/src/dev' } }),
        off: entry('off', AUTO, { enabled: false }),
        plain: entry('plain', []),
      },
      { devAllowed: false },
    )
    await expect(t.jobs.run('off', { prompt: 'Hi' })).rejects.toThrow(OFF)
    await expect(t.jobs.run('gone', { prompt: 'Hi' })).rejects.toThrow(OFF)
    await expect(t.jobs.run('dev', { prompt: 'Hi' })).rejects.toThrow(OFF)
    await expect(t.jobs.run('plain', { prompt: 'Hi' })).rejects.toThrow(NOT_ALLOWED)
  })

  it('refuses a waiting job at its start when the module lost the permission', async () => {
    const t = await setup({ demo: entry('demo', JOBS) })
    const job = t.jobs.run('demo', { prompt: 'Hi' })
    await until(() => t.jobs.waiting('demo') === 1)
    await t.store.change(s => ({
      modules: { demo: { ...(s.modules.demo as ModuleEntry), granted: [] } },
    }))
    t.jobs.refresh('demo')
    await expect(job).rejects.toThrow(NOT_ALLOWED)
    expect(t.runner.calls).toHaveLength(0)
  })

  it('refuses a queued job at its start when the module is off', async () => {
    const t = await setup({
      'mod-a': entry('mod-a', AUTO),
      'mod-b': entry('mod-b', AUTO),
      'mod-c': entry('mod-c', AUTO),
    })
    t.runner.hold()
    void t.jobs.run('mod-a', { prompt: 'A' }).catch(() => {})
    void t.jobs.run('mod-b', { prompt: 'B' }).catch(() => {})
    const queued = t.jobs.run('mod-c', { prompt: 'C' })
    await until(() => t.runner.calls.length === 2)
    await t.store.change(s => ({
      modules: {
        ...s.modules,
        'mod-c': { ...(s.modules['mod-c'] as ModuleEntry), enabled: false },
      },
    }))
    t.runner.calls[0]?.finish(claudeOutput('a'))
    await expect(queued).rejects.toThrow(OFF)
    expect(t.runner.calls).toHaveLength(2)
  })
})

// A store that applies one change of the user just before the next change of the jobs, so the
// change comes between the first check of a job and the step that counts it.
function userChangeFirst(change: (s: ModulesState) => ModulesState) {
  return (store: ModulesStateStore): JobsDeps['store'] => {
    let pending: typeof change | null = change
    return {
      change: async fn => {
        const first = pending
        pending = null
        if (first !== null) await store.change(first)
        return store.change(fn)
      },
      get: () => store.get(),
    }
  }
}

// A store that holds the next change of the jobs at a gate: before the count step runs, or after
// it ran and while its write goes on. So a cancel or the end of the wait can come at that time.
function holdCount(at: 'before' | 'during') {
  const gate: { reached: boolean; open: () => void } = { open: () => {}, reached: false }
  const opened = new Promise<void>(resolve => {
    gate.open = resolve
  })
  const wrap = (store: ModulesStateStore): JobsDeps['store'] => ({
    change: async fn => {
      gate.reached = true
      if (at === 'before') await opened
      const next = await store.change(fn)
      if (at === 'during') await opened
      return next
    },
    get: () => store.get(),
  })
  return { gate, wrap }
}

const withDemo = (s: ModulesState, extra: Partial<ModuleEntry>): ModulesState => ({
  modules: { ...s.modules, demo: { ...(s.modules.demo as ModuleEntry), ...extra } },
})

describe('the step that counts a job', () => {
  it('refuses the job when the module is off or lost claude-jobs at that step', async () => {
    const cases: [Partial<ModuleEntry>, string][] = [
      [{ enabled: false }, OFF],
      [{ granted: [] }, NOT_ALLOWED],
    ]
    for (const [extra, code] of cases) {
      const wrap = userChangeFirst(s => withDemo(s, extra))
      const t = await setup({ demo: entry('demo', AUTO) }, {}, wrap)
      await expect(t.jobs.run('demo', { prompt: 'Hi' }), code).rejects.toThrow(code)
      expect(t.runner.calls).toHaveLength(0)
      expect(t.store.get().modules.demo?.jobs).toEqual({ count: 0, day: '' })
    }
  })

  it('puts the job back to wait when the module lost claude-jobs-auto at that step', async () => {
    const wrap = userChangeFirst(s => withDemo(s, { granted: JOBS }))
    const t = await setup({ demo: entry('demo', AUTO) }, {}, wrap)
    const job = t.jobs.run('demo', { prompt: 'Hi' })
    await until(() => t.jobs.waiting('demo') === 1)
    expect(t.runner.calls).toHaveLength(0)
    expect(t.store.get().modules.demo?.jobs).toEqual({ count: 0, day: '' })
    t.jobs.refresh('demo')
    await expect(job).resolves.toEqual({ text: 'done' })
    expect(t.store.get().modules.demo?.jobs).toEqual({ count: 1, day: '2026-11-13' })
  })

  // Final review: an abort during the write of the count gave a job in the count, and then a
  // refusal. Now the count step checks the abort, and it marks the job as counted itself.
  it('refuses a job with no count when a cancel comes before the count step', async () => {
    const { gate, wrap } = holdCount('before')
    const t = await setup({ demo: entry('demo', AUTO) }, {}, wrap)
    const job = t.jobs.run('demo', { prompt: 'Hi' })
    await until(() => gate.reached)
    const ended = expect(job).rejects.toThrow(CANCELLED)
    t.jobs.cancel('demo')
    gate.open()
    await ended
    expect(t.runner.calls).toHaveLength(0)
    expect(t.store.get().modules.demo?.jobs).toEqual({ count: 0, day: '' })
  })

  it('runs a counted job when a cancel comes during the write of the count', async () => {
    const { gate, wrap } = holdCount('during')
    const t = await setup({ demo: entry('demo', AUTO) }, {}, wrap)
    const job = t.jobs.run('demo', { prompt: 'Hi' })
    await until(() => t.store.get().modules.demo?.jobs.count === 1)
    t.jobs.cancel('demo')
    gate.open()
    await expect(job).resolves.toEqual({ text: 'done' })
    expect(t.runner.calls).toHaveLength(1)
    expect(t.store.get().modules.demo?.jobs).toEqual({ count: 1, day: '2026-11-13' })
  })

  it('runs a counted job when its wait ends during the write of the count', async () => {
    vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] })
    const { gate, wrap } = holdCount('during')
    const t = await setup({ demo: entry('demo', AUTO) }, {}, wrap)
    const job = t.jobs.run('demo', { prompt: 'Hi' })
    await until(() => t.store.get().modules.demo?.jobs.count === 1)
    vi.advanceTimersByTime(JOB_WAIT_MS)
    gate.open()
    await expect(job).resolves.toEqual({ text: 'done' })
    expect(t.runner.calls).toHaveLength(1)
  })

  it('checks claude-jobs-auto again before a queued job runs with no click', async () => {
    const t = await setup({
      demo: entry('demo', AUTO),
      'mod-a': entry('mod-a', AUTO),
      'mod-b': entry('mod-b', AUTO),
    })
    t.runner.hold()
    void t.jobs.run('mod-a', { prompt: 'A' }).catch(() => {})
    void t.jobs.run('mod-b', { prompt: 'B' }).catch(() => {})
    const queued = t.jobs.run('demo', { prompt: 'D' })
    await until(() => t.runner.calls.length === 2)
    await t.store.change(s => withDemo(s, { granted: JOBS }))
    t.runner.calls[0]?.finish(claudeOutput('a'))
    await until(() => t.jobs.waiting('demo') === 1)
    for (let i = 0; i < 50; i += 1) await new Promise(resolve => setImmediate(resolve))
    expect(t.runner.calls).toHaveLength(2)
    t.runner.answer(claudeOutput('done'))
    t.jobs.refresh('demo')
    await expect(queued).resolves.toEqual({ text: 'done' })
  })
})

describe('the places', () => {
  it('runs one job at a time for each module, and two in all', async () => {
    const t = await setup({
      'mod-a': entry('mod-a', AUTO),
      'mod-b': entry('mod-b', AUTO),
      'mod-c': entry('mod-c', AUTO),
    })
    t.runner.hold()
    const jobs = [
      t.jobs.run('mod-a', { prompt: 'a1' }),
      t.jobs.run('mod-a', { prompt: 'a2' }),
      t.jobs.run('mod-b', { prompt: 'b1' }),
      t.jobs.run('mod-c', { prompt: 'c1' }),
    ]
    await until(() => t.runner.calls.length === JOBS_AT_ONCE)
    for (let i = 0; i < 50; i += 1) await new Promise(resolve => setImmediate(resolve))
    expect(JOBS_AT_ONCE).toBe(2)
    // Each job prepares its folder before the run, so two modules can call claude in any order.
    const callOf = (input: string) => t.runner.calls.find(c => c.body === input)
    expect(t.runner.calls.map(c => c.body).sort()).toEqual(['a1', 'b1'])
    callOf('a1')?.finish(claudeOutput('a1 done'))
    await until(() => t.runner.calls.length === 3)
    expect(t.runner.calls[2]?.body).toBe('a2')
    callOf('b1')?.finish(claudeOutput('b1 done'))
    await until(() => t.runner.calls.length === 4)
    expect(t.runner.calls[3]?.body).toBe('c1')
    callOf('a2')?.finish(claudeOutput('a2 done'))
    callOf('c1')?.finish(claudeOutput('c1 done'))
    await expect(Promise.all(jobs)).resolves.toEqual([
      { text: 'a1 done' },
      { text: 'a2 done' },
      { text: 'b1 done' },
      { text: 'c1 done' },
    ])
  })
})

describe('stop', () => {
  it('aborts a running job, ends the waiting jobs, and refuses new jobs', async () => {
    const t = await setup({ auto: entry('auto', AUTO), demo: entry('demo', JOBS) })
    t.runner.hold()
    const running = t.jobs.run('auto', { prompt: 'Run' })
    const waiting = t.jobs.run('demo', { prompt: 'Wait' })
    await until(() => t.runner.calls.length === 1 && t.jobs.waiting('demo') === 1)
    const ended = Promise.all([
      expect(running).rejects.toThrow(CANCELLED),
      expect(waiting).rejects.toThrow(CANCELLED),
    ])
    t.jobs.stop()
    expect(t.runner.calls[0]?.opts.signal.aborted).toBe(true)
    await ended
    expect(t.jobs.waiting('demo')).toBe(0)
    await expect(t.jobs.run('auto', { prompt: 'Again' })).rejects.toThrow(CANCELLED)
    expect(await readdir(join(t.jobRoot, 'auto'))).toEqual([])
  })
})

// Settings cancels the jobs of a module that the user removes, turns off, or that loses
// claude-jobs or claude-jobs-auto (plan Task 9).
describe('cancel', () => {
  it('ends the waiting and ready jobs of one module at once, and keeps the others', async () => {
    const t = await setup({ demo: entry('demo', JOBS), other: entry('other', JOBS) })
    const first = t.jobs.run('demo', { prompt: 'One' })
    const second = t.jobs.run('demo', { prompt: 'Two' })
    const other = t.jobs.run('other', { prompt: 'Other' })
    await until(() => t.jobs.waiting('demo') === 2 && t.jobs.waiting('other') === 1)
    const before = t.changes()
    const ended = Promise.all([
      expect(first).rejects.toThrow(CANCELLED),
      expect(second).rejects.toThrow(CANCELLED),
    ])
    t.jobs.cancel('demo')
    expect(t.jobs.waiting('demo')).toBe(0)
    expect(t.jobs.waiting('other')).toBe(1)
    expect(t.changes()).toBe(before + 1)
    await ended
    t.jobs.refresh('other')
    await expect(other).resolves.toEqual({ text: 'done' })
    expect(t.runner.calls.map(c => c.body)).toEqual(['Other'])
  })

  it('lets a job that runs go on, and ends the jobs that wait for its place', async () => {
    const t = await setup({ demo: entry('demo', AUTO) })
    t.runner.hold()
    const running = t.jobs.run('demo', { prompt: 'Run' })
    const ready = t.jobs.run('demo', { prompt: 'Next' })
    await until(() => t.runner.calls.length === 1)
    const ended = expect(ready).rejects.toThrow(CANCELLED)
    t.jobs.cancel('demo')
    await ended
    expect(t.runner.calls[0]?.opts.signal.aborted).toBe(false)
    t.runner.calls[0]?.finish(claudeOutput('ran'))
    await expect(running).resolves.toEqual({ text: 'ran' })
    for (let i = 0; i < 50; i += 1) await new Promise(resolve => setImmediate(resolve))
    expect(t.runner.calls).toHaveLength(1)
  })

  it('changes nothing for a module with no job', async () => {
    const t = await setup({ demo: entry('demo', JOBS) })
    t.jobs.cancel('demo')
    t.jobs.cancel('gone')
    expect(t.changes()).toBe(0)
  })
})

describe('a closed panel (Review Focus 4)', () => {
  it('does not stop a running job, and drops its result with no error', async () => {
    const t = await setup({ demo: entry('demo', AUTO) })
    t.runner.hold()
    const heimdall = createHeimdall({
      devAllowed: true,
      emit: () => {},
      jobs: t.jobs,
      log: message => t.logs.push(message),
      notify: () => {},
      now: () => Date.now(),
      serviceStatus: () => [],
      sessions: { pr: async () => ({ kind: 'none' }), rows: () => [] },
      state: () => t.store.get(),
      store: createModuleDataStore(join(root, 'data'), {
        io: { read: async () => null, write: async () => {}, writeSync: () => {} },
      }),
      usage: () => ({ account: null, snapshot: null }),
    })
    // Two panels of the module are open. Each one asks for a job.
    const frames = [0, 1].map(() => {
      const posted: unknown[] = []
      return { posted, postMessage: (message: unknown) => posted.push(message) }
    })
    const bridges = frames.map(frame =>
      createBridge({
        call: (moduleId, name, args) => heimdall.call(moduleId, name, args),
        frame: () => frame,
        moduleId: 'demo',
        now: () => Date.now(),
      }),
    )
    frames.forEach((frame, i) => {
      bridges[i]?.receive({
        data: { args: { prompt: `Panel ${i}` }, bifrost: 1, call: 'claude.job', id: i + 1 },
        source: frame,
      })
    })
    await until(() => t.runner.calls.length === 1)
    expect(t.runner.calls[0]?.body).toBe('Panel 0')
    // The first panel closes while its job runs. The job goes on.
    bridges[0]?.close()
    expect(t.runner.calls[0]?.opts.signal.aborted).toBe(false)
    t.runner.calls[0]?.finish(claudeOutput('for panel 0'))
    await until(() => t.runner.calls.length === 2)
    t.runner.calls[1]?.finish(claudeOutput('for panel 1'))
    await until(() => (frames[1]?.posted.length ?? 0) === 1)
    expect(frames[0]?.posted).toEqual([])
    expect(frames[1]?.posted).toEqual([
      { bifrost: 1, id: 2, ok: true, value: { text: 'for panel 1' } },
    ])
    expect(t.store.get().modules.demo?.jobs).toEqual({ count: 2, day: '2026-11-13' })
    expect(t.logs).toEqual([])
  })
})

describe('watchLocalDay', () => {
  it('calls the function at local midnight, and only then', () => {
    vi.useFakeTimers({ now: new Date(2026, 10, 13, 23, 58, 0) })
    let days = 0
    const stop = watchLocalDay(
      () => {
        days += 1
      },
      { log: () => {} },
    )
    vi.advanceTimersByTime(60_000)
    expect(days).toBe(0)
    vi.advanceTimersByTime(60_001)
    expect(days).toBe(1)
    vi.advanceTimersByTime(23 * 3_600_000)
    expect(days).toBe(1)
    vi.advanceTimersByTime(3_600_000)
    expect(days).toBe(2)
    stop()
    vi.advanceTimersByTime(3 * 86_400_000)
    expect(days).toBe(2)
  })

  it('finds the new day within a minute when the clock jumps past midnight', () => {
    // A timer can fire late after the Mac sleeps. So the watcher checks at least each minute.
    vi.useFakeTimers({ now: new Date(2026, 10, 13, 18, 0) })
    let days = 0
    const stop = watchLocalDay(
      () => {
        days += 1
      },
      { log: () => {} },
    )
    vi.setSystemTime(new Date(2026, 10, 14, 8, 0))
    vi.advanceTimersByTime(60_000)
    expect(days).toBe(1)
    stop()
  })

  it('gives a failure of the function to the log, and goes on', () => {
    vi.useFakeTimers({ now: new Date(2026, 10, 13, 23, 59, 30) })
    const logs: string[] = []
    const stop = watchLocalDay(
      () => {
        throw new Error('the send failed')
      },
      { log: message => logs.push(message) },
    )
    vi.advanceTimersByTime(30_000)
    expect(logs).toHaveLength(1)
    expect(logs[0]).toContain('the send failed')
    stop()
  })
})
