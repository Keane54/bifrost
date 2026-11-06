// The test home (D12, D25). With BIFROST_TEST_HOME=<absolute folder>, Bifrost keeps its files,
// the Live details socket, the mod folder and the Claude settings under that folder. A check can
// then click Install or Remove of Live details, and the real home of the user does not change.

import { isAbsolute, join, normalize, sep } from 'node:path'

export const TEST_HOME_ENV = 'BIFROST_TEST_HOME'

export interface TestHome {
  home: string
  userData: string
}

// Remove a trailing separator, but keep the root "/".
function trimSlash(path: string): string {
  return path.length > 1 && path.endsWith(sep) ? path.slice(0, -1) : path
}

// Read the test home from the env. No value gives null.
// The value must be an absolute path. Bifrost refuses "/", the real home and a parent of the
// real home, because the test home must never hold the real files of the user. A refused value
// also gives null.
export function testHomeConfig(
  env: Record<string, string | undefined>,
  realHome: string,
): TestHome | null {
  const value = env[TEST_HOME_ENV]
  if (value === undefined || value === '' || !isAbsolute(value)) return null
  const home = trimSlash(normalize(value))
  const real = trimSlash(normalize(realHome))
  if (home === sep || home === real || real.startsWith(home + sep)) return null
  return { home, userData: join(home, 'user-data') }
}

// The value of BIFROST_TEST_HOME when testHomeConfig refuses it, else null. Bifrost then does not
// start, so a check never uses the real home by mistake.
export function refusedTestHome(
  env: Record<string, string | undefined>,
  realHome: string,
): string | null {
  const value = env[TEST_HOME_ENV]
  if (value === undefined || value === '') return null
  return testHomeConfig(env, realHome) === null ? value : null
}

// Find the first executable <dir>/<name> in the PATH value. Only an absolute directory counts.
export function findOnPath(
  name: string,
  pathEnv: string | undefined,
  isExecutable: (path: string) => boolean,
): string | null {
  for (const dir of (pathEnv ?? '').split(':')) {
    if (!isAbsolute(dir)) continue
    const path = join(dir, name)
    if (isExecutable(path)) return path
  }
  return null
}

// The env of a "claude plugin" command (D25). In a test home, the command gets HOME and
// CLAUDE_CONFIG_DIR of the test home, so it writes only under the test home. Without a test
// home, the function gives the same object. It never changes base.
export function pluginEnv(
  base: Record<string, string>,
  testHome: TestHome | null,
): Record<string, string> {
  if (testHome === null) return base
  return { ...base, CLAUDE_CONFIG_DIR: join(testHome.home, '.claude'), HOME: testHome.home }
}
