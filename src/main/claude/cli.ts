import { execFile as nodeExecFile } from 'node:child_process'
import { accessSync, constants } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export type ExecResult = { code: number; stdout: string; stderr: string }
export type ExecFn = (
  file: string,
  args: string[],
  opts?: { cwd?: string; timeoutMs?: number }
) => Promise<ExecResult>

const DEFAULT_TIMEOUT_MS = 10000

// Run a program. This function never rejects.
// A spawn error, a timeout or a non-zero exit all give an ExecResult.
export const execFile: ExecFn = (file, args, opts) =>
  new Promise((resolve) => {
    nodeExecFile(
      file,
      args,
      { cwd: opts?.cwd, timeout: opts?.timeoutMs ?? DEFAULT_TIMEOUT_MS, encoding: 'utf8' },
      (error, stdout, stderr) => {
        if (!error) {
          resolve({ code: 0, stdout, stderr })
          return
        }
        const code = (error as NodeJS.ErrnoException).code
        if (typeof code === 'number') {
          resolve({ code, stdout, stderr })
          return
        }
        // No exit code: the program did not start, or a signal ended it.
        resolve({ code: 1, stdout, stderr: stderr || error.message })
      }
    )
  })

function defaultIsExecutable(path: string): boolean {
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
  isExecutable: (path: string) => boolean = defaultIsExecutable
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
    '/usr/local/bin/claude'
  ]
  return fallbacks.find((p) => isExecutable(p)) ?? null
}

export type RunClaude = (
  args: string[],
  opts?: { cwd?: string; timeoutMs?: number }
) => Promise<ExecResult>

export function createRunClaude(exec: ExecFn, claudePath: string): RunClaude {
  return (args, opts) => exec(claudePath, args, opts)
}
