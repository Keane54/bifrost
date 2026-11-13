import type { spawn as nodeSpawn } from 'node:child_process'
import { childEnv } from '../child-env'

export const KILL_GRACE_MS = 2_000

export type SpawnLines = (
  args: string[],
  opts: { cwd: string; timeoutMs: number; onLine(line: string): boolean; signal?: AbortSignal },
) => Promise<{ stopped: boolean; timedOut: boolean; code: number | null; aborted?: true }>

// Make a function that runs claude and gives each stdout line to onLine.
// When onLine returns true, the child gets SIGTERM and no more lines go to onLine.
// At the time limit, the child gets SIGTERM and timedOut is true.
// The stdin is closed: claude adds piped stdin to the prompt.
// The promise ends when the child ends. It never rejects.
// If the child does not end KILL_GRACE_MS after the SIGTERM, it gets SIGKILL and the promise
// ends at once, also when the stdout pipe is still open.
// An abort of opts.signal stops the child in the same way, and no more lines go to onLine. The
// result then has aborted true. With a signal that is aborted before, no child starts.
export function createSpawnLines(
  spawn: typeof nodeSpawn,
  claudePath: string,
  baseEnv: NodeJS.ProcessEnv,
): SpawnLines {
  return (args, opts) =>
    new Promise(resolve => {
      const { signal } = opts
      if (signal?.aborted) {
        resolve({ aborted: true, code: null, stopped: false, timedOut: false })
        return
      }
      let stopped = false
      let aborted = false
      let timedOut = false
      let done = false
      let buffer = ''
      let graceTimer: ReturnType<typeof setTimeout> | undefined
      let timer: ReturnType<typeof setTimeout> | undefined
      let child: ReturnType<typeof nodeSpawn>
      try {
        child = spawn(claudePath, args, {
          cwd: opts.cwd,
          env: childEnv(baseEnv, { pty: false }),
          stdio: ['ignore', 'pipe', 'ignore'],
        })
      } catch {
        resolve({ code: null, stopped, timedOut })
        return
      }
      const finish = (code: number | null) => {
        if (done) return
        done = true
        clearTimeout(timer)
        clearTimeout(graceTimer)
        signal?.removeEventListener('abort', onAbort)
        resolve(aborted ? { aborted, code, stopped, timedOut } : { code, stopped, timedOut })
      }
      const stop = () => {
        child.kill('SIGTERM')
        if (graceTimer !== undefined) return
        graceTimer = setTimeout(() => {
          child.kill('SIGKILL')
          finish(null)
        }, KILL_GRACE_MS)
      }
      timer = setTimeout(() => {
        timedOut = true
        stop()
      }, opts.timeoutMs)
      function onAbort(): void {
        aborted = true
        stop()
      }
      signal?.addEventListener('abort', onAbort, { once: true })
      const give = (line: string) => {
        if (stopped || aborted || line === '') return
        if (opts.onLine(line)) {
          stopped = true
          stop()
        }
      }
      child.stdout?.setEncoding('utf8')
      child.stdout?.on('data', (chunk: string) => {
        buffer += chunk
        let index = buffer.indexOf('\n')
        while (index !== -1) {
          give(buffer.slice(0, index).replace(/\r$/, ''))
          buffer = buffer.slice(index + 1)
          index = buffer.indexOf('\n')
        }
      })
      child.stdout?.on('end', () => {
        give(buffer.replace(/\r$/, ''))
        buffer = ''
      })
      child.on('error', () => finish(null))
      child.on('close', code => finish(code))
    })
}
