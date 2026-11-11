// The git runner of the repository store.

import type { ExecFn, ExecResult } from '../claude/cli'

// Each git command gets these settings. A repository cannot run a hook or a file monitor.
// Paths stay as they are in the output. gh gives the credentials, and no other helper runs.
// Each -c and its value are two items.
export const GIT_CONFIG: readonly string[] = [
  '-c',
  'core.hooksPath=/dev/null',
  '-c',
  'core.fsmonitor=false',
  '-c',
  'core.quotePath=false',
  '-c',
  'credential.helper=',
  '-c',
  'credential.helper=!gh auth git-credential',
  '-c',
  'advice.detachedHead=false',
]

export const GIT_TIMEOUT_MS = 120_000
export const CLONE_TIMEOUT_MS = 900_000
// The limit of stdout and of stderr. The status of a worktree with many new files can be long.
export const GIT_MAX_BUFFER = 16 * 1024 * 1024

export interface RepoGit {
  run(args: string[], opts?: { cwd?: string; timeoutMs?: number }): Promise<ExecResult>
}

export interface RepoGitDeps {
  exec: ExecFn
  // The env for git. Node finds git through the PATH of this env.
  env(): Promise<Record<string, string>>
}

// Run git with GIT_CONFIG before the arguments. git never asks for a password, and it does not
// download the files of Git LFS.
export function createRepoGit(deps: RepoGitDeps): RepoGit {
  return {
    async run(args, opts) {
      return deps.exec('git', [...GIT_CONFIG, ...args], {
        ...(opts?.cwd === undefined ? {} : { cwd: opts.cwd }),
        env: {
          ...(await deps.env()),
          GCM_INTERACTIVE: 'never',
          GIT_LFS_SKIP_SMUDGE: '1',
          GIT_TERMINAL_PROMPT: '0',
        },
        maxBuffer: GIT_MAX_BUFFER,
        timeoutMs: opts?.timeoutMs ?? GIT_TIMEOUT_MS,
      })
    },
  }
}
