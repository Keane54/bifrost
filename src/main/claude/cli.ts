import { execFile as nodeExecFile } from 'node:child_process'
import { accessSync, constants } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { childEnv } from '../child-env'

// timedOut is true only when the timeout stopped the program.
// overflow is true only when Node stopped the program at the maxBuffer limit.
export type ExecResult = {
  code: number
  stdout: string
  stderr: string
  timedOut?: boolean
  overflow?: boolean
}
// The Node error code when stdout or stderr is longer than maxBuffer.
const MAXBUFFER_CODE = 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER'
// The signal that stops a program at the timeout.
export type KillSignal = 'SIGKILL' | 'SIGTERM'
export type ExecFn = (
  file: string,
  args: string[],
  opts?: {
    cwd?: string
    timeoutMs?: number
    env?: Record<string, string>
    killSignal?: KillSignal
    // The limit of stdout and of stderr in bytes. The default is the default of Node.
    maxBuffer?: number
    // The text for stdin. Only gh gets it. A claude run never gets it (see execFile).
    input?: string
  },
) => Promise<ExecResult>

const DEFAULT_TIMEOUT_MS = 10000

// Run a program. This function never rejects.
// A spawn error, a timeout or a non-zero exit all give an ExecResult.
// Without opts.env, the program gets the env of the app.
// At the timeout, SIGKILL stops the program. A program can ignore SIGTERM, but not SIGKILL.
// So a hung program cannot stop a poll.
// opts.killSignal SIGTERM lets the program stop its work cleanly. Use it only for a command
// that a SIGKILL can leave half done. Node then waits until the program ends, so the caller
// must also set its own limit.
// The program gets an empty, closed stdin. claude adds piped stdin to the prompt (spec 8).
// A program that reads stdin then gets the end of the input at once. It does not wait.
// With opts.input, the program gets that text on stdin, then the end of the input.
export const execFile: ExecFn = (file, args, opts) =>
  new Promise(resolve => {
    const child = nodeExecFile(
      file,
      args,
      {
        cwd: opts?.cwd,
        encoding: 'utf8',
        env: opts?.env,
        killSignal: opts?.killSignal ?? 'SIGKILL',
        maxBuffer: opts?.maxBuffer,
        timeout: opts?.timeoutMs ?? DEFAULT_TIMEOUT_MS,
      },
      (error, stdout, stderr) => {
        if (!error) {
          resolve({ code: 0, stderr, stdout })
          return
        }
        // Node sets killed when it sent the kill signal at the timeout.
        // A program can exit with a code after SIGTERM. The timeout still stopped it.
        const killed = (error as { killed?: boolean }).killed === true
        const code = (error as NodeJS.ErrnoException).code
        if (typeof code === 'number') {
          const result: ExecResult = { code, stderr, stdout }
          if (killed) result.timedOut = true
          resolve(result)
          return
        }
        // No exit code: the program did not start, a signal ended it, or Node stopped it at
        // the maxBuffer limit.
        const result: ExecResult = { code: 1, stderr: stderr || error.message, stdout }
        if (code === MAXBUFFER_CODE) result.overflow = true
        else if (killed) result.timedOut = true
        resolve(result)
      },
    )
    if (opts?.input === undefined) {
      child.stdin?.end()
      return
    }
    // The program can end before it reads stdin. The write then fails with EPIPE. The callback
    // gives the result of the program, so this error has no other effect.
    child.stdin?.on('error', () => undefined)
    child.stdin?.end(opts.input)
  })

// True when the file exists and the user can run it.
export function defaultIsExecutable(path: string): boolean {
  try {
    accessSync(path, constants.X_OK)
    return true
  } catch {
    return false
  }
}

// Ask an interactive login shell for the path of claude.
// The app can start from Finder or the Dock, so its PATH can miss the folder of claude.
// A login shell without -i does not read .zshrc, and .zshrc can add that folder.
// If the shell does not give a valid path, use the first executable known path.
export async function resolveClaudePath(
  exec: ExecFn,
  shell?: string,
  isExecutable: (path: string) => boolean = defaultIsExecutable,
): Promise<string | null> {
  const sh = shell ?? process.env.SHELL ?? '/bin/zsh'
  const result = await exec(sh, ['-lic', 'command -v claude'], { timeoutMs: 5000 })
  if (result.code === 0) {
    // An interactive shell can print extra text. The path is on the last line.
    const path = result.stdout.trim().split('\n').pop()?.trim() ?? ''
    if (path.startsWith('/')) return path
  }
  const fallbacks = [
    join(homedir(), '.local/bin/claude'),
    '/opt/homebrew/bin/claude',
    '/usr/local/bin/claude',
  ]
  return fallbacks.find(p => isExecutable(p)) ?? null
}

export type RunClaude = (
  args: string[],
  opts?: { cwd?: string; timeoutMs?: number; killSignal?: KillSignal },
) => Promise<ExecResult>

// Each claude run gets the clean child env, made from baseEnv.
// baseEnv is the login-shell env.
// A claude run has no TTY, so the env does not set TERM or COLORTERM.
export function createRunClaude(
  exec: ExecFn,
  claudePath: string,
  baseEnv: NodeJS.ProcessEnv,
): RunClaude {
  return (args, opts) => {
    // claude adds piped stdin to the prompt. So a claude run never gets input, also when a
    // caller passes a wider object.
    const { input: _input, ...rest } = (opts ?? {}) as NonNullable<Parameters<ExecFn>[2]>
    return exec(claudePath, args, { ...rest, env: childEnv(baseEnv, { pty: false }) })
  }
}
