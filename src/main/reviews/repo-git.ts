// The git runner of the repository store.

import type { ExecFn, ExecResult } from '../claude/cli'

// Each git command gets these settings. A repository cannot run a hook or a file monitor.
// Paths stay as they are in the output. gh gives the credentials, and no other helper runs.
// A symbolic link of a PR becomes a plain file that holds the link text, so a session that
// reads its worktree cannot follow a link out of it. git does not go into submodules.
// The settings apply to each command, so they also apply to a clone made before a change here.
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
  '-c',
  'core.symlinks=false',
  '-c',
  'submodule.recurse=false',
]

export const GIT_TIMEOUT_MS = 120_000
export const CLONE_TIMEOUT_MS = 900_000
// The limit of stdout and of stderr. The status of a worktree with many new files can be long.
export const GIT_MAX_BUFFER = 16 * 1024 * 1024

// The GIT_ variables that stay in the env. A test home sets them, so that git reads no git config
// of the user. Each other GIT_ variable goes, because it can point git at another repository,
// index or object folder, add config, or write a trace.
const KEEP_GIT_VARS: readonly string[] = ['GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM']

function cleanEnv(env: Record<string, string>): Record<string, string> {
  return Object.fromEntries(
    Object.entries(env).filter(
      ([name]) => !name.startsWith('GIT_') || KEEP_GIT_VARS.includes(name),
    ),
  )
}

export interface RepoGit {
  run(args: string[], opts?: { cwd?: string; timeoutMs?: number }): Promise<ExecResult>
}

export interface RepoGitDeps {
  exec: ExecFn
  // The env for git. Node finds git through the PATH of this env.
  env(): Promise<Record<string, string>>
}

// Run git with GIT_CONFIG before the arguments. git never asks for a password, and it does not
// download the files of Git LFS. Of the GIT_ variables of the env, only KEEP_GIT_VARS stay.
export function createRepoGit(deps: RepoGitDeps): RepoGit {
  return {
    async run(args, opts) {
      return deps.exec('git', [...GIT_CONFIG, ...args], {
        ...(opts?.cwd === undefined ? {} : { cwd: opts.cwd }),
        env: {
          ...cleanEnv(await deps.env()),
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
