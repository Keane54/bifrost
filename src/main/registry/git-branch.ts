import type { ExecFn } from '../claude/cli'

// Read the branch name of a directory. Return null when git fails.
export async function readBranch(exec: ExecFn, cwd: string): Promise<string | null> {
  const result = await exec('git', ['-C', cwd, 'rev-parse', '--abbrev-ref', 'HEAD'], {
    timeoutMs: 2000,
  })
  return result.code === 0 ? result.stdout.trim() : null
}
