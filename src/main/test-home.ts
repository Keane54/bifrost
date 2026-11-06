// The test home (D12, D25). With BIFROST_TEST_HOME=<absolute folder>, Bifrost keeps its files,
// the Live details socket, the mod folder and the Claude settings under that folder. A check can
// then click Install or Remove of Live details, and the real home of the user does not change.

import { realpathSync } from 'node:fs'
import { isAbsolute, join, normalize, sep } from 'node:path'

export const TEST_HOME_ENV = 'BIFROST_TEST_HOME'

export interface TestHome {
  home: string
  userData: string
}

// How testHomeConfig compares two paths. A test can give its own values.
export interface PathCheck {
  // On darwin, the file system ignores the case of a path. So the compare ignores it too.
  platform: NodeJS.Platform
  // The real path of a path that exists, with each symbolic link resolved. Else null.
  realpath(path: string): string | null
}

const DEFAULT_CHECK: PathCheck = {
  platform: process.platform,
  realpath: path => {
    try {
      return realpathSync.native(path)
    } catch {
      return null
    }
  },
}

// Remove a trailing separator, but keep the root "/".
function trimSlash(path: string): string {
  return path.length > 1 && path.endsWith(sep) ? path.slice(0, -1) : path
}

// True when home is "/", the real home or a parent of the real home.
function holdsRealHome(home: string, real: string, ignoreCase: boolean): boolean {
  const h = ignoreCase ? home.toLowerCase() : home
  const r = ignoreCase ? real.toLowerCase() : real
  return h === sep || h === r || r.startsWith(h + sep)
}

// Read the test home from the env. No value gives null.
// The value must be an absolute path. Bifrost refuses "/", the real home and a parent of the
// real home, because the test home must never hold the real files of the user. The check uses
// the path as given and the real path of each path that exists. So a symbolic link to the real
// home is refused too. A refused value also gives null.
export function testHomeConfig(
  env: Record<string, string | undefined>,
  realHome: string,
  check: PathCheck = DEFAULT_CHECK,
): TestHome | null {
  const value = env[TEST_HOME_ENV]
  if (value === undefined || value === '' || !isAbsolute(value)) return null
  const home = trimSlash(normalize(value))
  const real = trimSlash(normalize(realHome))
  const homes = [home, trimSlash(check.realpath(home) ?? home)]
  const reals = [real, trimSlash(check.realpath(real) ?? real)]
  const ignoreCase = check.platform === 'darwin'
  if (homes.some(h => reals.some(r => holdsRealHome(h, r, ignoreCase)))) return null
  return { home, userData: join(home, 'user-data') }
}

// The value of BIFROST_TEST_HOME when testHomeConfig refuses it, else null. Bifrost then does not
// start, so a check never uses the real home by mistake. A variable that is set but empty is
// refused too.
export function refusedTestHome(
  env: Record<string, string | undefined>,
  realHome: string,
  check: PathCheck = DEFAULT_CHECK,
): string | null {
  const value = env[TEST_HOME_ENV]
  if (value === undefined) return null
  return testHomeConfig(env, realHome, check) === null ? value : null
}

// The error line for a refused value. An empty value shows as "(empty)".
export function testHomeError(value: string): string {
  const shown = value === '' ? '(empty)' : value
  return `Bifrost can't use the test home ${shown}. Use an absolute folder that isn't /, your home folder or a parent of it.`
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
