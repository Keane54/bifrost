import { execFile as nodeExecFile } from 'node:child_process'

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

// Ask a login shell for the path of claude. The app does not start from a terminal,
// so its PATH can miss the folder of claude.
export async function resolveClaudePath(exec: ExecFn, shell?: string): Promise<string | null> {
  const sh = shell ?? process.env.SHELL ?? '/bin/zsh'
  const result = await exec(sh, ['-lc', 'command -v claude'], { timeoutMs: 5000 })
  if (result.code !== 0) return null
  const path = result.stdout.trim().split('\n').pop()?.trim() ?? ''
  return path.startsWith('/') ? path : null
}

export type RunClaude = (
  args: string[],
  opts?: { cwd?: string; timeoutMs?: number }
) => Promise<ExecResult>

export function createRunClaude(exec: ExecFn, claudePath: string): RunClaude {
  return (args, opts) => exec(claudePath, args, opts)
}
