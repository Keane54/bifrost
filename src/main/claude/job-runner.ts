// The runner of the module jobs of the modules (plan Task 7). It is the only claude run that gets
// stdin, so no text of a module is an argument of claude. claude starts in its own process group.
// At the timeout, at an abort and at the output limit, SIGKILL stops the whole group, so no child
// of claude stays. A job writes no file that it can leave half done.

import { spawn as nodeSpawn } from 'node:child_process'
import { childEnv } from '../child-env'
import type { ExecResult } from './cli'

// After the kill of the group, the run ends after this time also when a pipe stays open.
export const JOB_KILL_GRACE_MS = 2_000
// The stderr of a run that an abort stopped before it started.
const ABORTED_TEXT = 'Bifrost stopped the program.'

// The options of a module job. Each one is required.
export interface JobRunOptions {
  cwd: string
  // The text of the job on stdin.
  input: string
  timeoutMs: number
  // The limit of stdout and of stderr in bytes.
  maxBuffer: number
  signal: AbortSignal
}

export type RunClaudeJob = (args: string[], opts: JobRunOptions) => Promise<ExecResult>

// The parts of Node that the runner uses. A test gives fakes.
export interface JobProcessDeps {
  spawn: typeof nodeSpawn
  kill(pid: number, signal: NodeJS.Signals): void
}

const NODE_DEPS: JobProcessDeps = {
  kill: (pid, signal) => {
    process.kill(pid, signal)
  },
  spawn: nodeSpawn,
}

// Each job gets the clean child env, made from baseEnv (the login-shell env). The promise never
// rejects.
export function createRunClaudeJob(
  claudePath: string,
  baseEnv: NodeJS.ProcessEnv,
  deps: JobProcessDeps = NODE_DEPS,
): RunClaudeJob {
  return (args, opts) =>
    new Promise(resolve => {
      if (opts.signal.aborted) {
        resolve({ aborted: true, code: 1, stderr: ABORTED_TEXT, stdout: '' })
        return
      }
      let child: ReturnType<typeof nodeSpawn>
      try {
        // detached makes claude the leader of a new process group.
        child = deps.spawn(claudePath, args, {
          cwd: opts.cwd,
          detached: true,
          env: childEnv(baseEnv, { pty: false }),
          stdio: ['pipe', 'pipe', 'pipe'],
        })
      } catch (error) {
        resolve({ code: 1, stderr: String(error), stdout: '' })
        return
      }
      const out: Buffer[] = []
      const err: Buffer[] = []
      let outBytes = 0
      let errBytes = 0
      let stopped: 'timedOut' | 'aborted' | 'overflow' | null = null
      let done = false
      let graceTimer: ReturnType<typeof setTimeout> | undefined

      const finish = (code: number | null, signal: string | null): void => {
        if (done) return
        done = true
        clearTimeout(timer)
        clearTimeout(graceTimer)
        opts.signal.removeEventListener('abort', onAbort)
        const result: ExecResult = {
          code: code ?? 1,
          stderr: Buffer.concat(err).toString('utf8'),
          stdout: Buffer.concat(out).toString('utf8'),
        }
        if (stopped !== null) result[stopped] = true
        else if (code === null && signal !== null) result.signal = signal
        resolve(result)
      }

      // Kill the whole group: the negative pid is the id of the group.
      const stopGroup = (why: 'timedOut' | 'aborted' | 'overflow'): void => {
        if (stopped !== null || done) return
        stopped = why
        if (child.pid !== undefined) {
          try {
            deps.kill(-child.pid, 'SIGKILL')
          } catch {
            // The group is gone.
          }
        }
        graceTimer = setTimeout(() => finish(null, 'SIGKILL'), JOB_KILL_GRACE_MS)
      }

      const timer = setTimeout(() => stopGroup('timedOut'), opts.timeoutMs)
      function onAbort(): void {
        stopGroup('aborted')
      }
      opts.signal.addEventListener('abort', onAbort, { once: true })

      child.stdout?.on('data', (chunk: Buffer) => {
        outBytes += chunk.length
        if (outBytes > opts.maxBuffer) stopGroup('overflow')
        else out.push(chunk)
      })
      child.stderr?.on('data', (chunk: Buffer) => {
        errBytes += chunk.length
        if (errBytes > opts.maxBuffer) stopGroup('overflow')
        else err.push(chunk)
      })
      child.on('error', error => {
        if (done) return
        done = true
        clearTimeout(timer)
        clearTimeout(graceTimer)
        opts.signal.removeEventListener('abort', onAbort)
        resolve({ code: 1, stderr: error.message, stdout: '' })
      })
      child.on('close', (code: number | null, signal: string | null) => finish(code, signal))
      // claude can end before it reads stdin. The write then fails with EPIPE. The close event
      // gives the result, so this error has no other effect.
      child.stdin?.on('error', () => undefined)
      child.stdin?.end(opts.input)
    })
}
