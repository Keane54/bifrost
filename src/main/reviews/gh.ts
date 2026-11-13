// The GitHub CLI (gh) runner of the Reviews feature.

import {
  REASON_GH_FAILED,
  REASON_GH_LOGGED_OUT,
  REASON_GH_MISSING,
  REASON_GH_OVERFLOW,
  REASON_GH_TIMEOUT,
} from '../../shared/reviews'
import type { ExecFn, ExecResult } from '../claude/cli'

export const GH_TIMEOUT_MS = 30_000
export const GH_MAX_BUFFER = 16 * 1024 * 1024
export const MESSAGE_MAX = 200
// gh gives exit code 4 when the user is not logged in.
export const EXIT_AUTH = 4

export interface Gh {
  // input goes to the stdin of gh, for example for --input -.
  run(
    args: string[],
    opts?: { cwd?: string; timeoutMs?: number; input?: string },
  ): Promise<ExecResult>
}

export interface GhDeps {
  exec: ExecFn
  // The env for gh. Node finds gh through the PATH of this env.
  env(): Promise<Record<string, string>>
}

export function createGh(deps: GhDeps): Gh {
  return {
    async run(args, opts) {
      return deps.exec('gh', args, {
        ...(opts?.cwd === undefined ? {} : { cwd: opts.cwd }),
        env: await deps.env(),
        ...(opts?.input === undefined ? {} : { input: opts.input }),
        maxBuffer: GH_MAX_BUFFER,
        timeoutMs: opts?.timeoutMs ?? GH_TIMEOUT_MS,
      })
    },
  }
}

// detail is the raw first line of gh. Only the raw-line case sets it.
export type GhFailure = {
  availability: 'no-gh' | 'logged-out' | 'error'
  message: string
  detail?: string
}

// Give null when gh ended well. Else say why it failed.
export function ghFailure(result: ExecResult): GhFailure | null {
  if (result.code === 0 && !result.timedOut) return null
  if (result.timedOut) return { availability: 'error', message: REASON_GH_TIMEOUT }
  if (result.overflow) return { availability: 'error', message: REASON_GH_OVERFLOW }
  if (result.stderr.includes('ENOENT')) {
    return { availability: 'no-gh', message: REASON_GH_MISSING }
  }
  if (result.code === EXIT_AUTH || result.stderr.includes('gh auth login')) {
    return { availability: 'logged-out', message: REASON_GH_LOGGED_OUT }
  }
  const line = result.stderr.trim().split('\n')[0]?.trim().slice(0, MESSAGE_MAX)
  if (!line) return { availability: 'error', message: REASON_GH_FAILED }
  return { availability: 'error', detail: line, message: line }
}
