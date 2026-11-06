import type { ClaudeVersion } from '../../shared/types'
import type { RunClaude } from './cli'

export const MIN_CLAUDE_VERSION = '2.1.281'

// Find the version number in the output of `claude --version`.
export function parseClaudeVersion(stdout: string): string | null {
  return /\d+\.\d+\.\d+/.exec(stdout)?.[0] ?? null
}

// Compare two versions part by part as numbers.
// The result is below 0, 0 or above 0.
export function compareVersions(a: string, b: string): number {
  const pa = a.split('.').map(Number)
  const pb = b.split('.').map(Number)
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const diff = (pa[i] ?? 0) - (pb[i] ?? 0)
    if (diff !== 0) return diff
  }
  return 0
}

// Compare the version of claude with the minimum. A feature can give a higher minimum.
export async function checkClaudeVersion(
  run: RunClaude,
  minimum = MIN_CLAUDE_VERSION,
): Promise<ClaudeVersion> {
  const result = await run(['--version'], { timeoutMs: 5000 })
  const version = result.code === 0 ? parseClaudeVersion(result.stdout) : null
  return {
    minimum,
    ok: version !== null && compareVersions(version, minimum) >= 0,
    version,
  }
}
