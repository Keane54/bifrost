// The module jobs of the modules (Modules design 8.5, plan Task 7). A job is one short claude -p
// run on text that a module gives. It has no tools, no MCP servers, no hooks, no slash commands,
// no skills and no auto memory, and it saves no session: the argument list comes from Spike B and
// ruling S-A10 (findings-job.md). The text goes on stdin, after a fixed Bifrost line, so the text
// of a module is never first. Each module has one fixed job folder in the system temp folder, so
// the context of a job holds no user name. A job runs in that folder when it is empty, and
// empties it after the run.
//
// With the permission claude-jobs-auto, a job runs when the module asks. Without it, the job
// waits until the user clicks Refresh on a panel of the module. A job that does not start within
// 10 minutes ends. One job of each module runs at a time, and two jobs run in all.
//
// The daily cap counts the jobs of the local day. A job counts when it starts.
//
// The prompt and the input pass the secret filter before the run, and the result passes it after
// the run (ruling S-A6). The result is data only. A model can write text that looks like a tool
// call. Bifrost gives that text to the module and never acts on it.

import { chmod, lstat, mkdir, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { localDate } from '../../shared/daily-schedule'
import { MODULE_ID_PATTERN } from '../../shared/module-manifest'
import {
  REFUSED_BAD_MODULE_INPUT,
  REFUSED_JOB_CANCELLED,
  REFUSED_JOB_CAP,
  REFUSED_JOB_FAILED,
  REFUSED_JOB_NOT_JSON,
  REFUSED_JOB_TOO_LONG,
  REFUSED_MODULE_OFF,
  REFUSED_NOT_ALLOWED,
} from '../../shared/modules'
import { MODEL_VALUES, type ModelChoice } from '../../shared/new-session'
import { isPlainObject } from '../../shared/plain-object'
import type { ExecResult } from '../claude/cli'
import type { RunClaudeJob } from '../claude/job-runner'
import { activeModule } from './heimdall'
import type { ModuleEntry, ModulesState } from './module-state'
import { filterSecrets, filterSecretValue } from './secret-filter'

// The longest prompt and the longest input of a job, in characters.
export const JOB_PROMPT_MAX = 20_000
export const JOB_INPUT_MAX = 200_000
// The longest run of a job. Then a SIGKILL stops claude.
export const JOB_TIMEOUT_MS = 120_000
// The longest time that a job can wait before it starts.
export const JOB_WAIT_MS = 10 * 60_000
// The most jobs that run at the same time, for all modules.
export const JOBS_AT_ONCE = 2
// The most bytes of the stdout of claude. A larger output fails the job.
export const JOB_OUTPUT_BYTES = 1024 * 1024
// The text that a JSON job adds after the text of the module.
export const JSON_RULE = 'Answer with only one JSON value and no other text.'
// The first line of the text of each job (rulings S-A10 and S-A12). A blank line and the text of
// the module come after it. The line only keeps the text of the module from the first place.
// Claude follows the prompt of the module.
export const JOB_HEADER = 'This is a Bifrost module job.'
// The settings of a job: no hooks, no auto memory, and no shell from a skill (ruling S-A10).
const JOB_SETTINGS =
  '{"disableAllHooks":true,"autoMemoryEnabled":false,"disableSkillShellExecution":true}'
// The folder of the job folders in the system temp folder.
const JOBS_FOLDER = 'bifrost-module-jobs'
// The longest time between two checks of the local day. A timer can fire late after the Mac
// sleeps, so watchLocalDay checks at least this often.
const DAY_CHECK_MS = 60_000

const REQUEST_KEYS: readonly string[] = ['prompt', 'input', 'json']
// The longest part of stderr in a log line.
const MAX_LOG_TEXT = 200
// A result that is one fenced block, for example ```json ... ```.
const FENCE = /^```[a-z]*\n([\s\S]*?)\n?```$/

export interface JobRequest {
  prompt: string
  input?: string
  json?: boolean
}

export type JobResult = { text: string } | { json: unknown }

export interface JobsDeps {
  // The runner of claude. It gives null when Bifrost cannot find claude.
  runner(): Promise<RunClaudeJob | null>
  // The modules state. A job reads the newest entry when it starts, and it counts itself in the
  // saved state.
  store: {
    get(): ModulesState
    change(fn: (s: ModulesState) => ModulesState): Promise<ModulesState>
  }
  // False in a packaged app. Then a dev module counts as off.
  devAllowed: boolean
  // Send an event to the frames of a module.
  emit(moduleId: string, event: string, data: unknown): void
  // The count of the jobs that wait for Refresh changed.
  changed(): void
  now(): number
  // The folder that holds one job folder for each module (moduleJobsRoot of the system temp
  // folder).
  jobsRoot: string
  // The log of the main process.
  log?: (message: string) => void
}

export interface Jobs {
  // Run a job for a module. This rejects with a "refused: ..." code.
  run(moduleId: string, req: unknown): Promise<JobResult>
  // Run the waiting jobs of the module, and send the refresh event to it.
  refresh(moduleId: string): void
  // The count of the jobs of the module that wait for Refresh.
  waiting(moduleId: string): number
  // End each job of the module that did not start, at once, with "refused: job cancelled". A job
  // that prepares its start ends at its next check. A job that runs goes on. Settings calls it
  // when the user removes the module, turns it off, or removes claude-jobs.
  cancel(moduleId: string): void
  // Stop each running job, end each job that waits, and refuse new jobs.
  stop(): void
}

interface Job {
  moduleId: string
  // The text on stdin.
  text: string
  json: boolean
  // waiting: the job waits for Refresh. ready: the job waits for a place. running: the job has
  // its place.
  state: 'waiting' | 'ready' | 'running'
  // True after the job is in the count of the day.
  counted: boolean
  // True after a click on Refresh. A job with no click runs only with claude-jobs-auto.
  clicked: boolean
  timer: ReturnType<typeof setTimeout> | null
  abort: AbortController | null
  resolve(value: JobResult): void
  reject(error: Error): void
}

function refuse(code: string): never {
  throw new Error(code)
}

// The folder of the job folders of the modules in the temp folder.
export function moduleJobsRoot(tempDir: string): string {
  return join(tempDir, JOBS_FOLDER)
}

// The arguments of claude for a job: no saved session, no slash commands or skills, no tools, no
// MCP servers, no settings files, no hooks and no auto memory. The empty model gives no --model
// flag. Then claude uses its default model. A model that is not a model choice throws, so no
// saved value can become a flag.
export function jobArgs(model: ModelChoice): string[] {
  if (!MODEL_VALUES.includes(model)) throw new Error('The model of the job is not a model choice.')
  const args = [
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
    JOB_SETTINGS,
    '--permission-mode',
    'dontAsk',
  ]
  if (model !== '') args.push('--model', model)
  return args
}

function parseRequest(req: unknown): Required<JobRequest> {
  if (!isPlainObject(req)) refuse(REFUSED_BAD_MODULE_INPUT)
  if (Object.keys(req).some(key => !REQUEST_KEYS.includes(key))) refuse(REFUSED_BAD_MODULE_INPUT)
  const { input = '', json = false, prompt } = req
  if (typeof prompt !== 'string' || prompt.trim() === '' || prompt.length > JOB_PROMPT_MAX) {
    refuse(REFUSED_BAD_MODULE_INPUT)
  }
  if (typeof input !== 'string' || input.length > JOB_INPUT_MAX) refuse(REFUSED_BAD_MODULE_INPUT)
  if (typeof json !== 'boolean') refuse(REFUSED_BAD_MODULE_INPUT)
  return { input, json, prompt }
}

// The text of a job on stdin: the Bifrost line, the prompt, the input in an input block, and the
// JSON rule. The filter runs on each part, so a cut private key block in the prompt cannot hide
// the input.
function jobText(req: Required<JobRequest>): string {
  const parts = [JOB_HEADER, filterSecrets(req.prompt)]
  if (req.input !== '') parts.push(`<input>\n${filterSecrets(req.input)}\n</input>`)
  if (req.json) parts.push(JSON_RULE)
  return parts.join('\n\n')
}

// The result text of the stdout of claude -p with --output-format json, or null.
function resultText(stdout: string): string | null {
  let data: unknown
  try {
    data = JSON.parse(stdout)
  } catch {
    return null
  }
  if (!isPlainObject(data) || data.is_error !== false || typeof data.result !== 'string') {
    return null
  }
  return data.result
}

// Make the folder empty: remove it, then make it again with mode 0700. rm removes a link in the
// place of the folder, never the target of the link.
async function emptyFolder(dir: string): Promise<void> {
  await rm(dir, { force: true, recursive: true })
  await mkdir(dir, { mode: 0o700 })
}

// The JSON value of a result. A result can be one fenced block.
function jsonValue(text: string): { ok: true; value: unknown } | { ok: false } {
  const trimmed = text.trim()
  const body = FENCE.exec(trimmed)?.[1] ?? trimmed
  try {
    return { ok: true, value: JSON.parse(body) }
  } catch {
    return { ok: false }
  }
}

// The result of the step that counts a job.
type Claim =
  | { kind: 'ok'; model: ModelChoice }
  | { kind: 'refused'; code: string }
  | { kind: 'bad-model' }
  // The module lost claude-jobs-auto, and the job has no click.
  | { kind: 'wait' }

export function createJobs(deps: JobsDeps): Jobs {
  const log = deps.log ?? ((message: string) => console.error(message))
  // The jobs that did not end, in the order of the requests.
  const jobs: Job[] = []
  let stopped = false

  const today = (): string => localDate(new Date(deps.now()))
  const active = (moduleId: unknown): ModuleEntry | null =>
    activeModule(deps.store.get(), moduleId, deps.devAllowed)

  function remove(job: Job): void {
    const index = jobs.indexOf(job)
    if (index !== -1) jobs.splice(index, 1)
    if (job.timer !== null) clearTimeout(job.timer)
    job.timer = null
  }

  // The jobs of the module that are not in the saved count yet.
  function uncounted(moduleId: string): number {
    return jobs.filter(job => job.moduleId === moduleId && !job.counted).length
  }

  // Check the module and add one job of today to its saved count, in one step of the store
  // queue. So the user cannot turn the module off, or remove a permission, between the check and
  // the count. The model comes from the same entry. An abort (a cancel or the end of the wait)
  // before this step refuses the job with no count. The step marks the job as counted. So a
  // cancel or the end of the wait during the write of the count does not abort the job.
  async function claim(job: Job): Promise<Claim> {
    const day = today()
    const out: { claim: Claim } = { claim: { code: REFUSED_MODULE_OFF, kind: 'refused' } }
    await deps.store.change(s => {
      if (job.abort?.signal.aborted) {
        out.claim = { code: REFUSED_JOB_CANCELLED, kind: 'refused' }
        return s
      }
      const entry = activeModule(s, job.moduleId, deps.devAllowed)
      if (entry === null) return s
      if (!entry.granted.includes('claude-jobs')) {
        out.claim = { code: REFUSED_NOT_ALLOWED, kind: 'refused' }
        return s
      }
      if (!job.clicked && !entry.granted.includes('claude-jobs-auto')) {
        out.claim = { kind: 'wait' }
        return s
      }
      if (!MODEL_VALUES.includes(entry.model)) {
        out.claim = { kind: 'bad-model' }
        return s
      }
      const done = entry.jobs.day === day ? entry.jobs.count : 0
      if (done >= entry.dailyCap) {
        out.claim = { code: REFUSED_JOB_CAP, kind: 'refused' }
        return s
      }
      out.claim = { kind: 'ok', model: entry.model }
      job.counted = true
      const next = { ...entry, jobs: { count: done + 1, day } }
      return { ...s, modules: { ...s.modules, [job.moduleId]: next } }
    })
    return out.claim
  }

  // The fixed job folder of the module, empty. The jobs folder must be a real folder, not a link.
  async function jobFolder(moduleId: string): Promise<string> {
    // The job folder of a module has the name of its id.
    if (!MODULE_ID_PATTERN.test(moduleId)) throw new Error('The module id is not a folder name.')
    const root = deps.jobsRoot
    await mkdir(root, { mode: 0o700, recursive: true })
    const info = await lstat(root)
    if (!info.isDirectory()) throw new Error(`The jobs folder ${root} is not a real folder.`)
    await chmod(root, 0o700)
    const dir = join(root, moduleId)
    await emptyFolder(dir)
    return dir
  }

  // The value of a run, or a refusal.
  function resultOf(job: Job, result: ExecResult): JobResult {
    if (result.aborted) refuse(REFUSED_JOB_CANCELLED)
    if (result.timedOut) refuse(REFUSED_JOB_TOO_LONG)
    const text = result.code === 0 && !result.overflow ? resultText(result.stdout) : null
    if (text === null) {
      const why = result.overflow
        ? 'the output was too large'
        : `exit ${result.code}${result.signal ? ` (${result.signal})` : ''}`
      const stderr = result.stderr.replace(/\s+/g, ' ').trim().slice(0, MAX_LOG_TEXT)
      log(filterSecrets(`A module job of the module ${job.moduleId} failed: ${why}. ${stderr}`))
      refuse(REFUSED_JOB_FAILED)
    }
    if (!job.json) return { text: filterSecrets(text) }
    const parsed = jsonValue(text)
    if (!parsed.ok) refuse(REFUSED_JOB_NOT_JSON)
    return { json: filterSecretValue(parsed.value) }
  }

  // A refusal keeps its code. Each other error goes to the log, and the module gets the code of
  // a failed job.
  function refusalOf(job: Job, error: unknown): Error {
    const message = error instanceof Error ? error.message : ''
    if (message.startsWith('refused: ')) return new Error(message)
    log(filterSecrets(`A module job of the module ${job.moduleId} failed. ${error}`))
    return new Error(REFUSED_JOB_FAILED)
  }

  // The wait timer of a job stays until the job is in the count. An abort (stop, or the end of
  // the wait) ends the job at its next check.
  async function start(job: Job): Promise<void> {
    const abort = new AbortController()
    job.abort = abort
    const notStopped = (): void => {
      if (abort.signal.aborted) refuse(REFUSED_JOB_CANCELLED)
    }
    let dir: string | null = null
    let outcome: { value: JobResult } | { error: Error } | { wait: true }
    try {
      // A first check before the slow steps. The step that counts the job checks again.
      const entry = active(job.moduleId)
      if (entry === null) refuse(REFUSED_MODULE_OFF)
      if (!entry.granted.includes('claude-jobs')) refuse(REFUSED_NOT_ALLOWED)
      const run = await deps.runner()
      notStopped()
      if (run === null) {
        log(`Bifrost can't find Claude Code for a job of the module ${job.moduleId}.`)
        refuse(REFUSED_JOB_FAILED)
      }
      dir = await jobFolder(job.moduleId)
      notStopped()
      const claimed = await claim(job)
      if (claimed.kind === 'wait') {
        outcome = { wait: true }
      } else {
        if (claimed.kind === 'refused') refuse(claimed.code)
        if (claimed.kind === 'bad-model') {
          log(`The saved model of the module ${job.moduleId} is not a model choice.`)
          refuse(REFUSED_JOB_FAILED)
        }
        // The count step marked the job as counted. Only a stop aborts it now.
        if (job.timer !== null) clearTimeout(job.timer)
        job.timer = null
        notStopped()
        const result = await run(jobArgs(claimed.model), {
          cwd: dir,
          input: job.text,
          maxBuffer: JOB_OUTPUT_BYTES,
          signal: abort.signal,
          timeoutMs: JOB_TIMEOUT_MS,
        })
        outcome = { value: resultOf(job, result) }
      }
    } catch (error) {
      outcome = { error: refusalOf(job, error) }
    }
    if (dir !== null) {
      await emptyFolder(dir).catch(error => {
        log(`Bifrost cannot empty the job folder ${dir}. ${error}`)
      })
    }
    if ('wait' in outcome && abort.signal.aborted) {
      outcome = { error: new Error(REFUSED_JOB_CANCELLED) }
    }
    if ('wait' in outcome) {
      // The job waits for a click again. Its wait timer goes on.
      job.state = 'waiting'
      job.abort = null
      deps.changed()
      pump()
      return
    }
    remove(job)
    if ('value' in outcome) job.resolve(outcome.value)
    else job.reject(outcome.error)
    pump()
  }

  // Give a place to each ready job that can have one, in the order of the requests. A ready job
  // with no click goes back to wait when its module that is on lost claude-jobs-auto.
  function pump(): void {
    if (stopped) return
    const running = jobs.filter(job => job.state === 'running')
    const busy = new Set(running.map(job => job.moduleId))
    let free = JOBS_AT_ONCE - running.length
    let back = false
    const next: Job[] = []
    for (const job of jobs) {
      if (job.state !== 'ready') continue
      const entry = active(job.moduleId)
      if (!job.clicked && entry !== null && !entry.granted.includes('claude-jobs-auto')) {
        job.state = 'waiting'
        back = true
        continue
      }
      if (free <= 0 || busy.has(job.moduleId)) continue
      job.state = 'running'
      busy.add(job.moduleId)
      free -= 1
      next.push(job)
    }
    if (back) deps.changed()
    for (const job of next) void start(job)
  }

  // End a job that did not start in time. A job that prepares its start ends at its next check.
  function expire(job: Job): void {
    job.timer = null
    if (!jobs.includes(job)) return
    if (job.state === 'running') {
      if (!job.counted) job.abort?.abort()
      return
    }
    const waited = job.state === 'waiting'
    remove(job)
    job.reject(new Error(REFUSED_JOB_CANCELLED))
    if (waited) deps.changed()
  }

  function run(moduleId: string, req: unknown): Promise<JobResult> {
    try {
      if (stopped) refuse(REFUSED_JOB_CANCELLED)
      const entry = active(moduleId)
      if (entry === null) refuse(REFUSED_MODULE_OFF)
      if (!entry.granted.includes('claude-jobs')) refuse(REFUSED_NOT_ALLOWED)
      const request = parseRequest(req)
      // The jobs that wait also count, so a module cannot queue more jobs than its cap.
      const done = entry.jobs.day === today() ? entry.jobs.count : 0
      if (done + uncounted(moduleId) >= entry.dailyCap) refuse(REFUSED_JOB_CAP)
      const auto = entry.granted.includes('claude-jobs-auto')
      return new Promise<JobResult>((resolve, reject) => {
        const job: Job = {
          abort: null,
          clicked: false,
          counted: false,
          json: request.json,
          moduleId,
          reject,
          resolve,
          state: auto ? 'ready' : 'waiting',
          text: jobText(request),
          timer: null,
        }
        job.timer = setTimeout(() => expire(job), JOB_WAIT_MS)
        jobs.push(job)
        if (!auto) deps.changed()
        pump()
      })
    } catch (error) {
      return Promise.reject(error)
    }
  }

  // A click runs each job of the module that did not start, also a job that waits for a place.
  function refresh(moduleId: string): void {
    if (stopped || active(moduleId) === null) return
    let moved = false
    for (const job of jobs) {
      if (job.moduleId !== moduleId || job.state === 'running') continue
      job.clicked = true
      if (job.state !== 'waiting') continue
      job.state = 'ready'
      moved = true
    }
    if (moved) deps.changed()
    deps.emit(moduleId, 'refresh', null)
    pump()
  }

  function waiting(moduleId: string): number {
    return jobs.filter(job => job.moduleId === moduleId && job.state === 'waiting').length
  }

  // A job that prepares its start is not in the count yet. Its abort ends it at its next check, so
  // it cannot go back to wait. A job in the count runs to its end.
  function cancel(moduleId: string): void {
    let waited = false
    for (const job of [...jobs]) {
      if (job.moduleId !== moduleId) continue
      if (job.state === 'running') {
        if (!job.counted) job.abort?.abort()
        continue
      }
      if (job.state === 'waiting') waited = true
      remove(job)
      job.reject(new Error(REFUSED_JOB_CANCELLED))
    }
    if (waited) deps.changed()
    pump()
  }

  // A running job ends by its abort, and it empties its folder.
  function stop(): void {
    if (stopped) return
    stopped = true
    let waited = false
    for (const job of [...jobs]) {
      if (job.state === 'running') {
        job.abort?.abort()
        continue
      }
      if (job.state === 'waiting') waited = true
      remove(job)
      job.reject(new Error(REFUSED_JOB_CANCELLED))
    }
    if (waited) deps.changed()
  }

  return { cancel, refresh, run, stop, waiting }
}

// Call onDay when the local date changes, for example at midnight. The rows of the modules then
// show the jobs of the new day. A failure of onDay goes to the log. The returned function stops
// the watch.
export function watchLocalDay(
  onDay: () => void,
  opts: { log(message: string): void; now?: () => number },
): () => void {
  const now = opts.now ?? (() => Date.now())
  let day = localDate(new Date(now()))
  let timer: ReturnType<typeof setTimeout> | null = null
  let stopped = false
  const arm = (): void => {
    const time = new Date(now())
    const midnight = new Date(time.getFullYear(), time.getMonth(), time.getDate() + 1).getTime()
    timer = setTimeout(tick, Math.min(Math.max(midnight - time.getTime(), 0), DAY_CHECK_MS))
  }
  const tick = (): void => {
    timer = null
    if (stopped) return
    const next = localDate(new Date(now()))
    if (next !== day) {
      day = next
      try {
        onDay()
      } catch (error) {
        opts.log(`A listener of the local day failed. ${error}`)
      }
    }
    arm()
  }
  arm()
  return () => {
    stopped = true
    if (timer !== null) clearTimeout(timer)
    timer = null
  }
}
